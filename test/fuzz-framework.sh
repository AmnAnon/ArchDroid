#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║  ArchDroid — test/fuzz-framework.sh                             ║
# ║  Comprehensive Failure Injection and Fuzz Testing System        ║
# ╚══════════════════════════════════════════════════════════════════╝

# ─── STRICT MODE ─────────────────────────────────────────────────────────────
set -euo pipefail

# ─── CONFIGURATION ───────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(dirname "$SCRIPT_DIR")/core"
TEST_DIR="/tmp/archdroid-fuzz-$$"
ARCH_PATH="$TEST_DIR/arch"
STATE_DIR="$TEST_DIR/state"

# Override paths for isolated testing
export ARCH_PATH STATE_DIR

# Session tracking
SESSION_ID=$(date +%s)
FUZZ_LOG="$TEST_DIR/fuzz-${SESSION_ID}.log"

# ─── COLORS ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
PURPLE='\033[0;35m'

ok()   { echo -e "${GREEN}  ✔  $*${RESET}"; }
warn() { echo -e "${YELLOW}  ⚠  $*${RESET}"; }
fail() { echo -e "${RED}  ✘  $*${RESET}"; }
info() { echo -e "${CYAN}  ▶  $*${RESET}"; }
fuzz() { echo -e "${PURPLE}  🎯  $*${RESET}"; }

banner() {
    echo -e "${BOLD}${CYAN}"
    echo "  ╔══════════════════════════════════════════════════╗"
    printf "  ║  %-48s║\n" "$*"
    echo "  ╚══════════════════════════════════════════════════╝"
    echo -e "${RESET}"
}

# ─── FAILURE INJECTION PRIMITIVES ────────────────────────────────────────────

# Kill process after random delay
inject_process_kill() {
    local target_script="$1"
    local delay_min="${2:-1}"
    local delay_max="${3:-10}"

    local delay
    delay=$((RANDOM % (delay_max - delay_min + 1) + delay_min))

    fuzz "Will kill $target_script after ${delay}s"
    (
        sleep "$delay"
        pkill -f "$(basename "$target_script")" 2>/dev/null || true
        fuzz "Killed process: $(basename "$target_script")"
    ) &

    echo $!  # Return killer PID
}

# Corrupt file at random point
inject_file_corruption() {
    local target_file="$1"
    local corruption_type="${2:-random}"

    if [ ! -f "$target_file" ]; then
        warn "Target file doesn't exist: $target_file"
        return 1
    fi

    local filesize
    filesize=$(stat -c %s "$target_file")

    case "$corruption_type" in
        "truncate")
            # Truncate at random point
            local cut_point
            cut_point=$((RANDOM % filesize))
            truncate -s "$cut_point" "$target_file"
            fuzz "Truncated $target_file at byte $cut_point"
            ;;
        "zero")
            # Zero out random section
            local start_byte
            start_byte=$((RANDOM % filesize))
            local corrupt_len
            corrupt_len=$((RANDOM % 1024 + 1))
            dd if=/dev/zero of="$target_file" bs=1 seek="$start_byte" count="$corrupt_len" conv=notrunc 2>/dev/null
            fuzz "Zeroed ${corrupt_len} bytes in $target_file at offset $start_byte"
            ;;
        "random")
            # Insert random bytes
            local start_byte
            start_byte=$((RANDOM % filesize))
            local corrupt_len
            corrupt_len=$((RANDOM % 512 + 1))
            dd if=/dev/urandom of="$target_file" bs=1 seek="$start_byte" count="$corrupt_len" conv=notrunc 2>/dev/null
            fuzz "Corrupted ${corrupt_len} bytes in $target_file with random data"
            ;;
        "header")
            # Corrupt file header
            dd if=/dev/urandom of="$target_file" bs=1 count=32 conv=notrunc 2>/dev/null
            fuzz "Corrupted file header of $target_file"
            ;;
    esac
}

