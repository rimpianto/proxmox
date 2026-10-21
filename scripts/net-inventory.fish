#!/usr/bin/env fish
# net-inventory.fish — host network inventory and status
#
# Everything is read from sysfs/ethtool/lspci/ip: read-only, no changes.
# Dependencies: iproute2, pciutils, ethtool, udevadm.
#
# Usage:
#   net-inventory.fish                 # full inventory
#   net-inventory.fish --up            # only interfaces with carrier/link
#   net-inventory.fish -d nic3         # detail for one interface
#   net-inventory.fish --no-color      # no ANSI colours
#
# Physical table columns:
#   IFACE  DRIVER  PCI  ROOTPORT  STATE  SPEED  MAX  MEDIA  MTU  MAC  MASTER  LINKFILE
# MAX is the highest speed declared in the "Supported link modes"; PCIe shows
# LnkCap (slot capability) against LnkSta (negotiated): when they differ the
# device sits in a narrower slot or behind a riser.

set -g VERSION "1.0.0"
set -g COLOR 1
set -g ONLY_UP 0
set -g DETAIL ""

set -l i 1
while test $i -le (count $argv)
    switch $argv[$i]
        case "--up" "-u"
            set -g ONLY_UP 1
        case "--no-color" "-n"
            set -g COLOR 0
        case "--detail" "-d"
            set i (math $i + 1)
            set -g DETAIL $argv[$i]
        case "-h" "--help"
            echo "net-inventory.fish v$VERSION"
            echo "  (no option)         full inventory"
            echo "  -u, --up            only interfaces with carrier/link"
            echo "  -d, --detail IFACE  detail for one interface"
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
    printf '%s\n' (string repeat -n 100 '─')
end

function rd --argument-names path
    if test -r "$path"
        cat "$path" 2>/dev/null | string trim
    else
        echo ""
    end
end

function human_speed --argument-names n
    if test -z "$n"; or test "$n" = "0"
        echo "-"
    else if test $n -ge 1000
        echo (math "$n / 1000")"G"
    else
        echo "$n M"
    end
end

function iface_kind --argument-names i
    if test "$i" = "lo"
        echo "loopback"
        return
    end
    if test -e /sys/class/net/$i/device
        echo "physical"
        return
    end
    if test -d /sys/class/net/$i/bridge
        echo "bridge"
        return
    end
    if test -d /sys/class/net/$i/bonding
        echo "bond"
        return
    end
    set -l d (ip -d link show $i 2>/dev/null)
    for k in vlan vxlan veth dummy tun tap wireguard
        if string match -q -- "* $k *" "$d"; or string match -q -- "* $k" "$d"
            echo $k
            return
        end
    end
    echo "virtual"
end

function iface_max_mode --argument-names i
    set -l modes (ethtool $i 2>/dev/null | string match -rg '^\s+([0-9]+)base')
    set -l max 0
    for m in $modes
        if test $m -gt $max
            set max $m
        end
    end
    echo $max
end

function iface_media --argument-names i drv
    # the r8127 driver hardcodes PORT_TP: ethtool lies even with an SFP inserted.
    # The real value lives in the driver debug file.
    if test "$drv" = "r8127"; and test -r /proc/net/r8127/$i/debug/driver_var
        set -l v (grep -m1 HwFiberModeVer /proc/net/r8127/$i/debug/driver_var 2>/dev/null | string match -r '0x[0-9a-fA-F]+')
        if test "$v" = "0x1"
            echo "fiber*"
        else if test -n "$v"
            echo "copper*"
        else
            echo "?"
        end
        return
    end
    set -l p (ethtool $i 2>/dev/null | string match -rg 'Supported ports: \[ (.*) \]')
    if test -n "$p"
        echo (string lower $p | string replace -a ' ' ',')
    else
        echo "n/a"
    end
end

function iface_rootport --argument-names dev
    set -l d (dirname $dev)
    while test "$d" != "/sys/devices"; and test "$d" != "/"
        if test -d $d/pci_bus
            basename $d
            return
        end
        set d (dirname $d)
    end
    echo "-"
end

function pcie_link --argument-names bdf
    if test -z "$bdf"
        echo "-"
        return
    end
    set -l cap (lspci -vv -s $bdf 2>/dev/null | string match -rg 'LnkCap:\s+Port #\d+, Speed (\S+), Width (x[0-9]+)')
    set -l sta (lspci -vv -s $bdf 2>/dev/null | string match -rg 'LnkSta:\s+Speed (\S+), Width (x[0-9]+)')
    if test (count $cap) -lt 2
        echo "-"
        return
    end
    set -l out "$cap[2] $cap[1]"
    if test (count $sta) -ge 2
        set out "$out → $sta[2] $sta[1]"
        set -l cw (string replace 'x' '' $cap[2])
        set -l sw (string replace 'x' '' $sta[2])
        if test $sw -lt $cw
            set out "$out ⚠ down"
        end
    end
    echo $out
