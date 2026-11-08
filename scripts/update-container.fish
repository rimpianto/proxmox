#!/usr/bin/env fish
# update-container.fish — bump a pinned image tag and recreate the container.
# Portable across hosts: the WUD URL and the service registry live in
# /etc/update-container.conf (one per host), so this single script works on
# both fribourg (192.168.100.x) and dell7760 (192.168.97.x).
#
# Usage:
#   update-container.fish list                 # table: LXC / container / version / update
#   update-container.fish <service>            # show current tag + available update
#   update-container.fish <service> <new-tag>  # bump + recreate
#   update-container.fish <service> <new-tag> --dry

set -g VERSION "1.6.1"
set -g CONFIG /etc/update-container.conf

function config_wud_url
    awk '$1 == "WUD_URL" {print $2; exit}' $CONFIG
end

function service_info
    # echo "ct compose-path repo container-name" for $argv[1]
    awk -v s="$argv[1]" '$1 == s && NF >= 5 {print $2, $3, $4, $5}' $CONFIG
end

function all_services
    awk 'NF >= 5 && $1 !~ /^#/ {print $1}' $CONFIG
end

function usage
    echo "usage: update-container.fish <service> [<new-tag>] [--dry]"
    echo "       update-container.fish list"
    echo "services: "(all_services | string join " ")
end

function wud_suggest
    # returns "newtag|diff" for the container named $argv[1], or empty if unknown
    set -l cname $argv[1]
    set -l passfile /root/.wud-admin-pass
    if not test -f $passfile
        return 1
    end
    set -l pass (cat $passfile | string trim)
    set -l wudurl (config_wud_url)
    set -l json (curl -s -m 6 -u "admin:$pass" "$wudurl/api/containers" 2>/dev/null)
    if test -z "$json"
        return 1
    end
    set -l target (printf "%s" "$json" | env CNAME="$cname" python3 -c 'import sys,json,os; d=json.load(sys.stdin); n=os.environ["CNAME"]; r=[c for c in d if c.get("name")==n]; c=r[0] if r and r[0].get("updateAvailable") and r[0].get("result") and r[0]["result"].get("tag") else None; print((c["result"]["tag"]+"|"+((c.get("updateKind") or {}).get("semverDiff") or "?")) if c else "")' 2>/dev/null)
    if test -z "$target"
        return 1
    end
    echo $target
    return 0
end

function list_all
    # table of every service: LXC (CT) / container / current tag / available / diff kind
    set -l passfile /root/.wud-admin-pass
    if not test -f $passfile
        echo "[error] /root/.wud-admin-pass missing — create it to enable the list (needs WUD API)"
        return 1
    end
    set -l pass (cat $passfile | string trim)
    set -l wudurl (config_wud_url)
    set -l json (curl -s -m 6 -u "admin:$pass" "$wudurl/api/containers" 2>/dev/null)
    if test -z "$json"
        echo "[error] WUD unreachable at $wudurl"
        return 1
    end
    set -l rows
    for svc in (all_services)
        set -l fields (service_info $svc | string split " ")
        set -l ct $fields[1]
        set -l cname $fields[4]
        set -l row (printf "%s" "$json" | env CNAME="$cname" python3 -c 'import sys,json,os; d=json.load(sys.stdin); n=os.environ["CNAME"]; r=[c for c in d if c.get("name")==n]; c=r[0] if r else None; cur=c["image"]["tag"]["value"] if c else "?"; up=bool(c and c.get("updateAvailable") and c.get("result") and c["result"].get("tag")); avail=(c["result"]["tag"] if up else "-"); kind=((c.get("updateKind") or {}).get("semverDiff") if up else "-"); print(cur+"|"+avail+"|"+kind)' 2>/dev/null)
        set -l parts (string split "|" $row)
        set -a rows "$svc|$ct|$cname|$parts[1]|$parts[2]|$parts[3]"
    end
    printf "%s\n" $rows | python3 -c 'import sys; h=["SERVICE","CT","CONTAINER","CURRENT","AVAILABLE","KIND"]; rows=[l.split("|") for l in sys.stdin.read().splitlines() if l.strip()]; a=[h]+rows; w=[max(len(r[i]) for r in a) for i in range(6)]; [print("  ".join(r[i].ljust(w[i]) for i in range(6))) for r in a]'
