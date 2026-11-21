# Proxmox VE helper scripts & automation

Scripts and automation used to operate Proxmox VE nodes: automatic host
upgrades with conditional reboot (the **pve-auto-upgrade** system below),
safe guest shutdown, LXC package updates, standalone node renaming, read-only
network and NVMe inventories, an interactive security/audit menu, and pinned
Docker container updates (WUD companion).

Tested on Proxmox VE 9.x (Debian 13) with `fish` 3.7+/4.x. Written for the
author's homelab — paths, CT IDs and mail recipients are site-specific; read
each script before running it on your own host.

All command examples in this repository use **fish** syntax.

**New here?** See [Getting started](docs/getting-started.md) for cloning,
updating a local checkout and contributing new files.

## Repository layout

```text
proxmox/
├── .gitignore                                  # ignores the generated symlink below
├── LICENSE                                     # GNU GPL v3.0
├── README.md                                   # this document
├── docs/
│   ├── README-pve-auto-upgrade.md              # pve-auto-upgrade architecture & ops reference
│   ├── getting-started.md                      # clone / update / contribute guide
│   └── proxmox-audit.md                        # full manual for proxmox_audit-ver01A.fish
└── scripts/
    ├── install-pve-auto-upgrade.fish           # idempotent installer (symlink + systemd + logrotate)
    ├── upgrade_and_reboot-host.ver1.5.0.fish   # upgrade engine with conditional reboot
    ├── update-all-lxcs.fish                    # apt upgrade inside every running LXC
    ├── update-all-lxcs.sh                      # same logic, bash variant
    ├── stop_all.fish                           # vzdump backup, then shut down all guests
    ├── stop_all_noBackup.fish                  # shut down all guests, no backup
    ├── pve_rename-ver.2.1.fish                 # rename a standalone node (v2.1)
    ├── net-inventory.fish                      # read-only NIC inventory
    ├── nvme-inventory.fish                     # read-only NVMe inventory
    ├── proxmox_audit-ver01A.fish               # interactive audit menu (v0.1A)
    ├── update-container.fish                   # bump a pinned Docker tag + recreate (v1.6.1)
    └── update-container.conf.example           # template for /etc/update-container.conf
```

`scripts/upgrade_and_reboot-host.fish` is intentionally **not in Git**: it is
a symlink generated locally by the installer and excluded via `.gitignore`
(see the pve-auto-upgrade section).

## Script index

| Script | Purpose | Changes the system |
|---|---|---|
| [`upgrade_and_reboot-host.ver1.5.0.fish`](scripts/upgrade_and_reboot-host.ver1.5.0.fish) | `apt update` + `full-upgrade` + `autoremove`; 3-level reboot detection; controlled guest shutdown; email report; conditional `reboot` | yes (packages, shutdowns, possible reboot) |
| [`install-pve-auto-upgrade.fish`](scripts/install-pve-auto-upgrade.fish) | Idempotent installer for the script above: symlink, systemd service + daily timer, logrotate, dry-run verification | yes (system units, logrotate) |
| [`update-all-lxcs.fish`](scripts/update-all-lxcs.fish) | `apt-get update` / `full-upgrade` / `autoremove` / `clean` inside every **running** LXC via `pct exec` | yes (packages inside CTs) |
| [`update-all-lxcs.sh`](scripts/update-all-lxcs.sh) | Same logic as a bash script | yes (packages inside CTs) |
| [`stop_all.fish`](scripts/stop_all.fish) | `vzdump` snapshot backup of every guest, then graceful shutdown of all LXCs and VMs, then wait | yes (backup + shutdown) |
| [`stop_all_noBackup.fish`](scripts/stop_all_noBackup.fish) | Same shutdown sequence **without** the backup | yes (shutdown) |
| [`pve_rename-ver.2.1.fish`](scripts/pve_rename-ver.2.1.fish) | Rename a **standalone** PVE node (hostname, `/etc/hosts`, node directory in `/etc/pve`) with pre-flight backups | yes |
| [`net-inventory.fish`](scripts/net-inventory.fish) | Read-only inventory of NICs: driver, PCI, speed, media, MTU, master/bridge, IPs, PCIe link | **no** |
| [`nvme-inventory.fish`](scripts/nvme-inventory.fish) | Read-only inventory of NVMe drives: model, capacity, PCIe link/gen, SMART health, endurance, who uses them | **no** |
| [`proxmox_audit-ver01A.fish`](scripts/proxmox_audit-ver01A.fish) | Interactive menu for sessions, SSH/GUI login history, ports, processes, cron and rootkit scanners | no configuration changes; scanners may write logs |
| [`update-container.fish`](scripts/update-container.fish) | Bump a pinned Docker image tag and recreate one container (manual-update companion to a report-only WUD) | yes (recreate) |
| [`update-container.conf.example`](scripts/update-container.conf.example) | Template for the per-host `/etc/update-container.conf` registry (not executable) | — |