end

function iface_addrs --argument-names i
    set -l out
    for a in (ip -o -4 addr show dev $i 2>/dev/null | string match -rg 'inet (\S+)')
        set out "$out $a"
    end
    for a in (ip -o -6 addr show dev $i 2>/dev/null | string match -rg 'inet6 (\S+)')
        if not string match -q -- "fe80:*" "$a"
            set out "$out $a"
        end
    end
    if test -z "$out"
        echo "-"
    else
        echo (string trim $out)
    end
end

function iface_master --argument-names i
    if test -L /sys/class/net/$i/master
        basename (readlink -f /sys/class/net/$i/master)
    else
        echo "-"
    end
end

function iface_linkfile --argument-names i
    set -l f (udevadm info /sys/class/net/$i 2>/dev/null | string match -rg 'ID_NET_LINK_FILE=(\S+)')
    if test -n "$f"
        basename $f
    else
        echo "-"
    end
end

# ---------- header ----------
set -l hname (hostname)
echo (c "1;36" "NET INVENTORY") (c "2" "· $hname · kernel "(uname -r)" · "(date "+%Y-%m-%d %H:%M"))
hr

# ---------- collect ----------
set -l allifs (for d in (ls /sys/class/net); if test -d /sys/class/net/$d; echo $d; end; end | sort)
set -l phys
set -l virt
for i in $allifs
    switch (iface_kind $i)
        case physical
            set phys $phys $i
        case "*"
            set virt $virt $i
    end
end

# ---------- physical ----------
echo (c "1;33" "PHYSICAL NICS")
printf "%-7s %-9s %-13s %-13s %-6s %-9s %-5s %-9s %-5s %-17s %-9s %s\n" \
    IFACE DRIVER PCI ROOTPORT STATE SPEED MAX MEDIA MTU MAC MASTER LINKFILE
for i in $phys
    set -l state (rd /sys/class/net/$i/operstate)
    set -l carrier (rd /sys/class/net/$i/carrier)
    if test $ONLY_UP -eq 1; and test "$carrier" != "1"
        continue
    end
    set -l dev (readlink -f /sys/class/net/$i/device)
    set -l bdf (basename $dev)
    set -l rp (iface_rootport $dev)
    set -l drv (basename (readlink -f /sys/class/net/$i/device/driver 2>/dev/null))
    set -l cur_num (ethtool $i 2>/dev/null | string match -rg 'Speed: (\S+)' | string replace -a 'Mb/s' '')
    if test -z "$cur_num"; or test "$cur_num" = "Unknown!"
        set cur_num 0
    end
    set -l maxn (iface_max_mode $i)
    set -l curflag ""
    if test $cur_num -gt $maxn; and test $maxn -gt 0
        # the driver declares less than what it negotiates: flag it
        set curflag "!"
        set maxn $cur_num
    end
    set -l cur "-"
    if test $cur_num -gt 0
        set cur (human_speed $cur_num)"$curflag"
    end
    set -l maxh (human_speed $maxn)
    set -l media (iface_media $i $drv)
    set -l mtu (rd /sys/class/net/$i/mtu)
    set -l mac (rd /sys/class/net/$i/address)
    set -l lf (iface_linkfile $i)
    set -l statecolor "32"
    if test "$carrier" != "1"
        set statecolor "31"
    end
    printf "%-7s %-9s %-13s %-13s " $i $drv $bdf $rp
    c $statecolor (printf "%-6s" $state)
    printf " %-8s %-5s %-9s %-5s %-17s %-9s %s\n" $cur $maxh $media $mtu $mac (iface_master $i) $lf
end
echo (c "2" "  MAX = highest speed declared in Supported link modes (or the current speed if higher).")
echo (c "2" "  !   = negotiated speed exceeds the driver's declared maximum (driver lying).")
echo (c "2" "  *   = media read from the driver debug file (r8127 hardcodes PORT_TP in ethtool).")
echo (c "2" "  n/a = driver does not report media (e.g. ice without an SFP module).")

# ---------- PCIe ----------
echo
echo (c "1;33" "PCIe LINK (slot capability -> negotiated)")
for i in $phys
    set -l car (rd /sys/class/net/$i/carrier)
    if test $ONLY_UP -eq 1; and test "$car" != "1"
        continue
    end
    set -l dev (readlink -f /sys/class/net/$i/device)
    set -l bdf (basename $dev)
    printf "  %-7s %-13s %s\n" $i $bdf (pcie_link $bdf)
end

