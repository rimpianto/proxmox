#!/usr/bin/env fish

set VERSION "1.0"

# =============================================================================
# Proxmox Standalone Node Renaming Script (v$VERSION)
# 
# WARNING: Do NOT use this script if the node is part of a Proxmox Cluster (Corosync).
# Changing the hostname of a clustered node will break the cluster configuration.
# This is strictly for standalone Proxmox VE servers.
# =============================================================================

# Fetch arguments passed from the command line
set OLD_NAME $argv[1]
set NEW_NAME $argv[2]

# Ensure both the old and new hostnames are provided before proceeding
if test -z "$NEW_NAME"
    echo "Proxmox Rename Script v$VERSION"
    echo "Error: Missing parameters."
    echo "Usage: ./rename_proxmox_v$VERSION.fish <old-name> <new-name>"
    echo "Example: ./rename_proxmox_v$VERSION.fish pve pve-dell"
    exit 1
end

# =============================================================================
# SAFETY CHECK: Prevent execution if the node is part of a cluster
# =============================================================================
if test -f /etc/pve/corosync.conf
    set_color red
    echo "CRITICAL ERROR: Cluster configuration detected (/etc/pve/corosync.conf)."
    echo "Renaming a node that is part of a Proxmox cluster will break the Corosync sync"
    echo "and corrupt the distributed database (pmxcfs)."
    echo "Aborting script to prevent system damage. You must remove the node from the"
    echo "cluster properly before renaming it."
    set_color normal
    exit 1
end

echo "=> 1. Updating /etc/hosts..."
# We use '\b' (word boundaries) in sed to ensure we only match the exact hostname
# as a standalone word. This prevents accidentally replacing parts of other strings
# or Fully Qualified Domain Names (FQDNs). This step ensures local DNS resolution works.
sed -i "s/\b$OLD_NAME\b/$NEW_NAME/g" /etc/hosts

echo "=> 2. Updating /etc/hostname..."
# This file dictates the static hostname of the system.
# We overwrite its contents entirely with the new hostname.
echo $NEW_NAME > /etc/hostname

echo "=> 3. Setting the new hostname at the OS level..."
# 'hostnamectl' updates the running system's hostname immediately in the kernel
# without requiring a full system reboot right away.
hostnamectl set-hostname $NEW_NAME

echo "=> 4. Updating node references in /etc/pve/storage.cfg..."
# Proxmox storage configurations often restrict access to specific nodes.
# We replace 'nodes <old-name>' with 'nodes <new-name>' so the renamed node 
# can still mount and access its storage (like zfs-apps, zfs-cloud, local, etc.).
# Note: We intentionally do NOT change 'vgname <name>' because that is the LVM 
# Volume Group name created during OS installation, which remains unchanged.
sed -i "s/nodes $OLD_NAME/nodes $NEW_NAME/g" /etc/pve/storage.cfg

echo "=> 5. Migrating Virtual Machines (KVM) and Containers (LXC) configurations..."
# Proxmox uses a database-driven cluster file system (pmxcfs) mounted at /etc/pve.
# VM and LXC configuration files are strictly bound to the node's directory:
# /etc/pve/nodes/<hostname>/. We must move these configs to the new node's folder
# otherwise the VMs will "disappear" from the Proxmox Web GUI.

# Create the new node directory structure first
mkdir -p /etc/pve/nodes/$NEW_NAME

# Move KVM (Virtual Machine) configurations if the old directory exists
if test -d /etc/pve/nodes/$OLD_NAME/qemu-server
    mv /etc/pve/nodes/$OLD_NAME/qemu-server /etc/pve/nodes/$NEW_NAME/
end

# Move LXC (Linux Container) configurations if the old directory exists
if test -d /etc/pve/nodes/$OLD_NAME/lxc
    mv /etc/pve/nodes/$OLD_NAME/lxc /etc/pve/nodes/$NEW_NAME/
end

echo "=> 6. Cleaning up the old node directory..."
# Remove the old hostname folder to prevent a "ghost node" (an offline node
# with the old name) from appearing in the Proxmox Web GUI datacenter view.
rm -rf /etc/pve/nodes/$OLD_NAME

set_color green
echo "======================================================================="
echo "Migration completed successfully from '$OLD_NAME' to '$NEW_NAME'!"
echo "Please type 'reboot' to restart the server and apply all changes."
echo "======================================================================="
set_color normal

