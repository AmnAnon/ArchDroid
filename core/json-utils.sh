#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║  ArchDroid — core/json-utils.sh                                 ║
# ║  Safe JSON parsing utilities for automation                     ║
# ╚══════════════════════════════════════════════════════════════════╝

# ─── STRICT MODE ─────────────────────────────────────────────────────────────
set -euo pipefail

# ─── DEPENDENCY CHECK ────────────────────────────────────────────────────────
# Note: We allow graceful degradation when jq is not available
# but functions should handle this explicitly
check_jq_available() {
    command -v jq >/dev/null 2>&1
}

# ─── COLORS ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; RESET='\033[0m'
fail() { echo -e "${RED}  ✘  $*${RESET}"; }
warn() { echo -e "${YELLOW}  ⚠  $*${RESET}"; }

# ─── JSON SAFETY FUNCTIONS ───────────────────────────────────────────────────

# Validate JSON file
validate_json() {
    local json_file="$1"

    if [ ! -f "$json_file" ]; then
        fail "JSON file not found: $json_file"
        return 1
    fi

    if ! check_jq_available; then
        warn "jq not available - cannot validate JSON structure"
        return 0  # Graceful degradation
    fi

    if ! jq empty "$json_file" 2>/dev/null; then
        fail "Invalid JSON in: $json_file"
        return 1
    fi

    return 0
}

# Safely get value from JSON with default
safe_json_get() {
    local json_file="$1"
    local path="$2"
    local default="${3:-null}"

    if ! validate_json "$json_file"; then
        echo "$default"
        return 1
    fi

    if ! check_jq_available; then
        warn "jq not available - returning default value"
        echo "$default"
        return 1
    fi

    jq -r "$path // \"$default\"" "$json_file" 2>/dev/null || echo "$default"
}

# Get boolean value safely (returns true/false strings)
safe_json_bool() {
    local json_file="$1"
    local path="$2"
    local default="${3:-false}"

    local result
    result=$(safe_json_get "$json_file" "$path" "$default")

    case "$result" in
        true|false) echo "$result" ;;
        *) echo "$default" ;;
    esac
}

# Get integer value safely
safe_json_int() {
    local json_file="$1"
    local path="$2"
    local default="${3:-0}"

    local result
    result=$(safe_json_get "$json_file" "$path" "$default")

    # Validate it's an integer
    if [[ "$result" =~ ^[0-9]+$ ]]; then
        echo "$result"
    else
        echo "$default"
    fi
}

# Check if system is ready based on JSON
is_system_ready() {
    local json_file="$1"
    local status

    status=$(safe_json_int "$json_file" ".overall_status" 2)

    case "$status" in
        0) return 0 ;;  # OK
        1) return 1 ;;  # WARN - may work
        *) return 2 ;;  # FAIL - not ready
    esac
}

# Get component status
get_component_status() {
    local json_file="$1"
    local component="$2"

    safe_json_int "$json_file" ".components.${component}" 2
}

# Validate that all required components are OK
validate_components() {
    local json_file="$1"
    local required_components=("filesystem" "network" "environment" "security")
    local failed_components=()

    for component in "${required_components[@]}"; do
        local status
        status=$(get_component_status "$json_file" "$component")
        if [ "$status" -gt 1 ]; then
            failed_components+=("$component")
        fi
    done

    if [ ${#failed_components[@]} -gt 0 ]; then
        fail "Failed components: ${failed_components[*]}"
        return 1
    fi

    return 0
}

# Example usage function
show_usage() {
    cat << 'EOF'
JSON Utils Usage Examples:

# Validate JSON
validate_json "/data/local/archdroid-state/runtime-snapshot.json"

# Get values safely
arch_path=$(safe_json_get "$json_file" ".arch_path" "/data/local/arch")
rootfs_valid=$(safe_json_bool "$json_file" ".rootfs.valid" "false")
overall_status=$(safe_json_int "$json_file" ".overall_status" 2)

# Check system readiness
if is_system_ready "$json_file"; then
    echo "System ready"
else
    echo "System not ready: $?"
fi

# Validate components
if validate_components "$json_file"; then
    echo "All components OK"
else
    echo "Component failures detected"
fi

# Get component status
fs_status=$(get_component_status "$json_file" "filesystem")
echo "Filesystem status: $fs_status"
EOF
}

# ─── MAIN EXECUTION ──────────────────────────────────────────────────────────
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    # Called directly - show usage
    show_usage
fi