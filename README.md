# Proxmox VE helper scripts

Small, opinionated **fish** scripts used to operate standalone Proxmox VE hosts:
rename a node, stop or upgrade a host safely, and take network and NVMe inventories.

Tested on Proxmox VE 9.x (Debian 13) with `fish` 3.7+/4.x. They are written for the
author's homelab (paths, CT IDs and storage names may need adapting) — read the script
before running it on your own host.

## Scripts

| Script | Purpose | Changes the system |
|---|---|---|
| [`pve_rename-ver.2.1.fish`](scripts/pve_rename-ver.2.1.fish) | Rename a **standalone** PVE node (hostname, `/etc/hosts`, node directory in `/etc/pve`) with pre-flight backups | yes |
| [`stop_all.fish`](scripts/stop_all.fish) | `vzdump` snapshot backup of every guest, then graceful shutdown of all LXCs and VMs, then wait | yes (backup + shutdown) |
| [`stop_all_noBackup.fish`](scripts/stop_all_noBackup.fish) | Same shutdown sequence **without** the backup | yes (shutdown) |
| [`upgrade_and_reboot-host.ver1.3.0.fish`](scripts/upgrade_and_reboot-host.ver1.3.0.fish) | `apt update` + `full-upgrade` + `autoremove`; if a reboot is required, shut the guests down and reboot | yes |
| [`net-inventory.fish`](scripts/net-inventory.fish) | Read-only inventory of NICs: driver, PCI, speed, media, MTU, master/bridge, IPs, PCIe link | **no** |
| [`nvme-inventory.fish`](scripts/nvme-inventory.fish) | Read-only inventory of NVMe drives: model, capacity, PCIe link/gen, SMART health, endurance, who uses them | **no** |

Requirements: `root` (except `net-inventory.fish`), `fish`, and the usual Proxmox CLI
tools (`pct`, `qm`, `vzdump`, `pvesh`) already present on a PVE host.

```sh
apt install fish          # if it is not installed yet
chmod +x scripts/*.fish   # the repository already ships the executable bit
cp scripts/*.fish /usr/local/bin/   # optional: make them available in PATH
```

---

## pve_rename-ver.2.1.fish

Renames a Proxmox node **without losing guests**: it copies the node configuration
directory, updates the hostname and `/etc/hosts`, and leaves the old
`/etc/pve/nodes/<old_name>` directory in place (never deleted).

```sh
./pve_rename-ver.2.1.fish <old-name> <new-name>
# e.g.
./pve_rename-ver.2.1.fish pve-old pve-lab
```

What it does, in order:

1. requires root, `fish`, and **exactly two arguments**;
2. validates the new name against RFC 1123 and refuses identical names;
3. **refuses to run on a cluster** (checks for Corosync state): standalone nodes only;
4. takes pre-flight backups (tarball + raw copy) of `/etc/pve`, `config.db`,
   `/etc/hosts`, `/etc/hostname`, `/etc/network/interfaces`;
5. copies `/etc/pve/nodes/<old>/` to `/etc/pve/nodes/<new>/` (qemu-server, lxc, …);
6. updates `/etc/hosts`, `/etc/hostname`, `hostnamectl`;
7. prints the final view of registered containers/VMs and the manual cleanup command
   for the old node directory (`rm -rf /etc/pve/nodes/<old_name>`), which it does
   **not** run for you.

Notes:

- run it from the host console or an SSH session that does not depend on the node name;
- after the rename, check `/etc/pve/nodes/<new>/` and the PVE web UI before removing
  the old directory;
- if the host is in a cluster, this script refuses: use the supported cluster
  procedure instead.

---

## stop_all.fish

Backs up every guest with `vzdump --all --mode snapshot --compress zstd`, then shuts
down all running LXCs (`pct shutdown`) and VMs (`qm shutdown`), waits until nothing is
running anymore and tells you the host is ready for a reboot.

```sh
./stop_all.fish
# optional: choose the backup storage by editing the vzdump line, e.g.
#   vzdump --all --mode snapshot --compress zstd --storage local-zfs
```

Notes:

- `vzdump --all` uses the **default** storage and can take a long time: make sure there
  is free space before running it;
- snapshot mode leaves the guests running during the backup, then the shutdown starts;
- the wait loop uses `pct list`/`qm list`: if a guest is stuck, the script waits
  forever (Ctrl+C and stop the guest by hand).

## stop_all_noBackup.fish

Identical shutdown sequence **without** the `vzdump` step (the backup lines are
commented out). Use it when you already have a recent backup and just want everything
down before a reboot or a hardware change.

---

## upgrade_and_reboot-host.ver1.3.0.fish