Requirements: `root` (except the inventory scripts), `fish`, and the usual
Proxmox CLI tools (`pct`, `qm`, `vzdump`, `pvesh`) already present on a PVE
host.

---

## The automatic upgrade system (pve-auto-upgrade)

Architecture details and the full operations reference live in
[`docs/README-pve-auto-upgrade.md`](docs/README-pve-auto-upgrade.md).
This section is the summary of record for both scripts.

### `upgrade_and_reboot-host.ver1.5.0.fish` — the upgrade engine

Command line (via `argparse`):

| Flag | Meaning |
|---|---|
| `-d`, `--dry-run` | Simulate: show kernel diagnostics, shutdown targets and email preview; nothing is changed |
| `-m`, `--mail-to EMAIL` | Report recipient (code default: `noc@rimpianto.com`) |
| `-h`, `--help` | Usage |

What it does, in order:

1. **Non-interactive upgrade.** Exports `DEBIAN_FRONTEND=noninteractive` and
   `NEEDRESTART_MODE=l`, then runs `apt update` and
   `apt -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" full-upgrade -y`
   (existing config files are kept: no conffile prompts, no `.dpkg-new`
   surprises). A failure in either step aborts the run and mails an error
   report.
2. **Cleanup.** `apt autoremove -y` (old kernels included).
3. **3-level reboot detection** — any one of these triggers the reboot path:
   - `/var/run/reboot-required` exists;
   - `needrestart -b` reports `NEEDRESTART-KSTA`/`NEEDRESTART-UCSTA` pending
     (value 2 or 3: kernel or microcode update);
   - the running kernel (`uname -r`) differs from the newest installed
     `/boot/vmlinuz-*` (compared with `sort -V`).
4. **Controlled shutdown, then reboot** (only when a reboot is required):
   `pct shutdown` for every running LXC — **excluding CT ID `205`** on
   purpose (site-specific exception) — and `qm shutdown` for every running
   QEMU VM; then wait for all of them to go down, up to **180 s** (60 polls
   × 3 s). On timeout the automatic reboot is **aborted** to prevent data
   corruption and an error email is sent. On success the host mails the
   report and executes `reboot`.
5. **Logging and reporting.** Every run is appended (timestamped, via `tee`)
   to `/var/log/pve-auto-upgrade.log`, with a fallback to
   `/tmp/pve-auto-upgrade.log` when `/var/log` is not writable (non-root
   `--dry-run`). At the end the run log is mailed through
   `/usr/sbin/sendmail -t` with subject prefix `[<hostname>] Proxmox
   Upgrade:` (success, reboot, or error variants); recipient
   `noc@rimpianto.com` by default — chosen so Proxmox VE's built-in
   Datacenter → Notifications forwarding picks it up — overridable with
   `-m`/`--mail-to`.

v1.5.0 replaces v1.3.0 (removed from the repo). Compared to 1.3.0 it adds
`--dry-run`, the two extra reboot checks (`needrestart`, kernel comparison),
file logging, email reporting, and a **working** wait loop: the old LXC
condition was ineffective (only VMs were actually awaited), and 180 s
aborts instead of waiting forever.

