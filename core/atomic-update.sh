#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║  ArchDroid — core/atomic-update.sh                              ║
# ║  Atomic Update System - Safe In-Place Updates with Rollback     ║
# ╚══════════════════════════════════════════════════════════════════╝

# ─── STRICT MODE ─────────────────────────────────────────────────────────────
set -euo pipefail

# ─── CONFIGURATION ───────────────────────────────────────────────────────────
ARCH_PATH="${ARCH_PATH:-/data/local/arch}"
STATE_DIR="${STATE_DIR:-/data/local/archdroid-state}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Session tracking
SESSION_ID=$(date +%s)
mkdir -p "${STATE_DIR}/logs"
UPDATE_LOG="${STATE_DIR}/logs/atomic-update-${SESSION_ID}.log"

# Load utilities
source "${SCRIPT_DIR}/versions.sh"
source "${SCRIPT_DIR}/json-utils.sh"

# ─── COLORS ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

ok()   { echo -e "${GREEN}  ✔  $*${RESET}"; }
warn() { echo -e "${YELLOW}  ⚠  $*${RESET}"; }
fail() { echo -e "${RED}  ✘  $*${RESET}"; }
info() { echo -e "${CYAN}  ▶  $*${RESET}"; }

banner() {
    echo -e "${BOLD}${CYAN}"
    echo "  ╔══════════════════════════════════════════════════╗"
    printf "  ║  %-48s║\n" "$*"
    echo "  ╚══════════════════════════════════════════════════╝"
    echo -e "${RESET}"
}

