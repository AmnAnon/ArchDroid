#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║  ArchDroid — core/inspect-network.sh                            ║
# ║  Network and DNS configuration validation                       ║
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

# ─── DNS VALIDATION ──────────────────────────────────────────────────────────
validate_dns() {
    local status=0
    local resolv_conf="$ARCH_PATH/etc/resolv.conf"

    echo "=== DNS Configuration Validation ==="

    if [ ! -f "$resolv_conf" ]; then
        fail "No resolv.conf found in rootfs"
        return 2
    fi

    if [ ! -s "$resolv_conf" ]; then
        fail "Empty resolv.conf in rootfs"
        return 2
    fi

    local nameserver_count
    nameserver_count=$(grep -c "^nameserver" "$resolv_conf")

    if [ "$nameserver_count" -eq 0 ]; then
        fail "No nameserver entries in resolv.conf"
        return 2
    elif [ "$nameserver_count" -gt 3 ]; then
        warn "Too many nameservers ($nameserver_count) - may cause delays"
        status=1
    else
        ok "Nameserver count: $nameserver_count"
    fi

    # Validate nameserver entries
    while IFS= read -r line; do
        if [[ "$line" =~ ^nameserver[[:space:]]+([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            local ip
            ip=$(echo "$line" | awk '{print $2}')
            ok "DNS server: $ip"
        elif [[ "$line" =~ ^nameserver[[:space:]] ]]; then
            local server
            server=$(echo "$line" | awk '{print $2}')
            warn "Non-IP DNS server: $server (may not work in chroot)"
            status=1
        fi
    done < <(grep "^nameserver" "$resolv_conf")

    return $status
}

validate_network_accessibility() {
    local status=0

    echo "=== Network Accessibility Test ==="

    # Test basic connectivity from host (not chroot)
    if timeout 3 ping -c 1 8.8.8.8 &>/dev/null; then
        ok "Host network connectivity"
    else
        warn "Host network connectivity issues"
        status=1
    fi

    # Test DNS resolution from host
    if timeout 3 nslookup google.com &>/dev/null; then
        ok "Host DNS resolution"
    else
        warn "Host DNS resolution issues"
        status=1
    fi

    return $status
}

extract_dns_info() {
    local resolv_conf="$ARCH_PATH/etc/resolv.conf"

    echo "=== DNS Information Extraction ==="

    [ ! -f "$resolv_conf" ] && { echo "No DNS info available"; return; }

    echo "DNS Servers:"
    grep "^nameserver" "$resolv_conf" | while read -r line; do
        local server
        server=$(echo "$line" | awk '{print $2}')
        echo "  - $server"
    done

    if grep -q "^search\|^domain" "$resolv_conf"; then
        echo "Search domains:"
        grep "^search\|^domain" "$resolv_conf" | while read -r line; do
            echo "  $line"
        done
    fi
}

# ─── MAIN EXECUTION ──────────────────────────────────────────────────────────
main() {
    [ ! -d "$ARCH_PATH" ] && { fail "Arch path not found: $ARCH_PATH"; exit 2; }

    local overall_status=0

    validate_dns || [ $? -gt $overall_status ] && overall_status=$?
    validate_network_accessibility || [ $? -gt $overall_status ] && overall_status=$?
    extract_dns_info

    echo "=== Network Validation Summary ==="
    case $overall_status in
        0) ok "All network checks passed" ;;
        1) warn "Network has warnings" ;;
        *) fail "Network has critical issues" ;;
    esac

    exit $overall_status
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "${0}" ] && main "$@"