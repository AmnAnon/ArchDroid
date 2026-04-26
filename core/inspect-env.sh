#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║  ArchDroid — core/inspect-env.sh                                ║
# ║  Environment variables and execution context validation         ║
# ╚══════════════════════════════════════════════════════════════════╝

# ─── COLORS ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; RESET='\033[0m'
ok() { echo -e "${GREEN}  ✔  $*${RESET}"; }
warn() { echo -e "${YELLOW}  ⚠  $*${RESET}"; }
fail() { echo -e "${RED}  ✘  $*${RESET}"; }
info() { echo -e "${CYAN}  ▶  $*${RESET}"; }

# ─── ENVIRONMENT DETECTION ───────────────────────────────────────────────────
detect_environment() {
    local env_type="unknown"

    # Check if we're in chroot
    if [ "$(stat -c %d:%i /)" != "$(stat -c %d:%i /proc/1/root/.)" ] 2>/dev/null; then
        env_type="chroot"
    # Check if we're in proot (common indicators)
    elif [ -n "${PROOT_TMP_DIR:-}" ] || [ -n "${PROOT_L2S_DIR:-}" ]; then
        env_type="proot"
    # Check for Android/Termux environment
    elif [ -d "/data/data/com.termux" ] || [ -n "${PREFIX:-}" ]; then
        env_type="termux"
    elif [ -d "/system/bin" ] && [ -f "/system/build.prop" ]; then
        env_type="android"
    else
        env_type="native"
    fi

    echo "$env_type"
}

validate_path() {
    local status=0

    echo "=== PATH Validation ==="
    info "Current PATH: $PATH"

    # Check for Android contamination
    if echo "$PATH" | grep -q "/system/bin"; then
        warn "Android /system/bin in PATH - may cause conflicts"
        status=1
    fi

    # Check for essential directories
    local essential_paths=("/usr/bin" "/bin" "/usr/sbin" "/sbin")
    for path in "${essential_paths[@]}"; do
        if echo "$PATH" | grep -q "$path"; then
            ok "$path in PATH"
        else
            warn "$path missing from PATH"
            status=1
        fi
    done

    # Check PATH order (standard should come first)
    local first_path
    first_path=$(echo "$PATH" | cut -d: -f1)
    if [[ "$first_path" == "/usr/local/sbin" || "$first_path" == "/usr/local/bin" || "$first_path" == "/usr/bin" ]]; then
        ok "PATH order looks correct"
    else
        warn "PATH order may be problematic: starts with $first_path"
        status=1
    fi

    return $status
}

validate_environment_vars() {
    local status=0

    echo "=== Environment Variables Validation ==="

    # HOME
    if [ -n "$HOME" ]; then
        if [[ "$HOME" == "/root" || "$HOME" == "/home/"* ]]; then
            ok "HOME: $HOME"
        else
            warn "HOME: $HOME (unusual value)"
            status=1
        fi
    else
        fail "HOME not set"
        status=2
    fi

    # SHELL
    if [ -n "$SHELL" ]; then
        if [[ "$SHELL" == *"/bash" || "$SHELL" == *"/zsh" || "$SHELL" == *"/sh" ]]; then
            ok "SHELL: $SHELL"
        else
            warn "SHELL: $SHELL (unusual shell)"
            status=1
        fi
    else
        warn "SHELL not set"
        status=1
    fi

    # USER
    if [ -n "$USER" ]; then
        ok "USER: $USER"
    else
        warn "USER not set"
        status=1
    fi

    # Check for problematic Android variables
    local android_vars=("ANDROID_DATA" "ANDROID_ROOT" "BOOTCLASSPATH")
    for var in "${android_vars[@]}"; do
        if [ -n "${!var}" ]; then
            warn "$var is set (may indicate Android contamination)"
            status=1
        fi
    done

    return $status
}

validate_execution_context() {
    local status=0

    echo "=== Execution Context Validation ==="

    # Root check
    if [ "$(id -u)" -eq 0 ]; then
        ok "Running as root"
    else
        fail "Not running as root (UID: $(id -u))"
        status=2
    fi

    # SELinux check
    local selinux_mode
    selinux_mode=$(getenforce 2>/dev/null || echo "unknown")
    case "$selinux_mode" in
        "Permissive"|"Disabled") ok "SELinux: $selinux_mode" ;;
        "Enforcing") warn "SELinux: $selinux_mode (may block operations)" && status=1 ;;
        *) warn "SELinux: $selinux_mode (status unknown)" && status=1 ;;
    esac

    # Namespace detection
    if [ -d "/data/adb/ksu" ]; then
        ok "Root manager: KernelSU detected"
    elif [ -d "/data/adb/magisk" ] || [ -f "/data/adb/magisk.db" ]; then
        ok "Root manager: Magisk detected"
        if ! command -v nsenter &>/dev/null; then
            warn "nsenter not available - namespace operations may fail"
            status=1
        fi
    else
        warn "No known root manager detected"
        status=1
    fi

    return $status
}

extract_env_info() {
    echo "=== Environment Information Export ==="

    local env_type
    env_type=$(detect_environment)
    echo "Environment Type: $env_type"
    echo "PATH: $PATH"
    echo "HOME: $HOME"
    echo "SHELL: $SHELL"
    echo "USER: $USER"
    echo "UID: $(id -u)"
    echo "GID: $(id -g)"
    echo "SELinux: $(getenforce 2>/dev/null || echo 'unknown')"
}

# ─── MAIN EXECUTION ──────────────────────────────────────────────────────────
main() {
    local overall_status=0

    validate_path || [ $? -gt $overall_status ] && overall_status=$?
    validate_environment_vars || [ $? -gt $overall_status ] && overall_status=$?
    validate_execution_context || [ $? -gt $overall_status ] && overall_status=$?
    extract_env_info

    echo "=== Environment Validation Summary ==="
    case $overall_status in
        0) ok "All environment checks passed" ;;
        1) warn "Environment has warnings" ;;
        *) fail "Environment has critical issues" ;;
    esac

    exit $overall_status
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "${0}" ] && main "$@"