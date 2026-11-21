# Proxmox VE Automated Upgrade & Conditional Reboot (`v1.5.0`)

Automazione completa dell'aggiornamento dei nodi Proxmox VE (`apt update`, `apt full-upgrade`, `apt autoremove`) con rilevamento intelligente del riavvio necessario, spegnimento controllato di container LXC e VM, logging su file e notifica email finale.

## Funzionalità principali

- **Aggiornamento non interattivo sicuro:** imposta `DEBIAN_FRONTEND=noninteractive` e `NEEDRESTART_MODE=l` per evitare interruzioni o riavvii prematuri dei servizi Proxmox durante `apt full-upgrade`.
- **Triplo controllo per il reboot:**
  1. Verifica la presenza di `/var/run/reboot-required`.
  2. Interroga `needrestart -b` (`NEEDRESTART-KSTA` / `NEEDRESTART-UCSTA`).
  3. Confronta il kernel in esecuzione (`uname -r`) con l'ultimo kernel installato in `/boot/vmlinuz-*`.
- **Spegnimento controllato dei guest:** arresta in modo pulito tutti i container LXC attivi (**escluso l'ID `205`**) e tutte le VM QEMU, attendendo fino a 180 secondi prima di procedere al `reboot` (in caso di timeout blocca il riavvio e invia un'email di errore).
- **Modalità simulazione (`--dry-run` / `-d`):** mostra la diagnostica del kernel, i guest che verrebbero spenti e l'anteprima dell'email senza apportare alcuna modifica.
- **Notifica email a fine esecuzione:** invia il log dell'esecuzione tramite `/usr/sbin/sendmail` (default: `noc@rimpianto.com`, personalizzabile con `-m` / `--mail-to`).

---

## Struttura dei file

```text
proxmox/
├── docs/
│   └── README-pve-auto-upgrade.md              # Questa documentazione
└── scripts/
    ├── upgrade_and_reboot-host.ver1.5.0.fish   # Script principale
    ├── upgrade_and_reboot-host.fish            # Symlink all'ultima versione (creato dall'installer)
    └── install-pve-auto-upgrade.fish           # Installer automatico (symlink, systemd, timer, logrotate)
```

---

## Installazione su un nuovo nodo Proxmox VE (shell `fish`)

1. **Verifica che la shell `fish` sia installata e clona il repository:**
   ```fish
   which fish; or begin; apt update; and apt install -y fish; end
   git clone [https://github.com/rimpianto/proxmox.git](https://github.com/rimpianto/proxmox.git) /root/proxmox
   ```

2. **Esegui lo script di installazione:**
   ```fish
   /root/proxmox/scripts/install-pve-auto-upgrade.fish
   ```
   Lo script crea il symlink `upgrade_and_reboot-host.fish`, genera `/etc/systemd/system/pve-auto-upgrade.service`, `/etc/systemd/system/pve-auto-upgrade.timer` (schedulato **ogni giorno alle 06:00** con `RandomizedDelaySec=10m` e `Persistent=false`) e `/etc/logrotate.d/pve-auto-upgrade`, abilita il timer ed esegue subito un `--dry-run` di verifica.

---

## Gestione e comandi utili

- **Simulazione senza modifiche:**
  ```fish
  /root/proxmox/scripts/upgrade_and_reboot-host.fish -d
  ```
- **Esecuzione manuale immediata tramite systemd:**
  ```fish
  systemctl start --no-block pve-auto-upgrade.service
  ```
- **Verifica prossima esecuzione programmata:**
  ```fish
  systemctl list-timers pve-auto-upgrade.timer
  ```
- **Controllo log e coda email:**
  ```fish
  cat /var/log/pve-auto-upgrade.log
  postqueue -p
  ```
