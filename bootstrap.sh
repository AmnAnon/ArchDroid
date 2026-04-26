#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║  ArchDroid — core/bootstrap.sh                                  ║
# ║  Download, verify, extract Arch rootfs                          ║
# ╚══════════════════════════════════════════════════════════════════╝

source "$(dirname "$0")/../core/env.sh" 2>/dev/null || true

TARBALL="ArchLinuxARM-aarch64-latest.tar.gz"
MIRROR_PRIMARY="http://de3.mirror.archlinuxarm.org/os/${TARBALL}"
MIRROR_FALLBACK="http://mirror.archlinuxarm.org/os/${TARBALL}"

# ─── CURL RESOLVER ───────────────────────────────────────────────────────────
# After su, PATH may drop Termux — find curl with proper SSL certs explicitly
find_curl() {
  for candidate in \
      /data/data/com.termux/files/usr/bin/curl \
      /usr/bin/curl \
      /bin/curl; do
    [ -x "$candidate" ] && echo "$candidate" && return 0
  done
  fail "curl not found. In Termux: pkg install curl"
  exit 1
}

# ─── ARCHITECTURE CHECK ──────────────────────────────────────────────────────
check_arch() {
  local ARCH
  ARCH=$(uname -m)
  if [ "$ARCH" != "aarch64" ]; then
    fail "Unsupported architecture: $ARCH"
    info "ArchDroid requires an aarch64 (ARMv8) device."
    exit 1
  fi
  ok "Architecture: aarch64 ✓"
}

# ─── DOWNLOAD ────────────────────────────────────────────────────────────────
download_rootfs() {
  local CURL_BIN
  CURL_BIN=$(find_curl)
  local DEST="${ARCH_PATH}/${TARBALL}"

  info "Downloading Arch Linux ARM rootfs (~930MB)..."
  info "Source: $MIRROR_PRIMARY"

  "$CURL_BIN" -L --progress-bar -o "$DEST" "$MIRROR_PRIMARY" 2>&1
  if [ $? -ne 0 ]; then
    warn "Primary mirror failed — trying fallback..."
    "$CURL_BIN" -L --progress-bar -o "$DEST" "$MIRROR_FALLBACK" 2>&1 \
      || { fail "Both mirrors failed. Check your connection."; exit 1; }
  fi

  ok "Download complete: $DEST"
}

# ─── EXTRACT ─────────────────────────────────────────────────────────────────
extract_rootfs() {
  local TARFILE="${ARCH_PATH}/${TARBALL}"

  [ -f "$TARFILE" ] || { fail "Tarball not found: $TARFILE"; exit 1; }

  info "Extracting rootfs → $ARCH_PATH (may take a few minutes)..."
  tar -xzf "$TARFILE" -C "$ARCH_PATH" \
    || { fail "Extraction failed — archive may be corrupted. Re-run archdroid init."; exit 1; }

  ok "Extraction complete"
  rm -f "$TARFILE"
  ok "Tarball removed"
}

# ─── PACMAN CONFIG ───────────────────────────────────────────────────────────
patch_pacman_conf() {
  local PCONF="${ARCH_PATH}/etc/pacman.conf"
  [ -f "$PCONF" ] || { warn "pacman.conf not found — skipping patch"; return; }

  # Add DisableSandbox under [options] if not already present
  # Required for kernel 4.x — Landlock is not supported
  if ! grep -q "^DisableSandbox" "$PCONF"; then
    sed -i '/^\[options\]/a DisableSandbox' "$PCONF" \
      && ok "pacman.conf patched: DisableSandbox added (kernel 4.x compat)" \
      || warn "Could not patch pacman.conf — you may need to add DisableSandbox manually"
  else
    ok "pacman.conf already patched"
  fi
}

# ─── FULL BOOTSTRAP ──────────────────────────────────────────────────────────
run_bootstrap() {
  section "Bootstrap"
  check_arch
  mkdir -p "$ARCH_PATH"
  download_rootfs
  extract_rootfs
  patch_pacman_conf
  touch "${ARCH_PATH}/.akn_firstboot"
  ok "Bootstrap complete"
}
