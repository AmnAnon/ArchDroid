#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║  ArchDroid — core/doctor.sh                                     ║
# ║  Diagnose and auto-fix common runtime issues                    ║
# ╚══════════════════════════════════════════════════════════════════╝

source "$(dirname "$0")/../core/env.sh" 2>/dev/null || true
source "$(dirname "$0")/../core/mounts.sh" 2>/dev/null || true

PASS=0; WARN=0; FAIL=0

check() {
  local label="$1" result="$2" fix_cmd="$3"
  if [ "$result" = "ok" ]; then
    ok "$label"
    ((PASS++))
  elif [ "$result" = "warn" ]; then
    warn "$label"
    ((WARN++))
  else
    fail "$label"
    ((FAIL++))
    if [ -n "$fix_cmd" ]; then
      read -rp "  ▶  Auto-fix? [Y/n]: " FIX
      FIX="${FIX:-Y}"
      if [[ "$FIX" =~ ^[Yy]$ ]]; then
        eval "$fix_cmd" && ok "Fixed: $label" || warn "Fix failed — manual intervention needed"
      fi
    fi
  fi
}

run_doctor() {
  banner "ArchDroid Doctor v${ARCHDROID_VERSION}"
  _log "INFO" "Doctor started"

  section "1 · Root & Environment"

  # Root check
  [ "$(id -u)" -eq 0 ] \
    && check "Running as root" "ok" \
    || check "Running as root" "fail" ""

  # Arch rootfs exists
  [ -d "$ARCH_PATH/etc" ] && [ -d "$ARCH_PATH/usr" ] \
    && check "Rootfs found at $ARCH_PATH" "ok" \
    || check "Rootfs found at $ARCH_PATH" "fail" "echo 'Run: archdroid init'"

  # SELinux
  SELINUX_STATUS=$(getenforce 2>/dev/null || echo "unknown")
  [ "$SELINUX_STATUS" = "Permissive" ] || [ "$SELINUX_STATUS" = "Disabled" ] \
    && check "SELinux: $SELINUX_STATUS" "ok" \
    || check "SELinux: $SELINUX_STATUS (should be Permissive)" "warn" "setenforce 0"

  section "2 · Mounts"

  local EXPECTED_MOUNTS=("dev" "dev/pts" "proc" "sys" "tmp" "media/sdcard")
  for mnt in "${EXPECTED_MOUNTS[@]}"; do
    if mountpoint -q "$ARCH_PATH/$mnt" 2>/dev/null; then
      check "$mnt mounted" "ok"
    else
      check "$mnt NOT mounted" "fail" "mount_all"
    fi
  done

  section "3 · DNS"

  # resolv.conf exists and non-empty
  if [ -f "$ARCH_PATH/etc/resolv.conf" ] && [ -s "$ARCH_PATH/etc/resolv.conf" ]; then
    check "resolv.conf present" "ok"
    # Check it has a nameserver line
    grep -q "^nameserver" "$ARCH_PATH/etc/resolv.conf" \
      && check "nameserver entry found" "ok" \
      || check "no nameserver in resolv.conf" "fail" "sync_dns"
  else
    check "resolv.conf missing or empty" "fail" "sync_dns"
  fi

  # DNS resolution test (from host)
  ping -c 1 -W 2 8.8.8.8 &>/dev/null \
    && check "Network connectivity (ping 8.8.8.8)" "ok" \
    || check "Network connectivity (ping 8.8.8.8)" "fail" ""

  section "4 · Pacman Config"

  local PCONF="$ARCH_PATH/etc/pacman.conf"
  if [ -f "$PCONF" ]; then
    check "pacman.conf exists" "ok"
    grep -q "^DisableSandbox" "$PCONF" \
      && check "DisableSandbox set (kernel 4.x compat)" "ok" \
      || check "DisableSandbox missing — pacman may fail on kernel 4.x" "fail" \
         "sed -i '/^\[options\]/a DisableSandbox' $PCONF"
  else
    check "pacman.conf exists" "fail" ""
  fi

  section "5 · Shell"

  local SHELL_FOUND=false
  for s in /usr/bin/zsh /bin/zsh /bin/bash /bin/sh; do
    if [ -x "$ARCH_PATH$s" ]; then
      check "Shell available: $s" "ok"
      SHELL_FOUND=true
      break
    fi
  done
  $SHELL_FOUND || check "No shell found in chroot" "fail" ""

  section "6 · Logs"

  [ -d "$LOG_DIR" ] \
    && check "Log directory: $LOG_DIR" "ok" \
    || check "Log directory missing" "warn" "mkdir -p $LOG_DIR"
  [ -f "$LOG_FILE" ] \
    && check "Today's log: $LOG_FILE ($(wc -l < "$LOG_FILE") lines)" "ok" \
    || check "No log file yet" "warn" ""

  # ─── SUMMARY ──────────────────────────────────────────────────────────────
  echo ""
  echo -e "${BOLD}  ─── Doctor Report ───────────────────────────────${RESET}"
  echo -e "  ${GREEN}Passed:  $PASS${RESET}  ${YELLOW}Warnings: $WARN${RESET}  ${RED}Failed: $FAIL${RESET}"
  echo ""

  if [ "$FAIL" -eq 0 ] && [ "$WARN" -eq 0 ]; then
    echo -e "  ${BOLD}${GREEN}✔  Everything looks healthy. Ready to: archdroid start${RESET}"
  elif [ "$FAIL" -eq 0 ]; then
    echo -e "  ${YELLOW}⚠  Minor warnings — chroot should still work.${RESET}"
  else
    echo -e "  ${RED}✘  $FAIL issue(s) need attention before starting.${RESET}"
  fi
  echo ""

  _log "INFO" "Doctor complete — pass:$PASS warn:$WARN fail:$FAIL"
}
