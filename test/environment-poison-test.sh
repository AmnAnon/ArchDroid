#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║  ArchDroid — test/environment-poison-test.sh                    ║
# ║  Environment Cleaning Verification Test                         ║
# ╚══════════════════════════════════════════════════════════════════╝

# ─── STRICT MODE ─────────────────────────────────────────────────────────────
set -euo pipefail

# ─── CONFIGURATION ───────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(dirname "$SCRIPT_DIR")/core"

# ─── COLORS ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; RESET='\033[0m'

ok()   { echo -e "${GREEN}  ✔  $*${RESET}"; }
fail() { echo -e "${RED}  ✘  $*${RESET}"; }
info() { echo -e "${CYAN}  ▶  $*${RESET}"; }

test_environment_cleaning() {
    info "Testing environment variable cleaning..."

    # Create a test script that sources runtime and checks environment
    local test_script="/tmp/env-test-$$.sh"

    cat > "$test_script" << 'EOF'
#!/bin/bash
set -euo pipefail

# Poison the environment
export PATH="/evil/path:/more/evil:$PATH"
export HOME="/tmp/fake-home"
export USER="hacker"
export ANDROID_DATA="/system/corrupted"
export TERMUX="/data/data/evil"
export BOOTCLASSPATH="/evil/classpath"
export PREFIX="/fake/prefix"

# Source only the enforcement function from runtime
source_runtime_functions() {
    # Extract just the enforce_environment function
    sed -n '/^enforce_environment() {/,/^}/p' "$1"
}

# Load the function
eval "$(source_runtime_functions "/arch-android/core/runtime.sh")"

# Record original poisoned state
echo "BEFORE_PATH=$PATH"
echo "BEFORE_HOME=$HOME"
echo "BEFORE_USER=$USER"

# Call the cleaning function
enforce_environment 2>/dev/null

# Record cleaned state
echo "AFTER_PATH=$PATH"
echo "AFTER_HOME=$HOME"
echo "AFTER_USER=$USER"
echo "ANDROID_DATA_SET=${ANDROID_DATA:-UNSET}"
echo "TERMUX_SET=${TERMUX:-UNSET}"
EOF

    chmod +x "$test_script"

    # Run the test and capture output
    local output
    if output=$("$test_script" 2>&1); then
        # Parse the results
        local before_path before_home before_user
        local after_path after_home after_user
        local android_data_set termux_set

        before_path=$(echo "$output" | grep "BEFORE_PATH=" | cut -d= -f2-)
        before_home=$(echo "$output" | grep "BEFORE_HOME=" | cut -d= -f2-)
        before_user=$(echo "$output" | grep "BEFORE_USER=" | cut -d= -f2-)
        after_path=$(echo "$output" | grep "AFTER_PATH=" | cut -d= -f2-)
        after_home=$(echo "$output" | grep "AFTER_HOME=" | cut -d= -f2-)
        after_user=$(echo "$output" | grep "AFTER_USER=" | cut -d= -f2-)
        android_data_set=$(echo "$output" | grep "ANDROID_DATA_SET=" | cut -d= -f2-)
        termux_set=$(echo "$output" | grep "TERMUX_SET=" | cut -d= -f2-)

        # Verify cleaning worked
        local failures=0

        # Check PATH was cleaned
        if [[ "$after_path" == *"/evil/"* ]]; then
            fail "PATH still contains evil paths: $after_path"
            ((failures++))
        else
            ok "PATH cleaned successfully"
        fi

        # Check HOME was set correctly
        if [ "$after_home" != "/root" ]; then
            fail "HOME not set to /root: $after_home"
            ((failures++))
        else
            ok "HOME set correctly: $after_home"
        fi

        # Check USER was set correctly
        if [ "$after_user" != "root" ]; then
            fail "USER not set to root: $after_user"
            ((failures++))
        else
            ok "USER set correctly: $after_user"
        fi

        # Check Android variables were cleared
        if [ "$android_data_set" != "UNSET" ]; then
            fail "ANDROID_DATA not cleared: $android_data_set"
            ((failures++))
        else
            ok "ANDROID_DATA cleared successfully"
        fi

        if [ "$termux_set" != "UNSET" ]; then
            fail "TERMUX not cleared: $termux_set"
            ((failures++))
        else
            ok "TERMUX cleared successfully"
        fi

        # Cleanup
        rm -f "$test_script"

        if [ $failures -eq 0 ]; then
            ok "Environment cleaning test PASSED"
            return 0
        else
            fail "Environment cleaning test FAILED ($failures failures)"
            return 1
        fi
    else
        fail "Environment test script failed to run"
        rm -f "$test_script"
        return 1
    fi
}

# Run the test
if test_environment_cleaning; then
    exit 0
else
    exit 1
fi