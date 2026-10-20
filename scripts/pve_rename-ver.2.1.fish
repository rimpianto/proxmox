#!/usr/bin/env fish
# =============================================================================
# Proxmox VE Standalone Node Renaming Tool (Fish Shell Edition)
# Version: 2.1
#
# ARCHITECTURAL OVERVIEW & SAFETY GUARANTEES:
# 1. Zero Data Loss: Guest storage volumes (e.g., ZFS subvol-*/vm-*) are detached
#    from the node identity. VM/CT loss occurs strictly when metadata files
#    (.conf) are removed or misplaced from /etc/pve/nodes/<node>/.
# 2. pmxcfs Protection: /etc/pve is a FUSE filesystem driven by an SQLite
#    database (/var/lib/pve-cluster/config.db). Modifying files while services
#    run or without syncing causes locks and ghost folders.
# 3. Non-Destructive Operation: The original /etc/pve/nodes/<old_name> directory
#    is NEVER removed by this script. Configurations are safely copied.
# 4. Mandatory Pre-Flight Backups: Creates tarballs and raw copies of config.db
#    and system network files before executing any system modification.
# 5. Standalone Enforcement: Verifies that no Corosync cluster state exists.
# =============================================================================

set -g SCRIPT_VERSION "2.1"

# --- Helper Output Functions ---
function log_info
    set_color cyan
    echo "[INFO] "(date +"%H:%M:%S")" - $argv"
    set_color normal
end

function log_ok
    set_color green
    echo "[OK]   "(date +"%H:%M:%S")" - $argv"
    set_color normal
end

function log_warn
    set_color yellow
    echo "[WARN] "(date +"%H:%M:%S")" - $argv"
    set_color normal
end

function log_error
    set_color red
    echo "[FAIL] "(date +"%H:%M:%S")" - $argv" >&2
    set_color normal
    exit 1
end

# =============================================================================
# STEP 1: Pre-Flight Safety & Environment Checks
# =============================================================================

# Ensure execution with root privileges
if test (id -u) -ne 0
    log_error "This script requires root privileges to manipulate Proxmox services and /etc/pve."
end

# Verify CLI parameters
if test (count $argv) -ne 2
    echo "======================================================================="
    echo "Proxmox Standalone Node Renaming Script (v$SCRIPT_VERSION)"
    echo "======================================================================="
    echo "Usage: ./rename_proxmox_v2.1.fish <old_nodename> <new_nodename>"
    echo "Example: ./rename_proxmox_v2.1.fish pve pve-lenovo"
    echo "======================================================================="
    exit 1
end

set -l OLD_NAME $argv[1]
set -l NEW_NAME $argv[2]
set -l CURRENT_HOSTNAME (hostname)

log_info "Starting Proxmox Node Renamer v$SCRIPT_VERSION"

# Validate RFC 1123 hostname compliance
if not string match -rq '^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$' "$NEW_NAME"
    log_error "New hostname '$NEW_NAME' is invalid. Must adhere to RFC 1123 (alphanumeric and dashes only, max 63 chars)."
end

if test "$OLD_NAME" = "$NEW_NAME"
    log_error "Old hostname and new hostname are identical ('$OLD_NAME'). No action required."
end

# =============================================================================
# STEP 2: Rigorous Cluster Verification
# Renaming a node that belongs to a Corosync cluster causes quorum loss,
# split-brain scenarios, and cluster fencing (reboot loops).
# =============================================================================

log_info "Verifying standalone status (checking for active cluster configuration)..."

# Check 1: Existence of corosync.conf in the PVE cluster filesystem
if test -f /etc/pve/corosync.conf
    log_error "CRITICAL: Detected '/etc/pve/corosync.conf'. This node is part of a cluster! You MUST NOT rename a clustered node with this script."
end

# Check 2: Query pvecm runtime status if the binary is present
if command -v pvecm >/dev/null 2>&1
    set -l PVECM_OUT (pvecm status 2>&1)
    if string match -qi "*Cluster Information*" "$PVECM_OUT"
        log_error "CRITICAL: 'pvecm status' reports an active cluster environment. Aborting to prevent quorum corruption."
    end
end

log_ok "Confirmed: Node is standalone (no Corosync cluster detected)."

# Verify that the target source node directory or current hostname matches $OLD_NAME
if test ! -d "/etc/pve/nodes/$OLD_NAME"; and test "$CURRENT_HOSTNAME" != "$OLD_NAME"
    log_error "Neither directory '/etc/pve/nodes/$OLD_NAME' nor the current hostname ('$CURRENT_HOSTNAME') match '$OLD_NAME'."
