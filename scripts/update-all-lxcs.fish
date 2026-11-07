#!/usr/bin/env fish
#
# Proxmox LXC Upgrade Script
# Description: Automates the apt update/full-upgrade and autoremove process
#              for all running LXC containers on this Proxmox host.

echo "=== Starting update of all running LXC containers ==="

# Get all currently running LXC container IDs
set -l running_lxcs (pct list | awk '/running/ {print $1}')

if test (count $running_lxcs) -eq 0
    echo "No running LXC containers found."
    exit 0
end

for ct in $running_lxcs
    echo "------------------------------------------------------------"
    echo " Updating Container ID: $ct"
    echo "------------------------------------------------------------"

    # pct exec runs commands directly inside the container as root
    pct exec $ct -- bash -c '
        export DEBIAN_FRONTEND=noninteractive
        echo "--> Running apt update..."
        apt-get update -qq

        echo "--> Running apt full-upgrade..."
        apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" full-upgrade -y -qq

        echo "--> Cleaning up unused packages..."
        apt-get autoremove -y -qq
        apt-get clean
    '

    if test $status -eq 0
        echo "[ OK ] Container $ct updated successfully."
    else
        echo "[ ERROR ] Failed to update container $ct."
    end
end

echo "============================================================"
echo "=== All LXC containers update completed! ==="
echo "============================================================"