### `install-pve-auto-upgrade.fish` — the idempotent installer

Must run as root, from any checkout of this repo. Re-running it is safe: it
recreates everything it manages.

1. Picks the newest `scripts/upgrade_and_reboot-host.ver*.fish` in its own
   directory (`sort -V | tail -n 1`), `chmod +x` on it, and creates the
   local symlink `scripts/upgrade_and_reboot-host.fish` → versioned file.
   The symlink is a **generated artifact**: systemd points at it (not at a
   versioned name), it is excluded from Git tracking by the root
   [`.gitignore`](.gitignore), and bumping the engine = drop the new
   `ver*.fish` in `scripts/` and re-run the installer.
2. Writes `/etc/systemd/system/pve-auto-upgrade.service` — `Type=oneshot`,
   `User=root`, `After=network-online.target pve-cluster.service
   postfix.service`, `ExecStart=/usr/bin/fish <repo>/scripts/upgrade_and_reboot-host.fish`.
3. Writes `/etc/systemd/system/pve-auto-upgrade.timer` — **daily at 06:00**
   (`OnCalendar=*-*-* 06:00:00`) with `RandomizedDelaySec=10m` and
   `Persistent=false` (no catch-up run after downtime), `WantedBy=timers.target`.
4. Writes `/etc/logrotate.d/pve-auto-upgrade` — `/var/log/pve-auto-upgrade.log`
   monthly, rotate 6, compress + delaycompress, `create 0640 root adm`.
5. `systemctl daemon-reload`, `systemctl enable --now pve-auto-upgrade.timer`,
   prints the next scheduled run (`systemctl list-timers`) and finishes with
   a live `--dry-run` verification of the engine.

### Quick start on a new Proxmox VE node

```fish
# 1. make sure fish is installed (Debian package name is `fish`)
which fish; or begin; apt update; and apt install -y fish; end

# 2. clone the repository (git too, if missing)
which git; or begin; apt update; and apt install -y git; end
git clone https://github.com/rimpianto/proxmox.git /root/proxmox

# 3. install the automation (root; ends with a built-in --dry-run check)
/root/proxmox/scripts/install-pve-auto-upgrade.fish
```

Day-to-day operation (all commands as root, in fish):

```fish
/root/proxmox/scripts/upgrade_and_reboot-host.fish -d                 # simulate, change nothing
/root/proxmox/scripts/upgrade_and_reboot-host.fish -m noc@example.com # manual run, custom recipient
# trigger the timer job now and follow the progress live (Ctrl+C detaches, the job keeps running)
systemctl start --no-block pve-auto-upgrade.service; and tail -f /var/log/pve-auto-upgrade.log
systemctl list-timers pve-auto-upgrade.timer                          # next scheduled run
tail -n 50 /var/log/pve-auto-upgrade.log                              # last run log
postqueue -p                                                          # postfix mail queue
```

---

## Other scripts in detail

### update-all-lxcs.fish

Loops over `pct list` (running only) and runs, inside each container,
`DEBIAN_FRONTEND=noninteractive` + `apt-get update` + `apt-get full-upgrade -y`
(`--force-confdef --force-confold`) + `apt-get autoremove -y` + `apt-get clean`,
then prints a per-CT OK/ERROR summary. `update-all-lxcs.sh` is the bash twin.

```fish
/root/proxmox/scripts/update-all-lxcs.fish
```

### stop_all.fish / stop_all_noBackup.fish

Both shut down every running guest gracefully (`pct shutdown`, `qm shutdown`)
and wait until nothing is running. `stop_all.fish` first backs everything up
with `vzdump --all --mode snapshot --compress zstd` (default storage — check
free space; add `--storage <name>` on the vzdump line to redirect).
`stop_all_noBackup.fish` has the backup lines commented out. The wait loop
has no timeout: a stuck guest waits forever (Ctrl+C and stop it by hand).

