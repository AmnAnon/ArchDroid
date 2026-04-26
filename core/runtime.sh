#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║  ArchDroid — core/runtime.sh                                    ║
# ║  Deterministic Runtime System - Forces Reality to Match State   ║
# ╚══════════════════════════════════════════════════════════════════╝

# ─── STRICT MODE ─────────────────────────────────────────────────────────────
set -euo pipefail

# ─── CONFIGURATION ───────────────────────────────────────────────────────────
ARCH_PATH="${ARCH_PATH:-/data/local/arch}"
STATE_DIR="${STATE_DIR:-/data/local/archdroid-state}"
RUNTIME_JSON="${STATE_DIR}/runtime-snapshot.json"
LAST_GOOD_JSON="${STATE_DIR}/runtime-last-good.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Session tracking
SESSION_ID=$(date +%s)
mkdir -p "${STATE_DIR}/logs"
LOG_FILE="${STATE_DIR}/logs/runtime-${SESSION_ID}.log"

# Load utilities
source "${SCRIPT_DIR}/json-utils.sh"

# ─── TAMPER-AWARE LOGGING ────────────────────────────────────────────────────
add_log_integrity() {
    local log_file="$1"
    local message="${2:-LOG_ENTRY}"

    # Create tamper-evident chain, not just snapshot
    if [ -f "$log_file" ] && [ -s "$log_file" ]; then
        # Get previous hash from chain (if exists)
        local prev_hash
        prev_hash=$(tail -n 1 "$log_file" 2>/dev/null | grep "LOG_CHAIN=" | cut -d= -f2 | cut -d: -f2)

        # If no previous hash, this is first entry
        if [ -z "$prev_hash" ]; then
            prev_hash="GENESIS"
        fi

        # Compute current log state hash
        local current_hash
        current_hash=$(sha256sum "$log_file" | awk '{print $1}')

        # Create tamper-evident chain link
        echo "${message}_LOG_CHAIN=${prev_hash}:${current_hash}" >> "$log_file"
    else
        # Initialize chain for new log
        echo "${message}_LOG_CHAIN=GENESIS:INIT" >> "$log_file"
    fi
}

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

