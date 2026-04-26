#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║  ArchDroid — core/versions.sh                                   ║
# ║  Version Control and Checksums - Single Source of Truth         ║
# ╚══════════════════════════════════════════════════════════════════╝

# ─── STRICT MODE ─────────────────────────────────────────────────────────────
set -euo pipefail

# ─── VERSION CONTROL ─────────────────────────────────────────────────────────
# NO MORE "latest" - everything is version-locked

# Current Arch Linux ARM release
ARCH_VERSION="2024-03-31"

# Trust anchor is now in separate checksums file
CHECKSUM_FILE="${SCRIPT_DIR:-$(dirname "${BASH_SOURCE[0]}")}/checksums.txt"

# Checksums file integrity protection - prevents repo compromise attacks
#
# TRUST BOUNDARY NOTICE:
# This hash verifies the checksums file itself hasn't been tampered with.
# However, this hash is embedded in code and can be modified by attackers
# who compromise the repository.
#
# FOR PRODUCTION USE:
# 1. Verify this hash against external sources:
#    - GitHub release description
#    - Pinned commit in README
#    - Signed git tags (recommended)
# 2. Example verification:
#    git tag -s v1.0
#    git verify-tag v1.0
# 3. Hash should match external publication
#
# Current hash for checksums.txt:
CHECKSUMS_FILE_HASH="d334b9b321fc8b30f1db8b162610f5dfed7527e2531345189559480954cb2427"

# External verification reminder
CHECKSUMS_HASH_SOURCE="VERIFY_MANUALLY_AGAINST_EXTERNAL_SOURCES"

# Mirror configuration (HTTPS only)
ARCH_MIRROR_PRIMARY="https://de3.mirror.archlinuxarm.org/os"
ARCH_MIRROR_FALLBACK="https://mirror.archlinuxarm.org/os"

# Derived values (do not modify)
ARCH_TARBALL="ArchLinuxARM-aarch64-${ARCH_VERSION}.tar.gz"
ARCH_URL_PRIMARY="${ARCH_MIRROR_PRIMARY}/${ARCH_TARBALL}"
ARCH_URL_FALLBACK="${ARCH_MIRROR_FALLBACK}/${ARCH_TARBALL}"

# ─── CHECKSUM MANAGEMENT ─────────────────────────────────────────────────────

# ─── CHECKSUM MANAGEMENT ─────────────────────────────────────────────────────

verify_checksums_file_integrity() {
    local checksum_file="${1:-$CHECKSUM_FILE}"

    if [ ! -f "$checksum_file" ]; then
        echo "ERROR: Checksum file not found: $checksum_file" >&2
        return 1
    fi

    # Verify the checksums file itself hasn't been tampered with
    local computed_hash
    computed_hash=$(sha256sum "$checksum_file" | cut -d' ' -f1)

    if [ "$computed_hash" != "$CHECKSUMS_FILE_HASH" ]; then
        echo "ERROR: Checksums file integrity compromised" >&2
        echo "  Expected: $CHECKSUMS_FILE_HASH" >&2
        echo "  Computed: $computed_hash" >&2
        echo "  File: $checksum_file" >&2
        echo "" >&2
        echo "TRUST BOUNDARY WARNING:" >&2
        echo "  This could indicate repository compromise or local tampering." >&2
        echo "  Verify checksum hash against external sources:" >&2
        echo "    - GitHub release description" >&2
        echo "    - Signed git tags" >&2
        echo "    - Pinned commit in README" >&2
        echo "  Source requirement: $CHECKSUMS_HASH_SOURCE" >&2
        return 1
    fi

    return 0
}

get_expected_checksum() {
    local tarball="$1"
    local checksum_file="${2:-$CHECKSUM_FILE}"

    # First verify the checksums file integrity
    if ! verify_checksums_file_integrity "$checksum_file"; then
        return 1
    fi

    local checksum
    checksum=$(grep "^$tarball " "$checksum_file" | awk '{print $2}')

    if [ -z "$checksum" ]; then
        echo "ERROR: No checksum found for: $tarball" >&2
        return 1
    fi

    if [[ "$checksum" == *"PLACEHOLDER"* ]]; then
        echo "ERROR: Placeholder checksum for: $tarball" >&2
        return 1
    fi

    echo "$checksum"
}

