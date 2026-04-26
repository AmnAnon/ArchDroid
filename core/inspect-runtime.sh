#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║  ArchDroid — core/inspect-runtime.sh                            ║
# ║  Runtime Environment Verification and Extraction                ║
# ║  Collects actual configuration from existing Arch environment   ║
# ╚══════════════════════════════════════════════════════════════════╝

# ─── CONFIGURATION ───────────────────────────────────────────────────────────
ARCH_PATH="${ARCH_PATH:-/data/local/arch}"
STATE_DIR="${STATE_DIR:-/data/local/archdroid-state}"
SNAPSHOT_FILE="${STATE_DIR}/runtime-snapshot.log"
RUNTIME_JSON="${STATE_DIR}/runtime-snapshot.json"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# Load arch path override if config exists
CONF_FILE="/data/local/archdroid.conf"
[ -f "$CONF_FILE" ] && source "$CONF_FILE"

# ─── VALIDATION STATUS ───────────────────────────────────────────────────────
STATUS_OK=0
STATUS_WARN=1
STATUS_FAIL=2
OVERALL_STATUS=$STATUS_OK

# Component-level status tracking
COMPONENT_STATUS=()
COMPONENT_STATUS[filesystem]=$STATUS_OK
COMPONENT_STATUS[network]=$STATUS_OK
COMPONENT_STATUS[environment]=$STATUS_OK
COMPONENT_STATUS[security]=$STATUS_OK

# ─── COLORS ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

ok()   { echo -e "${GREEN}  ✔  $*${RESET}"; }
warn() { echo -e "${YELLOW}  ⚠  $*${RESET}"; }
# ─── VALIDATION HELPERS ──────────────────────────────────────────────────────
update_status() {
    local new_status=$1
    [ $new_status -gt $OVERALL_STATUS ] && OVERALL_STATUS=$new_status
}

update_component_status() {
    local component="$1"
    local status="$2"
    [ $status -gt ${COMPONENT_STATUS[$component]} ] && COMPONENT_STATUS[$component]=$status
    update_status $status
}

# JSON Safety Functions
validate_json() {
    local json_file="$1"
    if ! jq empty "$json_file" 2>/dev/null; then
        fail "Invalid JSON in $json_file"
        return 1
    fi
    return 0
}

safe_json_get() {
    local json_file="$1"
    local path="$2"
    local default="$3"

    if [ ! -f "$json_file" ]; then
        echo "$default"
        return 1
    fi

    if ! validate_json "$json_file"; then
        echo "$default"
        return 1
    fi

    jq -r "$path // \"$default\"" "$json_file" 2>/dev/null || echo "$default"
}

