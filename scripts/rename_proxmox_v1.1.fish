#!/usr/bin/env fish

set VERSION "1.1"

# =============================================================================
# Proxmox Standalone Node Renaming Script (v$VERSION)
# =============================================================================

set OLD_NAME $argv[1]
set NEW_NAME $argv[2]

if test -z "$NEW_NAME"
    echo "Proxmox Rename Script v$VERSION"
    echo "Error: Missing parameters."
    echo "Usage: ./rename_proxmox_v1.0.fish <old-name> <new-name>"
    echo "Example: ./rename_proxmox_v1.0.fish pve pve-dell"
    exit 1
end

if test -f /etc/pve/corosync.conf
    set_color red
    echo "CRITICAL ERROR: Cluster configuration detected (/etc/pve/corosync.conf)."
    echo "Aborting script to prevent system damage."
    set_color normal
    exit 1
end

echo "=> 1. Updating /etc/hosts..."
sed -i "s/\b$OLD_NAME\b/$NEW_NAME/g" /etc/hosts

echo "=> 2. Updating /etc/hostname..."
echo $NEW_NAME > /etc/hostname

echo "=> 3. Setting the new hostname at the OS level..."
hostnamectl set-hostname $NEW_NAME

echo "=> 4. Updating node references in /etc/pve/storage.cfg..."
sed -i "s/nodes $OLD_NAME/nodes $NEW_NAME/g" /etc/pve/storage.cfg

echo "=> 5. Migrating Virtual Machines (KVM) and Containers (LXC) configurations..."
mkdir -p /etc/pve/nodes/$NEW_NAME/qemu-server
mkdir -p /etc/pve/nodes/$NEW_NAME/lxc

# Move KVM configurations (*.conf files only)
if test -d /etc/pve/nodes/$OLD_NAME/qemu-server
    mv /etc/pve/nodes/$OLD_NAME/qemu-server/*.conf /etc/pve/nodes/$NEW_NAME/qemu-server/ 2>/dev/null
end

# Move LXC configurations (*.conf files only)
if test -d /etc/pve/nodes/$OLD_NAME/lxc
    mv /etc/pve/nodes/$OLD_NAME/lxc/*.conf /etc/pve/nodes/$NEW_NAME/lxc/ 2>/dev/null
end

echo "=> 6. Cleaning up the old node directory..."
rm -rf /etc/pve/nodes/$OLD_NAME

set_color green
echo "======================================================================="
echo "Migration completed successfully from '$OLD_NAME' to '$NEW_NAME'!"
echo "Please type 'reboot' to restart the server and apply all changes."
echo "======================================================================="
set_color normal
