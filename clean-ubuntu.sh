#!/usr/bin/env bash
###############################################################################
# clean-ubuntu.sh — Reset Ubuntu Server to bare-install state
#
# Supported: Ubuntu Server 22.04 LTS (Jammy) and 24.04 LTS (Noble)
#
# Preserves: users, groups, sudoers, SSH keys/certs/config
# Removes:   everything else installed or configured after the base install
#
# Usage:
#   sudo ./clean-ubuntu.sh               # dry-run (scan + report only)
#   sudo ./clean-ubuntu.sh --execute     # perform actual cleanup
#   sudo ./clean-ubuntu.sh --help        # show help
###############################################################################
set -euo pipefail

# ─── Constants ───────────────────────────────────────────────────────────────
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
readonly LOG_FILE="/var/log/clean-ubuntu-${TIMESTAMP}.log"
readonly BACKUP_DIR="/root/clean-ubuntu-backup-${TIMESTAMP}"

# Default snaps (version-specific, set in check_prerequisites)
DEFAULT_SNAPS=""

# Detected version (set in check_prerequisites)
UBUNTU_VERSION=""
UBUNTU_CODENAME=""

# ─── Global State ────────────────────────────────────────────────────────────
MODE="dry-run"
AUTO_YES=false
SKIP_BACKUP=false
SKIP_PHASES=()

# Report accumulator
declare -a REPORT_LINES=()
declare -a ERRORS=()

# Phase data (populated during scan)
declare -a ADDED_REPOS=()
declare -a ADDED_KEYS=()
declare -a SAFE_TO_REMOVE=()
declare -a ADDED_SNAPS=()
declare -a ADDED_SERVICES=()
DOCKER_INSTALLED=false
declare -a DOCKER_CONTAINERS=()
declare -a DOCKER_IMAGES=()
declare -a DOCKER_VOLUMES=()
declare -a DOCKER_NETWORKS=()
declare -a DOCKER_PACKAGES=()
declare -a DOCKER_DATA_DIRS=()
declare -a DB_FOUND=()
declare -a DB_PACKAGES=()
declare -a DB_DATA_DIRS=()
declare -a ADDED_CRONTABS=()
declare -a ADDED_CRON_FILES=()
declare -a AT_JOBS=()
UFW_STATUS="inactive"
declare -a UFW_RULES=()
IPTABLES_RULES_COUNT=0
IP6TABLES_RULES_COUNT=0
declare -a DIRS_TO_CLEAN=()
declare -a DIR_SIZES=()
declare -a USRLOCAL_ADDITIONS=()
declare -a PIP_GLOBAL_PACKAGES=()
declare -a NPM_GLOBAL_PACKAGES=()
CARGO_GLOBAL=false
GO_GLOBAL=false
declare -a OLD_KERNELS=()
BASE_PACKAGES=""

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Logging ─────────────────────────────────────────────────────────────────
log_info()   { echo -e "${BLUE}[INFO]${NC}  $*" | tee -a "$LOG_FILE"; }
log_warn()   { echo -e "${YELLOW}[WARN]${NC}  $*" | tee -a "$LOG_FILE"; }
log_error()  { echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"; ERRORS+=("$*"); }
log_phase()  { echo -e "\n${BOLD}${CYAN}═══ $* ═══${NC}" | tee -a "$LOG_FILE"; }
log_action() { echo -e "${GREEN}[DONE]${NC}  $*" | tee -a "$LOG_FILE"; }
log_item()   { echo -e "        $*" | tee -a "$LOG_FILE"; }
die()        { log_error "$*"; exit 1; }

report_section() { REPORT_LINES+=("  ${BOLD}$1:${NC} $2"); }
report_item()    { REPORT_LINES+=("    $1"); }
report_warn()    { REPORT_LINES+=("  ${YELLOW}WARNING: $1:${NC} $2"); }

# ─── Usage ───────────────────────────────────────────────────────────────────
usage() {
    cat <<'EOF'
Usage: sudo ./clean-ubuntu.sh [OPTIONS]

Reset Ubuntu Server (20.04, 22.04, 24.04, or 26.04 LTS) to bare-installation state.
Preserves: users, groups, sudoers, SSH keys/certificates/config.

Options:
  --dry-run        Scan and report only, no changes (default)
  --execute        Perform actual cleanup
  --skip-backup    Skip the pre-execution backup step
  --skip-phase N   Skip phase number N (can be repeated)
  --yes            Skip confirmation prompts (for automation)
  --no-color       Disable colored output
  -h, --help       Show this help

Phases:
   1  External repositories and GPG keys
   2  APT packages (installed after base)
   3  Snap packages (non-default)
   4  Systemd services (user-added)
   5  Docker (containers, images, volumes, packages)
   6  Databases (PostgreSQL, MySQL, MongoDB, Redis)
   7  Cron jobs and at jobs
   8  Firewall rules (UFW, iptables, nftables)
   9  Directories (/opt, /srv, /var/www, /usr/local)
  10  Language packages (pip, npm, cargo, go)
  11  Logs and temp files
  12  Old kernels

Examples:
  sudo ./clean-ubuntu.sh                    # Scan and show report
  sudo ./clean-ubuntu.sh --execute          # Execute cleanup
  sudo ./clean-ubuntu.sh --skip-phase 5     # Skip Docker cleanup
EOF
    exit 0
}

# ─── Argument Parsing ────────────────────────────────────────────────────────
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)   MODE="dry-run"; shift ;;
            --execute)   MODE="execute"; shift ;;
            --skip-backup) SKIP_BACKUP=true; shift ;;
            --skip-phase)
                [[ -z "${2:-}" ]] && die "--skip-phase requires a phase number"
                SKIP_PHASES+=("$2"); shift 2 ;;
            --yes)       AUTO_YES=true; shift ;;
            --no-color)
                RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; NC=''
                shift ;;
            -h|--help)   usage ;;
            *)           die "Unknown option: $1" ;;
        esac
    done
}

should_skip_phase() {
    local phase_num="$1"
    for skip in "${SKIP_PHASES[@]}"; do
        [[ "$skip" == "$phase_num" ]] && return 0
    done
    return 1
}

