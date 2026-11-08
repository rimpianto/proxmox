#!/usr/bin/env fish
# update-container.fish — bump a pinned image tag and recreate the container.
# Runs on the PVE host (fribourg). Service registry is the switch below.
# Usage:
#   fish update-container.fish <service>              # show current tag
#   fish update-container.fish <service> <new-tag>    # bump + recreate
#   fish update-container.fish <service> <new-tag> --dry   # dry run

set -g VERSION "1.4.0"

function service_info
    switch $argv[1]
        case npm
            echo "195 /var/lib/docker/volumes/hawser_stacks/_data/nginx/compose.yaml jc21/nginx-proxy-manager"
        case adguard
            echo "253 /opt/adguardhome/docker-compose.yml adguard/adguardhome"
        case unbound
            echo "252 /opt/unbound/docker-compose.yml mvance/unbound"
        case postgres
            echo "210 /var/lib/docker/volumes/hawser_stacks/_data/pg/compose.yaml postgres"
        case odoo-web
            echo "202 /opt/odoo/docker-compose.yml odoo"
        case odoo-db
            echo "202 /opt/odoo/docker-compose.yml postgres"
        case soon-nginx
            echo "100 /opt/coming-soon/docker/docker-compose.yml nginx"
        case soon-mongo
            echo "100 /opt/coming-soon/docker/docker-compose.yml mongo"
        case soon-certbot
            echo "100 /opt/coming-soon/docker/docker-compose.yml certbot/certbot"
        case wud
            echo "107 /opt/wud/docker-compose.yml getwud/wud"
        case '*'
            return 1
    end
end

function usage
    echo "usage: update-container.fish <service> [<new-tag>] [--dry]"
    echo "services: npm adguard unbound postgres odoo-web odoo-db soon-nginx soon-mongo soon-certbot wud"
end

function wud_suggest
    # returns the newer tag WUD detected for $repo, or empty if unknown
    set -l repo $argv[1]
    set -l passfile /root/.wud-admin-pass
    if not test -f $passfile
        return 1
    end
    set -l pass (cat $passfile | string trim)
    set -l json (curl -s -m 6 -u "admin:$pass" "http://192.168.100.107:3000/api/containers" 2>/dev/null)
    if test -z "$json"
        return 1
    end
    set -l target (printf "%s" "$json" | env REPO="$repo" python3 -c 'import sys,json,os; d=json.load(sys.stdin); r=[c for c in d if c.get("image",{}).get("name")==os.environ["REPO"]]; print((r[0]["result"]["tag"] if r and r[0].get("updateAvailable") and r[0].get("result") and r[0]["result"].get("tag") else ""))' 2>/dev/null)
    if test -z "$target"
        return 1
    end
    echo $target
    return 0
end

if test "$argv[1]" = "--version"; or test "$argv[1]" = "-V"
    echo "update-container.fish v$VERSION"
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
if test (count $fields) -lt 3
    echo "unknown service: $svc" >&2
    usage
    exit 1
end
set -l ct $fields[1]
set -l compose $fields[2]
set -l repo $fields[3]

echo "[update-container.fish v$VERSION] $svc  ct=$ct  repo=$repo"

# status query: no new tag given, show current tag + WUD's suggestion
if test -z "$newtag"
    echo "[current]"
    pct exec $ct -- grep -E "image:.*$repo:" "$compose"
    set -l target (wud_suggest $repo)
    if test -n "$target"
        echo "[available] $repo:$target"
        echo "[suggested] update-container.fish $svc $target"
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

# 3. bump the tag (replace repo:TAG with repo:newtag, keeping any quotes)
if not pct exec $ct -- sed -i "s|$repo:[^ '\"]*|$repo:$newtag|" "$compose"
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