end

if test "$argv[1]" = "--version"; or test "$argv[1]" = "-V"
    echo "update-container.fish v$VERSION"
    exit 0
end

if test "$argv[1]" = "--help"; or test "$argv[1]" = "-h"
    echo "update-container.fish v$VERSION"
    usage
    exit 0
end

if test "$argv[1]" = "list"; or test "$argv[1]" = "ls"
    echo "[update-container.fish v$VERSION]"
    list_all
    exit 0
end

if test (count $argv) -lt 1
    usage
    exit 2
end

set -l svc $argv[1]
set -l newtag ""
set -l dry 0
if test (count $argv) -ge 2
    set newtag $argv[2]
end
if test "$newtag" = "--dry"
    set newtag ""
    set dry 1
else if test (count $argv) -ge 3; and test "$argv[3]" = "--dry"
    set dry 1
end

set -l fields (service_info $svc | string split " ")
if test (count $fields) -lt 4
    echo "unknown service: $svc" >&2
    usage
    exit 1
end
set -l ct $fields[1]
set -l compose $fields[2]
set -l repo $fields[3]
set -l cname $fields[4]

echo "[update-container.fish v$VERSION] $svc  ct=$ct  repo=$repo"

# status query: no new tag given, show current tag + WUD's suggestion
if test -z "$newtag"
    echo "[current]"
    pct exec $ct -- grep -E "image:.*$repo:" "$compose"
    set -l target (wud_suggest $cname)
    if test -n "$target"
        set -l parts (string split "|" $target)
        set -l tag $parts[1]
        set -l diff $parts[2]
        echo "[available] $repo:$tag  ($diff)"
        if test "$diff" = "major"
            echo "[warning] major jump — do NOT update in one step (incremental upgrade required, e.g. mongo 7->8->9)"
        else if test "$diff" = "prerelease"
            echo "[note] prerelease/variant — not a real version update, skip"
        else
            echo "[suggested] update-container.fish $svc $tag"
        end
    else
        echo "[available] none (up to date, or WUD unreachable — create /root/.wud-admin-pass)"
    end
    exit 0
end

echo "[update] $repo -> $newtag"

if test $dry -eq 1
    echo "[dry] would: backup $compose, docker pull $repo:$newtag, sed, compose up -d on CT $ct"
    exit 0
end

# 1. backup the compose file
set -l ts (date +%F-%H%M)
if not pct exec $ct -- cp "$compose" "$compose.bak-$ts"
    echo "[error] backup failed" >&2
    exit 1
end
echo "[backup] $compose.bak-$ts"

# 2. validate + pre-pull the new tag (fail BEFORE touching the compose)
if not pct exec $ct -- docker pull "$repo:$newtag"
    echo "[error] cannot pull $repo:$newtag (tag not found? certbot/adguard use a v prefix, e.g. v5.9.0)" >&2
    echo "[error] compose left untouched" >&2
    exit 1
end

# 3. bump the tag (anchor to image: so it never hits the service key)
if not pct exec $ct -- sed -i "s|\(image:.*$repo:\)[^ '\"]*|\1$newtag|" "$compose"
    echo "[error] sed failed" >&2
    exit 1
end
pct exec $ct -- grep -E "image:.*$repo:" "$compose"

# 4. recreate (image already pulled)
set -l dir (path dirname "$compose")
if not pct exec $ct -- bash -c "cd $dir && docker compose config -q && docker compose up -d"
    echo "[error] compose up failed (restore: cp $compose.bak-$ts $compose)" >&2
    exit 1
end

# 5. status
sleep 3
pct exec $ct -- docker ps --format '{{.Names}}|{{.Image}}|{{.Status}}'