# ─── Prerequisites ───────────────────────────────────────────────────────────
check_prerequisites() {
    [[ $EUID -ne 0 ]] && die "This script must be run as root (use sudo)"

    source /etc/os-release 2>/dev/null || die "Cannot read /etc/os-release"
    [[ "$ID" != "ubuntu" ]] && die "This script only supports Ubuntu (detected: $ID)"

    case "$VERSION_ID" in
        20.04|22.04|24.04|26.04) ;;
        *) die "This script supports Ubuntu 20.04, 22.04, 24.04 and 26.04 LTS only (detected: $VERSION_ID)" ;;
    esac

    UBUNTU_VERSION="$VERSION_ID"
    UBUNTU_CODENAME="$VERSION_CODENAME"

    # Version-specific default snaps
    case "$UBUNTU_VERSION" in
        20.04) DEFAULT_SNAPS="bare core18 core20 lxd snapd" ;;
        22.04) DEFAULT_SNAPS="bare core20 core22 lxd snapd" ;;
        24.04) DEFAULT_SNAPS="bare core22 core24 lxd snapd" ;;
        26.04) DEFAULT_SNAPS="bare core24 core26 lxd snapd" ;;
    esac

    # Ensure log directory is writable
    touch "$LOG_FILE" 2>/dev/null || die "Cannot write to $LOG_FILE"

    log_info "Ubuntu $UBUNTU_VERSION ($UBUNTU_CODENAME) detected"
    log_info "Mode: $MODE"
    log_info "Log file: $LOG_FILE"
}

# ─── Load Base Package List ─────────────────────────────────────────────────
load_base_packages() {
    local manifest_file="$SCRIPT_DIR/defaults/base-packages-${UBUNTU_VERSION}.txt"

    if [[ -f /var/log/installer/initial-status.gz ]]; then
        BASE_PACKAGES=$(gzip -dc /var/log/installer/initial-status.gz | \
                        sed -n 's/^Package: //p' | sort -u)
        log_info "Loaded base manifest from /var/log/installer/initial-status.gz ($(echo "$BASE_PACKAGES" | wc -l) packages)"
    elif [[ -f "$manifest_file" ]]; then
        BASE_PACKAGES=$(grep -v '^#' "$manifest_file" | grep -v '^$' | sort -u)
        log_warn "initial-status.gz not found — using fallback manifest for $UBUNTU_VERSION ($(echo "$BASE_PACKAGES" | wc -l) packages)"
    else
        die "No base package manifest found for Ubuntu $UBUNTU_VERSION. Expected: $manifest_file"
    fi
}

# ─── Backup ──────────────────────────────────────────────────────────────────
create_backup() {
    if $SKIP_BACKUP; then
        log_warn "Backup skipped (--skip-backup)"
        return
    fi

    log_phase "Creating backup of preserved items"
    mkdir -p "$BACKUP_DIR"

    # SSH server config
    if [[ -d /etc/ssh ]]; then
        cp -a /etc/ssh "$BACKUP_DIR/etc_ssh"
        log_action "Backed up /etc/ssh"
    fi

    # All users' .ssh directories
    mkdir -p "$BACKUP_DIR/home_ssh"
    while IFS=: read -r user _ uid _ _ home _; do
        if [[ -d "$home/.ssh" ]]; then
            mkdir -p "$BACKUP_DIR/home_ssh/$user"
            cp -a "$home/.ssh" "$BACKUP_DIR/home_ssh/$user/"
            log_action "Backed up $home/.ssh"
        fi
    done < /etc/passwd

    # User/group/auth files
    for f in /etc/passwd /etc/shadow /etc/group /etc/gshadow; do
        cp -a "$f" "$BACKUP_DIR/" 2>/dev/null && log_action "Backed up $f"
    done

    # Sudoers
    cp -a /etc/sudoers "$BACKUP_DIR/" 2>/dev/null
    [[ -d /etc/sudoers.d ]] && cp -a /etc/sudoers.d "$BACKUP_DIR/"
    log_action "Backed up sudoers"

    # Package state snapshot
    dpkg --get-selections > "$BACKUP_DIR/dpkg-selections.txt" 2>/dev/null
    apt-mark showmanual > "$BACKUP_DIR/apt-manual.txt" 2>/dev/null

    # Sources list / sources files
    cp -a /etc/apt/sources.list "$BACKUP_DIR/" 2>/dev/null || true
    [[ -d /etc/apt/sources.list.d ]] && cp -a /etc/apt/sources.list.d "$BACKUP_DIR/"

    log_info "Backup created at: ${BOLD}$BACKUP_DIR${NC}"
}

# ─── Phase 1: Repositories ──────────────────────────────────────────────────
phase_01_scan() {
    log_phase "Phase 1: Scanning PPAs and external repositories"

    # External repo files
    if [[ -d /etc/apt/sources.list.d ]]; then
        while IFS= read -r -d '' file; do
            local basename
            basename=$(basename "$file")
            # On 24.04+, ubuntu.sources is the default system repo — not external
            if [[ "$UBUNTU_VERSION" != "22.04" && "$basename" == "ubuntu.sources" ]]; then
                continue
            fi
            ADDED_REPOS+=("$file")
        done < <(find /etc/apt/sources.list.d/ -type f \( -name '*.list' -o -name '*.sources' \) -print0 2>/dev/null)
    fi

    # Added GPG keys
    if [[ -d /etc/apt/trusted.gpg.d ]]; then
        while IFS= read -r -d '' keyfile; do
            local basename
            basename=$(basename "$keyfile")
            if [[ ! "$basename" =~ ^ubuntu-keyring ]]; then
                ADDED_KEYS+=("$keyfile")
            fi
        done < <(find /etc/apt/trusted.gpg.d/ -type f -print0 2>/dev/null)
    fi

    # Legacy keyring
    [[ -f /etc/apt/trusted.gpg ]] && ADDED_KEYS+=("/etc/apt/trusted.gpg")

    # Keys in /etc/apt/keyrings/
    if [[ -d /etc/apt/keyrings ]]; then
        while IFS= read -r -d '' keyfile; do
            ADDED_KEYS+=("$keyfile")
        done < <(find /etc/apt/keyrings/ -type f -print0 2>/dev/null)
    fi

    report_section "External repo files" "${#ADDED_REPOS[@]}"
    for r in "${ADDED_REPOS[@]}"; do
        report_item "$(basename "$r")"
    done
    report_section "Added GPG keys" "${#ADDED_KEYS[@]}"
    for k in "${ADDED_KEYS[@]}"; do
        report_item "$(basename "$k")"
    done
}