check_file() {
    local file="$1"
    local description="${2:-$file}"
    if [ -f "$ARCH_PATH/$file" ]; then
        # Check if it's actually executable for critical executables
        case "$file" in
            bin/*|usr/bin/*)
                if [ -x "$ARCH_PATH/$file" ]; then
                    ok "Found (executable): $description"
                else
                    warn "Found but not executable: $description"
                    update_component_status "filesystem" $STATUS_WARN
                    return 1
                fi
                ;;
            *)
                ok "Found: $description"
                ;;
        esac
        return 0
    else
        fail "Missing: $description"
        update_component_status "filesystem" $STATUS_FAIL
        return 1
    fi
}

check_mount_type() {
    local mount_point="$1"
    local expected_type="$2"

    if ! mountpoint -q "$ARCH_PATH/$mount_point" 2>/dev/null; then
        warn "NOT mounted: $mount_point"
        update_component_status "filesystem" $STATUS_WARN
        return 1
    fi

    # Check mount type if specified
    if [ -n "$expected_type" ]; then
        if mount | grep -q "$ARCH_PATH/$mount_point.*$expected_type"; then
            ok "Mounted ($expected_type): $mount_point"
        else
            local actual_type
            actual_type=$(mount | grep "$ARCH_PATH/$mount_point" | awk '{print $5}' | head -1)
            warn "Mount type mismatch: $mount_point (expected: $expected_type, got: $actual_type)"
            update_component_status "filesystem" $STATUS_WARN
            return 1
        fi
    else
        ok "Mounted: $mount_point"
    fi
    return 0
}

# ─── JSON OUTPUT BUILDER ─────────────────────────────────────────────────────
declare -A JSON_DATA
json_set() {
    local key="$1"
    local value="$2"
    JSON_DATA["$key"]="$value"
}

json_export() {
    local output_file="$1"
    local temp_file="${output_file}.tmp"

    # Write to temporary file first for atomic operation
    {
        echo "{"
        echo "  \"timestamp\": \"$TIMESTAMP\","
        echo "  \"arch_path\": \"$ARCH_PATH\","
        echo "  \"overall_status\": $OVERALL_STATUS,"

        # Component-level status
        echo "  \"components\": {"
        echo "    \"filesystem\": ${COMPONENT_STATUS[filesystem]},"
        echo "    \"network\": ${COMPONENT_STATUS[network]},"
        echo "    \"environment\": ${COMPONENT_STATUS[environment]},"
        echo "    \"security\": ${COMPONENT_STATUS[security]}"
        echo "  },"

        # Environment
        local safe_path="${JSON_DATA[path]//\"/\\\"}"  # Escape quotes in PATH
        echo "  \"environment\": {"
        echo "    \"type\": \"${JSON_DATA[env_type]}\","
        echo "    \"path\": \"${safe_path}\","
        echo "    \"home\": \"${JSON_DATA[home]}\""
        echo "  },"

        # Rootfs validation
        echo "  \"rootfs\": {"
        echo "    \"valid\": ${JSON_DATA[rootfs_valid]},"
        echo "    \"chroot_test\": ${JSON_DATA[chroot_test]},"
        echo "    \"files\": {"
        echo "      \"bash\": ${JSON_DATA[file_bash]},"
        echo "      \"env\": ${JSON_DATA[file_env]},"
        echo "      \"passwd\": ${JSON_DATA[file_passwd]},"
        echo "      \"pacman\": ${JSON_DATA[file_pacman]}"
        echo "    },"
        echo "    \"directories\": {"
        echo "      \"usr\": ${JSON_DATA[dir_usr]},"
        echo "      \"etc\": ${JSON_DATA[dir_etc]},"
        echo "      \"bin\": ${JSON_DATA[dir_bin]}"
        echo "    }"
        echo "  },"

        # Mounts with types
        echo "  \"mounts\": {"
        echo "    \"proc\": {"
        echo "      \"mounted\": ${JSON_DATA[mount_proc]},"
        echo "      \"type_valid\": ${JSON_DATA[mount_proc_type]}"
        echo "    },"
        echo "    \"sys\": {"
        echo "      \"mounted\": ${JSON_DATA[mount_sys]},"
        echo "      \"type_valid\": ${JSON_DATA[mount_sys_type]}"
        echo "    },"
        echo "    \"dev\": {"
        echo "      \"mounted\": ${JSON_DATA[mount_dev]},"
        echo "      \"type_valid\": ${JSON_DATA[mount_dev_type]}"
        echo "    },"
        echo "    \"dev_pts\": {"
        echo "      \"mounted\": ${JSON_DATA[mount_dev_pts]},"
        echo "      \"type_valid\": ${JSON_DATA[mount_dev_pts_type]}"
        echo "    },"
        echo "    \"tmp\": {"
        echo "      \"mounted\": ${JSON_DATA[mount_tmp]},"
        echo "      \"type_valid\": ${JSON_DATA[mount_tmp_type]}"
        echo "    }"
        echo "  },"

        # DNS with functionality
        echo "  \"network\": {"
        echo "    \"dns_config\": ["
        [ -n "${JSON_DATA[dns_servers]}" ] && echo "      ${JSON_DATA[dns_servers]}"
        echo "    ],"
        echo "    \"connectivity\": ${JSON_DATA[network_connectivity]},"
        echo "    \"dns_resolution\": ${JSON_DATA[dns_resolution]}"
        echo "  },"

        # Security
        echo "  \"security\": {"
        echo "    \"rootfs_permissions\": \"${JSON_DATA[rootfs_perms]}\","
        echo "    \"config_safe\": ${JSON_DATA[config_safe]},"
        echo "    \"selinux_mode\": \"${JSON_DATA[selinux_mode]}\","
        echo "    \"root_access\": ${JSON_DATA[root_access]}"
        echo "  }"

        echo "}"
    } > "$temp_file" || {
        fail "Failed to write JSON to temporary file: $temp_file"
        return 1
    }

    # Validate generated JSON if jq is available
    if command -v jq >/dev/null 2>&1; then
        if ! jq empty "$temp_file" 2>/dev/null; then
            fail "Generated invalid JSON - discarding"
            rm -f "$temp_file"
            return 1
        fi
    fi

    # Atomic move to final location
    if mv "$temp_file" "$output_file" 2>/dev/null; then
        ok "JSON state exported: $output_file"
    else
        fail "Failed to atomically write JSON: $output_file"
        rm -f "$temp_file"
        return 1
    fi
}

# ─── LOGGING HELPER ──────────────────────────────────────────────────────────
log_section() {
    local title="$1"
    {
        echo ""
        echo "═══ ${title} ═══ [${TIMESTAMP}]"
        echo ""
    } | tee -a "$SNAPSHOT_FILE"
}

log_command() {
    local description="$1"
    local command="$2"
    {
        echo "--- ${description} ---"
        echo "Command: ${command}"
        echo ""
        eval "$command" 2>&1 || echo "ERROR: Command failed with exit code $?"
        echo ""
    } | tee -a "$SNAPSHOT_FILE"
}

# ─── ENVIRONMENT DETECTION ───────────────────────────────────────────────────
detect_environment() {
    local env_type="unknown"

    # Check if we're in chroot
    if [ "$(stat -c %d:%i /)" != "$(stat -c %d:%i /proc/1/root/.)" ]; then
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

# ─── MAIN INSPECTION ─────────────────────────────────────────────────────────
main() {
    echo -e "${BOLD}${CYAN}"
    echo "  ╔══════════════════════════════════════════════════╗"
    echo "  ║  ArchDroid Runtime Environment Inspector         ║"
    echo "  ║  Validating: ${ARCH_PATH}"
    printf "  ║  %-48s║\n" ""
    echo "  ╚══════════════════════════════════════════════════╝"
    echo -e "${RESET}"

    # Ensure state directory exists
    mkdir -p "$STATE_DIR"

    # Initialize ALL JSON variables with defaults
    json_set "env_type" "unknown"
    json_set "path" ""
    json_set "home" ""
    json_set "rootfs_valid" "false"
    json_set "chroot_test" "false"
    json_set "file_bash" "false"
    json_set "file_env" "false"
    json_set "file_passwd" "false"
    json_set "file_pacman" "false"
    json_set "dir_usr" "false"
    json_set "dir_etc" "false"
    json_set "dir_bin" "false"
    json_set "mount_proc" "false"
    json_set "mount_proc_type" "false"
    json_set "mount_sys" "false"
    json_set "mount_sys_type" "false"
    json_set "mount_dev" "false"
    json_set "mount_dev_type" "false"
    json_set "mount_dev_pts" "false"
    json_set "mount_dev_pts_type" "false"
    json_set "mount_tmp" "false"
    json_set "mount_tmp_type" "false"
    json_set "dns_servers" ""
    json_set "network_connectivity" "false"
    json_set "dns_resolution" "false"
    json_set "rootfs_perms" "unknown"
    json_set "config_safe" "true"
    json_set "selinux_mode" "unknown"
    json_set "root_access" "false"

    # Initialize snapshot file
    {
        echo "ArchDroid Runtime Environment Snapshot"
        echo "Generated: ${TIMESTAMP}"
        echo "Target: ${ARCH_PATH}"
        echo "Host: $(hostname 2>/dev/null || echo 'unknown')"
        echo "User: $(whoami) (UID: $(id -u))"
        echo ""
    } > "$SNAPSHOT_FILE"

    # ─── 1. ENVIRONMENT DETECTION ───────────────────────────────────────────
    log_section "Environment Detection"
    source "$(dirname "$0")/inspect-env.sh"
    ENV_TYPE=$(detect_environment)
    json_set "env_type" "$ENV_TYPE"
    json_set "path" "$PATH"
    json_set "home" "$HOME"
    info "Environment detected: ${ENV_TYPE}"

    # ─── 2. ARCH ROOTFS VALIDATION (CRITICAL) ───────────────────────────────
    log_section "Arch Rootfs Validation"

    if [ ! -d "$ARCH_PATH" ]; then
        fail "Arch path does not exist: $ARCH_PATH"
        update_component_status "filesystem" $STATUS_FAIL
        json_set "rootfs_valid" "false"
        json_set "chroot_test" "false"
        json_set "file_bash" "false"
        json_set "file_env" "false"
        json_set "file_passwd" "false"
        json_set "file_pacman" "false"
        json_set "dir_usr" "false"
        json_set "dir_etc" "false"
        json_set "dir_bin" "false"
    else
        info "Arch path found: $ARCH_PATH"

        # Check critical directories first
        local dirs_valid=true
        if [ -d "$ARCH_PATH/usr" ]; then
            json_set "dir_usr" "true"
            ok "Directory: usr"
        else
            json_set "dir_usr" "false"
            fail "Directory missing: usr"
            dirs_valid=false
            update_component_status "filesystem" $STATUS_FAIL
        fi

        if [ -d "$ARCH_PATH/etc" ]; then
            json_set "dir_etc" "true"
            ok "Directory: etc"
        else
            json_set "dir_etc" "false"
            fail "Directory missing: etc"
            dirs_valid=false
            update_component_status "filesystem" $STATUS_FAIL
        fi

        if [ -d "$ARCH_PATH/bin" ]; then
            json_set "dir_bin" "true"
            ok "Directory: bin"
        else
            json_set "dir_bin" "false"
            fail "Directory missing: bin"
            dirs_valid=false
            update_component_status "filesystem" $STATUS_FAIL
        fi

        # Check critical files with executability
        local files_valid=true
        if check_file "bin/bash" "Bash shell"; then
            json_set "file_bash" "true"
        else
            json_set "file_bash" "false"
            files_valid=false
        fi

        if check_file "usr/bin/env" "Environment binary"; then
            json_set "file_env" "true"
        else
            json_set "file_env" "false"
            files_valid=false
        fi

        if check_file "etc/passwd" "Password database"; then
            json_set "file_passwd" "true"
        else
            json_set "file_passwd" "false"
            files_valid=false
        fi

        if check_file "usr/bin/pacman" "Pacman package manager"; then
            json_set "file_pacman" "true"
        else
            json_set "file_pacman" "false"
            files_valid=false
        fi

        # Real chroot execution test (if directories and bash exist)
        if [ "$dirs_valid" = true ] && [ -x "$ARCH_PATH/bin/bash" ]; then
            info "Testing chroot execution..."
            # Use clean env and proper timeout handling
            timeout 5 chroot "$ARCH_PATH" /usr/bin/env -i /bin/bash -c "echo ok" >/dev/null 2>&1
            local chroot_exit=$?

            case $chroot_exit in
                0)
                    json_set "chroot_test" "true"
                    ok "Chroot execution test: PASSED"
                    ;;
                124)
                    json_set "chroot_test" "false"
                    warn "Chroot execution test: TIMEOUT (possible mount issue)"
                    update_component_status "filesystem" $STATUS_WARN
                    ;;
                *)
                    json_set "chroot_test" "false"
                    fail "Chroot execution test: FAILED (exit code: $chroot_exit)"
                    update_component_status "filesystem" $STATUS_FAIL
                    files_valid=false
                    ;;
            esac
        else
            json_set "chroot_test" "false"
            warn "Chroot execution test: SKIPPED (missing prerequisites)"
        fi

        # Overall rootfs validity
        if [ "$dirs_valid" = true ] && [ "$files_valid" = true ]; then
            json_set "rootfs_valid" "true"
            ok "Rootfs validation: PASSED"
        else
            json_set "rootfs_valid" "false"
            fail "Rootfs validation: FAILED"
            update_component_status "filesystem" $STATUS_FAIL
        fi
    fi

    # ─── 3. MOUNT VALIDATION ─────────────────────────────────────────────────
    log_section "Mount Point Validation"

    # proc filesystem
    if check_mount_type "proc" "proc"; then
        json_set "mount_proc" "true"
        json_set "mount_proc_type" "true"
    else
        if mountpoint -q "$ARCH_PATH/proc" 2>/dev/null; then
            json_set "mount_proc" "true"
            json_set "mount_proc_type" "false"
        else
            json_set "mount_proc" "false"
            json_set "mount_proc_type" "false"
        fi
    fi

    # sysfs filesystem
    if check_mount_type "sys" "sysfs"; then
        json_set "mount_sys" "true"
        json_set "mount_sys_type" "true"
    else
        if mountpoint -q "$ARCH_PATH/sys" 2>/dev/null; then
            json_set "mount_sys" "true"
            json_set "mount_sys_type" "false"
        else
            json_set "mount_sys" "false"
            json_set "mount_sys_type" "false"
        fi
    fi

    # dev filesystem (bind mount)
    if check_mount_type "dev" ""; then  # dev can be various types
        json_set "mount_dev" "true"
        json_set "mount_dev_type" "true"
    else
        json_set "mount_dev" "false"
        json_set "mount_dev_type" "false"
    fi

    # dev/pts filesystem
    if check_mount_type "dev/pts" "devpts"; then
        json_set "mount_dev_pts" "true"
        json_set "mount_dev_pts_type" "true"
    else
        if mountpoint -q "$ARCH_PATH/dev/pts" 2>/dev/null; then
            json_set "mount_dev_pts" "true"
            json_set "mount_dev_pts_type" "false"
        else
            json_set "mount_dev_pts" "false"
            json_set "mount_dev_pts_type" "false"
        fi
    fi

    # tmp filesystem (should be tmpfs)
    if check_mount_type "tmp" "tmpfs"; then
        json_set "mount_tmp" "true"
        json_set "mount_tmp_type" "true"
    else
        if mountpoint -q "$ARCH_PATH/tmp" 2>/dev/null; then
            json_set "mount_tmp" "true"
            json_set "mount_tmp_type" "false"
        else
            json_set "mount_tmp" "false"
            json_set "mount_tmp_type" "false"
        fi
    fi

    # ─── 4. NETWORK & DNS VALIDATION ────────────────────────────────────────
    log_section "Network & DNS Configuration Validation"

    # DNS configuration check
    if [ -f "$ARCH_PATH/etc/resolv.conf" ]; then
        local dns_servers
        dns_servers=$(grep -E '^nameserver' "$ARCH_PATH/etc/resolv.conf" | awk '{print "\"" $2 "\""}' | tr '\n' ',' | sed 's/,$//')
        json_set "dns_servers" "$dns_servers"
        ok "DNS configuration found"
    else
        warn "No DNS configuration in rootfs"
        update_component_status "network" $STATUS_WARN
        json_set "dns_servers" ""
    fi

    # Functional network connectivity test
    info "Testing network connectivity..."
    if timeout 3 ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then
        json_set "network_connectivity" "true"
        ok "Network connectivity: WORKING (ping 1.1.1.1)"
    else
        json_set "network_connectivity" "false"
        warn "Network connectivity: FAILED (ping 1.1.1.1)"
        update_component_status "network" $STATUS_WARN
    fi

    # Functional DNS resolution test
    info "Testing DNS resolution..."
    if timeout 5 getent hosts google.com >/dev/null 2>&1; then
        json_set "dns_resolution" "true"
        ok "DNS resolution: WORKING (getent hosts google.com)"
    else
        # Fallback test with nslookup if getent not available
        if timeout 5 nslookup google.com >/dev/null 2>&1; then
            json_set "dns_resolution" "true"
            ok "DNS resolution: WORKING (nslookup google.com)"
        else
            json_set "dns_resolution" "false"
            warn "DNS resolution: FAILED"
            update_component_status "network" $STATUS_WARN
        fi
    fi

    # ─── 5. SECURITY VALIDATION (TRUST BOUNDARY) ────────────────────────────
    log_section "Security Validation"

    # Root access check
    if [ "$(id -u)" -eq 0 ]; then
        json_set "root_access" "true"
        ok "Root access: AVAILABLE"
    else
        json_set "root_access" "false"
        fail "Root access: DENIED (UID: $(id -u))"
        update_component_status "security" $STATUS_FAIL
    fi

    # Rootfs permissions
    if [ -d "$ARCH_PATH" ]; then
        local rootfs_perms
        rootfs_perms=$(stat -c "%a" "$ARCH_PATH" 2>/dev/null || echo "unknown")
        json_set "rootfs_perms" "$rootfs_perms"

        case "$rootfs_perms" in
            755|750|700)
                ok "Rootfs permissions: $rootfs_perms (secure)"
                ;;
            777)
                warn "Rootfs permissions: $rootfs_perms (world-writable - insecure)"
                update_component_status "security" $STATUS_WARN
                ;;
            *)
                warn "Rootfs permissions: $rootfs_perms (unusual)"
                update_component_status "security" $STATUS_WARN
                ;;
        esac
    else
        json_set "rootfs_perms" "unknown"
    fi

    # Config file safety
    local config_safe="true"
    if [ -f "$CONF_FILE" ]; then
        local conf_owner conf_perms conf_group_perm conf_other_perm
        conf_owner=$(stat -c "%U" "$CONF_FILE" 2>/dev/null || echo "unknown")
        conf_perms=$(stat -c "%a" "$CONF_FILE" 2>/dev/null || echo "unknown")

        if [ "$conf_owner" != "root" ]; then
            fail "Config file not owned by root: $conf_owner"
            config_safe="false"
            update_component_status "security" $STATUS_FAIL
        fi

        # Check for dangerous permissions (group/world writable)
        conf_group_perm=$(echo "$conf_perms" | cut -c2)
        conf_other_perm=$(echo "$conf_perms" | cut -c3)

        if [[ "$conf_group_perm" =~ [2367] ]] || [[ "$conf_other_perm" =~ [2367] ]]; then
            fail "Config file has dangerous permissions: $conf_perms (group/world writable)"
            config_safe="false"
            update_component_status "security" $STATUS_FAIL
        fi

        if [ "$config_safe" = "true" ]; then
            ok "Config file security: SAFE ($conf_owner:$conf_perms)"
        fi
    else
        warn "No config file found: $CONF_FILE"
        # This is not necessarily a security issue, so don't fail
    fi
    json_set "config_safe" "$config_safe"

    # SELinux detection and impact
    local selinux_mode
    selinux_mode=$(getenforce 2>/dev/null || echo "unknown")
    json_set "selinux_mode" "$selinux_mode"

    case "$selinux_mode" in
        "Permissive"|"Disabled")
            ok "SELinux: $selinux_mode (chroot operations allowed)"
            ;;
        "Enforcing")
            warn "SELinux: $selinux_mode (may block chroot operations)"
            update_component_status "security" $STATUS_WARN
            ;;
        *)
            warn "SELinux: $selinux_mode (status unknown)"
            update_component_status "security" $STATUS_WARN
            ;;
    esac

    # ─── 6. EXPORT MACHINE-READABLE STATE ────────────────────────────────────
    json_export "$RUNTIME_JSON"

    # ─── 7. FINAL STATUS ─────────────────────────────────────────────────────
    echo ""

    # Component status summary
    echo -e "${BOLD}Component Status:${RESET}"
    for component in filesystem network environment security; do
        local status=${COMPONENT_STATUS[$component]}
        case $status in
            0) echo -e "  ${GREEN}✔${RESET} ${component}: OK" ;;
            1) echo -e "  ${YELLOW}⚠${RESET} ${component}: WARNINGS" ;;
            *) echo -e "  ${RED}✘${RESET} ${component}: FAILED" ;;
        esac
    done
    echo ""

    case $OVERALL_STATUS in
        $STATUS_OK)
            echo -e "${BOLD}${GREEN}"
            echo "  ╔══════════════════════════════════════════════════╗"
            echo "  ║                  ✔ ALL CHECKS PASSED             ║"
            echo "  ║              System Ready for Operation          ║"
            echo "  ╚══════════════════════════════════════════════════╝"
            echo -e "${RESET}"
            ;;
        $STATUS_WARN)
            echo -e "${BOLD}${YELLOW}"
            echo "  ╔══════════════════════════════════════════════════╗"
            echo "  ║               ⚠ WARNINGS DETECTED                ║"
            echo "  ║        System May Work But Has Issues            ║"
            echo "  ╚══════════════════════════════════════════════════╝"
            echo -e "${RESET}"
            ;;
        $STATUS_FAIL)
            echo -e "${BOLD}${RED}"
            echo "  ╔══════════════════════════════════════════════════╗"
            echo "  ║                ✘ CRITICAL FAILURES               ║"
            echo "  ║              System NOT Ready                    ║"
            echo "  ╚══════════════════════════════════════════════════╝"
            echo -e "${RESET}"
            ;;
    esac

    echo ""
    info "Human log: ${SNAPSHOT_FILE}"
    info "JSON state: ${RUNTIME_JSON}"
    info "Overall status: $OVERALL_STATUS (0=OK, 1=WARN, 2=FAIL)"

    # JSON safety usage example
    echo ""
    info "Safe JSON usage examples:"
    echo "  jq empty '$RUNTIME_JSON' 2>/dev/null || echo 'Invalid JSON'"
    echo "  jq -r '.rootfs.valid // false' '$RUNTIME_JSON'"
    echo "  jq -r '.components.filesystem // 2' '$RUNTIME_JSON'"

    exit $OVERALL_STATUS
}

# ─── ROOT CHECK ─────────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    warn "Running as non-root user - some checks may be limited"
fi

# Execute main function
main "$@"