verify_checksum() {
    local tarfile="$1"
    local expected_checksum

    if ! expected_checksum=$(get_expected_checksum "$(basename "$tarfile")"); then
        return 1
    fi

    local computed_checksum
    computed_checksum=$(sha256sum "$tarfile" | cut -d' ' -f1)

    if [ "$computed_checksum" = "$expected_checksum" ]; then
        return 0
    else
        echo "ERROR: Checksum mismatch for $(basename "$tarfile")" >&2
        echo "  Expected: $expected_checksum" >&2
        echo "  Computed: $computed_checksum" >&2
        return 1
    fi
}

# ─── VERSION MANAGEMENT ──────────────────────────────────────────────────────

get_current_version() {
    local state_dir="${1:-/data/local/archdroid-state}"
    local version_file="${state_dir}/rootfs.version"

    if [ -f "$version_file" ]; then
        cat "$version_file"
    else
        echo "none"
    fi
}

save_current_version() {
    local state_dir="${1:-/data/local/archdroid-state}"
    local version_file="${state_dir}/rootfs.version"

    mkdir -p "$state_dir"
    echo "$ARCH_VERSION" > "$version_file"
}

is_version_current() {
    local state_dir="${1:-/data/local/archdroid-state}"
    local current_version
    current_version=$(get_current_version "$state_dir")

    [ "$current_version" = "$ARCH_VERSION" ]
}

# ─── SECURITY VALIDATION ─────────────────────────────────────────────────────

validate_version_config() {
    local errors=0

    # Validate version format (YYYY-MM-DD)
    if ! [[ "$ARCH_VERSION" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        echo "ERROR: Invalid version format: $ARCH_VERSION (expected: YYYY-MM-DD)" >&2
        ((errors++))
    fi

    # Validate checksums file integrity
    if ! verify_checksums_file_integrity "$CHECKSUM_FILE"; then
        echo "ERROR: Checksums file integrity validation failed" >&2
        ((errors++))
        return $errors  # Don't continue if checksums file is compromised
    fi

    # Validate checksum for current version
    if ! get_expected_checksum "$ARCH_TARBALL" >/dev/null; then
        echo "ERROR: No valid checksum for current version: $ARCH_TARBALL" >&2
        ((errors++))
    fi

    # Validate URLs are HTTPS
    if [[ "$ARCH_URL_PRIMARY" != https://* ]]; then
        echo "ERROR: Primary URL is not HTTPS: $ARCH_URL_PRIMARY" >&2
        ((errors++))
    fi

    if [[ "$ARCH_URL_FALLBACK" != https://* ]]; then
        echo "ERROR: Fallback URL is not HTTPS: $ARCH_URL_FALLBACK" >&2
        ((errors++))
    fi

    return $errors
}

# ─── VERSION INFO DISPLAY ────────────────────────────────────────────────────

show_version_info() {
    local expected_checksum checksum_status

    if expected_checksum=$(get_expected_checksum "$ARCH_TARBALL" 2>/dev/null); then
        checksum_status="$expected_checksum"
    else
        checksum_status="$(get_expected_checksum "$ARCH_TARBALL" 2>&1 | head -1)"
    fi

    echo "ArchDroid Version Information:"
    echo "  Version: $ARCH_VERSION"
    echo "  Checksum: $checksum_status"
    echo "  Checksum File: $CHECKSUM_FILE"
    echo "  Tarball: $ARCH_TARBALL"
    echo "  Primary URL: $ARCH_URL_PRIMARY"
    echo "  Fallback URL: $ARCH_URL_FALLBACK"
}

# ─── MAIN EXECUTION ──────────────────────────────────────────────────────────
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    # Called directly - show version info and validate
    show_version_info
    echo ""

    if validate_version_config; then
        echo "✓ Version configuration is valid"
        exit 0
    else
        echo "✗ Version configuration has errors"
        exit 1
    fi
fi