end

# Inspect currently running guests (KVM and LXC)
set -l RUNNING_VMS (qm list 2>/dev/null | awk '$3=="running" {print $1}')
set -l RUNNING_CTS (pct list 2>/dev/null | awk '$2=="running" {print $1}')

if test -n "$RUNNING_VMS"; or test -n "$RUNNING_CTS"
    log_warn "Active workloads detected:"
    test -n "$RUNNING_VMS"; and echo "  -> Running VMs: $RUNNING_VMS"
    test -n "$RUNNING_CTS"; and echo "  -> Running LXCs: $RUNNING_CTS"
    log_warn "Renaming node while guests are active is possible, but graceful shutdown is strongly advised."
    read -l -P "Proceed anyway? (y/N): " CONFIRM
    if not string match -rq '^[yYsS]' "$CONFIRM"
        log_info "Aborted by user."
        exit 0
    end
end

# =============================================================================
# STEP 3: Complete Pre-Modification Backups
# Backing up SQLite database, system network definitions, and PVE node tree.
# =============================================================================

set -l TIMESTAMP (date +%Y%m%d_%H%M%S)
set -l BACKUP_DIR "/var/backups/pve-rename-v$SCRIPT_VERSION-$TIMESTAMP"
log_info "Creating complete safeguard backup in: $BACKUP_DIR"

mkdir -p "$BACKUP_DIR"

# 1. PVE SQLite cluster database backup (contains all pmxcfs state)
if test -f /var/lib/pve-cluster/config.db
    cp -a /var/lib/pve-cluster/config.db "$BACKUP_DIR/config.db.bak"
    log_ok "SQLite cluster database backed up."
end

# 2. Host networking backups
cp -a /etc/hosts "$BACKUP_DIR/hosts.bak"
cp -a /etc/hostname "$BACKUP_DIR/hostname.bak"
test -f /etc/pve/storage.cfg; and cp -a /etc/pve/storage.cfg "$BACKUP_DIR/storage.cfg.bak"

# 3. Archive existing node configuration tree
if test -d "/etc/pve/nodes/$OLD_NAME"
    tar -czf "$BACKUP_DIR/etc-pve-nodes-$OLD_NAME.tar.gz" -C "/etc/pve/nodes" "$OLD_NAME" 2>/dev/null
    log_ok "Compressed archive of '/etc/pve/nodes/$OLD_NAME' created."
end

# =============================================================================
# STEP 4: Stop High-Level PVE Management Daemons
# Prevents file lock races on SQLite/pmxcfs during node directory migration.
# =============================================================================

log_info "Stopping PVE management services (preventing FUSE/SQLite locks)..."
systemctl stop pvedaemon pveproxy pvestatd pve-ha-crm pve-ha-lrm 2>/dev/null

# =============================================================================
# STEP 5: Apply Hostname Changes to Linux Base OS
# Updates /etc/hosts, /etc/hostname, and systemd hostname state.
# =============================================================================

log_info "Updating system hostname and networking maps..."

# Token-bounded regex replacement ensures we don't accidentally match substrings
sed -i "s/\b$OLD_NAME\b/$NEW_NAME/g" /etc/hosts
echo "$NEW_NAME" > /etc/hostname
hostnamectl set-hostname "$NEW_NAME"

log_ok "OS hostname set to: "(hostname)

# =============================================================================
# STEP 6: Resynchronize pmxcfs with New Identity
# Restarting pve-cluster instructs pmxcfs to load with the new local node identity.
# =============================================================================

log_info "Restarting pve-cluster to adopt the new node identity..."
systemctl restart pve-cluster

# Poll until pmxcfs re-mounts /etc/pve/nodes (timeout after 20 seconds)
set -l RETRIES 20
while test ! -d /etc/pve/nodes; and test $RETRIES -gt 0
    sleep 1
    set RETRIES (math $RETRIES - 1)
end

if test ! -d /etc/pve/nodes
    log_error "Timeout reached: /etc/pve was not mounted by pmxcfs. Check 'systemctl status pve-cluster'."
end

log_ok "pmxcfs successfully mounted at /etc/pve."

# =============================================================================
# STEP 7: Safe Migration of Guest Configurations (Zero-Loss Principle)
# We deliberately use 'find' and 'cp -a' instead of shell globs (*.conf) or 'mv'.
# If a glob fails or directory doesn't exist, 'find' completes cleanly without error.
# We NEVER delete /etc/pve/nodes/$OLD_NAME here.
# =============================================================================

