#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║  ArchDroid — core/inspect-filesystem.sh                         ║
# ║  Filesystem integrity and security validation                   ║
# ╚══════════════════════════════════════════════════════════════════╝

# ─── CONFIGURATION ───────────────────────────────────────────────────────────
ARCH_PATH="/data/local/arch"
CONF_FILE="/data/local/archdroid.conf"
[ -f "$CONF_FILE" ] && source "$CONF_FILE"

# ─── COLORS ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; RESET='\033[0m'
ok() { echo -e "${GREEN}  ✔  $*${RESET}"; }
warn() { echo -e "${YELLOW}  ⚠  $*${RESET}"; }
fail() { echo -e "${RED}  ✘  $*${RESET}"; }

# ─── FILESYSTEM VALIDATION ───────────────────────────────────────────────────
validate_critical_files() {
    local status=0
    local critical_files=(
        "bin/bash"
        "usr/bin/env"
        "etc/passwd"
        "usr/bin/pacman"
        "etc/pacman.conf"
        "usr/lib/ld-linux-aarch64.so.1"
        "lib/libc.so.6"
    )

    echo "=== Critical File Validation ==="
    for file in "${critical_files[@]}"; do
        if [ -f "$ARCH_PATH/$file" ]; then
            ok "$file"
        else
            fail "$file (MISSING)"
            status=1
        fi
    done

    return $status
}

validate_permissions() {
    local status=0

    echo "=== Permission Validation ==="

    # Check rootfs permissions
    local rootfs_perms
    rootfs_perms=$(stat -c "%a" "$ARCH_PATH" 2>/dev/null || echo "unknown")
    if [ "$rootfs_perms" = "755" ] || [ "$rootfs_perms" = "750" ]; then
        ok "Rootfs permissions: $rootfs_perms"
    else
        warn "Rootfs permissions: $rootfs_perms (recommended: 755)"
        status=1
    fi

    # Check critical directory permissions
    local dirs=("bin" "usr" "etc" "tmp" "var")
    for dir in "${dirs[@]}"; do
        if [ -d "$ARCH_PATH/$dir" ]; then
            local dir_perms
            dir_perms=$(stat -c "%a" "$ARCH_PATH/$dir" 2>/dev/null)
            ok "$dir: $dir_perms"
        else
            fail "$dir: missing directory"
            status=2
        fi
    done

    return $status
}

validate_symlinks() {
    local status=0

    echo "=== Symlink Validation ==="
    local important_links=(
        "bin/sh"
        "usr/bin/sh"
        "lib64"
    )

    for link in "${important_links[@]}"; do
        if [ -L "$ARCH_PATH/$link" ]; then
            local target
            target=$(readlink "$ARCH_PATH/$link")
            if [ -e "$ARCH_PATH/$link" ]; then
                ok "$link -> $target"
            else
                fail "$link -> $target (BROKEN)"
                status=1
            fi
        elif [ -e "$ARCH_PATH/$link" ]; then
            ok "$link (regular file/dir)"
        else
            warn "$link (missing, may be optional)"
        fi
    done

    return $status
}

# ─── MAIN EXECUTION ──────────────────────────────────────────────────────────
main() {
    [ ! -d "$ARCH_PATH" ] && { fail "Arch path not found: $ARCH_PATH"; exit 2; }

    local overall_status=0

    validate_critical_files || overall_status=1
    validate_permissions || [ $? -gt $overall_status ] && overall_status=$?
    validate_symlinks || [ $? -gt $overall_status ] && overall_status=$?

    echo "=== Filesystem Validation Summary ==="
    case $overall_status in
        0) ok "All filesystem checks passed" ;;
        1) warn "Filesystem has warnings" ;;
        *) fail "Filesystem has critical issues" ;;
    esac

    exit $overall_status
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "${0}" ] && main "$@"