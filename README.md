# clean-ubuntu

Reset Ubuntu Server 22.04/24.04 LTS to bare-installation state. Removes everything installed or configured after the initial OS install while preserving users, sudoers, and SSH.

## What it does

The script auto-detects your Ubuntu version (22.04 or 24.04), compares your current system against the matching base package manifest, and removes everything that was added. It runs in **12 phases**:

| Phase | Target |
|-------|--------|
| 1 | PPAs, external repos, GPG keys |
| 2 | APT packages installed after base install |
| 3 | Non-default snap packages |
| 4 | User-added systemd services |
| 5 | Docker (containers, images, volumes, networks, packages) |
| 6 | Databases (PostgreSQL, MySQL/MariaDB, MongoDB, Redis) |
| 7 | Cron jobs and at jobs |
| 8 | Firewall rules (UFW, iptables, nftables) |
| 9 | Data directories (`/opt`, `/srv`, `/var/www`, `/usr/local`) |
| 10 | Language packages (pip, npm, cargo, go, gems) |
| 11 | Logs and temp files |
| 12 | Old kernel packages |

## What it preserves

- **Users and groups** (`/etc/passwd`, `/etc/shadow`, `/etc/group`, `/etc/gshadow`)
- **Sudo configuration** (`/etc/sudoers`, `/etc/sudoers.d/`)
- **SSH** (`/etc/ssh/`, all users' `~/.ssh/` directories)
- **Home directories** (user data is not touched)

A full backup of all preserved items is created at `/root/clean-ubuntu-backup-<timestamp>/` before any changes are made.

## Usage

```bash
# Clone
git clone https://github.com/KennethEhmsen/clean-ubuntu.git
cd clean-ubuntu
chmod +x clean-ubuntu.sh

# Dry-run first (default) — scan and report, no changes
sudo ./clean-ubuntu.sh

# Review the report, then execute
sudo ./clean-ubuntu.sh --execute
```

You will be prompted to type `YES I UNDERSTAND` before any changes are made.

## Options

```
--dry-run        Scan and report only (default)
--execute        Perform actual cleanup
--skip-backup    Skip the pre-execution backup
--skip-phase N   Skip phase N (can be repeated)
--yes            Skip confirmation prompt (for automation)
--no-color       Disable colored output
-h, --help       Show help
```

### Examples

```bash
# Skip Docker cleanup (phase 5)
sudo ./clean-ubuntu.sh --execute --skip-phase 5

# Skip both Docker and databases
sudo ./clean-ubuntu.sh --execute --skip-phase 5 --skip-phase 6

# Fully automated (no confirmation prompt)
sudo ./clean-ubuntu.sh --execute --yes
```

## Requirements

- Ubuntu Server **22.04 LTS** (Jammy Jellyfish) or **24.04 LTS** (Noble Numbat)
- Root privileges (`sudo`)
- The script will refuse to run on any other Ubuntu version

## How package detection works

The script identifies base packages using one of two methods:

1. **`/var/log/installer/initial-status.gz`** — the package snapshot created by the Ubuntu installer at install time (preferred, most accurate)
2. **`defaults/base-packages-{version}.txt`** — a version-specific fallback manifest derived from the official server ISO package manifest (used when the installer snapshot is missing). Separate manifests are maintained for 22.04 and 24.04.

Packages are compared using `apt-mark showmanual` against the base manifest. Only manually-installed non-base packages are targeted for removal. An `apt-get remove --dry-run` simulation is run before any actual removal to catch dependency conflicts.

## Post-cleanup

After execution, the script recommends a reboot:

```bash
sudo reboot
```

The backup at `/root/clean-ubuntu-backup-<timestamp>/` contains:
- SSH server and user keys
- User/group/shadow files
- Sudoers configuration
- Package state snapshot (`dpkg-selections.txt`, `apt-manual.txt`)
- Original `sources.list` / `sources.list.d/` (including deb822 `.sources` files on 24.04)

## License

MIT
