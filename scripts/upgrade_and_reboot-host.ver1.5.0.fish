#!/usr/bin/env fish
#
# Proxmox Host Upgrade & Reboot Script
# Version: 1.5.0
# Description: Automates apt update/full-upgrade and autoremove with file logging,
#              --dry-run simulation, and end-of-run email notifications via sendmail.

argparse 'd/dry-run' 'm/mail-to=' 'h/help' -- $argv; or exit 1

if set -q _flag_help
    echo "Usage: "(status filename)" [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -d, --dry-run         Simulate upgrade, check reboot conditions, and preview"
    echo "                        shutdown targets and email without making changes"
    echo "  -m, --mail-to EMAIL   Recipient email address (default: 'root', routed via"
    echo "                        Proxmox VE Datacenter -> Notifications)"
    echo "  -h, --help            Show this help message and exit"
    exit 0
end

set -l dry_run 0
if set -q _flag_dry_run
    set dry_run 1
end

# Default recipient 'noc@rimpianto.com' triggers Proxmox VE's built-in notification forwarding
set -l mail_to "noc@rimpianto.com"
if set -q _flag_mail_to
    set mail_to "$_flag_mail_to"
end

# Logging setup (falls back to /tmp if invoked as non-root during dry-run)
set -gx LOG_FILE "/var/log/pve-auto-upgrade.log"
if not touch "$LOG_FILE" 2>/dev/null
    set -gx LOG_FILE "/tmp/pve-auto-upgrade.log"
    echo "Warning: Cannot write to /var/log/pve-auto-upgrade.log, logging to $LOG_FILE"
end

set -gx RUN_LOG_FILE (mktemp /tmp/pve-upgrade-run.XXXXXX)

function log_msg
    set -l ts (date '+%Y-%m-%d %H:%M:%S')
    set -l line "[$ts] $argv"
    echo "$line"
    if set -q RUN_LOG_FILE; and test -f "$RUN_LOG_FILE"
        echo "$line" >> "$RUN_LOG_FILE"
    end
end

function send_notification --argument-names recipient subject body_file dry_run
    if test "$dry_run" -eq 1
        log_msg "[DRY-RUN] Would send email to '$recipient' | Subject: '$subject'"
        return 0
    end

    set -l sendmail_bin (command -v sendmail; or echo "/usr/sbin/sendmail")
    if not test -x "$sendmail_bin"
        log_msg "WARNING: '$sendmail_bin' not found. Skipping email notification."
        return 1
    end

    set -l host (hostname)

    begin
        echo "To: $recipient"
        echo "From: Proxmox Auto-Upgrade <root@$host>"
        echo "Subject: $subject"
        echo "Content-Type: text/plain; charset=UTF-8"
        echo ""
        cat "$body_file"
    end | $sendmail_bin -t

    if test $status -eq 0
        log_msg "Notification email sent to '$recipient'."
    else
        log_msg "WARNING: Failed to send notification email to '$recipient'."
    end
end