Updates the host and reboots it only if needed:

1. `export DEBIAN_FRONTEND=noninteractive`, then `apt update`;
2. `apt full-upgrade -y` with `--force-confdef --force-confold` (keeps existing config
   files: no conffile prompts, no `.dpkg-new` surprises);
3. `apt autoremove -y` (old kernels included);
4. if `/var/run/reboot-required` exists: graceful shutdown of all guests, wait, then
   `reboot`; otherwise it prints "No reboot is necessary".

**Site-specific detail:** the LXC loop skips container **205** on purpose. Change it if
your environment differs.

Known issue: the LXC wait condition is ineffective —
`while pct list | grep -q running | grep -v 205` feeds a `grep -q` (no output) into
`grep -v`, so the loop only really waits for the **VMs**. LXCs are asked to shut down
but not awaited before the reboot. Fix by writing the condition as two separate checks.

---

## net-inventory.fish

Read-only network report: **it changes nothing** and works as a normal user.

```sh
net-inventory                    # full inventory
net-inventory --up               # only interfaces with carrier/link
net-inventory -d nic3            # detail for one interface
net-inventory --no-color         # no ANSI colours
```

Sections printed:

| Section | Content |
|---|---|
| `PHYSICAL NICS` | name, driver, PCI address, root port, state, current speed, maximum supported speed, media, MTU, MAC, master (bridge/bond), udev `.link` file |
| `PCIe LINK` | `LnkCap` (slot capability) → `LnkSta` (negotiated), with `⚠ down` when the device is in a narrower slot than it could use |
| `VIRTUAL INTERFACES` | bridge/bond/vlan/veth/tun/dummy, state, MTU, master, members |
| `IP ADDRESSES` | IPv4 + global IPv6 per interface |
| `BRIDGE — PORT STATE` | STP state and per-port state (forwarding, blocking, …) |
| `VLAN` | VLAN interfaces and their parent |
| summary | physical NICs with link, bridges, VLANs, interfaces without IP |

Legend: `MAX` is the highest speed declared in *Supported link modes* (or the current
speed if it is higher); `!` means the negotiated speed exceeds the declared maximum
(driver lying); `*` means the media was read from the driver debug file because
`ethtool` hardcodes `PORT_TP` on that driver (r8127); `n/a` means the driver does not
report media (e.g. `ice` without an SFP module).

`-d/--detail IFACE` adds `ethtool -i` (driver/firmware), supported and advertised link
modes, SFP diagnostics (`ethtool -m`), error counters and `ip addr`.

## nvme-inventory.fish

Read-only report of every NVMe controller/namespace: **it changes nothing** and works as
a normal user.

```sh
nvme-inventory                # table
nvme-inventory -d nvme1n1     # full detail for one namespace
nvme-inventory --no-color     # no ANSI colours
```

| Column | Content |
|---|---|
| `DEVICE` | namespace block device (`nvme0n1`, …) |
| `MODEL` | model string from the drive's identify data |
| `SIZE` | namespace capacity |
| `PCIe` | controller `LnkCap` (capability) → `LnkSta` (negotiated), with generation (`Gen3`, `Gen4`, …) |
| `HEALTH` | SMART self-assessment (`PASSED` / `FAILED`) |
| `TEMP` | composite temperature, °C |
| `USED%` | `Percentage Used` from the NVMe SMART log (endurance) |
| `USED BY` | `zfs: <pool>`, `mounted <path>`, `<fs> (not mounted)`, `partitions only` or `unused` |

`⚠ speed` / `⚠ width` mean the drive is running below the link it supports — typically a
Gen4 SSD in a Gen3 slot or a x4 drive in a x2/x1 slot. The summary line counts
controllers, total capacity, downgraded links and unhealthy drives.

`-d/--detail DEVICE` adds the controller and root port, the serial number, the `lsblk`
tree, `smartctl -i` and the full SMART health/attributes block (data written, power-on
hours, unsafe shutdowns, media errors).

Dependencies: `pciutils`, `smartmontools`, `util-linux` (`lsblk`); `zfsutils-linux` for
the pool mapping (optional).

---

## Safety notes

- Most of these scripts **shut guests down** and some **reboot the host**: run them from
  the console or an out-of-band path, not from a session that will drop.
- `pve_rename` and `stop_all` assume a standalone node; read the pre-flight checks.
- Backups (`stop_all`, `pve_rename`) are written to the default storage/locations —
  check free space first.
- No credentials are stored in this repository.

## License

Unless stated otherwise in a script header, the contents are provided as-is for
personal use, without warranty of any kind. The `net-inventory.fish` script is
read-only and safe to run anywhere.
