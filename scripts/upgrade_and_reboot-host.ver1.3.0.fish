#!/usr/bin/env fish
#
# Proxmox Host Upgrade & Reboot Script
# Version: 1.3.0
# Description: Automates the apt update/full-upgrade and autoremove process. 
#              It then checks if a reboot is required. If so, it safely shuts down 
#              all LXCs (except ID 205) and VMs, waits for completion, and reboots the host.

echo "=== Proxmox Upgrade & Reboot Script v1.3.0 ==="

# Set non-interactive mode for APT to prevent prompts during the upgrade process
echo "=== Updating Proxmox ==="
export DEBIAN_FRONTEND=noninteractive
apt update

# Perform a full system upgrade with unattended configuration handling:
#  full-upgrade  : Upgrades packages, automatically handling dependencies (installing/removing as needed)
#  -y            : Automatically answers "yes" to the standard "Do you want to continue?" prompt
#  --force-confdef : If a config file has changed, automatically choose the package maintainer's default action
#  --force-confold : If there is no default action, always keep the old/existing configuration file
apt -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" full-upgrade -y

# Clean up unused packages and old kernels to free up disk space
echo "=== Cleaning up unused packages ==="
apt autoremove -y

echo "=== Checking if reboot is required ==="
# Debian/Proxmox creates this file if a core component (like the kernel) was updated
if test -f /var/run/reboot-required
    echo "A reboot is required. Proceeding with shutdown sequence."

    # Gracefully shut down all running LXC containers, intentionally skipping ID 205
    echo "=== Starting LXC containers shutdown (excluding 205) ==="
    for vmid in (pct list | awk '/running/ {print $1}')
        if test $vmid != "205"
            echo "Sending shutdown signal to LXC container: $vmid"
            pct shutdown $vmid
        end
    end

    # Gracefully shut down all running QEMU Virtual Machines
    echo "=== Starting QEMU virtual machines shutdown ==="
    for vmid in (qm list | awk '/running/ {print $1}')
        echo "Sending shutdown signal to VM: $vmid"
        qm shutdown $vmid
    end

    # Wait in a loop until all targeted LXCs and VMs are fully stopped
    echo "=== Waiting for all shutdown tasks to complete ==="
    while pct list | grep -q running | grep -v 205; or qm list | grep -q running
        echo "Waiting for machines to shut down completely..."
        sleep 3
    end

    # Trigger host reboot once all guests are down
    echo "=== Rebooting Host ==="
    reboot
else
    echo "No reboot is necessary. Upgrade complete!"
end
