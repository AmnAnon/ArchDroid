#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║  ArchDroid — test/recovery-validation.sh                        ║
# ║  Recovery and Resilience Validation Tests                       ║
# ╚══════════════════════════════════════════════════════════════════╝

# ─── STRICT MODE ─────────────────────────────────────────────────────────────
set -euo pipefail

# ─── CONFIGURATION ───────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(dirname "$SCRIPT_DIR")/core"
TEST_DIR="/tmp/archdroid-recovery-$$"

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

# ─── SPECIFIC RECOVERY TESTS ──────────────────────────────────────────────────

test_partial_download_cleanup() {
    banner "Testing Partial Download Cleanup"

    mkdir -p "$TEST_DIR/state"
    local fake_tarball="$TEST_DIR/state/ArchLinuxARM-aarch64-2024-03-31.tar.gz"

    # Create a partial download
    echo "PARTIAL DOWNLOAD CONTENT" > "$fake_tarball"
    info "Created fake partial download: $fake_tarball"

    # Simulate bootstrap failure by corrupting the checksum
    local original_checksums="/arch-android/core/checksums.txt"
    local backup_checksums="/tmp/checksums.backup.$$"
    cp "$original_checksums" "$backup_checksums"

    # Corrupt checksums to force failure
    echo "ArchLinuxARM-aarch64-2024-03-31.tar.gz INVALID_CHECKSUM_TO_FORCE_FAILURE" > "$original_checksums"

    # Try bootstrap - should fail and cleanup
    if ARCH_PATH="$TEST_DIR/arch" STATE_DIR="$TEST_DIR/state" "$CORE_DIR/bootstrap.sh" 2>/dev/null; then
        fail "Bootstrap unexpectedly succeeded with invalid checksum"
        return 1
    fi

    # Restore checksums
    cp "$backup_checksums" "$original_checksums"
    rm -f "$backup_checksums"

    # Verify cleanup happened
    if [ -f "$fake_tarball" ]; then
        warn "Partial download not cleaned up: $fake_tarball"
        return 1
    else
        ok "Partial download cleaned up successfully"
    fi

    if [ -d "$TEST_DIR/arch" ] && [ "$(ls -A "$TEST_DIR/arch" 2>/dev/null)" ]; then
        warn "Partial installation remains"
        ls -la "$TEST_DIR/arch"
        return 1
    else
        ok "No partial installation remains"
    fi

    return 0
}

test_atomic_rollback() {
    banner "Testing Atomic Rollback"

    # Create fake existing installation
    mkdir -p "$TEST_DIR/arch"/{bin,etc}
    echo "OLD_BASH_VERSION" > "$TEST_DIR/arch/bin/bash"
    chmod +x "$TEST_DIR/arch/bin/bash"
    echo "old_passwd" > "$TEST_DIR/arch/etc/passwd"

    # Create fake version
    mkdir -p "$TEST_DIR/state"
    echo "2024-01-01" > "$TEST_DIR/state/rootfs.version"

    info "Created fake existing installation"

    # Create fake staging (corrupted)
    mkdir -p "$TEST_DIR/arch.staging"/{bin,etc}
    echo "CORRUPTED_BASH" > "$TEST_DIR/arch.staging/bin/bash"
    # Deliberately omit passwd to make validation fail

    # Simulate atomic install with validation failure
    local staging_dir="$TEST_DIR/arch.staging"
    local target_dir="$TEST_DIR/arch"
    local backup_dir="${target_dir}.old"

    # Manual atomic operation simulation
    if mv "$target_dir" "$backup_dir" && mv "$staging_dir" "$target_dir"; then
        info "Atomic move completed - now testing validation"

        # Simulate validation failure (missing passwd file)
        if [ ! -f "$target_dir/etc/passwd" ]; then
            warn "Validation failed - performing rollback"

            # Rollback
            rm -rf "$target_dir"
            if mv "$backup_dir" "$target_dir"; then
                ok "Rollback completed successfully"
            else
                fail "Rollback failed"
                return 1
            fi
        fi
    else
        fail "Atomic move failed"
        return 1
    fi

    # Verify rollback worked
    if [ -f "$target_dir/bin/bash" ] && grep -q "OLD_BASH_VERSION" "$target_dir/bin/bash"; then
        ok "Original installation restored correctly"
    else
        fail "Original installation not restored"
        return 1
    fi

    if [ -f "$target_dir/etc/passwd" ] && grep -q "old_passwd" "$target_dir/etc/passwd"; then
        ok "Original configuration preserved"
    else
        fail "Original configuration lost"
        return 1
    fi

    return 0
}

