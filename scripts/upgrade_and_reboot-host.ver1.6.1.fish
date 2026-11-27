#!/usr/bin/env fish
#
# Proxmox Host Upgrade & Reboot Script
# Version: 1.6.1
# Description: Automates apt update & full-upgrade (Proxmox best practice) with
#              pre-flight removal guardrails (aborts safely if core PVE/PBS packages
#              would be removed), file logging, --dry-run, and email alerts.

argparse 'd/dry-run' 'm/mail-to=' 'h/help' -- $argv; or exit 1

if set -q _flag_help
    echo "Usage: "(status filename)" [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -d, --dry-run         Simulate full-upgrade, check reboot conditions, and preview"
    echo "                        shutdown targets and email without making changes"
    echo "  -m, --mail-to EMAIL   Recipient email address (default: 'root', sent via"
    echo "                        proxmox-mail-forward -> Datacenter Notifications)"
    echo "  -h, --help            Show this help message and exit"
    exit 0
end

set -l dry_run 0
if set -q _flag_dry_run
    set dry_run 1
end

# Default recipient 'root' is sent directly via /usr/libexec/proxmox-mail-forward (Proxmox VE Datacenter -> Notifications)
set -l mail_to "root"
if set -q _flag_mail_to
    set mail_to "$_flag_mail_to"
end

# Core packages that MUST NEVER be removed automatically (triggers immediate safe abort)
set -gx PROTECTED_PKGS_REGEX '^(proxmox-ve|proxmox-backup-server|pve-manager|pve-cluster|qemu-server|pve-container|zfsutils-linux)$'

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

function run_logged_cmd
    if set -q RUN_LOG_FILE; and test -f "$RUN_LOG_FILE"
        $argv 2>&1 | tee -a "$RUN_LOG_FILE"
        return $pipestatus[1]
    else
        $argv
        return $status
    end
end

function send_notification --argument-names recipient subject body_file dry_run
    set -l pve_forward_bin "/usr/libexec/proxmox-mail-forward"
    set -l use_pve_forward 0
    if test "$recipient" = "root"; and test -x "$pve_forward_bin"
        set use_pve_forward 1
    end

    if test "$dry_run" -eq 1
        if test $use_pve_forward -eq 1
            log_msg "[DRY-RUN] Would send email via proxmox-mail-forward (CRLF) | Subject: '$subject'"
        else
            log_msg "[DRY-RUN] Would send email to '$recipient' (CRLF) | Subject: '$subject'"
        end
        return 0
    end

    set -l host (hostname)
    set -l mail_date (date -R)

    if test $use_pve_forward -eq 1
        begin
            printf "To: root\r\n"
            printf "From: Proxmox Auto-Upgrade <root@%s>\r\n" "$host"
            printf "Date: %s\r\n" "$mail_date"
            printf "Subject: %s\r\n" "$subject"
            printf "Content-Type: text/plain; charset=UTF-8\r\n"
            printf "\r\n"
            sed 's/\r$//; s/$/\r/' "$body_file"
        end | $pve_forward_bin

        if test $status -eq 0
            log_msg "Notification email sent via proxmox-mail-forward."
        else
            log_msg "WARNING: Failed to send notification email via proxmox-mail-forward."
        end
        return 0
    end

    set -l sendmail_bin (command -v sendmail; or echo "/usr/sbin/sendmail")
    if not test -x "$sendmail_bin"
        log_msg "WARNING: '$sendmail_bin' not found. Skipping email notification."
        return 1
    end

    begin
        printf "To: %s\r\n" "$recipient"
        printf "From: Proxmox Auto-Upgrade <root@%s>\r\n" "$host"
        printf "Date: %s\r\n" "$mail_date"
        printf "Subject: %s\r\n" "$subject"
        printf "Content-Type: text/plain; charset=UTF-8\r\n"
        printf "\r\n"
        sed 's/\r$//; s/$/\r/' "$body_file"
    end | $sendmail_bin -t

    if test $status -eq 0
        log_msg "Notification email sent to '$recipient'."
    else
        log_msg "WARNING: Failed to send notification email to '$recipient'."
    end
end