function run_upgrade --argument-names dry_run mail_to
    set -l host (hostname)

    if test "$dry_run" -eq 1
        log_msg "=== Proxmox Upgrade & Reboot Script v1.5.0 [DRY-RUN MODE] ==="
        log_msg "Simulation active: no packages will be modified and no guests/host will be stopped."
    else
        log_msg "=== Proxmox Upgrade & Reboot Script v1.5.0 ==="
    end

    # 1. APT Update & Full-Upgrade
    log_msg "=== Step 1: Updating Proxmox ==="
    if test "$dry_run" -eq 1
        log_msg "[DRY-RUN] Skipping 'apt update' and 'apt full-upgrade -y'."
    else
        set -gx DEBIAN_FRONTEND noninteractive
        set -gx NEEDRESTART_MODE l

        apt update; or begin
            log_msg "ERROR: 'apt update' failed. Aborting."
            send_notification "$mail_to" "[$host] Proxmox Upgrade: ERRORE durante apt update" "$RUN_LOG_FILE" "$dry_run"
            return 1
        end

        apt -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" full-upgrade -y; or begin
            log_msg "ERROR: 'apt full-upgrade' failed. Aborting."
            send_notification "$mail_to" "[$host] Proxmox Upgrade: ERRORE durante apt full-upgrade" "$RUN_LOG_FILE" "$dry_run"
            return 1
        end
    end

    # 2. Cleanup
    log_msg "=== Step 2: Cleaning up unused packages ==="
    if test "$dry_run" -eq 1
        log_msg "[DRY-RUN] Skipping 'apt autoremove -y'."
    else
        apt autoremove -y
    end

    # 3. Reboot Detection
    log_msg "=== Step 3: Checking if reboot is required ==="
    set -l need_reboot 0
    set -l reboot_reason ""

    # Check A: Standard Debian flag file
    set -l has_reboot_file "no"
    if test -f /var/run/reboot-required
        set has_reboot_file "yes"
        set need_reboot 1
        set reboot_reason "/var/run/reboot-required found"
    end

    # Check B: needrestart batch output for kernel (KSTA) or microcode (UCSTA)
    set -l nr_summary "not installed"
    if type -q needrestart
        set -l nr_lines (needrestart -b 2>/dev/null | grep -E 'NEEDRESTART-(KSTA|UCSTA|VER)')
        if test (count $nr_lines) -gt 0
            set nr_summary (string join " | " $nr_lines)
        else
            set nr_summary "no output (requires root privileges?)"
        end

        if test $need_reboot -eq 0; and string match -rq 'NEEDRESTART-(KSTA|UCSTA):\s*[23]' -- $nr_lines
            set need_reboot 1
            set reboot_reason "needrestart detected pending kernel/microcode update"
        end
    end

    # Check C: Running kernel vs latest installed kernel in /boot
    set -l running_kernel (uname -r)
    set -l vmlinuz_files /boot/vmlinuz-*
    set -l latest_kernel ""
    if test (count $vmlinuz_files) -gt 0
        set latest_kernel (printf '%s\n' $vmlinuz_files | sort -V | tail -n 1 | string replace '/boot/vmlinuz-' '')
    end

    if test $need_reboot -eq 0; and test -n "$latest_kernel"; and test "$running_kernel" != "$latest_kernel"
        set need_reboot 1
        set reboot_reason "running kernel ($running_kernel) differs from installed ($latest_kernel)"
    end

    if test "$dry_run" -eq 1
        log_msg "[DRY-RUN] Reboot detection diagnostics:"
        log_msg "  - /var/run/reboot-required : $has_reboot_file"
        log_msg "  - needrestart (-b)         : $nr_summary"
        log_msg "  - Kernel (running / boot)  : $running_kernel / $latest_kernel"
    end

    # 4. Guest Shutdown & Host Reboot Sequence
    if test $need_reboot -eq 1
        log_msg "Reboot required ($reboot_reason). Proceeding with shutdown sequence."

        set -l target_lxcs (pct list | awk '$2 == "running" && $1 != "205" {print $1}')
        set -l target_vms (qm list | awk '$2 == "running" {print $1}')

        if test "$dry_run" -eq 1
            log_msg "[DRY-RUN] Would shut down LXC containers (excluding 205): "(test (count $target_lxcs) -gt 0; and string join ", " $target_lxcs; or echo "none")
            log_msg "[DRY-RUN] Would shut down QEMU VMs: "(test (count $target_vms) -gt 0; and string join ", " $target_vms; or echo "none")
            log_msg "[DRY-RUN] Would wait up to 180s for guests to stop, send email, and execute 'reboot'."
            send_notification "$mail_to" "[$host] Proxmox Upgrade: Reboot avviato ($latest_kernel)" "$RUN_LOG_FILE" "$dry_run"
            return 0
        end

        log_msg "=== Starting LXC containers shutdown (excluding 205) ==="
        for vmid in $target_lxcs
            log_msg "Sending shutdown signal to LXC container: $vmid"
            pct shutdown $vmid
        end

        log_msg "=== Starting QEMU virtual machines shutdown ==="
        for vmid in $target_vms
            log_msg "Sending shutdown signal to VM: $vmid"
            qm shutdown $vmid
        end

        log_msg "=== Waiting for all shutdown tasks to complete ==="
        set -l max_wait 60
        set -l count 0

        while true
            set -l running_lxc (pct list | awk '$2 == "running" && $1 != "205" {print $1}')
            set -l running_vm (qm list | awk '$2 == "running" {print $1}')

            if test (count $running_lxc) -eq 0; and test (count $running_vm) -eq 0
                log_msg "All targeted guests are down."
                break
            end

            if test $count -ge $max_wait
                log_msg "ERROR: Timeout reached after 180s. Still running - LXC: [$running_lxc], VM: [$running_vm]."
                log_msg "Aborting automatic reboot to prevent data corruption."
                send_notification "$mail_to" "[$host] Proxmox Upgrade: ERRORE timeout spegnimento guest" "$RUN_LOG_FILE" "$dry_run"
                return 1
            end

            log_msg "Waiting for guests to shut down... (LXC: [$running_lxc] | VM: [$running_vm])"
            set count (math $count + 1)
            sleep 3
        end

        log_msg "=== Sending pre-reboot report & rebooting host ==="
        send_notification "$mail_to" "[$host] Proxmox Upgrade: Reboot avviato ($latest_kernel)" "$RUN_LOG_FILE" "$dry_run"
        sleep 5
        reboot
    else
        log_msg "No reboot is necessary. Upgrade complete!"
        send_notification "$mail_to" "[$host] Proxmox Upgrade: Completato (nessun reboot)" "$RUN_LOG_FILE" "$dry_run"
    end

    return 0
end

run_upgrade "$dry_run" "$mail_to" 2>&1 | tee -a "$LOG_FILE"
set -l exit_code $pipestatus[1]

test -f "$RUN_LOG_FILE"; and rm -f "$RUN_LOG_FILE"
exit $exit_code

