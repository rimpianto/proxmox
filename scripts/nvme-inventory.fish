#!/usr/bin/env fish
# nvme-inventory.fish — NVMe inventory: model, capacity, PCIe link, usage, health
#
# Read-only. Sources: sysfs, lspci, smartctl, lsblk, zpool.
# Dependencies: pciutils, smartmontools, util-linux; zfs tools if pools are present.
#
# Usage:
#   nvme-inventory.fish                # table
#   nvme-inventory.fish -d nvme1n1     # full detail for one device
#   nvme-inventory.fish --no-color     # no ANSI colours
#
# The PCIe column shows the controller capability (LnkCap) against the
# negotiated link (LnkSta): a Gen4 drive in a Gen3 slot is the common case and
# is flagged with "⚠ down".

set -g VERSION "1.0.0"
set -g COLOR 1
set -g DETAIL ""

set -l i 1
while test $i -le (count $argv)
    switch $argv[$i]
        case "--no-color" "-n"
            set -g COLOR 0
        case "--detail" "-d"
            set i (math $i + 1)
            set -g DETAIL $argv[$i]
        case "-h" "--help"
            echo "nvme-inventory.fish v$VERSION"
            echo "  (no option)         table of all NVMe namespaces"
            echo "  -d, --detail DEV    full detail for one device (e.g. nvme1n1)"
            echo "  -n, --no-color      disable colours"
            exit 0
        case "*"
            echo "Unknown option: $argv[$i] (try --help)" >&2
            exit 64
    end
    set i (math $i + 1)
end

if not tty -s
    set -g COLOR 0
end

# ---------- helpers ----------
function c --argument-names code text
    if test $COLOR -eq 1
        printf '\e[%sm%s\e[0m' $code $text
    else
        printf '%s' $text
    end
end

function hr
    printf '%s\n' (string repeat -n 118 '─')
end

function rd --argument-names path
    if test -r "$path"
        cat "$path" 2>/dev/null | string trim
    else
        echo ""
    end
end

function human_size --argument-names sectors
    if test -z "$sectors"; or test "$sectors" = "0"
        echo "-"
        return
    end
    set -l bytes (math "$sectors * 512")
    if test $bytes -ge 1000000000000
        printf "%.2f TB" (math "$bytes / 1000000000000")
    else
        printf "%.1f GB" (math "$bytes / 1000000000")
    end
end

function pcie_gen --argument-names speed
    switch $speed
        case "2.5GT/s"
            echo "Gen1"
        case "5GT/s"
            echo "Gen2"
        case "8GT/s"
            echo "Gen3"
        case "16GT/s"
            echo "Gen4"
        case "32GT/s"
            echo "Gen5"
        case "64GT/s"
            echo "Gen6"
        case "*"
            echo "?"
    end
end

function human_bytes --argument-names units
    # NVMe "Data Units" are 512000 bytes each
    set -l n (string replace -a ',' '' $units)
    if test -z "$n"
        echo "-"
        return
    end
    set -l bytes (math "$n * 512000")
    if test $bytes -ge 1000000000000
        printf "%.2f TB" (math "$bytes / 1000000000000")
    else if test $bytes -ge 1000000000
        printf "%.1f GB" (math "$bytes / 1000000000")
    else if test $bytes -ge 1000000
        printf "%.0f MB" (math "$bytes / 1000000")
    else
        printf "%.0f kB" (math "$bytes / 1000")
    end
end

# map /dev/... vdev -> pool
set -g POOLMAP
for p in (zpool list -H -o name 2>/dev/null)
    for v in (zpool status -P $p 2>/dev/null | string match -rg '^\s+(/dev/\S+)')
        set -l real (readlink -f $v 2>/dev/null)
        if test -z "$real"
            set real $v
        end
        set -g POOLMAP $POOLMAP "$real=$p"
    end
end

function used_by --argument-names dev
    # dev = nvme0n1
    set -l parts (lsblk -n -l -o NAME /dev/$dev 2>/dev/null)
    for part in $parts
        set -l path "/dev/$part"
        for entry in $POOLMAP
            set -l kv (string split -m1 '=' $entry)
            if test "$kv[1]" = "$path"
                echo "zfs: "$kv[2]
                return
            end
        end
    end

    set -l mp (lsblk -n -l -o MOUNTPOINT /dev/$dev 2>/dev/null | string match -r '\S+' | head -n1)
    if test -n "$mp"
        echo "mounted "$mp
        return
    end

    set -l fs (lsblk -n -d -o FSTYPE /dev/$dev 2>/dev/null | string match -r '\S+')
    if test -n "$fs"
        echo "$fs (not mounted)"
        return
    end

    # partitions but nothing we recognise
    set -l count (count $parts)
    if test $count -gt 1
        echo "partitions only"
        return
    end

    echo "unused"
end

# ---------- header ----------
set -l hname (hostname)
echo (c "1;36" "NVME INVENTORY") (c "2" "· $hname · kernel "(uname -r)" · "(date "+%Y-%m-%d %H:%M"))
hr