function run_upgrade --argument-names dry_run mail_to
    set -l host (hostname)
    set -l autoremove_blocked 0

    if test "$dry_run" -eq 1
        log_msg "=== Proxmox Upgrade & Reboot Script v1.6.1 [DRY-RUN MODE] ==="
        log_msg "Simulation active: no packages will be modified and no guests/host will be stopped."
    else
        log_msg "=== Proxmox Upgrade & Reboot Script v1.6.1 ==="
    end

    # 1. APT Update & Protected Full-Upgrade (Proxmox VE Standard)
    log_msg "=== Step 1: Updating Proxmox (full-upgrade) ==="
    if test "$dry_run" -eq 1
        log_msg "[DRY-RUN] Simulating 'apt-get -s full-upgrade' to check for protected package removals..."
        set -l sim_removals (apt-get -s full-upgrade 2>/dev/null | awk '/^Remv / {print $2}')
        if test (count $sim_removals) -gt 0
            log_msg "[DRY-RUN] Simulated full-upgrade removals: "(string join ", " $sim_removals)
        else
            log_msg "[DRY-RUN] Simulated full-upgrade removals: none"
        end
    else
        set -gx DEBIAN_FRONTEND noninteractive
        set -gx NEEDRESTART_MODE l

        run_logged_cmd apt-get update; or begin
            log_msg "ERROR: 'apt-get update' failed. Aborting."
            send_notification "$mail_to" "[$host] Proxmox Upgrade: ERRORE durante apt update" "$RUN_LOG_FILE" "$dry_run"
            return 1
        end

        # Pre-flight check: inspect packages that full-upgrade plans to remove
        set -l planned_removals (apt-get -s full-upgrade 2>/dev/null | awk '/^Remv / {print $2}')
        set -l blocked_removals
        for pkg in $planned_removals
            if string match -rq "$PROTECTED_PKGS_REGEX" -- "$pkg"
                set -a blocked_removals "$pkg"
            end
        end

        if test (count $blocked_removals) -gt 0
            log_msg "CRITICAL WARNING: 'apt-get full-upgrade' attempted to remove protected package(s): "(string join ", " $blocked_removals)
            log_msg "Aborting upgrade completely (no partial 'apt upgrade' will be run on Proxmox VE). Manual intervention required."
            send_notification "$mail_to" "[$host] Proxmox Upgrade: BLOCCATO - tentata rimozione di "(string join ", " $blocked_removals) "$RUN_LOG_FILE" "$dry_run"
            return 1
        end

        if test (count $planned_removals) -gt 0
            log_msg "Non-critical packages to be replaced/removed by full-upgrade: "(string join ", " $planned_removals)
        end

        run_logged_cmd apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" full-upgrade -y; or begin
            log_msg "ERROR: 'apt-get full-upgrade' failed. Aborting."
            send_notification "$mail_to" "[$host] Proxmox Upgrade: ERRORE durante apt full-upgrade" "$RUN_LOG_FILE" "$dry_run"
            return 1
        end
    end

    # 2. Protected Cleanup
    log_msg "=== Step 2: Cleaning up unused packages ==="
    if test "$dry_run" -eq 1
        log_msg "[DRY-RUN] Skipping 'apt-get autoremove -y'."
    else
        set -l auto_removals (apt-get -s autoremove 2>/dev/null | awk '/^Remv / {print $2}')
        set -l blocked_auto
        for pkg in $auto_removals
            if string match -rq "$PROTECTED_PKGS_REGEX" -- "$pkg"
                set -a blocked_auto "$pkg"
            end
        end

        if test (count $blocked_auto) -gt 0
            set autoremove_blocked 1
            log_msg "WARNING: Skipping 'apt-get autoremove' because it attempted to remove protected package(s): "(string join ", " $blocked_auto)
        else
            run_logged_cmd apt-get autoremove -y
        end
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
            log_msg "[DRY-RUN] Would send pre-reboot email, shut down LXC (excluding 205): "(test (count $target_lxcs) -gt 0; and string join ", " $target_lxcs; or echo "none")
            log_msg "[DRY-RUN] Would shut down QEMU VMs: "(test (count $target_vms) -gt 0; and string join ", " $target_vms; or echo "none")
            log_msg "[DRY-RUN] Would wait up to 180s for guests to stop and execute 'reboot'."
            send_notification "$mail_to" "[$host] Proxmox Upgrade: Reboot avviato ($latest_kernel)" "$RUN_LOG_FILE" "$dry_run"
            return 0
        end

        log_msg "=== Sending pre-reboot report before stopping guests ==="
        log_msg "Target LXC containers to stop: "(test (count $target_lxcs) -gt 0; and string join ", " $target_lxcs; or echo "none")
        log_msg "Target QEMU VMs to stop: "(test (count $target_vms) -gt 0; and string join ", " $target_vms; or echo "none")
        send_notification "$mail_to" "[$host] Proxmox Upgrade: Reboot avviato ($latest_kernel)" "$RUN_LOG_FILE" "$dry_run"
        sleep 2

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

        log_msg "=== All guests stopped, rebooting host ==="
        sleep 3
        reboot
    else
        if test $autoremove_blocked -eq 1
            log_msg "Full-upgrade succeeded, but autoremove was skipped to protect core packages."
            send_notification "$mail_to" "[$host] Proxmox Upgrade: Completato (autoremove bloccato)" "$RUN_LOG_FILE" "$dry_run"
        else
            log_msg "No reboot is necessary. Upgrade complete!"
            send_notification "$mail_to" "[$host] Proxmox Upgrade: Completato (nessun reboot)" "$RUN_LOG_FILE" "$dry_run"
        end
    end

    return 0
end

run_upgrade "$dry_run" "$mail_to" 2>&1 | tee -a "$LOG_FILE"
set -l exit_code $pipestatus[1]

test -f "$RUN_LOG_FILE"; and rm -f "$RUN_LOG_FILE"
exit $exit_code