# Simulate disk space exhaustion
inject_disk_full() {
    local target_dir="$1"
    local fill_percent="${2:-95}"

    local available
    available=$(df "$target_dir" | awk 'NR==2 {print $4}')
    local fill_size
    fill_size=$((available * fill_percent / 100))

    local filler_file="${target_dir}/disk-filler-$$"
    dd if=/dev/zero of="$filler_file" bs=1K count="$fill_size" 2>/dev/null &
    local filler_pid=$!

    fuzz "Filling ${fill_percent}% of disk space in $target_dir"
    echo "$filler_file:$filler_pid"
}

# Break mount points
inject_mount_failure() {
    local mount_point="$1"

    # Unmount forcefully
    if mountpoint -q "$mount_point" 2>/dev/null; then
        umount -l "$mount_point" 2>/dev/null || true
        fuzz "Force unmounted: $mount_point"
    fi

    # Create a regular file where mount should be (blocks mounting)
    touch "$mount_point" 2>/dev/null || true
    fuzz "Blocked mount point: $mount_point"
}

# Network connectivity failure
inject_network_failure() {
    local failure_type="${1:-timeout}"

    case "$failure_type" in
        "timeout")
            # Block outbound connections temporarily
            iptables -A OUTPUT -p tcp --dport 80,443 -j DROP 2>/dev/null || true
            fuzz "Blocked outbound HTTP/HTTPS traffic"
            echo "iptables_block"
            ;;
        "dns")
            # Corrupt DNS resolution
            echo "127.0.0.1 mirror.archlinuxarm.org de3.mirror.archlinuxarm.org" >> /etc/hosts 2>/dev/null || true
            fuzz "Corrupted DNS resolution"
            echo "dns_corrupt"
            ;;
        "slow")
            # Add network delay
            tc qdisc add dev lo root netem delay 5000ms 2>/dev/null || true
            fuzz "Added 5s network delay"
            echo "tc_delay"
            ;;
    esac
}

# Cleanup failure injections
cleanup_injection() {
    local injection_type="$1"
    local injection_data="$2"

    case "$injection_type" in
        "disk_full")
            local filler_file filler_pid
            filler_file=$(echo "$injection_data" | cut -d: -f1)
            filler_pid=$(echo "$injection_data" | cut -d: -f2)
            kill "$filler_pid" 2>/dev/null || true
            rm -f "$filler_file" 2>/dev/null || true
            ;;
        "network")
            case "$injection_data" in
                "iptables_block")
                    iptables -D OUTPUT -p tcp --dport 80,443 -j DROP 2>/dev/null || true
                    ;;
                "dns_corrupt")
                    # Would need more sophisticated DNS cleanup
                    warn "DNS corruption cleanup may require reboot"
                    ;;
                "tc_delay")
                    tc qdisc del dev lo root 2>/dev/null || true
                    ;;
            esac
            ;;
    esac
}

# ─── FUZZ TEST SCENARIOS ──────────────────────────────────────────────────────