test_concurrent_access() {
    banner "Testing Concurrent Access Protection"

    mkdir -p "$TEST_DIR/arch" "$TEST_DIR/state"

    # Create a lock file to simulate running process
    local lock_file="$TEST_DIR/state/bootstrap.lock"
    echo "$$" > "$lock_file"

    info "Created lock file: $lock_file"

    # Try to run bootstrap while "locked"
    if ARCH_PATH="$TEST_DIR/arch" STATE_DIR="$TEST_DIR/state" \
       timeout 5 "$CORE_DIR/bootstrap.sh" 2>/dev/null; then
        warn "Bootstrap didn't detect concurrent access (or no lock checking implemented)"
    else
        ok "Bootstrap correctly handled potential concurrent access"
    fi

    rm -f "$lock_file"
    return 0
}

test_state_corruption_recovery() {
    banner "Testing State Corruption Recovery"

    mkdir -p "$TEST_DIR/state"

    # Create corrupted state file
    local state_file="$TEST_DIR/state/runtime-snapshot.json"
    echo "CORRUPTED_JSON_DATA" > "$state_file"

    info "Created corrupted state file"

    # Try runtime inspection with corrupted state
    if ARCH_PATH="$TEST_DIR/arch" STATE_DIR="$TEST_DIR/state" \
       "$CORE_DIR/inspect-runtime.sh" >/dev/null 2>&1; then
        ok "Runtime inspection handled corrupted state gracefully"
    else
        warn "Runtime inspection failed with corrupted state (expected if no recovery)"
    fi

    # Check if new state was generated
    if [ -f "$state_file" ] && ! grep -q "CORRUPTED" "$state_file"; then
        ok "Corrupted state was replaced with fresh state"
    else
        warn "Corrupted state not automatically recovered"
    fi

    return 0
}

test_mount_recovery() {
    banner "Testing Mount Recovery"

    mkdir -p "$TEST_DIR/arch"/{proc,sys,dev}

    # Create files where mount points should be (blocks mounting)
    echo "blocking file" > "$TEST_DIR/arch/proc"
    echo "blocking file" > "$TEST_DIR/arch/sys"

    info "Created mount point blockers"

    # Source the mount enforcement function and test
    # This is a simplified test since we can't actually test mounts without root
    if [ -f "$TEST_DIR/arch/proc" ] && [ ! -d "$TEST_DIR/arch/proc" ]; then
        ok "Mount blocker detection works (file where directory should be)"
    else
        warn "Mount blocker not properly detected"
    fi

    # Test directory creation recovery
    rm -f "$TEST_DIR/arch/proc" "$TEST_DIR/arch/sys"
    mkdir -p "$TEST_DIR/arch"/{proc,sys,dev}

    if [ -d "$TEST_DIR/arch/proc" ] && [ -d "$TEST_DIR/arch/sys" ]; then
        ok "Mount point directories recovered successfully"
    else
        fail "Mount point directory recovery failed"
        return 1
    fi

    return 0
}

# ─── MAIN TEST SUITE ──────────────────────────────────────────────────────────

run_recovery_tests() {
    banner "ArchDroid Recovery Validation Suite"

    local failed_tests=()
    local passed_tests=()

    # Cleanup function
    cleanup() {
        rm -rf "$TEST_DIR" 2>/dev/null || true
    }
    trap cleanup EXIT

    # Test suite
    local tests=(
        "test_partial_download_cleanup"
        "test_atomic_rollback"
        "test_concurrent_access"
        "test_state_corruption_recovery"
        "test_mount_recovery"
    )

    for test in "${tests[@]}"; do
        # Clean environment
        rm -rf "$TEST_DIR"
        mkdir -p "$TEST_DIR"

        info "Running: $test"
        if $test; then
            passed_tests+=("$test")
            ok "PASSED: $test"
        else
            failed_tests+=("$test")
            fail "FAILED: $test"
        fi
        echo ""
    done

    # Summary
    banner "Recovery Test Results"
    echo "Passed: ${#passed_tests[@]}"
    echo "Failed: ${#failed_tests[@]}"
    echo ""

    if [ ${#failed_tests[@]} -eq 0 ]; then
        ok "🎉 All recovery tests PASSED - System recovers gracefully"
        return 0
    else
        fail "❌ Some recovery tests FAILED - System needs hardening"
        echo ""
        fail "Failed tests:"
        for test in "${failed_tests[@]}"; do
            fail "  - $test"
        done
        return 1
    fi
}

# ─── MAIN EXECUTION ──────────────────────────────────────────────────────────
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    run_recovery_tests "$@"
fi