phase_01_clean() {
    log_phase "Phase 1: Removing external repositories"

    for repo in "${ADDED_REPOS[@]}"; do
        rm -f "$repo"
        log_action "Removed: $repo"
    done

    for key in "${ADDED_KEYS[@]}"; do
        rm -f "$key"
        log_action "Removed key: $key"
    done

    # Restore default sources — format depends on Ubuntu version
    if [[ "$UBUNTU_VERSION" == "24.04" || "$UBUNTU_VERSION" == "26.04" ]]; then
        # 24.04+ uses deb822 .sources format
        cat > /etc/apt/sources.list.d/ubuntu.sources <<SOURCES
Types: deb
URIs: http://archive.ubuntu.com/ubuntu/
Suites: ${UBUNTU_CODENAME} ${UBUNTU_CODENAME}-updates ${UBUNTU_CODENAME}-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: http://security.ubuntu.com/ubuntu/
Suites: ${UBUNTU_CODENAME}-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
SOURCES
        # Remove legacy sources.list if present (24.04 doesn't use it)
        rm -f /etc/apt/sources.list 2>/dev/null || true
        log_action "Restored default ubuntu.sources (deb822 format)"
    else
        # 22.04 uses traditional sources.list format
        cat > /etc/apt/sources.list <<SOURCES
# Ubuntu ${UBUNTU_VERSION} LTS (${UBUNTU_CODENAME^}) - default repositories
deb http://archive.ubuntu.com/ubuntu/ ${UBUNTU_CODENAME} main restricted
deb http://archive.ubuntu.com/ubuntu/ ${UBUNTU_CODENAME}-updates main restricted
deb http://archive.ubuntu.com/ubuntu/ ${UBUNTU_CODENAME} universe
deb http://archive.ubuntu.com/ubuntu/ ${UBUNTU_CODENAME}-updates universe
deb http://archive.ubuntu.com/ubuntu/ ${UBUNTU_CODENAME} multiverse
deb http://archive.ubuntu.com/ubuntu/ ${UBUNTU_CODENAME}-updates multiverse
deb http://archive.ubuntu.com/ubuntu/ ${UBUNTU_CODENAME}-backports main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu/ ${UBUNTU_CODENAME}-security main restricted
deb http://security.ubuntu.com/ubuntu/ ${UBUNTU_CODENAME}-security universe
deb http://security.ubuntu.com/ubuntu/ ${UBUNTU_CODENAME}-security multiverse
SOURCES
        log_action "Restored default sources.list"
    fi

    apt-get update -qq 2>&1 | tee -a "$LOG_FILE"
    log_action "apt-get update completed"
}