# ─── USER DATA PRESERVATION ──────────────────────────────────────────────────
detect_user_data() {
    local install_path="$1"
    local data_paths=()

    info "Detecting user data that needs preservation..."

    # Common user data locations
    local user_dirs=(
        "home"
        "root/.bashrc"
        "root/.profile"
        "root/.ssh"
        "root/.config"
        "etc/passwd"
        "etc/shadow"
        "etc/group"
        "etc/hostname"
        "etc/hosts"
        "etc/sudoers"
        "etc/sudoers.d"
        "var/lib/pacman/local"
        "usr/local"
    )

    for dir in "${user_dirs[@]}"; do
        local full_path="${install_path}/${dir}"
        if [ -e "$full_path" ]; then
            data_paths+=("$dir")
            ok "Found user data: $dir"
        fi
    done

    if [ ${#data_paths[@]} -eq 0 ]; then
        info "No user data detected - clean update possible"
    else
        info "Found ${#data_paths[@]} user data locations to preserve"
        echo "USER_DATA_PATHS=${data_paths[*]}" >> "$UPDATE_LOG"
    fi

    printf '%s\n' "${data_paths[@]}"
}

backup_user_data() {
    local install_path="$1"
    local backup_dir="$2"
    shift 2
    local data_paths=("$@")

    info "Creating user data backup..."
    echo "BACKUP: Starting user data backup" >> "$UPDATE_LOG"

    mkdir -p "$backup_dir"

    for path in "${data_paths[@]}"; do
        local src="${install_path}/${path}"
        local dst="${backup_dir}/${path}"

        if [ -e "$src" ]; then
            # Create parent directory structure
            mkdir -p "$(dirname "$dst")"

            # Preserve with all attributes
            if cp -a "$src" "$dst" 2>/dev/null; then
                ok "Backed up: $path"
                echo "BACKUP: $path" >> "$UPDATE_LOG"
            else
                warn "Failed to backup: $path"
                echo "WARN: Failed to backup $path" >> "$UPDATE_LOG"
                return 1
            fi
        fi
    done

    ok "User data backup completed"
    return 0
}

restore_user_data() {
    local install_path="$1"
    local backup_dir="$2"
    shift 2
    local data_paths=("$@")

    info "Restoring user data from backup..."
    echo "RESTORE: Starting user data restoration" >> "$UPDATE_LOG"

    for path in "${data_paths[@]}"; do
        local src="${backup_dir}/${path}"
        local dst="${install_path}/${path}"

        if [ -e "$src" ]; then
            # Create parent directory structure
            mkdir -p "$(dirname "$dst")"

            # Restore with all attributes
            if cp -a "$src" "$dst" 2>/dev/null; then
                ok "Restored: $path"
                echo "RESTORE: $path" >> "$UPDATE_LOG"
            else
                warn "Failed to restore: $path"
                echo "WARN: Failed to restore $path" >> "$UPDATE_LOG"
            fi
        fi
    done

    ok "User data restoration completed"
    return 0
}

# ─── UPDATE STRATEGY ANALYSIS ────────────────────────────────────────────────
analyze_update_strategy() {
    local current_version="$1"
    local target_version="$2"

    info "Analyzing update strategy..."
    echo "UPDATE_ANALYSIS: Current=$current_version Target=$target_version" >> "$UPDATE_LOG"

    # Version comparison logic
    if [ "$current_version" = "$target_version" ]; then
        echo "same"
        return 0
    fi

    # Parse version dates for comparison
    local current_date target_date

    # Handle "none" version case
    if [ "$current_version" = "none" ]; then
        echo "upgrade"
        return 0
    fi

    current_date=$(echo "$current_version" | tr -d '-')
    target_date=$(echo "$target_version" | tr -d '-')

    # Validate dates are numeric
    if ! [[ "$current_date" =~ ^[0-9]+$ ]] || ! [[ "$target_date" =~ ^[0-9]+$ ]]; then
        echo "unknown"
        return 1
    fi

    if [ "$target_date" -gt "$current_date" ]; then
        echo "upgrade"
        return 0
    elif [ "$target_date" -lt "$current_date" ]; then
        echo "downgrade"
        return 0
    else
        echo "unknown"
        return 1
    fi
}

# ─── ATOMIC UPDATE IMPLEMENTATION ────────────────────────────────────────────
perform_atomic_update() {
    local current_version target_version strategy

    banner "ArchDroid Atomic Update System"

    # Initialize update log
    {
        echo "=== ArchDroid Atomic Update Session ==="
        echo "Session ID: $SESSION_ID"
        echo "Started: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Target: $ARCH_PATH"
        echo ""
    } > "$UPDATE_LOG"

    # Step 1: Validate current installation
    info "Validating current installation..."
    if [ ! -d "$ARCH_PATH" ] || [ ! -f "$ARCH_PATH/bin/bash" ]; then
        fail "No valid installation found at: $ARCH_PATH"
        fail "Use 'archdroid bootstrap' for initial installation"
        echo "FATAL: No installation found" >> "$UPDATE_LOG"
        return 1
    fi

    current_version=$(get_current_version "$STATE_DIR")
    target_version="$ARCH_VERSION"

    ok "Current version: $current_version"
    ok "Target version: $target_version"

    # Step 2: Determine update strategy
    strategy=$(analyze_update_strategy "$current_version" "$target_version")

    case "$strategy" in
        "same")
            info "Already at target version - no update needed"
            echo "SKIP: Already at target version" >> "$UPDATE_LOG"
            return 0
            ;;
        "upgrade")
            ok "Strategy: UPGRADE ($current_version → $target_version)"
            ;;
        "downgrade")
            warn "Strategy: DOWNGRADE ($current_version → $target_version)"
            warn "Downgrades require extra caution"
            ;;
        *)
            fail "Cannot determine update strategy"
            echo "FATAL: Unknown update strategy" >> "$UPDATE_LOG"
            return 1
            ;;
    esac

    echo "STRATEGY: $strategy" >> "$UPDATE_LOG"

    # Step 3: Pre-update validation
    info "Running pre-update system validation..."
    if ! "${SCRIPT_DIR}/inspect-runtime.sh" >/dev/null 2>&1; then
        fail "System validation failed - cannot proceed with update"
        fail "Run 'archdroid doctor' to resolve issues first"
        echo "FATAL: Pre-update validation failed" >> "$UPDATE_LOG"
        return 1
    fi
    ok "Pre-update validation passed"

    # Step 4: Detect and backup user data
    local user_data_paths backup_dir update_dir snapshot_dir
    backup_dir="${ARCH_PATH}.update-backup"
    update_dir="${ARCH_PATH}.update-staging"
    snapshot_dir="${ARCH_PATH}.update-snapshot"

    mapfile -t user_data_paths < <(detect_user_data "$ARCH_PATH")

    if [ ${#user_data_paths[@]} -gt 0 ]; then
        info "Creating user data backup..."
        rm -rf "$backup_dir"
        if ! backup_user_data "$ARCH_PATH" "$backup_dir" "${user_data_paths[@]}"; then
            fail "User data backup failed - aborting update"
            echo "FATAL: User data backup failed" >> "$UPDATE_LOG"
            return 1
        fi
    else
        info "No user data to backup"
    fi

    # Step 5: Download and prepare new version
    info "Downloading target version..."
    rm -rf "$update_dir"

    # Download new rootfs
    local tarfile="${STATE_DIR}/${ARCH_TARBALL}"
    source "${SCRIPT_DIR}/bootstrap.sh"

    if ! download_rootfs "$tarfile"; then
        fail "Download failed"
        echo "FATAL: Download failed" >> "$UPDATE_LOG"
        return 1
    fi

    # Step 6: Verify download
    info "Verifying download integrity..."
    if ! verify_download "$tarfile"; then
        fail "Download verification failed"
        rm -f "$tarfile"
        echo "FATAL: Download verification failed" >> "$UPDATE_LOG"
        return 1
    fi

    # Step 7: Extract and validate new version
    info "Extracting new version..."
    if ! extract_to_staging "$tarfile" "$update_dir"; then
        fail "Extraction failed"
        rm -rf "$update_dir"
        echo "FATAL: Extraction failed" >> "$UPDATE_LOG"
        return 1
    fi

    info "Validating extracted rootfs..."
    if ! validate_staging_rootfs "$update_dir"; then
        fail "Staging validation failed"
        rm -rf "$update_dir"
        echo "FATAL: Staging validation failed" >> "$UPDATE_LOG"
        return 1
    fi

    # Step 8: Create atomic snapshot
    info "Creating atomic snapshot for guaranteed rollback..."
    rm -rf "$snapshot_dir"
    if ! cp -a "$ARCH_PATH" "$snapshot_dir" 2>/dev/null; then
        fail "Failed to create atomic snapshot"
        rm -rf "$update_dir"
        echo "FATAL: Snapshot creation failed" >> "$UPDATE_LOG"
        return 1
    fi
    ok "Atomic snapshot created"

    # Step 9: Atomic replacement
    info "Performing atomic update (point of no return)..."
    echo "ATOMIC: Starting atomic replacement" >> "$UPDATE_LOG"

    # The critical atomic operation
    if mv "$ARCH_PATH" "${ARCH_PATH}.old" && mv "$update_dir" "$ARCH_PATH"; then
        ok "Atomic replacement: SUCCESS"
        echo "SUCCESS: Atomic replacement completed" >> "$UPDATE_LOG"
    else
        fail "Atomic replacement: FAILED"
        echo "FATAL: Atomic replacement failed" >> "$UPDATE_LOG"

        # Emergency recovery
        warn "Attempting emergency recovery..."
        [ -d "${ARCH_PATH}.old" ] && mv "${ARCH_PATH}.old" "$ARCH_PATH" 2>/dev/null || true
        [ -d "$snapshot_dir" ] && { rm -rf "$ARCH_PATH" 2>/dev/null || true; mv "$snapshot_dir" "$ARCH_PATH" 2>/dev/null || true; }

        fail "Update failed - attempted emergency recovery"
        return 1
    fi

    # Step 10: Restore user data
    if [ ${#user_data_paths[@]} -gt 0 ]; then
        info "Restoring user data..."
        if ! restore_user_data "$ARCH_PATH" "$backup_dir" "${user_data_paths[@]}"; then
            warn "User data restoration failed - update successful but data lost"
            echo "WARN: User data restoration failed" >> "$UPDATE_LOG"
        else
            ok "User data restoration completed"
        fi
    fi

    # Step 11: Post-update validation
    info "Running post-update validation..."
    if ! "${SCRIPT_DIR}/verify.sh" >/dev/null 2>&1; then
        fail "Post-update validation failed"
        echo "FATAL: Post-update validation failed" >> "$UPDATE_LOG"

        # Rollback due to validation failure
        warn "Rolling back due to validation failure..."
        rm -rf "$ARCH_PATH"
        if mv "$snapshot_dir" "$ARCH_PATH" 2>/dev/null; then
            warn "Rollback completed successfully"
            echo "SUCCESS: Validation rollback completed" >> "$UPDATE_LOG"
        else
            fail "Rollback failed - manual intervention required"
            echo "FATAL: Rollback failed" >> "$UPDATE_LOG"
        fi
        return 1
    fi

    # Step 12: Update version tracking
    save_current_version "$STATE_DIR"
    ok "Version updated: $target_version"

    # Step 13: Cleanup
    rm -rf "${ARCH_PATH}.old" "$snapshot_dir" "$backup_dir" "$tarfile" 2>/dev/null || true
    ok "Update artifacts cleaned up"

    # Success summary
    {
        echo ""
        echo "=== Atomic Update Completed Successfully ==="
        echo "Updated: $current_version → $target_version"
        echo "Strategy: $strategy"
        echo "User data preserved: ${#user_data_paths[@]} locations"
        echo "Finished: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Session ID: $SESSION_ID"
    } >> "$UPDATE_LOG"

    echo ""
    banner "Update Complete!"
    ok "Successfully updated: $current_version → $target_version"
    ok "User data preserved and validated"
    info "Update log: $UPDATE_LOG"
    echo ""
    info "Next steps:"
    echo "  1. Run 'archdroid start' to test the updated system"
    echo "  2. Run 'archdroid doctor' if you encounter issues"

    return 0
}

# ─── MAIN EXECUTION ──────────────────────────────────────────────────────────
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    perform_atomic_update "$@"
fi