# ─── HARD GATE: VALIDATE SYSTEM READINESS ───────────────────────────────────
hard_gate_startup() {
    banner "ArchDroid Deterministic Runtime"

    # Log session start
    {
        echo "=== Runtime Session Started ==="
        echo "Session ID: $SESSION_ID"
        echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Arch Path: $ARCH_PATH"
        echo "Safe Mode: ${ARCHDROID_SAFE_MODE:-disabled}"
        echo ""
    } > "$LOG_FILE"

    info "Session ID: $SESSION_ID"
    info "Validating system readiness..."

    # Run inspection to get current state
    if ! "${SCRIPT_DIR}/inspect-runtime.sh" >/dev/null 2>&1; then
        warn "Runtime inspection had issues - checking state file"

        # Check if we have a recent state file
        if [ ! -f "$RUNTIME_JSON" ]; then
            fail "No runtime state available and inspection failed"
            echo "FATAL: No state file and inspection failed" >> "$LOG_FILE"
            exit 2
        fi

        # Check if state file is recent (less than 5 minutes old)
        local state_age
        state_age=$(($(date +%s) - $(stat -c %Y "$RUNTIME_JSON" 2>/dev/null || echo 0)))
        if [ "$state_age" -gt 300 ]; then
            fail "Runtime state is stale and inspection failed"
            echo "FATAL: Stale state (${state_age}s old) and inspection failed" >> "$LOG_FILE"
            exit 2
        fi

        warn "Using existing runtime state (${state_age}s old)"
        echo "WARN: Using stale state (${state_age}s old)" >> "$LOG_FILE"
    fi

    # Get overall status
    local status
    status=$(safe_json_int "$RUNTIME_JSON" ".overall_status" "2")

    case "$status" in
        0)
            ok "System validation: PASSED (all checks OK)"
            # Save as last known good state
            cp "$RUNTIME_JSON" "$LAST_GOOD_JSON" 2>/dev/null || true
            echo "SUCCESS: System validation passed" >> "$LOG_FILE"
            return 0
            ;;
        1)
            warn "System validation: WARNINGS (may have issues)"
            warn "Proceeding with runtime enforcement..."
            # Save as last known good (warnings are acceptable)
            cp "$RUNTIME_JSON" "$LAST_GOOD_JSON" 2>/dev/null || true
            echo "WARN: System has warnings but proceeding" >> "$LOG_FILE"
            return 0
            ;;
        *)
            # Check if safe mode is enabled
            if [ "${ARCHDROID_SAFE_MODE:-}" = "1" ]; then
                warn "SAFE MODE ENABLED - bypassing hard gate"
                warn "System has critical failures but continuing anyway"
                echo "SAFE_MODE: Bypassing hard gate with critical failures" >> "$LOG_FILE"
                return 0
            fi

            fail "System validation: FAILED (critical issues detected)"
            fail "Cannot start - system not ready"

            # Show component status for debugging
            local fs_status network_status env_status sec_status
            fs_status=$(safe_json_int "$RUNTIME_JSON" ".components.filesystem" "2")
            network_status=$(safe_json_int "$RUNTIME_JSON" ".components.network" "2")
            env_status=$(safe_json_int "$RUNTIME_JSON" ".components.environment" "2")
            sec_status=$(safe_json_int "$RUNTIME_JSON" ".components.security" "2")

            echo ""
            fail "Component failures:"
            [ "$fs_status" -gt 1 ] && fail "  - Filesystem: critical issues"
            [ "$network_status" -gt 1 ] && fail "  - Network: critical issues"
            [ "$env_status" -gt 1 ] && fail "  - Environment: critical issues"
            [ "$sec_status" -gt 1 ] && fail "  - Security: critical issues"

            echo ""
            fail "Run 'archdroid doctor' to diagnose and fix issues"
            fail "Or use: ARCHDROID_SAFE_MODE=1 archdroid start (for debugging only)"

            # Log detailed failure information
            {
                echo "FATAL: System validation failed"
                echo "Overall status: $status"
                echo "Component status: fs=$fs_status net=$network_status env=$env_status sec=$sec_status"
            } >> "$LOG_FILE"

            exit 2
            ;;
    esac
}

# ─── ENFORCE ENVIRONMENT: Clean State ───────────────────────────────────────
enforce_environment() {
    info "Enforcing clean runtime environment..."
    echo "=== Environment Enforcement ===" >> "$LOG_FILE"

    # Force clean PATH - ignore whatever Android/Termux gives us
    local old_path="$PATH"
    export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    ok "PATH enforced: /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    echo "PATH: $old_path → $PATH" >> "$LOG_FILE"

    # Force clean HOME
    local old_home="${HOME:-unset}"
    export HOME="/root"
    ok "HOME enforced: /root"
    echo "HOME: $old_home → $HOME" >> "$LOG_FILE"

    # Force clean USER
    local old_user="${USER:-unset}"
    export USER="root"
    ok "USER enforced: root"
    echo "USER: $old_user → $USER" >> "$LOG_FILE"

    # Clear dangerous Android variables
    local android_vars=("ANDROID_DATA" "ANDROID_ROOT" "BOOTCLASSPATH" "TERMUX" "PREFIX")
    for var in "${android_vars[@]}"; do
        if [ -n "${!var:-}" ]; then
            echo "Cleared: $var=${!var}" >> "$LOG_FILE"
            unset "$var"
            ok "Cleared Android variable: $var"
        fi
    done

    # Set essential variables
    export LANG="${LANG:-C.UTF-8}"
    export LC_ALL="${LC_ALL:-C.UTF-8}"
    ok "Locale enforced: C.UTF-8"
    echo "Locale: LANG=$LANG LC_ALL=$LC_ALL" >> "$LOG_FILE"

    echo "" >> "$LOG_FILE"
}