### pve_rename-ver.2.1.fish

Renames a **standalone** node without losing guests: requires exactly two
arguments, validates the new name against RFC 1123, **refuses to run on a
cluster**, takes pre-flight backups (`/etc/pve`, `config.db`, `/etc/hosts`,
`/etc/hostname`, `/etc/network/interfaces`), copies
`/etc/pve/nodes/<old>/` → `/etc/pve/nodes/<new>/`, updates hostname and
hosts, and prints (but does not run) the cleanup command for the old node
directory. Run it from the console or an out-of-band session.

```fish
./scripts/pve_rename-ver.2.1.fish pve-old pve-lab
```

### net-inventory.fish (read-only)

```fish
net-inventory.fish               # full inventory
net-inventory.fish --up          # only interfaces with carrier/link (-u)
net-inventory.fish -d nic3       # detail for one interface (--detail)
net-inventory.fish --no-color    # no ANSI colours (-n)
```

Sections: physical NICs (driver, PCI, current/max speed, media, MTU, MAC,
master, `.link` file), PCIe `LnkCap` → `LnkSta` with downgraded-slot
warnings, virtual interfaces, IP addresses, bridge port/STP state, VLANs,
summary. Safe for any user; dependencies: `iproute2`, `pciutils`, `ethtool`,
`udevadm`.

### nvme-inventory.fish (read-only)

```fish
nvme-inventory.fish              # table
nvme-inventory.fish -d nvme1n1   # full detail for one device (--detail)
nvme-inventory.fish --no-color   # (-n)
```

Per namespace: model, size, PCIe capability vs negotiated link (gen), SMART
health, temperature, endurance used %, and what consumes it (`zfs`, mount,
partitions, unused). Dependencies: `pciutils`, `smartmontools`, `util-linux`;
`zfsutils-linux` optional.

### proxmox_audit-ver01A.fish

Interactive menu (no command-line options; needs a TTY, normally root):
current users and sessions, successful/failed SSH and Proxmox GUI logins,
listening ports and established connections, process lookup, root cron,
`chkrootkit` and `rkhunter`. Scanner warnings need manual review. Full
manual: [docs/proxmox-audit.md](docs/proxmox-audit.md).

### update-container.fish (v1.6.1)

Manual single-container Docker image update, the counterpart to a
report-only WUD: bumps the pinned tag in a compose file (inside the target
LXC) and recreates the container. Portable across hosts via
`/etc/update-container.conf` (`WUD_URL` plus one line per service:
`service  ct  compose-path  repo  container-name`) — adapt
[`scripts/update-container.conf.example`](scripts/update-container.conf.example).
The WUD lookup (used by `list` and the update hint) reads the admin password
from `/root/.wud-admin-pass`. It backs up the compose file, pre-pulls the new
tag to validate it, edits only the `image:` line, and supports `--dry`
(`list` also accepts the `ls` alias).

```fish
fish scripts/update-container.fish list                 # table: LXC / container / version / update
fish scripts/update-container.fish <service>            # current tag + WUD suggestion
fish scripts/update-container.fish <service> <new-tag>  # bump + recreate
fish scripts/update-container.fish <service> <new-tag> --dry
fish scripts/update-container.fish --help               # usage (also -h, --version / -V)
```

---

## Safety notes

- Several scripts **shut guests down** and pve-auto-upgrade can **reboot the
  host** (unattended, daily at 06:00 once installed): run them from the
  console or an out-of-band path, and only after a clean `-d` dry run.
- The CT `205` exclusion and the `noc@rimpianto.com` recipient are
  site-specific — edit `upgrade_and_reboot-host.ver1.5.0.fish` if your
  environment differs.
- `pve_rename` and `stop_all` assume a standalone node; read the pre-flight
  checks. Backups go to the default storage — check free space first.
- No credentials are stored in this repository.

## License

GNU GPL v3.0 — see [LICENSE](LICENSE).
