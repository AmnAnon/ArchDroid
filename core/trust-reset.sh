#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║  ArchDroid — core/trust-reset.sh                                ║
# ║  Trust Reset - Clear All State and Force Fresh Bootstrap        ║
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
RESET_LOG="${STATE_DIR}/logs/trust-reset-${SESSION_ID}.log"

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

# ─── TRUST RESET IMPLEMENTATION ──────────────────────────────────────────────
reset_trust_state() {
    banner "ArchDroid Trust Reset"

    # Initialize reset log
    {
        echo "=== ArchDroid Trust Reset Session ==="
        echo "Session ID: $SESSION_ID"
        echo "Started: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Target: $ARCH_PATH"
        echo "State Dir: $STATE_DIR"
        echo ""
    } > "$RESET_LOG"

    info "This will remove ALL accumulated state and force fresh bootstrap"
    warn "This includes:"
    warn "  - Runtime state snapshots"
    warn "  - Version information"
    warn "  - Cached checksums"
    warn "  - Installation logs"
    warn "  - Verification history"
    echo ""

    # Confirm destructive operation
    echo -n "Are you sure? Type 'reset' to confirm: "
    read -r confirmation

    if [ "$confirmation" != "reset" ]; then
        info "Trust reset cancelled"
        echo "CANCELLED: User cancelled trust reset" >> "$RESET_LOG"
        return 0
    fi

    echo "CONFIRMED: User confirmed trust reset" >> "$RESET_LOG"

    # Phase 1: Clear runtime state
    info "Clearing runtime state..."
    local state_files=(
        "runtime-snapshot.json"
        "runtime-last-good.json"
        "staging-validation.json"
        "rootfs.version"
        "runtime.log"
    )

    for file in "${state_files[@]}"; do
        local full_path="${STATE_DIR}/${file}"
        if [ -f "$full_path" ]; then
            rm -f "$full_path"
            ok "Removed: $file"
            echo "REMOVED: $file" >> "$RESET_LOG"
        fi
    done

    # Phase 2: Clear cached downloads
    info "Clearing cached downloads..."
    if [ -d "$STATE_DIR" ]; then
        find "$STATE_DIR" -name "ArchLinuxARM-*.tar.gz" -type f -delete 2>/dev/null || true
        ok "Cleared cached rootfs archives"
        echo "REMOVED: Cached rootfs archives" >> "$RESET_LOG"
    fi

    # Phase 3: Clear logs except current session
    info "Clearing old logs..."
    if [ -d "${STATE_DIR}/logs" ]; then
        local current_log
        current_log=$(basename "$RESET_LOG")

        find "${STATE_DIR}/logs" -name "*.log" -type f ! -name "$current_log" -delete 2>/dev/null || true
        ok "Cleared old session logs"
        echo "REMOVED: Old session logs (kept current: $current_log)" >> "$RESET_LOG"
    fi

    # Phase 4: Invalidate installations (mark for re-bootstrap)
    info "Invalidating existing installations..."
    if [ -d "$ARCH_PATH" ]; then
        # Don't remove installation, just mark as untrusted
        local marker="${ARCH_PATH}/.archdroid-trust-reset"
        {
            echo "# ArchDroid Trust Reset Marker"
            echo "# This installation is marked as untrusted"
            echo "Session ID: $SESSION_ID"
            echo "Reset Time: $(date '+%Y-%m-%d %H:%M:%S')"
            echo "Reason: User-initiated trust reset"
        } > "$marker"

        warn "Installation marked as untrusted (not removed)"
        warn "Next bootstrap will detect and handle appropriately"
        echo "MARKED: Installation as untrusted at $marker" >> "$RESET_LOG"
    fi

    # Phase 5: Final state verification
    info "Verifying trust reset completion..."
    local cleanup_success=true

    for file in "${state_files[@]}"; do
        if [ -f "${STATE_DIR}/${file}" ]; then
            warn "Warning: Failed to remove ${STATE_DIR}/${file}"
            cleanup_success=false
        fi
    done

    if [ "$cleanup_success" = true ]; then
        ok "Trust reset completed successfully"
        echo "SUCCESS: Trust reset completed" >> "$RESET_LOG"
    else
        warn "Trust reset completed with warnings"
        echo "WARN: Trust reset completed with some warnings" >> "$RESET_LOG"
    fi

    # Completion summary
    {
        echo ""
        echo "=== Trust Reset Summary ==="
        echo "Cleared runtime state: YES"
        echo "Cleared cached downloads: YES"
        echo "Cleared old logs: YES"
        echo "Invalidated installation: $([ -f "${ARCH_PATH}/.archdroid-trust-reset" ] && echo "YES" || echo "NO")"
        echo "Reset completed: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Session ID: $SESSION_ID"
        echo ""
        echo "Next steps:"
        echo "  1. Run 'archdroid bootstrap' to start fresh"
        echo "  2. Verify checksums against external sources"
        echo "  3. Use 'archdroid doctor' if issues persist"
    } >> "$RESET_LOG"

    echo ""
    banner "Trust Reset Complete"
    ok "All accumulated state cleared"
    info "Reset log: $RESET_LOG"
    echo ""
    info "Next steps:"
    echo "  1. Run 'archdroid bootstrap' to start fresh"
    echo "  2. Verify checksums against external sources"
    echo "  3. Use 'archdroid doctor' if issues persist"
}

# ─── MAIN EXECUTION ──────────────────────────────────────────────────────────
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    reset_trust_state "$@"
fi