# ─── Phase 2: APT Packages ──────────────────────────────────────────────────
phase_02_scan() {
    log_phase "Phase 2: Scanning APT packages"

    # Currently manually-installed packages
    local manual_packages
    manual_packages=$(apt-mark showmanual | sort -u)

    # Packages added after install = manually installed but NOT in base manifest
    local added_packages
    added_packages=$(comm -23 <(echo "$manual_packages") <(echo "$BASE_PACKAGES"))

    # Filter: exclude openssh-server, openssh-client (preserve SSH)
    local pkg
    while IFS= read -r pkg; do
        [[ -z "$pkg" ]] && continue
        case "$pkg" in
            openssh-server|openssh-client|openssh-sftp-server) continue ;;
            ssh|ssh-import-id) continue ;;
        esac
        SAFE_TO_REMOVE+=("$pkg")
    done <<< "$added_packages"

    # Simulate removal
    local simulation=""
    local would_remove_count=0
    if [[ ${#SAFE_TO_REMOVE[@]} -gt 0 ]]; then
        simulation=$(apt-get remove --dry-run "${SAFE_TO_REMOVE[@]}" 2>&1 || true)
        would_remove_count=$(echo "$simulation" | grep -c "^Remv " || true)
    fi

    report_section "Manually installed (non-base) packages" "${#SAFE_TO_REMOVE[@]}"
    for p in "${SAFE_TO_REMOVE[@]}"; do
        report_item "$p"
    done
    report_section "Total packages that would be removed (incl. deps)" "$would_remove_count"
}

phase_02_clean() {
    log_phase "Phase 2: Removing added APT packages"

    if [[ ${#SAFE_TO_REMOVE[@]} -eq 0 ]]; then
        log_info "No packages to remove"
        return
    fi

    export DEBIAN_FRONTEND=noninteractive
    local apt_opts=(-o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold")
    local batch_size=20
    local max_passes=5
    local pass=0
    local total_removed=0
    local remaining=("${SAFE_TO_REMOVE[@]}")

    while [[ ${#remaining[@]} -gt 0 && $pass -lt $max_passes ]]; do
        pass=$((pass + 1))
        log_info "Pass $pass: ${#remaining[@]} packages to remove"
        local failed=()
        local removed_this_pass=0

        # Process in batches
        local i=0
        while [[ $i -lt ${#remaining[@]} ]]; do
            local batch=("${remaining[@]:$i:$batch_size}")
            i=$((i + batch_size))

            if apt-get remove --purge -y "${apt_opts[@]}" "${batch[@]}" 2>&1 | tee -a "$LOG_FILE"; then
                removed_this_pass=$((removed_this_pass + ${#batch[@]}))
            else
                # Batch failed — try each package individually
                log_warn "Batch failed, falling back to individual removal"
                for pkg in "${batch[@]}"; do
                    if dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
                        if apt-get remove --purge -y "${apt_opts[@]}" "$pkg" 2>&1 | tee -a "$LOG_FILE"; then
                            removed_this_pass=$((removed_this_pass + 1))
                        else
                            log_warn "Failed to remove: $pkg (will retry next pass)"
                            failed+=("$pkg")
                        fi
                    fi
                done
            fi
        done

        # Autoremove after each pass to unblock further removals
        apt-get autoremove --purge -y 2>&1 | tee -a "$LOG_FILE" || true

        total_removed=$((total_removed + removed_this_pass))
        log_info "Pass $pass complete: removed $removed_this_pass packages"

        # Filter remaining to only packages still installed
        local still_installed=()
        for pkg in "${failed[@]}"; do
            if dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
                still_installed+=("$pkg")
            fi
        done
        remaining=("${still_installed[@]}")

        # If nothing was removed this pass, no point retrying
        if [[ $removed_this_pass -eq 0 ]]; then
            if [[ ${#remaining[@]} -gt 0 ]]; then
                log_warn "Could not remove ${#remaining[@]} packages after $pass passes:"
                for pkg in "${remaining[@]}"; do
                    log_warn "  - $pkg"
                done
            fi
            break
        fi
    done

    apt-get clean 2>&1 | tee -a "$LOG_FILE"
    apt-get autoclean 2>&1 | tee -a "$LOG_FILE"
    log_action "Package removal completed: $total_removed removed, ${#remaining[@]} failed"

    # Re-install any base packages that may have been pulled as collateral
    local missing_base
    missing_base=$(comm -23 \
        <(echo "$BASE_PACKAGES") \
        <(dpkg-query -W -f='${Package}\n' 2>/dev/null | sort -u)) || true

    if [[ -n "$missing_base" ]]; then
        log_warn "Restoring missing base packages..."
        # shellcheck disable=SC2086
        apt-get install -y $missing_base 2>&1 | tee -a "$LOG_FILE" || true
    fi
}

# ─── Phase 3: Snap Packages ─────────────────────────────────────────────────
phase_03_scan() {
    log_phase "Phase 3: Scanning snap packages"

    if command -v snap &>/dev/null; then
        while IFS= read -r snap_name; do
            [[ -z "$snap_name" ]] && continue
            local is_default=false
            for default in $DEFAULT_SNAPS; do
                [[ "$snap_name" == "$default" ]] && is_default=true && break
            done
            $is_default || ADDED_SNAPS+=("$snap_name")
        done < <(snap list 2>/dev/null | tail -n +2 | awk '{print $1}')
    fi

    report_section "Non-default snaps" "${#ADDED_SNAPS[@]}"
    for s in "${ADDED_SNAPS[@]}"; do
        report_item "$s"
    done
}

phase_03_clean() {
    log_phase "Phase 3: Removing non-default snaps"

    for snap_pkg in "${ADDED_SNAPS[@]}"; do
        snap remove --purge "$snap_pkg" 2>&1 | tee -a "$LOG_FILE" || true
        log_action "Removed snap: $snap_pkg"
    done
}

# ─── Phase 4: Systemd Services ──────────────────────────────────────────────
phase_04_scan() {
    log_phase "Phase 4: Scanning systemd services"

    # Find service files in /etc/systemd/system that are NOT just enables of distro services
    while IFS= read -r -d '' service_file; do
        local service_name
        service_name=$(basename "$service_file")

        # Skip well-known targets and default overrides
        case "$service_name" in
            *.target|*.wants|*.requires|sshd.service|ssh.service) continue ;;
        esac

        # If it is a symlink to /lib/systemd/system — it is just an enable, skip
        if [[ -L "$service_file" ]]; then
            local target
            target=$(readlink -f "$service_file" 2>/dev/null || true)
            [[ "$target" == /lib/systemd/system/* ]] && continue
            [[ "$target" == /usr/lib/systemd/system/* ]] && continue
            # Symlink to /dev/null means "masked" — that is an admin action, flag it
        fi

        # Check if owned by a base package
        local owning_pkg
        owning_pkg=$(dpkg -S "$service_file" 2>/dev/null | head -1 | cut -d: -f1 || true)
        if [[ -z "$owning_pkg" ]] || ! echo "$BASE_PACKAGES" | grep -qx "$owning_pkg"; then
            ADDED_SERVICES+=("$service_file")
        fi
    done < <(find /etc/systemd/system/ -maxdepth 2 -name '*.service' \
             -not -path '*/wants/*' -not -path '*/requires/*' -print0 2>/dev/null)

    report_section "Non-default systemd services" "${#ADDED_SERVICES[@]}"
    for svc in "${ADDED_SERVICES[@]}"; do
        report_item "$(basename "$svc")"
    done
}

phase_04_clean() {
    log_phase "Phase 4: Stopping and removing added services"

    for entry in "${ADDED_SERVICES[@]}"; do
        local service_name
        service_name=$(basename "$entry")
        systemctl stop "$service_name" 2>/dev/null || true
        systemctl disable "$service_name" 2>/dev/null || true

        # Only remove file if not owned by a package (package files removed in phase 2)
        if ! dpkg -S "$entry" &>/dev/null; then
            rm -f "$entry"
            log_action "Removed service file: $entry"
        else
            log_action "Stopped/disabled: $service_name (file owned by package, will be removed in phase 2)"
        fi
    done

    systemctl daemon-reload
}

# ─── Phase 5: Docker ────────────────────────────────────────────────────────
phase_05_scan() {
    log_phase "Phase 5: Scanning Docker installation"

    if command -v docker &>/dev/null; then
        DOCKER_INSTALLED=true
        mapfile -t DOCKER_CONTAINERS < <(docker ps -a --format '{{.ID}} {{.Names}} {{.Image}}' 2>/dev/null || true)
        mapfile -t DOCKER_IMAGES < <(docker images --format '{{.Repository}}:{{.Tag}} ({{.Size}})' 2>/dev/null || true)
        mapfile -t DOCKER_VOLUMES < <(docker volume ls --format '{{.Name}}' 2>/dev/null || true)
        mapfile -t DOCKER_NETWORKS < <(docker network ls --format '{{.Name}}' 2>/dev/null | grep -v -E '^(bridge|host|none)$' || true)
        mapfile -t DOCKER_PACKAGES < <(dpkg -l 2>/dev/null | grep -iE 'docker|containerd' | awk '{print $2}' || true)
    fi

    # Data directories
    for dir in /var/lib/docker /var/lib/containerd /etc/docker; do
        [[ -d "$dir" ]] && DOCKER_DATA_DIRS+=("$dir")
    done

    report_section "Docker installed" "$(if $DOCKER_INSTALLED; then echo 'YES'; else echo 'No'; fi)"
    if $DOCKER_INSTALLED; then
        report_section "  Containers" "${#DOCKER_CONTAINERS[@]}"
        for c in "${DOCKER_CONTAINERS[@]}"; do
            report_item "$c"
        done
        report_section "  Images" "${#DOCKER_IMAGES[@]}"
        for i in "${DOCKER_IMAGES[@]}"; do
            report_item "$i"
        done
        report_section "  Volumes" "${#DOCKER_VOLUMES[@]}"
        report_section "  Custom networks" "${#DOCKER_NETWORKS[@]}"
        report_section "  Packages" "${DOCKER_PACKAGES[*]:-none}"
        report_section "  Data directories" "${DOCKER_DATA_DIRS[*]:-none}"
    fi
}

phase_05_clean() {
    log_phase "Phase 5: Removing Docker"

    if $DOCKER_INSTALLED; then
        # Stop all containers
        local container_ids
        container_ids=$(docker ps -aq 2>/dev/null || true)
        if [[ -n "$container_ids" ]]; then
            docker stop $container_ids 2>/dev/null || true
            docker rm -f $container_ids 2>/dev/null || true
            log_action "Removed all Docker containers"
        fi

        # Remove images
        local image_ids
        image_ids=$(docker images -aq 2>/dev/null || true)
        if [[ -n "$image_ids" ]]; then
            docker rmi -f $image_ids 2>/dev/null || true
            log_action "Removed all Docker images"
        fi

        # Remove volumes
        local volume_ids
        volume_ids=$(docker volume ls -q 2>/dev/null || true)
        if [[ -n "$volume_ids" ]]; then
            docker volume rm -f $volume_ids 2>/dev/null || true
            log_action "Removed all Docker volumes"
        fi

        # Remove custom networks
        for net in "${DOCKER_NETWORKS[@]}"; do
            docker network rm "$net" 2>/dev/null || true
        done

        # Stop Docker services
        systemctl stop docker.socket docker.service containerd.service 2>/dev/null || true
        systemctl disable docker.socket docker.service containerd.service 2>/dev/null || true
        log_action "Stopped Docker services"
    fi

    # Packages handled in phase 2, but ensure Docker-specific ones are flagged
    # Remove standalone binaries
    rm -f /usr/local/bin/docker-compose 2>/dev/null || true

    # Remove data directories
    for dir in "${DOCKER_DATA_DIRS[@]}"; do
        rm -rf "$dir"
        log_action "Removed: $dir"
    done

    # Remove docker group
    groupdel docker 2>/dev/null || true
}

# ─── Phase 6: Databases ─────────────────────────────────────────────────────
phase_06_scan() {
    log_phase "Phase 6: Scanning database installations"

    # PostgreSQL
    if dpkg -l postgresql 2>/dev/null | grep -q '^ii'; then
        DB_FOUND+=("PostgreSQL")
        while IFS= read -r pkg; do
            DB_PACKAGES+=("$pkg")
        done < <(dpkg -l 2>/dev/null | grep -i postgres | awk '{print $2}')
        [[ -d /var/lib/postgresql ]] && DB_DATA_DIRS+=("/var/lib/postgresql")
        [[ -d /etc/postgresql ]] && DB_DATA_DIRS+=("/etc/postgresql")
    fi

    # MySQL / MariaDB
    for db in mysql mariadb; do
        if dpkg -l "${db}-server" 2>/dev/null | grep -q '^ii'; then
            DB_FOUND+=("$db")
            while IFS= read -r pkg; do
                DB_PACKAGES+=("$pkg")
            done < <(dpkg -l 2>/dev/null | grep -i "$db" | awk '{print $2}')
            [[ -d /var/lib/mysql ]] && DB_DATA_DIRS+=("/var/lib/mysql")
            [[ -d /etc/mysql ]] && DB_DATA_DIRS+=("/etc/mysql")
        fi
    done

    # MongoDB
    if dpkg -l mongodb-org 2>/dev/null | grep -q '^ii' || dpkg -l mongod 2>/dev/null | grep -q '^ii'; then
        DB_FOUND+=("MongoDB")
        while IFS= read -r pkg; do
            DB_PACKAGES+=("$pkg")
        done < <(dpkg -l 2>/dev/null | grep -i mongo | awk '{print $2}')
        [[ -d /var/lib/mongodb ]] && DB_DATA_DIRS+=("/var/lib/mongodb")
    fi

    # Redis
    if dpkg -l redis-server 2>/dev/null | grep -q '^ii'; then
        DB_FOUND+=("Redis")
        while IFS= read -r pkg; do
            DB_PACKAGES+=("$pkg")
        done < <(dpkg -l 2>/dev/null | grep -i redis | awk '{print $2}')
        [[ -d /var/lib/redis ]] && DB_DATA_DIRS+=("/var/lib/redis")
    fi

    report_section "Databases found" "${DB_FOUND[*]:-none}"
    report_section "  Packages" "${#DB_PACKAGES[@]}"
    report_section "  Data directories" "${DB_DATA_DIRS[*]:-none}"
}

phase_06_clean() {
    log_phase "Phase 6: Removing databases"

    for svc in postgresql mysql mariadb mongod redis-server; do
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
    done

    for dir in "${DB_DATA_DIRS[@]}"; do
        rm -rf "$dir"
        log_action "Removed database data: $dir"
    done

    # Remove system users created by DB packages
    for db_user in postgres mysql mongodb redis; do
        if id "$db_user" &>/dev/null; then
            userdel -r "$db_user" 2>/dev/null || true
            log_action "Removed system user: $db_user"
        fi
    done
}

# ─── Phase 7: Cron Jobs ─────────────────────────────────────────────────────
phase_07_scan() {
    log_phase "Phase 7: Scanning cron jobs"

    # User crontabs
    if [[ -d /var/spool/cron/crontabs ]]; then
        while IFS= read -r -d '' crontab; do
            ADDED_CRONTABS+=("$crontab")
        done < <(find /var/spool/cron/crontabs/ -type f -print0 2>/dev/null)
    fi

    # System cron files in /etc/cron.d/
    if [[ -d /etc/cron.d ]]; then
        while IFS= read -r -d '' cronfile; do
            local name
            name=$(basename "$cronfile")
            case "$name" in
                e2scrub_all|.placeholder|popularity-contest|sysstat) continue ;;
            esac
            local owner
            owner=$(dpkg -S "$cronfile" 2>/dev/null | head -1 | cut -d: -f1 || true)
            if [[ -z "$owner" ]] || ! echo "$BASE_PACKAGES" | grep -qx "$owner"; then
                ADDED_CRON_FILES+=("$cronfile")
            fi
        done < <(find /etc/cron.d/ -type f -not -name '.placeholder' -print0 2>/dev/null)
    fi

    # /etc/cron.{hourly,daily,weekly,monthly}
    for period in hourly daily weekly monthly; do
        if [[ -d "/etc/cron.$period" ]]; then
            while IFS= read -r -d '' cronfile; do
                local owner
                owner=$(dpkg -S "$cronfile" 2>/dev/null | head -1 | cut -d: -f1 || true)
                if [[ -z "$owner" ]] || ! echo "$BASE_PACKAGES" | grep -qx "$owner"; then
                    ADDED_CRON_FILES+=("$cronfile")
                fi
            done < <(find "/etc/cron.$period/" -type f -not -name '.placeholder' -print0 2>/dev/null)
        fi
    done

    # At jobs
    if command -v atq &>/dev/null; then
        mapfile -t AT_JOBS < <(atq 2>/dev/null || true)
    fi

    report_section "User crontabs" "${#ADDED_CRONTABS[@]}"
    report_section "Added cron files" "${#ADDED_CRON_FILES[@]}"
    for cf in "${ADDED_CRON_FILES[@]}"; do
        report_item "$(basename "$cf")"
    done
    report_section "At jobs" "${#AT_JOBS[@]}"
}

phase_07_clean() {
    log_phase "Phase 7: Removing cron/at jobs"

    for crontab_file in "${ADDED_CRONTABS[@]}"; do
        rm -f "$crontab_file"
        log_action "Removed crontab: $(basename "$crontab_file")"
    done

    for cronfile in "${ADDED_CRON_FILES[@]}"; do
        rm -f "$cronfile"
        log_action "Removed cron file: $(basename "$cronfile")"
    done

    if command -v atrm &>/dev/null; then
        atq 2>/dev/null | awk '{print $1}' | while read -r job; do
            atrm "$job" 2>/dev/null || true
        done
    fi
}

# ─── Phase 8: Firewall ──────────────────────────────────────────────────────
phase_08_scan() {
    log_phase "Phase 8: Scanning firewall configuration"

    if command -v ufw &>/dev/null; then
        UFW_STATUS=$(ufw status 2>/dev/null | head -1 || echo "unknown")
        if [[ "$UFW_STATUS" == *"active"* ]]; then
            mapfile -t UFW_RULES < <(ufw status numbered 2>/dev/null | grep '^\[' || true)
        fi
    fi

    IPTABLES_RULES_COUNT=$(iptables -S 2>/dev/null | grep -cv '^-P' || true)
    IP6TABLES_RULES_COUNT=$(ip6tables -S 2>/dev/null | grep -cv '^-P' || true)

    report_section "UFW status" "$UFW_STATUS"
    report_section "UFW rules" "${#UFW_RULES[@]}"
    report_section "iptables custom rules" "$IPTABLES_RULES_COUNT"
    report_section "ip6tables custom rules" "$IP6TABLES_RULES_COUNT"
}

phase_08_clean() {
    log_phase "Phase 8: Resetting firewall"

    if command -v ufw &>/dev/null; then
        ufw --force reset 2>&1 | tee -a "$LOG_FILE" || true
        ufw disable 2>/dev/null || true
        log_action "UFW reset and disabled"
    fi

    # Flush iptables
    for table in filter nat mangle raw; do
        iptables -t "$table" -F 2>/dev/null || true
        iptables -t "$table" -X 2>/dev/null || true
        ip6tables -t "$table" -F 2>/dev/null || true
        ip6tables -t "$table" -X 2>/dev/null || true
    done
    iptables -P INPUT ACCEPT 2>/dev/null || true
    iptables -P FORWARD ACCEPT 2>/dev/null || true
    iptables -P OUTPUT ACCEPT 2>/dev/null || true
    ip6tables -P INPUT ACCEPT 2>/dev/null || true
    ip6tables -P FORWARD ACCEPT 2>/dev/null || true
    ip6tables -P OUTPUT ACCEPT 2>/dev/null || true

    # Reset nftables
    if command -v nft &>/dev/null; then
        nft flush ruleset 2>/dev/null || true
    fi

    log_action "Firewall rules flushed"
}

# ─── Phase 9: Directories ───────────────────────────────────────────────────
phase_09_scan() {
    log_phase "Phase 9: Scanning directories for cleanup"

    for dir in /opt /srv; do
        if [[ -d "$dir" ]] && [[ "$(ls -A "$dir" 2>/dev/null)" ]]; then
            local size
            size=$(du -sh "$dir" 2>/dev/null | awk '{print $1}')
            DIRS_TO_CLEAN+=("$dir")
            DIR_SIZES+=("$size")
        fi
    done

    # /var/www — doesn't exist on fresh install
    if [[ -d /var/www ]]; then
        local size
        size=$(du -sh /var/www 2>/dev/null | awk '{print $1}')
        DIRS_TO_CLEAN+=("/var/www")
        DIR_SIZES+=("$size")
    fi

    # /usr/local additions
    for subdir in bin sbin lib lib64 share include src etc; do
        local dir="/usr/local/$subdir"
        if [[ -d "$dir" ]] && [[ "$(ls -A "$dir" 2>/dev/null)" ]]; then
            while IFS= read -r -d '' file; do
                if ! dpkg -S "$file" &>/dev/null; then
                    USRLOCAL_ADDITIONS+=("$file")
                fi
            done < <(find "$dir" -type f -print0 2>/dev/null)
        fi
    done

    report_section "Directories to clean" "${#DIRS_TO_CLEAN[@]}"
    for i in "${!DIRS_TO_CLEAN[@]}"; do
        report_item "${DIRS_TO_CLEAN[$i]} (${DIR_SIZES[$i]})"
    done
    report_section "/usr/local additions" "${#USRLOCAL_ADDITIONS[@]} files"
}

phase_09_clean() {
    log_phase "Phase 9: Cleaning directories"

    for dir in "${DIRS_TO_CLEAN[@]}"; do
        case "$dir" in
            /opt)     rm -rf /opt/*; log_action "Cleaned /opt" ;;
            /srv)     rm -rf /srv/*; log_action "Cleaned /srv" ;;
            /var/www) rm -rf /var/www; log_action "Removed /var/www" ;;
        esac
    done

    for file in "${USRLOCAL_ADDITIONS[@]}"; do
        rm -f "$file"
    done

    # Remove empty directories in /usr/local but keep the skeleton
    find /usr/local -type d -empty \
        -not -path '/usr/local' \
        -not -path '/usr/local/bin' \
        -not -path '/usr/local/sbin' \
        -not -path '/usr/local/lib' \
        -not -path '/usr/local/share' \
        -not -path '/usr/local/share/man' \
        -not -path '/usr/local/include' \
        -not -path '/usr/local/src' \
        -not -path '/usr/local/etc' \
        -delete 2>/dev/null || true

    log_action "Cleaned /usr/local additions"
}

# ─── Phase 10: Language Packages ─────────────────────────────────────────────
phase_10_scan() {
    log_phase "Phase 10: Scanning language-specific package managers"

    # pip3 (system-wide only)
    if command -v pip3 &>/dev/null; then
        local pip_dirs
        pip_dirs=$(find /usr/local/lib -maxdepth 3 -name 'dist-packages' -type d 2>/dev/null || true)
        for pip_dir in $pip_dirs; do
            while IFS= read -r pkg; do
                [[ -n "$pkg" ]] && PIP_GLOBAL_PACKAGES+=("$pkg")
            done < <(pip3 list --path "$pip_dir" --format=columns 2>/dev/null | tail -n +3 | awk '{print $1}' || true)
        done
    fi

    # npm global packages
    if command -v npm &>/dev/null; then
        mapfile -t NPM_GLOBAL_PACKAGES < <(npm list -g --depth=0 --parseable 2>/dev/null | tail -n +2 | xargs -I{} basename {} || true)
    fi

    # Cargo
    [[ -d /usr/local/cargo ]] || [[ -d /root/.cargo ]] && CARGO_GLOBAL=true

    # Go
    [[ -d /usr/local/go ]] && GO_GLOBAL=true

    report_section "pip3 global packages" "${#PIP_GLOBAL_PACKAGES[@]}"
    for p in "${PIP_GLOBAL_PACKAGES[@]}"; do
        report_item "$p"
    done
    report_section "npm global packages" "${#NPM_GLOBAL_PACKAGES[@]}"
    for p in "${NPM_GLOBAL_PACKAGES[@]}"; do
        report_item "$p"
    done
    report_section "Cargo" "$(if $CARGO_GLOBAL; then echo 'Found'; else echo 'Not found'; fi)"
    report_section "Go" "$(if $GO_GLOBAL; then echo 'Found'; else echo 'Not found'; fi)"
}

phase_10_clean() {
    log_phase "Phase 10: Removing language packages"

    # pip cleanup
    if [[ ${#PIP_GLOBAL_PACKAGES[@]} -gt 0 ]]; then
        pip3 uninstall -y "${PIP_GLOBAL_PACKAGES[@]}" 2>/dev/null || true
        rm -rf /usr/local/lib/python*/dist-packages/* 2>/dev/null || true
        log_action "Removed pip global packages"
    fi

    # npm cleanup
    if [[ ${#NPM_GLOBAL_PACKAGES[@]} -gt 0 ]]; then
        for pkg in "${NPM_GLOBAL_PACKAGES[@]}"; do
            npm uninstall -g "$pkg" 2>/dev/null || true
        done
        log_action "Removed npm global packages"
    fi

    # Remove node if not from apt
    if command -v node &>/dev/null && ! dpkg -S "$(which node)" &>/dev/null 2>/dev/null; then
        rm -rf /usr/local/lib/node_modules 2>/dev/null || true
        rm -f /usr/local/bin/node /usr/local/bin/npm /usr/local/bin/npx 2>/dev/null || true
        log_action "Removed non-apt Node.js"
    fi

    # Cargo
    if $CARGO_GLOBAL; then
        rm -rf /usr/local/cargo /root/.cargo 2>/dev/null || true
        log_action "Removed Cargo"
    fi

    # Go
    if $GO_GLOBAL; then
        rm -rf /usr/local/go 2>/dev/null || true
        rm -f /usr/local/bin/go /usr/local/bin/gofmt 2>/dev/null || true
        log_action "Removed Go"
    fi
}

# ─── Phase 11: Logs and Temp ────────────────────────────────────────────────
phase_11_scan() {
    log_phase "Phase 11: Scanning logs and temp files"

    local log_size tmp_size vartmp_size old_logs
    log_size=$(du -sh /var/log 2>/dev/null | awk '{print $1}')
    tmp_size=$(du -sh /tmp 2>/dev/null | awk '{print $1}')
    vartmp_size=$(du -sh /var/tmp 2>/dev/null | awk '{print $1}')
    old_logs=$(find /var/log -name '*.gz' -o -name '*.old' -o -name '*.1' \
               -o -name '*.2' -o -name '*.3' 2>/dev/null | wc -l)

    report_section "/var/log" "$log_size ($old_logs rotated files)"
    report_section "/tmp" "$tmp_size"
    report_section "/var/tmp" "$vartmp_size"
}

phase_11_clean() {
    log_phase "Phase 11: Cleaning logs and temp files"

    # Truncate active log files
    find /var/log -type f -name '*.log' -exec truncate -s 0 {} \; 2>/dev/null || true

    # Remove rotated logs
    find /var/log -type f \( -name '*.gz' -o -name '*.old' -o -name '*.1' \
         -o -name '*.2' -o -name '*.3' -o -name '*.4' \) -delete 2>/dev/null || true

    # Clean journal
    journalctl --vacuum-time=1d 2>/dev/null || true

    # Clean temp
    find /tmp -mindepth 1 -delete 2>/dev/null || true
    find /var/tmp -mindepth 1 -delete 2>/dev/null || true

    log_action "Cleaned logs and temp files"
}

# ─── Phase 12: Old Kernels ──────────────────────────────────────────────────
phase_12_scan() {
    log_phase "Phase 12: Scanning old kernels"

    local current_kernel
    current_kernel=$(uname -r)

    mapfile -t OLD_KERNELS < <(dpkg -l 'linux-image-*' 'linux-headers-*' \
        'linux-modules-*' 'linux-modules-extra-*' 2>/dev/null | \
        grep '^ii' | awk '{print $2}' | \
        grep -v "$current_kernel" | \
        grep -v 'generic$' | \
        grep -v 'lowlatency$' | \
        grep -v "lowlatency-hwe-${UBUNTU_VERSION}\$" | \
        sort || true)

    report_section "Current kernel" "$current_kernel"
    report_section "Old kernel packages" "${#OLD_KERNELS[@]}"
    for k in "${OLD_KERNELS[@]}"; do
        report_item "$k"
    done
}

phase_12_clean() {
    log_phase "Phase 12: Removing old kernels"

    if [[ ${#OLD_KERNELS[@]} -gt 0 ]]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get remove --purge -y "${OLD_KERNELS[@]}" 2>&1 | tee -a "$LOG_FILE" || true
        update-grub 2>/dev/null || true
        log_action "Removed old kernels"
    fi
}

# ─── Report ──────────────────────────────────────────────────────────────────
generate_report() {
    echo ""
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║          CLEAN-UBUNTU SYSTEM SCAN REPORT             ║${NC}"
    echo -e "${BOLD}${CYAN}╠══════════════════════════════════════════════════════╣${NC}"
    printf "${BOLD}${CYAN}║${NC}  %-50s ${BOLD}${CYAN}║${NC}\n" "Mode: $MODE"
    printf "${BOLD}${CYAN}║${NC}  %-50s ${BOLD}${CYAN}║${NC}\n" "Date: $(date '+%Y-%m-%d %H:%M:%S')"
    printf "${BOLD}${CYAN}║${NC}  %-50s ${BOLD}${CYAN}║${NC}\n" "Host: $(hostname)"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""

    for line in "${REPORT_LINES[@]}"; do
        echo -e "$line"
    done

    if [[ ${#ERRORS[@]} -gt 0 ]]; then
        echo ""
        echo -e "${RED}${BOLD}Errors encountered during scan:${NC}"
        for err in "${ERRORS[@]}"; do
            echo -e "  ${RED}! $err${NC}"
        done
    fi

    echo ""
    if [[ "$MODE" == "dry-run" ]]; then
        echo -e "${YELLOW}${BOLD}══════════════════════════════════════════════════════${NC}"
        echo -e "${YELLOW}${BOLD}  This was a DRY RUN. No changes were made.${NC}"
        echo -e "${YELLOW}${BOLD}  Run with --execute to perform the cleanup.${NC}"
        echo -e "${YELLOW}${BOLD}══════════════════════════════════════════════════════${NC}"
    fi
}

generate_post_report() {
    echo ""
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║          CLEANUP COMPLETED SUCCESSFULLY              ║${NC}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  Backup location:  ${BOLD}$BACKUP_DIR${NC}"
    echo -e "  Log file:         ${BOLD}$LOG_FILE${NC}"
    echo ""

    if [[ ${#ERRORS[@]} -gt 0 ]]; then
        echo -e "${YELLOW}Warnings/errors during execution:${NC}"
        for err in "${ERRORS[@]}"; do
            echo -e "  ${YELLOW}! $err${NC}"
        done
        echo ""
    fi

    # Show current package count
    local pkg_count
    pkg_count=$(dpkg-query -W -f='${Package}\n' 2>/dev/null | wc -l)
    echo -e "  Packages remaining: ${BOLD}$pkg_count${NC}"
    echo -e "  Snaps remaining:    ${BOLD}$(snap list 2>/dev/null | tail -n +2 | wc -l)${NC}"
    echo ""
    echo -e "${YELLOW}  Recommended: Reboot the system to ensure clean state.${NC}"
    echo -e "${YELLOW}  Run: sudo reboot${NC}"
}

confirm_execution() {
    if $AUTO_YES; then
        log_warn "Auto-confirmation enabled (--yes)"
        return 0
    fi

    echo ""
    echo -e "${RED}${BOLD}════════════════════════════════════════════════════════${NC}"
    echo -e "${RED}${BOLD}  WARNING: This will PERMANENTLY remove all items above.${NC}"
    echo -e "${RED}${BOLD}  A backup will be created at: $BACKUP_DIR${NC}"
    echo -e "${RED}${BOLD}════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -n "  Type 'YES I UNDERSTAND' to proceed: "
    read -r confirmation
    if [[ "$confirmation" != "YES I UNDERSTAND" ]]; then
        echo ""
        log_info "Aborted by user."
        exit 0
    fi
}

# ─── Custom MOTD ─────────────────────────────────────────────────────────────
install_custom_motd() {
    log_phase "Installing custom MOTD banner"

    # Disable default Ubuntu MOTD scripts (ads, ESM nags, help links)
    local disable_scripts=(
        00-header
        10-help-text
        50-motd-news
        90-updates-available
        91-contract-ua-esm-status
        91-release-upgrade
        95-hwe-eol
        97-overlayroot
        98-fsck-at-reboot
        98-reboot-required
    )
    for script in "${disable_scripts[@]}"; do
        if [[ -f "/etc/update-motd.d/$script" ]]; then
            chmod -x "/etc/update-motd.d/$script"
        fi
    done

    # Clear static MOTD
    : > /etc/motd 2>/dev/null || true

    # Install custom dynamic MOTD from bundled file
    local motd_src="$SCRIPT_DIR/defaults/00-custom-motd"
    if [[ -f "$motd_src" ]]; then
        cp "$motd_src" /etc/update-motd.d/00-custom
        chmod +x /etc/update-motd.d/00-custom
        log_action "Custom MOTD installed at /etc/update-motd.d/00-custom"
    else
        log_warn "MOTD template not found at $motd_src — skipping"
    fi
}

# ─── Main ────────────────────────────────────────────────────────────────────
main() {
    parse_arguments "$@"
    check_prerequisites
    load_base_packages

    echo -e "${BOLD}${CYAN}"
    echo "  ┌─────────────────────────────────────────────┐"
    echo "  │         clean-ubuntu.sh v1.1                 │"
    echo "  │  Reset Ubuntu $UBUNTU_VERSION to bare-install state   │"
    echo "  │                                              │"
    echo "  │  Preserves: users, sudoers, SSH              │"
    echo "  │  Removes:   everything else                  │"
    echo "  └─────────────────────────────────────────────┘"
    echo -e "${NC}"

    # ── Scan all phases ──
    should_skip_phase 1  || phase_01_scan
    should_skip_phase 2  || phase_02_scan
    should_skip_phase 3  || phase_03_scan
    should_skip_phase 4  || phase_04_scan
    should_skip_phase 5  || phase_05_scan
    should_skip_phase 6  || phase_06_scan
    should_skip_phase 7  || phase_07_scan
    should_skip_phase 8  || phase_08_scan
    should_skip_phase 9  || phase_09_scan
    should_skip_phase 10 || phase_10_scan
    should_skip_phase 11 || phase_11_scan
    should_skip_phase 12 || phase_12_scan

    # ── Generate report ──
    generate_report

    # ── Execute if requested ──
    if [[ "$MODE" == "execute" ]]; then
        confirm_execution
        create_backup

        # Execute in dependency-safe order
        should_skip_phase 4  || phase_04_clean   # Stop services first
        should_skip_phase 5  || phase_05_clean   # Docker (stop containers before removing packages)
        should_skip_phase 6  || phase_06_clean   # Databases
        should_skip_phase 7  || phase_07_clean   # Cron
        should_skip_phase 10 || phase_10_clean   # Language packages (before removing interpreters)
        should_skip_phase 1  || phase_01_clean   # Repos (before packages — avoids broken repo conflicts)
        should_skip_phase 2  || phase_02_clean   # APT packages (main removal, batched with retries)
        should_skip_phase 3  || phase_03_clean   # Snaps
        should_skip_phase 8  || phase_08_clean   # Firewall
        should_skip_phase 9  || phase_09_clean   # Directories
        should_skip_phase 11 || phase_11_clean   # Logs/temp
        should_skip_phase 12 || phase_12_clean   # Old kernels

        # Final cleanup pass
        log_phase "Final cleanup"
        export DEBIAN_FRONTEND=noninteractive
        apt-get autoremove --purge -y 2>&1 | tee -a "$LOG_FILE" || true
        apt-get clean 2>&1 | tee -a "$LOG_FILE"

        # Ensure SSH is still working
        if ! systemctl is-active --quiet ssh && ! systemctl is-active --quiet sshd; then
            log_warn "SSH service not running! Attempting to start..."
            systemctl start ssh 2>/dev/null || systemctl start sshd 2>/dev/null || true
        fi

        # Install custom MOTD
        install_custom_motd

        generate_post_report
    fi
}

# Trap errors
trap 'log_error "Script failed at line $LINENO (exit code: $?)"' ERR

main "$@"
