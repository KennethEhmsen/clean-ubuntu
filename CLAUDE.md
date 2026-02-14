# CLAUDE.md — clean-ubuntu

## Project overview

Single bash script (`clean-ubuntu.sh`) that resets Ubuntu Server 22.04 or 24.04 LTS to bare-installation state. Removes all packages, services, data, and configs added after initial install while preserving users, sudoers, and SSH.

## Architecture

- **`clean-ubuntu.sh`** — monolithic script, all logic in one file. 12 scan/clean phase pairs, argument parser, report generator, backup system. Auto-detects Ubuntu version and adapts behavior accordingly.
- **`defaults/base-packages-22.04.txt`** — fallback package manifest for Ubuntu 22.04 (609 packages). Derived from `apt-cache depends --recurse ubuntu-server ubuntu-minimal ubuntu-standard` plus essential packages confirmed on a real system.
- **`defaults/base-packages-24.04.txt`** — fallback package manifest for Ubuntu 24.04 (670 packages). Derived from the official `ubuntu-24.04.4-live-server-amd64.manifest` with installer-only and version-specific kernel packages removed.

## Multi-version support

The script detects `VERSION_ID` from `/etc/os-release` and sets `UBUNTU_VERSION` and `UBUNTU_CODENAME` globals. Version-dependent behavior:

| Feature | 22.04 (Jammy) | 24.04 (Noble) |
|---------|---------------|---------------|
| APT sources format | Traditional `sources.list` | deb822 `ubuntu.sources` |
| Default snaps | bare core20 core22 lxd snapd | bare core22 core24 lxd snapd |
| Base manifest | `base-packages-22.04.txt` | `base-packages-24.04.txt` |
| Python version | 3.10 | 3.12 |

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

## Testing

- Always test with `--dry-run` first (the default).
- Target systems: Ubuntu Server 22.04 LTS and 24.04 LTS. The script gates on `VERSION_ID` and refuses to run on anything else.
- Deploy to server: `scp clean-ubuntu.sh defaults/ user@host:/tmp/`
- Run: `ssh user@host "sudo /tmp/clean-ubuntu.sh"`

## Common tasks

- **Adding packages to base manifest**: Add to `defaults/base-packages-{VERSION}.txt` in sorted order. These are packages that should NOT be removed on a bare system.
- **Adding a new cleanup phase**: Create `phase_NN_scan()` and `phase_NN_clean()` functions. Add scan call to the scan block and clean call to the execute block in `main()`. Add to the `SKIP_PHASES` help text.
- **Changing batch size**: Edit `batch_size=20` in `phase_02_clean()`.
- **Adding a new Ubuntu version**: Create `defaults/base-packages-{VERSION}.txt`, add the version to the `case` in `check_prerequisites()`, and handle any version-specific behavior (sources format, default snaps, etc.).
