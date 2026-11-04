# Getting started with the Proxmox helper repository

This guide covers cloning the repository, updating an existing checkout and
adding new files. Commands are shown for a Linux or Proxmox VE host; Git also
works from macOS or another development machine.

## 1. Prerequisites

Install Git and, when you want to run the Fish scripts locally, Fish:

```sh
sudo apt update
sudo apt install -y git fish
```

Use SSH if you will push changes and your GitHub SSH key is configured:

```sh
git clone git@github.com:rimpianto/proxmox.git
cd proxmox
```

For read-only cloning without a GitHub account or SSH key:

```sh
git clone https://github.com/rimpianto/proxmox.git
cd proxmox
```

Review a script before executing it, then make it executable if needed:

```sh
less scripts/proxmox_audit-ver01A.fish
chmod +x scripts/proxmox_audit-ver01A.fish
./scripts/proxmox_audit-ver01A.fish
```

The audit menu has additional dependencies documented in
[proxmox-audit.md](proxmox-audit.md).

## 2. Update an existing local clone

Move into the repository and inspect the checkout before updating:

```sh
cd /path/to/proxmox
git status
git switch main
git pull --ff-only origin main
```

`git status` should normally say `nothing to commit, working tree clean`.
If you have local edits, commit them first or save them temporarily:

```sh
git stash push -u -m "work in progress"
git pull --ff-only origin main
git stash pop
```

`--ff-only` avoids creating an accidental merge commit. If Git reports that
the branches have diverged, stop and review the local and remote commits
instead of force-pushing:

```sh
git log --oneline --graph --decorate --all -20
```

To fetch remote changes without changing the working tree:

```sh
git fetch origin
git log --oneline main..origin/main
```

## 3. Add a new script or document

Update `main` first, then copy the real file into the appropriate directory:

```sh
git pull --ff-only origin main
cp /path/to/new-script.fish scripts/new-script.fish
chmod +x scripts/new-script.fish
```

For Fish scripts, always run the parser check:

```sh
fish -n scripts/new-script.fish
```

Add documentation under `docs/` and list the new script in `README.md`.
Public repository content, including code comments and examples, should be
in English. Do not commit passwords, tokens, private keys or host-specific
secrets.

Inspect exactly what will be committed:

```sh
git status
git diff
git add scripts/new-script.fish docs/new-script.md README.md
git diff --cached
```

Commit with a descriptive message:

```sh
git commit -m "Add new-script and its documentation"
```

For a small change in your own repository, publish directly to `main`:

```sh
git push origin main
```

For work that should be reviewed first, use a branch instead:

```sh
git switch -c add-new-script
git push -u origin add-new-script
```

Then open a pull request on GitHub. After the branch is merged, update the
local main branch:

```sh
git switch main
git pull --ff-only origin main
```

## 4. Update an existing file

The workflow is the same: update first, edit the real file, test it, inspect
the diff, then commit and push:

```sh
cd /path/to/proxmox
git switch main
git pull --ff-only origin main
$EDITOR scripts/new-script.fish
fish -n scripts/new-script.fish
git diff
git add scripts/new-script.fish
git commit -m "Fix new-script behaviour"
git push origin main
```

Do not use `git push --force` on the shared `main` branch.

## 5. Verify what is on GitHub

After pushing, confirm that local and remote `main` point to the same commit:

```sh
git rev-parse HEAD
git ls-remote origin refs/heads/main
```

The two commit IDs must match. You can also inspect the file at:

```text
https://github.com/rimpianto/proxmox/tree/main/scripts
```

## 6. Download one released file without cloning

To download the current audit script directly from `main`:

```sh
curl -fsSLO https://raw.githubusercontent.com/rimpianto/proxmox/main/scripts/proxmox_audit-ver01A.fish
chmod +x proxmox_audit-ver01A.fish
./proxmox_audit-ver01A.fish
```

A raw download is not a Git checkout: use `curl` again to update it, or clone
the repository if you want version history and `git pull` updates.
