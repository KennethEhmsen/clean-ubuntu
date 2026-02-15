# CLAUDE.md — clean-ubuntu

## Project overview

Single bash script (`clean-ubuntu.sh`) that resets Ubuntu Server 20.04, 22.04, 24.04, or 26.04 LTS to bare-installation state. Removes all packages, services, data, and configs added after initial install while preserving users, sudoers, and SSH.

## Architecture

- **`clean-ubuntu.sh`** — monolithic script, all logic in one file. 12 scan/clean phase pairs, argument parser, report generator, backup system. Auto-detects Ubuntu version and adapts behavior accordingly.
- **`defaults/base-packages-20.04.txt`** — fallback package manifest for Ubuntu 20.04 (562 packages). Derived from the official `ubuntu-20.04.6-live-server-amd64.manifest` with installer-only packages removed.
- **`defaults/base-packages-22.04.txt`** — fallback package manifest for Ubuntu 22.04 (609 packages). Derived from `apt-cache depends --recurse ubuntu-server ubuntu-minimal ubuntu-standard` plus essential packages confirmed on a real system.
- **`defaults/base-packages-24.04.txt`** — fallback package manifest for Ubuntu 24.04 (670 packages). Derived from the official `ubuntu-24.04.4-live-server-amd64.manifest` with installer-only and version-specific kernel packages removed.
- **`defaults/base-packages-26.04.txt`** — placeholder manifest for Ubuntu 26.04. To be populated from the official server ISO manifest after release (April 2026).

## Multi-version support

The script detects `VERSION_ID` from `/etc/os-release` and sets `UBUNTU_VERSION` and `UBUNTU_CODENAME` globals. Version-dependent behavior:

| Feature | 20.04 (Focal) | 22.04 (Jammy) | 24.04 (Noble) | 26.04 (Resolute) |
|---------|---------------|---------------|---------------|------------------|
| APT sources format | Traditional `sources.list` | Traditional `sources.list` | deb822 `ubuntu.sources` | deb822 `ubuntu.sources` |
| Default snaps | bare core18 core20 lxd snapd | bare core20 core22 lxd snapd | bare core22 core24 lxd snapd | bare core24 core26 lxd snapd |
| Base manifest | `base-packages-20.04.txt` | `base-packages-22.04.txt` | `base-packages-24.04.txt` | `base-packages-26.04.txt` (placeholder) |
| Python version | 3.8 | 3.10 | 3.12 | TBD |

## Key design decisions

- **Dry-run by default**: `--execute` flag required for destructive operations.
- **Batched removal**: Phase 2 removes APT packages in batches of 20, falling back to individual removal on failure, with up to 5 retry passes. This prevents silent bulk failures.
- **Execution order**: Repos cleaned before packages (phase 1 before phase 2) so apt-get doesn't choke on broken external repos. Services/Docker/databases stopped before package removal.
- **SSH protection**: openssh-server, openssh-client, openssh-sftp-server are hardcoded exclusions in phase 2 scan. SSH service health is verified after cleanup.
- **`set -euo pipefail`** with `|| true` on individual apt operations that may legitimately fail.

## Conventions

- Functions follow `phase_NN_scan()` / `phase_NN_clean()` naming pattern.
- All output goes through `log_info`, `log_warn`, `log_error`, `log_action`, `log_phase` helpers that tee to both stdout and the log file.
- Report data accumulates in `REPORT_LINES` array during scan phases, rendered by `generate_report()`.
- Global arrays (e.g., `SAFE_TO_REMOVE`, `ADDED_REPOS`, `DOCKER_CONTAINERS`) are populated during scan and consumed during clean.

## Custom MOTD

- `defaults/00-custom-motd` — standalone bash script installed to `/etc/update-motd.d/00-custom`
- `install_custom_motd()` runs as the last step in execute mode
- Disables all default Ubuntu MOTD scripts (ads, ESM nags, help text, update/reboot notices) via `chmod -x`
- Header box shows: hostname, OS, kernel, clean-ubuntu version
- Body shows: uptime, load, users, pending updates, color-coded memory/disk usage bars, IP addresses
- **Version must be updated in two places**: `clean-ubuntu.sh` banner (~line 1204) and `defaults/00-custom-motd` header box

## Testing

- Always test with `--dry-run` first (the default).
- Target systems: Ubuntu Server 20.04, 22.04, 24.04, and 26.04 LTS. The script gates on `VERSION_ID` and refuses to run on anything else.
- Deploy to server: `scp clean-ubuntu.sh defaults/ user@host:/tmp/`
- Run: `ssh user@host "sudo /tmp/clean-ubuntu.sh"`

## Common tasks

- **Adding packages to base manifest**: Add to `defaults/base-packages-{VERSION}.txt` in sorted order. These are packages that should NOT be removed on a bare system.
- **Adding a new cleanup phase**: Create `phase_NN_scan()` and `phase_NN_clean()` functions. Add scan call to the scan block and clean call to the execute block in `main()`. Add to the `SKIP_PHASES` help text.
- **Changing batch size**: Edit `batch_size=20` in `phase_02_clean()`.
- **Adding a new Ubuntu version**: Create `defaults/base-packages-{VERSION}.txt`, add the version to the `case` in `check_prerequisites()`, and handle any version-specific behavior (sources format, default snaps, etc.).
- **Bumping version**: Update the version string in both `clean-ubuntu.sh` banner (~line 1204) and `defaults/00-custom-motd` header box.
- **Deploying to server**: `scp clean-ubuntu.sh defaults/* ehm_admin@192.168.1.15:/tmp/clean-ubuntu/` then `sudo cp` to `/opt/clean-ubuntu/`. To update the live MOTD: `sudo cp /opt/clean-ubuntu/defaults/00-custom-motd /etc/update-motd.d/00-custom && sudo chmod +x /etc/update-motd.d/00-custom`.
