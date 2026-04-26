#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║  ArchDroid — core/mounts.sh                                     ║
# ║  All bind mount / unmount logic                                 ║
# ╚══════════════════════════════════════════════════════════════════╝

source "$(dirname "$0")/../core/env.sh" 2>/dev/null || true

# ─── SAFE MOUNT HELPER ───────────────────────────────────────────────────────
do_mount() {
  local label="$1" target="$2"
  shift 2
  if mountpoint -q "$target" 2>/dev/null; then
    warn "Already mounted: $label — skipping"
  else
    "$@" \
      && ok "Mounted: $label" \
      || fail "Failed to mount: $label"
  fi
}

# ─── ENSURE DIRS ─────────────────────────────────────────────────────────────
prepare_mount_dirs() {
  mkdir -p \
    "$ARCH_PATH/dev" \
    "$ARCH_PATH/dev/pts" \
    "$ARCH_PATH/proc" \
    "$ARCH_PATH/sys" \
    "$ARCH_PATH/tmp" \
    "$ARCH_PATH/media/sdcard" \
    "$ARCH_PATH/etc"
}

# ─── MOUNT ALL ───────────────────────────────────────────────────────────────
mount_all() {
  section "Bind Mounts"
  prepare_mount_dirs

  do_mount "dev"     "$ARCH_PATH/dev"     mount --rbind /dev "$ARCH_PATH/dev"
  mount --make-rslave "$ARCH_PATH/dev" 2>/dev/null

  do_mount "dev/pts" "$ARCH_PATH/dev/pts" mount --rbind /dev/pts "$ARCH_PATH/dev/pts"
  mount --make-rslave "$ARCH_PATH/dev/pts" 2>/dev/null

  do_mount "proc"    "$ARCH_PATH/proc"    mount -t proc proc "$ARCH_PATH/proc"
  do_mount "sys"     "$ARCH_PATH/sys"     mount -t sysfs sysfs "$ARCH_PATH/sys"

  # /tmp as RAM-backed tmpfs — critical for llama.cpp / AI agent performance
  do_mount "tmp" "$ARCH_PATH/tmp" \
    mount -t tmpfs -o size=512m,mode=1777 tmpfs "$ARCH_PATH/tmp"

  # sdcard — try both common Android paths
  local SDCARD_SRC=""
  [ -d "/sdcard" ]                   && SDCARD_SRC="/sdcard"
  [ -z "$SDCARD_SRC" ] && [ -d "/storage/emulated/0" ] && SDCARD_SRC="/storage/emulated/0"

  if [ -n "$SDCARD_SRC" ]; then
    do_mount "sdcard" "$ARCH_PATH/media/sdcard" \
      mount --bind "$SDCARD_SRC" "$ARCH_PATH/media/sdcard"
  else
    warn "No sdcard source found — skipping sdcard mount"
  fi

  ok "All mounts complete"
}

# ─── SYNC DNS ────────────────────────────────────────────────────────────────
sync_dns() {
  section "DNS"
  mkdir -p "$ARCH_PATH/etc"

  local DNS_WRITTEN=false

  # Strategy 1: copy from Android host
  if [ -f /etc/resolv.conf ] && [ -s /etc/resolv.conf ]; then
    cp /etc/resolv.conf "$ARCH_PATH/etc/resolv.conf" 2>/dev/null \
      && ok "DNS synced from host resolv.conf" \
      && DNS_WRITTEN=true
  fi

  # Strategy 2: write hardcoded fallback
  if [ "$DNS_WRITTEN" = false ]; then
    {
      echo "nameserver 8.8.8.8"
      echo "nameserver 1.1.1.1"
      echo "nameserver 208.67.222.222"
    } > "$ARCH_PATH/etc/resolv.conf" \
      && ok "Fallback DNS written (8.8.8.8 / 1.1.1.1 / OpenDNS)" \
      || fail "Could not write resolv.conf"
  fi
}

# ─── UNMOUNT ALL ─────────────────────────────────────────────────────────────
unmount_all() {
  section "Unmounting"

  # Reverse order — children before parents
  local MOUNT_POINTS=(
    "$ARCH_PATH/tmp"
    "$ARCH_PATH/media/sdcard"
    "$ARCH_PATH/dev/pts"
    "$ARCH_PATH/dev"
    "$ARCH_PATH/sys"
    "$ARCH_PATH/proc"
  )

  for mnt in "${MOUNT_POINTS[@]}"; do
    if mountpoint -q "$mnt" 2>/dev/null; then
      umount -l "$mnt" \
        && ok "Unmounted: $mnt" \
        || fail "Failed: $mnt"
    else
      warn "Not mounted: $mnt — skipping"
    fi
  done

  # Final check
  local REMAINING
  REMAINING=$(mount 2>/dev/null | grep -c "$ARCH_PATH" || true)
  if [ "$REMAINING" -eq 0 ]; then
    ok "All mounts cleared — safe to modify chroot folder"
  else
    warn "${REMAINING} mount(s) still active. Check: mount | grep '$ARCH_PATH'"
  fi
}

# ─── MOUNT STATUS ────────────────────────────────────────────────────────────
mount_status() {
  local EXPECTED=("dev" "dev/pts" "proc" "sys" "tmp" "media/sdcard")
  local ALL_OK=true

  for mnt in "${EXPECTED[@]}"; do
    if mountpoint -q "$ARCH_PATH/$mnt" 2>/dev/null; then
      ok "$mnt"
    else
      warn "$mnt — NOT mounted"
      ALL_OK=false
    fi
  done

  $ALL_OK && return 0 || return 1
}