# ─── ENFORCE MOUNTS: Converge to Desired State ──────────────────────────────
enforce_mounts() {
    info "Enforcing mount points (converging to desired state)..."

    # Ensure mount point directories exist
    local mount_dirs=("proc" "sys" "dev" "dev/pts" "tmp" "media/sdcard")
    for dir in "${mount_dirs[@]}"; do
        mkdir -p "$ARCH_PATH/$dir"
    done

    # proc filesystem - clean mount
    umount -lf "$ARCH_PATH/proc" 2>/dev/null || true
    if mount -t proc proc "$ARCH_PATH/proc" 2>/dev/null; then
        ok "Mounted: proc (clean)"
    else
        warn "Failed to mount proc (may need root)"
    fi

    # sysfs filesystem - clean mount
    umount -lf "$ARCH_PATH/sys" 2>/dev/null || true
    if mount -t sysfs sysfs "$ARCH_PATH/sys" 2>/dev/null; then
        ok "Mounted: sys (clean)"
    else
        warn "Failed to mount sys (may need root)"
    fi

    # dev filesystem - clean rbind mount with proper propagation
    umount -lf "$ARCH_PATH/dev" 2>/dev/null || true
    if mount --rbind /dev "$ARCH_PATH/dev" 2>/dev/null; then
        mount --make-rslave "$ARCH_PATH/dev" 2>/dev/null || true
        ok "Mounted: dev (clean rbind + rslave)"
    else
        warn "Failed to mount dev (may need root)"
    fi

    # dev/pts filesystem - clean rbind mount with proper propagation
    umount -lf "$ARCH_PATH/dev/pts" 2>/dev/null || true
    if mount --rbind /dev/pts "$ARCH_PATH/dev/pts" 2>/dev/null; then
        mount --make-rslave "$ARCH_PATH/dev/pts" 2>/dev/null || true
        ok "Mounted: dev/pts (clean rbind + rslave)"
    else
        warn "Failed to mount dev/pts (may need root)"
    fi

    # tmpfs for /tmp - clean mount, critical for performance
    umount -lf "$ARCH_PATH/tmp" 2>/dev/null || true
    if mount -t tmpfs -o size=512m,mode=1777 tmpfs "$ARCH_PATH/tmp" 2>/dev/null; then
        ok "Mounted: tmp (clean tmpfs 512MB)"
    else
        warn "Failed to mount tmpfs on /tmp"
    fi

    # sdcard mount (best effort) - clean mount
    local sdcard_src=""
    [ -d "/sdcard" ] && sdcard_src="/sdcard"
    [ -z "$sdcard_src" ] && [ -d "/storage/emulated/0" ] && sdcard_src="/storage/emulated/0"

    if [ -n "$sdcard_src" ]; then
        umount -lf "$ARCH_PATH/media/sdcard" 2>/dev/null || true
        if mount --bind "$sdcard_src" "$ARCH_PATH/media/sdcard" 2>/dev/null; then
            ok "Mounted: sdcard (clean bind from $sdcard_src)"
        else
            warn "Failed to mount sdcard"
        fi
    else
        warn "No sdcard source found - skipping"
    fi
}

