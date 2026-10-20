#!/usr/bin/env fish

echo "=== Starting Proxmox Backup ==="
# Back up all VMs and LXCs using snapshot mode (no downtime during the backup)
# Optional: If you want to specify a specific storage target, add '--storage <name>' (e.g., --storage local-btrfs)
vzdump --all --mode snapshot --compress zstd

echo "=== Backup completed. Starting LXC containers shutdown ==="
# Find all running containers and extract the ID (first column)
for vmid in (pct list | awk '/running/ {print $1}')
    echo "Sending shutdown signal to LXC container: $vmid"
    pct shutdown $vmid
end

echo "=== Starting QEMU virtual machines shutdown ==="
# Find all running VMs and extract the ID (first column)
for vmid in (qm list | awk '/running/ {print $1}')
    echo "Sending shutdown signal to VM: $vmid"
    qm shutdown $vmid
end

echo "=== Waiting for all shutdown tasks to complete ==="
# Loop to ensure everything is fully stopped before proceeding
# grep -q returns true if it finds "running", keeping the loop active
while pct list | grep -q running; or qm list | grep -q running
    echo "Waiting for machines to shut down completely..."
    sleep 3
end

echo "Everything is safely backed up and down. The server is ready for reboot! 🚀"