# ---------- virtual ----------
echo
echo (c "1;33" "VIRTUAL INTERFACES")
printf "%-10s %-8s %-9s %-6s %-5s %-17s %-22s %s\n" IFACE KIND STATE CARRIER MTU MAC MASTER MEMBERS
for i in $virt
    set -l kind (iface_kind $i)
    set -l state (rd /sys/class/net/$i/operstate)
    set -l carrier (rd /sys/class/net/$i/carrier)
    if test $ONLY_UP -eq 1
        if test "$carrier" != "1"; and test "$state" != "up"
            continue
        end
    end
    set -l mtu (rd /sys/class/net/$i/mtu)
    set -l mac (rd /sys/class/net/$i/address)
    set -l master (iface_master $i)
    set -l members "-"
    if test -d /sys/class/net/$i/brif
        set members (ls /sys/class/net/$i/brif | string join ',')
    end
    if test -d /sys/class/net/$i/bonding
        set members (ls /sys/class/net/$i/lower_* 2>/dev/null | string replace -a '/sys/class/net/' '' | string join ',')
    end
    printf "%-10s %-8s %-9s %-6s %-5s %-17s %-22s %s\n" $i $kind $state $carrier $mtu $mac $master "$members"
end

# ---------- addresses ----------
echo
echo (c "1;33" "IP ADDRESSES")
for i in $allifs
    set -l addrs (iface_addrs $i)
    if test "$addrs" = "-"
        continue
    end
    printf "  %-10s %s\n" $i "$addrs"
end

# ---------- bridges: port state ----------
set -l bridges
for i in $allifs
    if test -d /sys/class/net/$i/bridge
        set bridges $bridges $i
    end
end
if test (count $bridges) -gt 0
    echo
    echo (c "1;33" "BRIDGE — PORT STATE")
    for b in $bridges
        printf "  %s (stp=%s)\n" $b (rd /sys/class/net/$b/bridge/stp_state)
        if test -d /sys/class/net/$b/brif
            for p in (ls /sys/class/net/$b/brif)
                set -l st (rd /sys/class/net/$p/brport/state)
                set -l pstate "?"
                switch $st
                    case 0
                        set pstate "disabled"
                    case 1
                        set pstate "listening"
                    case 2
                        set pstate "learning"
                    case 3
                        set pstate "forwarding"
                    case 4
                        set pstate "blocking"
                end
                printf "    %-7s state=%-11s mtu=%s\n" $p $pstate (rd /sys/class/net/$p/mtu)
            end
        end
    end
end

# ---------- VLAN ----------
set -l vlans
for i in $allifs
    if string match -q vlan (iface_kind $i)
        set vlans $vlans $i
    end
end
if test (count $vlans) -gt 0
    echo
    echo (c "1;33" "VLAN")
    for v in $vlans
        set -l parent (ls /sys/class/net/$v/lower_* 2>/dev/null | head -n1 | string replace -a '/sys/class/net/' '')
        printf "  %-10s parent=%s\n" $v "$parent"
    end
end

# ---------- summary ----------
echo
hr
set -l up 0
for i in $phys
    set -l car (rd /sys/class/net/$i/carrier)
    if test "$car" = "1"
        set up (math $up + 1)
    end
end
set -l noip 0
for i in $allifs
    set -l k (iface_kind $i)
    if test "$k" = "physical"; or test "$k" = "bridge"
        set -l a (iface_addrs $i)
        if test "$a" = "-"
            set noip (math $noip + 1)
        end
    end
end
echo (c "2" "summary: ")(count $phys)" physical ("$up" with link) · "(count $bridges)" bridges · "(count $vlans)" vlans · "$noip" interfaces without IP"

# ---------- detail ----------
if test -n "$DETAIL"
    if not test -e /sys/class/net/$DETAIL
        echo; echo (c "31" "interface $DETAIL does not exist")
        exit 1
    end
    echo
    echo (c "1;33" "DETAIL $DETAIL")
    echo "  kind   : "(iface_kind $DETAIL)
    echo "  driver : "(basename (readlink -f /sys/class/net/$DETAIL/device/driver 2>/dev/null))
    echo "  pci    : "(basename (readlink -f /sys/class/net/$DETAIL/device 2>/dev/null))
    echo "  udev   : "(udevadm info /sys/class/net/$DETAIL 2>/dev/null | string match -r 'E: ID_NET_NAME\S*=.*' | string join ' · ')
    echo
    echo (c "2" "  ethtool -i")
    ethtool -i $DETAIL 2>/dev/null | sed 's/^/    /'
    echo (c "2" "  ethtool")
    ethtool $DETAIL 2>/dev/null | sed -n '/Supported link modes/,/Link detected/p' | sed 's/^/    /'
    echo (c "2" "  SFP")
    set -l m (ethtool -m $DETAIL 2>&1)
    if string match -qi -- "*not supported*" "$m"; or string match -qi -- "*Operation not supported*" "$m"
        echo "    no readable module (or driver without SFP support)"
    else
        echo "$m" | sed -n '1,25p' | sed 's/^/    /'
    end
    echo (c "2" "  error counters")
    ethtool -S $DETAIL 2>/dev/null | grep -E "rx_errors|tx_errors|rx_dropped|tx_dropped|rx_crc|rx_missed" | sed 's/^/    /'
    echo (c "2" "  addresses")
    ip addr show dev $DETAIL | sed 's/^/    /'
end
