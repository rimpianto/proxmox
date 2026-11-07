#!/usr/bin/env bash
#
# Proxmox LXC Upgrade Script
# Description: Automates the apt update/full-upgrade and autoremove process
#              for all running LXC containers on this Proxmox host.

echo "=== Starting update of all running LXC containers ==="

# Get all currently running LXC container IDs
RUNNING_LXCS=$(pct list | awk '/running/ {print $1}')

if [ -z "$RUNNING_LXCS" ]; then
    echo "No running LXC containers found."
    exit 0
fi

for CT in $RUNNING_LXCS; do
    echo "------------------------------------------------------------"
    echo " Updating Container ID: $CT"
    echo "------------------------------------------------------------"

    # pct exec runs commands directly inside the container as root
    pct exec $CT -- bash -c '
        export DEBIAN_FRONTEND=noninteractive
        echo "--> Running apt update..."
        apt-get update -qq

        echo "--> Running apt full-upgrade..."
        apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" full-upgrade -y -qq

        echo "--> Cleaning up unused packages..."
        apt-get autoremove -y -qq
        apt-get clean
    '

    if [ $? -eq 0 ]; then
        echo "[ OK ] Container $CT updated successfully."
    else
        echo "[ ERROR ] Failed to update container $CT."
    fi
done

echo "============================================================"
echo "=== All LXC containers update completed! ==="
echo "============================================================"

