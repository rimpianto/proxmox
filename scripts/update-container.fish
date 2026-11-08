#!/usr/bin/env fish
# update-container.fish — bump a pinned image tag and recreate the container.
# Runs on the PVE host (fribourg). Service registry is the switch below.
# Usage:
#   fish update-container.fish <service> <new-tag> [--dry]
# Example:
#   fish update-container.fish npm 2.16.0

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
    echo "usage: update-container.fish <service> <new-tag> [--dry]"
    echo "services: npm adguard unbound postgres odoo-web odoo-db soon-nginx soon-mongo soon-certbot wud"
end

if test (count $argv) -lt 2
    usage
    exit 2
end

set -l svc $argv[1]
set -l newtag $argv[2]
set -l dry 0
if test (count $argv) -ge 3; and test "$argv[3]" = "--dry"
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

echo "[service] $svc  ct=$ct  compose=$compose  repo=$repo  ->  $newtag"

if test $dry -eq 1
    echo "[dry] would: backup $compose, sed $repo:TAG -> $repo:$newtag, compose pull + up -d on CT $ct"
    exit 0
end

# 1. backup the compose file
set -l ts (date +%F-%H%M)
if not pct exec $ct -- cp "$compose" "{$compose}.bak-{$ts}"
    echo "[error] backup failed" >&2
    exit 1
end
echo "[backup] {$compose}.bak-{$ts}"

# 2. bump the tag (replace repo:TAG with repo:newtag, keeping any quotes)
if not pct exec $ct -- sed -i "s|$repo:[^ '\"]*|$repo:$newtag|" "$compose"
    echo "[error] sed failed" >&2
    exit 1
end
pct exec $ct -- grep -E "image:.*$repo:" "$compose"

# 3. validate, pull, recreate
set -l dir (path dirname "$compose")
if not pct exec $ct -- bash -c "cd $dir && docker compose config -q && docker compose pull && docker compose up -d"
    echo "[error] compose up failed (restore with: cp {$compose}.bak-{$ts} $compose)" >&2
    exit 1
end

# 4. status
sleep 3
pct exec $ct -- docker ps --format '{{.Names}}|{{.Image}}|{{.Status}}'