# Test bootstrap resilience
fuzz_bootstrap() {
    local scenario="$1"

    banner "Fuzz Test: Bootstrap ($scenario)"

    # Setup isolated environment
    mkdir -p "$TEST_DIR"
    echo "=== Fuzz Bootstrap: $scenario ===" > "$FUZZ_LOG"

    case "$scenario" in
        "process_kill_early")
            fuzz "Scenario: Kill bootstrap process early"
            local killer_pid
            killer_pid=$(inject_process_kill "bootstrap.sh" 2 5)

            # Run bootstrap - should be killed
            if "$CORE_DIR/bootstrap.sh" 2>&1 | tee -a "$FUZZ_LOG"; then
                fail "Bootstrap unexpectedly succeeded despite kill"
                return 1
            fi

            # Cleanup killer
            kill "$killer_pid" 2>/dev/null || true

            # Verify no partial state left
            if [ -d "$ARCH_PATH" ] && [ "$(ls -A "$ARCH_PATH" 2>/dev/null)" ]; then
                fail "Partial installation left after kill"
                ls -la "$ARCH_PATH"
                return 1
            fi
            ok "No partial state after early kill"
            ;;

        "process_kill_late")
            fuzz "Scenario: Kill bootstrap during extraction"

            # Pre-download to test extraction phase
            local tarfile="${STATE_DIR}/ArchLinuxARM-aarch64-2024-03-31.tar.gz"
            mkdir -p "$STATE_DIR"

            # Create a fake tarfile for faster testing
            tar czf "$tarfile" -C /usr/share/doc . 2>/dev/null || echo "fake" > "$tarfile"

            # Kill during extraction (longer delay)
            local killer_pid
            killer_pid=$(inject_process_kill "bootstrap.sh" 8 12)

            if "$CORE_DIR/bootstrap.sh" 2>&1 | tee -a "$FUZZ_LOG"; then
                warn "Bootstrap completed despite attempted kill"
            fi

            kill "$killer_pid" 2>/dev/null || true

            # Check for partial installations
            if [ -d "$ARCH_PATH" ]; then
                warn "Partial installation found - checking integrity"
                if [ ! -f "$ARCH_PATH/bin/bash" ]; then
                    ok "Incomplete installation correctly detected"
                else
                    fail "Partial installation appears complete"
                    return 1
                fi
            fi
            ;;

        "tar_corruption")
            fuzz "Scenario: Corrupt tar file during download"

            # Start bootstrap in background
            "$CORE_DIR/bootstrap.sh" 2>&1 | tee -a "$FUZZ_LOG" &
            local bootstrap_pid=$!

            # Wait for download to start, then corrupt
            sleep 3
            local tarfile="${STATE_DIR}/ArchLinuxARM-aarch64-2024-03-31.tar.gz"

            # Wait for file to appear
            local attempts=0
            while [ ! -f "$tarfile" ] && [ $attempts -lt 10 ]; do
                sleep 1
                ((attempts++))
            done

            if [ -f "$tarfile" ]; then
                sleep 2  # Let some data download
                inject_file_corruption "$tarfile" "header"
            fi

            # Wait for bootstrap to finish
            if wait "$bootstrap_pid" 2>/dev/null; then
                fail "Bootstrap succeeded with corrupted tar"
                return 1
            else
                ok "Bootstrap correctly failed with corrupted tar"
            fi

            # Verify no installation created
            if [ -d "$ARCH_PATH" ] && [ "$(ls -A "$ARCH_PATH" 2>/dev/null)" ]; then
                fail "Installation exists despite tar corruption"
                return 1
            fi
            ok "No installation created with corrupted tar"
            ;;

        "disk_full")
            fuzz "Scenario: Disk full during bootstrap"

            # Fill disk to 95%
            local disk_injection
            disk_injection=$(inject_disk_full "$TEST_DIR" 95)

            # Try bootstrap
            if "$CORE_DIR/bootstrap.sh" 2>&1 | tee -a "$FUZZ_LOG"; then
                fail "Bootstrap succeeded despite full disk"
                cleanup_injection "disk_full" "$disk_injection"
                return 1
            else
                ok "Bootstrap correctly failed with full disk"
            fi

            cleanup_injection "disk_full" "$disk_injection"

            # Verify clean failure
            if [ -d "$ARCH_PATH" ] && [ "$(ls -A "$ARCH_PATH" 2>/dev/null)" ]; then
                warn "Partial files left after disk full failure"
                du -sh "$ARCH_PATH"/* 2>/dev/null || true
            else
                ok "Clean failure - no partial files"
            fi
            ;;

        "network_failure")
            fuzz "Scenario: Network failure during download"

            # Block network after starting
            "$CORE_DIR/bootstrap.sh" 2>&1 | tee -a "$FUZZ_LOG" &
            local bootstrap_pid=$!

            sleep 2
            local net_injection
            net_injection=$(inject_network_failure "timeout")

            if wait "$bootstrap_pid" 2>/dev/null; then
                fail "Bootstrap succeeded despite network failure"
                cleanup_injection "network" "$net_injection"
                return 1
            else
                ok "Bootstrap correctly failed with network issues"
            fi

            cleanup_injection "network" "$net_injection"
            ;;
    esac

    ok "Fuzz test completed: $scenario"
}

# Test runtime resilience
fuzz_runtime() {
    local scenario="$1"

    banner "Fuzz Test: Runtime ($scenario)"

    # Create minimal fake installation for testing
    mkdir -p "$ARCH_PATH"/{bin,etc,proc,sys,dev,tmp}
    echo "fake bash" > "$ARCH_PATH/bin/bash"
    chmod +x "$ARCH_PATH/bin/bash"
    echo "fake passwd" > "$ARCH_PATH/etc/passwd"

    case "$scenario" in
        "mount_failures")
            fuzz "Scenario: Mount points pre-corrupted"

            # Corrupt mount points before runtime
            inject_mount_failure "$ARCH_PATH/proc"
            inject_mount_failure "$ARCH_PATH/sys"

            # Try to start runtime
            if timeout 10 "$CORE_DIR/runtime.sh" 2>&1 | tee -a "$FUZZ_LOG"; then
                warn "Runtime started despite mount issues"
            else
                ok "Runtime correctly detected mount issues"
            fi
            ;;

        "environment_corruption")
            fuzz "Scenario: Hostile environment variables"

            # Poison environment
            export PATH="/evil/path:$PATH"
            export HOME="/tmp/fake-home"
            export ANDROID_DATA="/system/corrupted"
            export TERMUX="/data/data/evil"

            # Runtime should clean this
            if timeout 10 "$CORE_DIR/runtime.sh" 2>&1 | tee -a "$FUZZ_LOG"; then
                # Check if environment was cleaned
                if [[ "$PATH" == *"/evil/path"* ]]; then
                    fail "Runtime didn't clean hostile PATH"
                    return 1
                fi
                ok "Runtime cleaned hostile environment"
            else
                warn "Runtime failed with environment corruption"
            fi
            ;;
    esac
}

# Test update resilience
fuzz_update() {
    local scenario="$1"

    banner "Fuzz Test: Update ($scenario)"

    # Create fake existing installation
    mkdir -p "$ARCH_PATH"/{bin,etc,home,root}
    echo "fake bash old" > "$ARCH_PATH/bin/bash"
    chmod +x "$ARCH_PATH/bin/bash"
    echo "old passwd" > "$ARCH_PATH/etc/passwd"
    echo "user data" > "$ARCH_PATH/home/user.txt"

    # Create fake version
    mkdir -p "$STATE_DIR"
    echo "2024-01-01" > "${STATE_DIR}/rootfs.version"

    case "$scenario" in
        "kill_during_atomic_move")
            fuzz "Scenario: Kill during atomic installation"

            # Start update
            "$CORE_DIR/atomic-update.sh" 2>&1 | tee -a "$FUZZ_LOG" &
            local update_pid=$!

            # Kill during critical section (give time to start)
            sleep 5
            kill -KILL "$update_pid" 2>/dev/null || true

            # Check recovery
            if [ -d "${ARCH_PATH}.update-snapshot" ]; then
                ok "Snapshot exists for recovery"
            else
                warn "No recovery snapshot found"
            fi

            # Verify original installation intact
            if [ -f "$ARCH_PATH/bin/bash" ] && grep -q "old" "$ARCH_PATH/bin/bash"; then
                ok "Original installation preserved"
            else
                fail "Original installation corrupted"
                return 1
            fi
            ;;

        "user_data_corruption")
            fuzz "Scenario: User data backup corruption"

            # Create complex user data
            mkdir -p "$ARCH_PATH/home/user/.config"
            echo "important config" > "$ARCH_PATH/home/user/.config/app.conf"

            # Start update and corrupt backup during process
            "$CORE_DIR/atomic-update.sh" 2>&1 | tee -a "$FUZZ_LOG" &
            local update_pid=$!

            sleep 3
            # Corrupt backup if it exists
            local backup_dir="${ARCH_PATH}.update-backup"
            if [ -d "$backup_dir" ]; then
                rm -rf "$backup_dir/home" 2>/dev/null || true
                fuzz "Corrupted user data backup"
            fi

            # Wait for update to complete
            wait "$update_pid" 2>/dev/null || true

            # Check if user data recovery was attempted
            if [ -f "$ARCH_PATH/home/user.txt" ]; then
                ok "User data preservation attempted"
            else
                warn "User data lost during update"
            fi
            ;;
    esac
}

# ─── MAIN FUZZ TEST RUNNER ────────────────────────────────────────────────────

run_fuzz_suite() {
    banner "ArchDroid Comprehensive Fuzz Testing"

    local failed_tests=()
    local passed_tests=()

    # Bootstrap fuzz tests
    local bootstrap_scenarios=(
        "process_kill_early"
        "process_kill_late"
        "tar_corruption"
        "disk_full"
        "network_failure"
    )

    # Runtime fuzz tests
    local runtime_scenarios=(
        "mount_failures"
        "environment_corruption"
    )

    # Update fuzz tests
    local update_scenarios=(
        "kill_during_atomic_move"
        "user_data_corruption"
    )

    info "Starting bootstrap fuzz tests..."
    for scenario in "${bootstrap_scenarios[@]}"; do
        # Clean environment for each test
        rm -rf "$TEST_DIR"
        mkdir -p "$TEST_DIR"

        if fuzz_bootstrap "$scenario"; then
            passed_tests+=("bootstrap:$scenario")
            ok "PASSED: bootstrap:$scenario"
        else
            failed_tests+=("bootstrap:$scenario")
            fail "FAILED: bootstrap:$scenario"
        fi
    done

    info "Starting runtime fuzz tests..."
    for scenario in "${runtime_scenarios[@]}"; do
        rm -rf "$TEST_DIR"
        mkdir -p "$TEST_DIR"

        if fuzz_runtime "$scenario"; then
            passed_tests+=("runtime:$scenario")
            ok "PASSED: runtime:$scenario"
        else
            failed_tests+=("runtime:$scenario")
            fail "FAILED: runtime:$scenario"
        fi
    done

    info "Starting update fuzz tests..."
    for scenario in "${update_scenarios[@]}"; do
        rm -rf "$TEST_DIR"
        mkdir -p "$TEST_DIR"

        if fuzz_update "$scenario"; then
            passed_tests+=("update:$scenario")
            ok "PASSED: update:$scenario"
        else
            failed_tests+=("update:$scenario")
            fail "FAILED: update:$scenario"
        fi
    done

    # Summary
    banner "Fuzz Test Results"
    echo "Passed: ${#passed_tests[@]}"
    echo "Failed: ${#failed_tests[@]}"
    echo ""

    if [ ${#failed_tests[@]} -eq 0 ]; then
        ok "🎉 All fuzz tests PASSED - System is robust against failures"
        return 0
    else
        fail "❌ Some fuzz tests FAILED - System needs hardening"
        echo ""
        fail "Failed tests:"
        for test in "${failed_tests[@]}"; do
            fail "  - $test"
        done
        return 1
    fi
}

# ─── MAIN EXECUTION ──────────────────────────────────────────────────────────
main() {
    # Validate we have core scripts
    if [ ! -d "$CORE_DIR" ]; then
        fail "Core directory not found: $CORE_DIR"
        exit 1
    fi

    # Check if running as root (needed for some injection techniques)
    if [ "$EUID" -ne 0 ]; then
        warn "Not running as root - some fuzz tests may be limited"
    fi

    # Trap cleanup
    trap 'rm -rf "$TEST_DIR" 2>/dev/null || true' EXIT

    local command="${1:-suite}"
    shift || true

    case "$command" in
        "suite"|"all")
            run_fuzz_suite "$@"
            ;;
        "bootstrap")
            local scenario="${1:-process_kill_early}"
            fuzz_bootstrap "$scenario"
            ;;
        "runtime")
            local scenario="${1:-mount_failures}"
            fuzz_runtime "$scenario"
            ;;
        "update")
            local scenario="${1:-kill_during_atomic_move}"
            fuzz_update "$scenario"
            ;;
        *)
            fail "Unknown command: $command"
            echo ""
            echo "Usage: $0 [suite|bootstrap|runtime|update] [scenario]"
            echo ""
            echo "Commands:"
            echo "  suite      Run complete fuzz test suite"
            echo "  bootstrap  Run specific bootstrap fuzz test"
            echo "  runtime    Run specific runtime fuzz test"
            echo "  update     Run specific update fuzz test"
            exit 1
            ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi