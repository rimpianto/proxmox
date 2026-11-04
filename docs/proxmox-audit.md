# proxmox_audit-ver01A.fish

Interactive Proxmox VE security and audit menu for Fish shell, version 0.1A.
It groups common inspection commands in one terminal UI instead of modifying
the host configuration.

## Requirements

Run it on a Proxmox VE host, normally as `root` so that process, journal and
root-crontab information is visible.

Required tools:

- `fish`;
- `ccze` for coloured output;
- `less` for the journal viewers;
- the usual PVE/Debian tools: `w`, `loginctl`, `journalctl`, `ss`, `ps`,
  `crontab` and `ls`;
- `chkrootkit` for menu option 13;
- `rkhunter` for menu option 14.

On Debian/Proxmox VE:

```sh
apt update
apt install -y fish ccze less iproute2 procps chkrootkit rkhunter
```

The script warns when `ccze` is absent, but the current version still pipes
most views through it. Install `ccze` rather than relying on that warning.

## Start

From a repository clone:

```sh
chmod +x scripts/proxmox_audit-ver01A.fish
./scripts/proxmox_audit-ver01A.fish
```

The script is interactive and has no command-line options. Select a menu
entry and press Enter. Press `q` at the main menu to exit.

## Menu entries

| Entry | Action | Underlying command/source |
|---|---|---|
| 1 | Currently connected users | `w` |
| 2 | Active login sessions | `loginctl list-sessions` |
| 3 | Details for one session ID | `loginctl session-status` |
| 4 | Successful SSH logins | `journalctl -u ssh.service --grep=Accepted` |
| 5 | Failed SSH password logins | `journalctl -u ssh.service --grep="Failed password"` |
| 6 | Successful Proxmox web logins | `pvedaemon` journal, `successful auth` |
| 7 | Failed Proxmox web logins | `pvedaemon` journal, `authentication failure` |
| 8 | Listening TCP/UDP ports and processes | `ss -tulpn` |
| 9 | Established TCP connections | `ss -tnp`, filtered by `ESTAB` |
| 10 | Command name and arguments for a PID | `ps -p PID -o comm,args` |
| 11 | Root user's crontab | `crontab -l` |
| 12 | Files under `/etc/cron.d/` | directory listing |
| 13 | Quick rootkit scan | `chkrootkit` |
| 14 | Interactive-free rkhunter check | `rkhunter --check --sk` |

Journal entries 4–7 open in `less`: use the arrow keys to scroll and `q` to
leave the pager, then press Enter when asked to return to the menu.

## Environment and terminal behaviour

The script exports `TERM=xterm-256color` at startup. This is a workaround
for terminals whose original `TERM` entry is not installed on the Proxmox
host. It affects the script process and its children, not the parent shell.

Use a real interactive terminal. Piping menu input to the script or running
it from cron is not supported.

## Remote session

Because the menu is interactive, `nohup` is not a useful way to run it. If
the SSH connection may drop, run it inside `tmux` instead:

```sh
tmux new -s pve-audit
./scripts/proxmox_audit-ver01A.fish
```

Detach with `Ctrl+b`, then `d`. Reattach later with:

```sh
tmux attach -t pve-audit
```

## Output, logs and exit status

Most views are displayed directly or through `ccze`; the script does not
create its own audit report file. The two rootkit scanners may write or
update their own logs and state under `/var/log` or their package-specific
locations.

Normal exit through the `q` menu entry returns success. Individual command
failures are printed but do not stop the menu loop; inspect the displayed
output rather than treating the script's final exit status as an audit
result.

## Limits and safety

- The menu does not intentionally change Proxmox configuration, start/stop
  guests, install packages or reboot the host.
- `chkrootkit` and `rkhunter` are scanners, not proof that a host is clean
  or compromised. Review warnings manually and keep their databases and
  packages up to date through the normal distribution process.
- Log patterns depend on the services and their logging configuration.
  Other SSH authentication methods or custom log messages may not match.
- An empty root crontab or an empty `/etc/cron.d/` result is not an error.
- Version 0.1A is a menu wrapper around standard tools; it does not perform
  automated remediation.