set -l controllers (ls /sys/class/nvme 2>/dev/null | sort)
if test (count $controllers) -eq 0
    echo (c "31" "no NVMe controllers found")
    exit 1
end

printf "%-10s %-26s %-8s %-20s %-8s %-5s %-6s %s\n" \
    DEVICE MODEL SIZE PCIe HEALTH TEMP USED% "USED BY"

set -l downgraded 0
set -l unhealthy 0
set -l totalbytes 0

for ctl in $controllers
    set -l pci (basename (readlink -f /sys/class/nvme/$ctl/device 2>/dev/null))
    set -l info (smartctl -i /dev/$ctl 2>/dev/null | string collect)
    set -l model (string trim (echo "$info" | string match -rg 'Model Number:\s+(.+)'))
    set -l serial (string trim (echo "$info" | string match -rg 'Serial Number:\s+(.+)'))
    set -l fw (string trim (echo "$info" | string match -rg 'Firmware Version:\s+(.+)'))

    # health block
    set -l hl (smartctl -H -A /dev/$ctl 2>/dev/null | string collect)
    set -l health "n/a"
    if string match -q -- "*PASSED*" "$hl"
        set health "PASSED"
    else if string match -q -- "*FAILED*" "$hl"
        set health "FAILED"
        set unhealthy (math $unhealthy + 1)
    end
    set -l temp (string trim (echo "$hl" | string match -rg 'Temperature:\s+(\d+)'))
    set -l usedpct (string trim (echo "$hl" | string match -rg 'Percentage Used:\s+(\d+)%'))

    # PCIe capability vs negotiated
    set -l cap (lspci -vv -s $pci 2>/dev/null | string match -rg 'LnkCap:\s+Port #\d+, Speed (\S+), Width (x[0-9]+)')
    set -l sta (lspci -vv -s $pci 2>/dev/null | string match -rg 'LnkSta:\s+Speed (\S+)(?: \([^)]*\))?, Width (x[0-9]+)')
    set -l pcie "-"
    if test (count $cap) -ge 2
        set pcie (pcie_gen $cap[1])" $cap[2]"
        if test (count $sta) -ge 2
            set pcie "$pcie → "(pcie_gen $sta[1])" $sta[2]"
            set -l cw (string replace 'x' '' $cap[2])
            set -l sw (string replace 'x' '' $sta[2])
            if test $sw -lt $cw
                set pcie "$pcie ⚠ width"
                set downgraded (math $downgraded + 1)
            else if test "$sta[1]" != "$cap[1]"
                set pcie "$pcie ⚠ speed"
                set downgraded (math $downgraded + 1)
            end
        end
    end

    set -l nspat (string join '' '^' $ctl 'n[0-9]+$')
    for ns in (ls /sys/class/block 2>/dev/null | string match -r $nspat)
        set -l sectors (rd /sys/block/$ns/size)
        set -l size (human_size $sectors)
        set totalbytes (math "$totalbytes + $sectors * 512")
        set -l ub (used_by $ns)
        printf "%-10s %-26s %-8s %-20s %-8s %-5s %-6s %s\n" \
            $ns (string sub -l 26 -- $model) $size $pcie $health (string sub -l 5 -- $temp) (string sub -l 6 -- $usedpct) "$ub"
    end
end

echo
echo (c "2" "PCIe: capability -> negotiated. ⚠ = the drive is running below what it supports (slot/root port).")
echo (c "2" "TEMP/USED% come from the NVMe SMART log; HEALTH is the drive self-assessment.")

# ---------- summary ----------
hr
set -l tot (printf "%.2f TB" (math "$totalbytes / 1000000000000"))
echo (c "2" "summary: "(count $controllers)" controllers · total "$tot" · "$downgraded" link downgraded · "$unhealthy" unhealthy")

# ---------- detail ----------
if test -n "$DETAIL"
    set -l dev (string replace -r '^/dev/' '' $DETAIL)
    if not test -b /dev/$dev
        echo; echo (c "31" "block device /dev/$dev does not exist")
        exit 1
    end
    set -l ctl (string replace -r 'n[0-9]+$' '' $dev)
    set -l devpath (readlink -f /sys/class/nvme/$ctl/device 2>/dev/null)
    set -l pci (basename $devpath)
    set -l rp (basename (dirname $devpath))
    echo
    echo (c "1;33" "DETAIL /dev/$dev")
    echo "  controller : /dev/$ctl"
    echo "  pci        : $pci (root port $rp)"
    echo "  serial     : "(string trim (smartctl -i /dev/$dev 2>/dev/null | string match -rg 'Serial Number:\s+(.+)'))
    echo "  used by    : "(used_by $dev)
    echo
    echo (c "2" "  lsblk")
    lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT /dev/$dev | sed 's/^/    /'
    echo (c "2" "  smartctl -i")
    smartctl -i /dev/$dev 2>/dev/null | sed 's/^/    /'
    echo (c "2" "  smartctl -H -A")
    smartctl -H -A /dev/$dev 2>/dev/null | sed 's/^/    /'
end