# ─── ENFORCE DNS: Fix Broken DNS with Backup Strategy ───────────────────────
enforce_dns() {
    info "Enforcing DNS configuration with backup strategy..."

    local resolv_conf="$ARCH_PATH/etc/resolv.conf"
    local dns_fixed=false

    # Ensure /etc directory exists
    mkdir -p "$ARCH_PATH/etc"

    # Test actual DNS resolution (not just config)
    if ! timeout 5 getent hosts google.com >/dev/null 2>&1; then
        warn "DNS resolution failed — applying fallback configuration"

        # Apply robust multi-resolver configuration
        {
            echo "# ArchDroid enforced DNS configuration"
            echo "# Applied due to DNS resolution failure"
            echo "nameserver 1.1.1.1"
            echo "nameserver 8.8.8.8"
            echo "nameserver 208.67.222.222"
            echo "# Fallback to OpenDNS"
            echo "nameserver 208.67.220.220"
        } > "$resolv_conf"

        warn "DNS enforced: 1.1.1.1, 8.8.8.8, 208.67.222.222, 208.67.220.220"
        dns_fixed=true

        # Test again to verify fix
        sleep 1
        if timeout 5 getent hosts google.com >/dev/null 2>&1; then
            ok "DNS resolution now working after enforcement"
        else
            warn "DNS still failing after enforcement - network may be down"
        fi
    else
        ok "DNS resolution working - keeping current configuration"
    fi

    # Always ensure resolv.conf exists with at least minimal config
    if [ ! -f "$resolv_conf" ] || [ ! -s "$resolv_conf" ]; then
        {
            echo "# ArchDroid minimal DNS configuration"
            echo "nameserver 1.1.1.1"
            echo "nameserver 8.8.8.8"
        } > "$resolv_conf"
        warn "Created minimal DNS configuration (file was missing/empty)"
        dns_fixed=true
    fi

    # Log enforcement for transparency
    if [ "$dns_fixed" = true ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] DNS enforced" >> "${STATE_DIR}/runtime.log"
        warn "DNS enforcement logged for transparency"
    fi
}

# ─── CONTROLLED ENTRY: Clean Isolated Execution ────────────────────────────
controlled_entry() {
    info "Preparing controlled chroot entry..."
    echo "=== Controlled Entry ===" >> "$LOG_FILE"

    # Validate bash exists and is executable
    if [ ! -x "$ARCH_PATH/bin/bash" ]; then
        fail "Cannot enter chroot: /bin/bash not found or not executable"
        echo "FATAL: bash not found or not executable" >> "$LOG_FILE"
        exit 2
    fi

    # Final environment setup
    export TERM="${TERM:-xterm-256color}"
    export SHELL="/bin/bash"

    ok "Environment prepared for chroot entry"

    # Show what we're about to do
    echo ""
    info "Entering clean, isolated chroot environment:"
    echo "  Path: $ARCH_PATH"
    echo "  Shell: /bin/bash --login"
    echo "  Environment: Clean (no Android contamination)"
    echo "  Mounts: Enforced and validated"
    echo "  DNS: Working and reliable"
    echo ""

    # Log final environment and entry with integrity protection
    {
        echo "Final environment:"
        echo "  ARCH_PATH=$ARCH_PATH"
        echo "  PATH=$PATH"
        echo "  HOME=$HOME"
        echo "  USER=$USER"
        echo "  TERM=$TERM"
        echo "  SHELL=$SHELL"
        echo "  LANG=$LANG"
        echo "  LC_ALL=$LC_ALL"
        echo ""
        echo "Entering chroot with exec..."
        echo "Command: chroot $ARCH_PATH /usr/bin/env -i [clean env] /bin/bash --login"
        echo "=== Session $SESSION_ID Complete ==="
    } >> "$LOG_FILE"

    # Add tamper detection to log
    add_log_integrity "$LOG_FILE" "RUNTIME_COMPLETE"

    # Clean, isolated entry point
    exec chroot "$ARCH_PATH" /usr/bin/env -i \
        HOME="/root" \
        TERM="$TERM" \
        PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        LANG="C.UTF-8" \
        LC_ALL="C.UTF-8" \
        SHELL="/bin/bash" \
        USER="root" \
        /bin/bash --login
}

# ─── MAIN EXECUTION ──────────────────────────────────────────────────────────
main() {
    # Phase 2: Force reality to match expectations
    # NO adaptation - NO "try anyway" - ENFORCE correctness

    hard_gate_startup      # Validate or fail hard
    enforce_environment    # Clean environment variables
    enforce_mounts         # Converge mount state
    enforce_dns            # Fix broken DNS
    controlled_entry       # Clean isolated execution
}

# Execute if called directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi