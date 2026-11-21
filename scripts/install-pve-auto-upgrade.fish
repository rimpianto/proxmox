#!/usr/bin/env fish

# Installer per Proxmox VE Automated Upgrade & Conditional Reboot

if test (id -u) -ne 0
    echo "Errore: questo script deve essere eseguito come root."
    exit 1
end

set -l script_dir (realpath (dirname (status -f)))
set -l target_script (find "$script_dir" -maxdepth 1 -name "upgrade_and_reboot-host.ver*.fish" | sort -V | tail -n 1)

if test -z "$target_script"
    echo "Errore: nessuno script upgrade_and_reboot-host.ver*.fish trovato in $script_dir"
    exit 1
end

echo "=== Installazione pve-auto-upgrade ==="
echo "Directory script : $script_dir"
echo "Versione rilevata: "(basename "$target_script")

chmod +x "$target_script"
ln -sf "$target_script" "$script_dir/upgrade_and_reboot-host.fish"
echo "[OK] Symlink creato: upgrade_and_reboot-host.fish -> "(basename "$target_script")

string join \n \
    "[Unit]" \
    "Description=Proxmox VE Automated Upgrade and Conditional Reboot" \
    "Wants=network-online.target" \
    "After=network-online.target pve-cluster.service postfix.service" \
    "" \
    "[Service]" \
    "Type=oneshot" \
    "User=root" \
    'Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"' \
    "ExecStart=/usr/bin/fish $script_dir/upgrade_and_reboot-host.fish" \
    > /etc/systemd/system/pve-auto-upgrade.service
echo "[OK] Creato /etc/systemd/system/pve-auto-upgrade.service"

string join \n \
    "[Unit]" \
    "Description=Daily Proxmox VE Upgrade & Reboot Timer" \
    "" \
    "[Timer]" \
    "OnCalendar=*-*-* 06:00:00" \
    "RandomizedDelaySec=10m" \
    "Persistent=false" \
    "" \
    "[Install]" \
    "WantedBy=timers.target" \
    > /etc/systemd/system/pve-auto-upgrade.timer
echo "[OK] Creato /etc/systemd/system/pve-auto-upgrade.timer (ogni giorno alle 06:00)"

string join \n \
    "/var/log/pve-auto-upgrade.log {" \
    "    monthly" \
    "    rotate 6" \
    "    compress" \
    "    delaycompress" \
    "    missingok" \
    "    notifempty" \
    "    create 0640 root adm" \
    "}" \
    > /etc/logrotate.d/pve-auto-upgrade
echo "[OK] Creato /etc/logrotate.d/pve-auto-upgrade"

systemctl daemon-reload
systemctl enable --now pve-auto-upgrade.timer
echo "[OK] Timer systemd abilitato e avviato"

echo ""
echo "=== Prossima esecuzione programmata ==="
systemctl list-timers pve-auto-upgrade.timer --no-pager

echo ""
echo "=== Verifica rapida (--dry-run) ==="
"$script_dir/upgrade_and_reboot-host.fish" -d