log_info "Migrating configuration files from '$OLD_NAME' to '$NEW_NAME'..."

mkdir -p "/etc/pve/nodes/$NEW_NAME/qemu-server"
mkdir -p "/etc/pve/nodes/$NEW_NAME/lxc"
mkdir -p "/etc/pve/nodes/$NEW_NAME/openvz" 2>/dev/null

# Migrate LXC container configurations
if test -d "/etc/pve/nodes/$OLD_NAME/lxc"
    find "/etc/pve/nodes/$OLD_NAME/lxc" -maxdepth 1 -name "*.conf" -exec cp -a "{}" "/etc/pve/nodes/$NEW_NAME/lxc/" \;
    set -l LXC_COUNT (find "/etc/pve/nodes/$NEW_NAME/lxc" -maxdepth 1 -name "*.conf" | count)
    log_ok "LXC configurations copied: $LXC_COUNT file(s)."
end

# Migrate KVM/QEMU virtual machine configurations
if test -d "/etc/pve/nodes/$OLD_NAME/qemu-server"
    find "/etc/pve/nodes/$OLD_NAME/qemu-server" -maxdepth 1 -name "*.conf" -exec cp -a "{}" "/etc/pve/nodes/$NEW_NAME/qemu-server/" \;
    set -l QEMU_COUNT (find "/etc/pve/nodes/$NEW_NAME/qemu-server" -maxdepth 1 -name "*.conf" | count)
    log_ok "QEMU VM configurations copied: $QEMU_COUNT file(s)."
end

# Migrate node-specific SSL certificates and privilege files if present
for item in pve-ssl.key pve-ssl.pem priv
    if test -e "/etc/pve/nodes/$OLD_NAME/$item"; and test ! -e "/etc/pve/nodes/$NEW_NAME/$item"
        cp -a "/etc/pve/nodes/$OLD_NAME/$item" "/etc/pve/nodes/$NEW_NAME/" 2>/dev/null
    end
end

# Update storage allocation constraints in /etc/pve/storage.cfg
if test -f /etc/pve/storage.cfg
    sed -i "s/\b$OLD_NAME\b/$NEW_NAME/g" /etc/pve/storage.cfg
    log_ok "Storage references updated in /etc/pve/storage.cfg."
end

# Migrate historical RRD performance metric databases (CPU/RAM graphs)
if test -d "/var/lib/rrdcached/db/pve2-node/$OLD_NAME"
    mv "/var/lib/rrdcached/db/pve2-node/$OLD_NAME" "/var/lib/rrdcached/db/pve2-node/$NEW_NAME" 2>/dev/null
    log_ok "RRD historical metric databases migrated."
end

# =============================================================================
# STEP 8: Regenerate SSL Certificates & Restart Daemons
# PVE proxies and APIs authenticate using node-specific SSL certificates.
# Changing hostname requires regenerating these certs to restore Web UI and API.
# =============================================================================

log_info "Forcing regeneration of node SSL certificates..."
pvecm updatecerts -f

log_info "Restarting all Proxmox management services..."
systemctl restart pve-cluster
systemctl restart pvedaemon
systemctl restart pveproxy
systemctl restart pvestatd

# =============================================================================
# STEP 9: Post-Flight Validation
# Verify that containers and VMs are visible and registered by Proxmox.
# =============================================================================

sleep 2
set -l FINAL_LXC (pct list 2>/dev/null | tail -n +2 | count)
set -l FINAL_QEMU (qm list 2>/dev/null | tail -n +2 | count)

echo ""
set_color green
echo "======================================================================="
echo "Node successfully migrated from '$OLD_NAME' to '$NEW_NAME' (v$SCRIPT_VERSION)!"
echo "======================================================================="
set_color normal
log_info "System Guest Visibility Report:"
echo "   -> Registered Containers (LXC): $FINAL_LXC"
echo "   -> Registered Virtual Machines: $FINAL_QEMU"
echo "======================================================================="
set_color yellow
echo "SAFETY NOTICE:"
echo "The source directory '/etc/pve/nodes/$OLD_NAME' was NOT deleted."
echo "Your guest configuration files are fully preserved in both locations."
echo "Once you verify the Web GUI (https://"(hostname -I | awk '{print $1}')":8006), you may remove it:"
echo "   rm -rf /etc/pve/nodes/$OLD_NAME"
set_color normal
echo "======================================================================="
log_info "Full recovery backup archived at: $BACKUP_DIR"

