#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║  ArchDroid — core/runtime.sh                                    ║
# ║  Chroot entry, namespace detection, shell resolution            ║
# ╚══════════════════════════════════════════════════════════════════╝

source "$(dirname "$0")/../core/env.sh" 2>/dev/null || true

# ─── SELINUX ──────────────────────────────────────────────────────────────────
set_selinux_permissive() {
  setenforce 0 2>/dev/null \
    && ok "SELinux → Permissive" \
    || warn "SELinux: already permissive or not applicable"
}

# ─── NAMESPACE DETECTION ──────────────────────────────────────────────────────
detect_namespace() {
  section "Root Environment"
  if [ -d "/data/adb/ksu" ]; then
    ok "KernelSU detected — global mount namespace active"
  elif [ -d "/data/adb/magisk" ] || [ -f "/data/adb/magisk.db" ]; then
    info "Magisk detected — attempting namespace breakout..."
    if command -v nsenter &>/dev/null; then
      nsenter -t 1 -m -u -i -n -p -- /bin/true 2>/dev/null \
        && ok "Magisk global namespace active" \
        || warn "nsenter failed — mounts may not propagate globally"
    else
      warn "nsenter not found — install busybox for full mount visibility"
    fi
  else
    warn "Root manager not detected — assuming mounts are visible"
  fi
}

# ─── SHELL DETECTION ──────────────────────────────────────────────────────────
detect_shell() {
  local CHROOT_SHELL=""
  for CANDIDATE in /usr/bin/zsh /bin/zsh /bin/bash /bin/sh; do
    if [ -x "$ARCH_PATH$CANDIDATE" ]; then
      CHROOT_SHELL="$CANDIDATE"
      break
    fi
  done

  if [ -z "$CHROOT_SHELL" ]; then
    fail "No usable shell found in chroot at $ARCH_PATH"
    exit 1
  fi

  ok "Shell: $CHROOT_SHELL"
  echo "$CHROOT_SHELL"
}

# ─── FIRST BOOT ───────────────────────────────────────────────────────────────
handle_first_boot() {
  [ -f "${ARCH_PATH}/.akn_firstboot" ] || return 0

  echo ""
  echo -e "${BOLD}${GREEN}"
  echo "  ╔══════════════════════════════════════════════════╗"
  echo "  ║  🎉  Arch Linux Chroot Installed Successfully!   ║"
  echo "  ║                                                  ║"
  echo "  ║     Welcome to your Sovereign Space.             ║"
  echo "  ╚══════════════════════════════════════════════════╝"
  echo -e "${RESET}"
  echo ""
  echo -e "  ${BOLD}Would you like to run a full system upgrade now?${RESET}"
  echo -e "  ${CYAN}  Initializes pacman keys + updates all packages.${RESET}"
  echo -e "  ${YELLOW}  Recommended. Takes ~5-10 minutes.${RESET}"
  echo ""
  read -rp "  Run system upgrade? [Y/n]: " UPGRADE_CHOICE
  UPGRADE_CHOICE="${UPGRADE_CHOICE:-Y}"

  if [[ "$UPGRADE_CHOICE" =~ ^[Yy]$ ]]; then
    cat > "${ARCH_PATH}/root/.akn_firstboot_init.sh" << 'INITEOF'
#!/bin/bash
GREEN='\033[0;32m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
echo -e "\n${BOLD}${CYAN}  ▶  Initializing pacman keyring...${RESET}"
pacman-key --init
pacman-key --populate archlinuxarm
echo -e "\n${BOLD}${CYAN}  ▶  Running full system upgrade...${RESET}"
pacman --noconfirm -Syu
echo -e "\n${GREEN}  ✔  Done! Your Arch chroot is ready.${RESET}\n"
rm -f /root/.akn_firstboot_init.sh
INITEOF
    chmod +x "${ARCH_PATH}/root/.akn_firstboot_init.sh"
    for RC in "${ARCH_PATH}/root/.bashrc" "${ARCH_PATH}/root/.zshrc"; do
      echo '[ -f /root/.akn_firstboot_init.sh ] && bash /root/.akn_firstboot_init.sh' >> "$RC"
    done
    ok "First-boot upgrade queued — runs automatically on login"
  else
    info "Skipping. Run manually later:"
    echo "     pacman-key --init && pacman-key --populate archlinuxarm && pacman -Syu"
  fi

  rm -f "${ARCH_PATH}/.akn_firstboot"
}

# ─── ENTER CHROOT ─────────────────────────────────────────────────────────────
enter_chroot() {
  local SHELL_BIN
  SHELL_BIN=$(detect_shell)

  echo ""
  info "Entering Arch chroot → ${ARCH_PATH}"
  _log "INFO" "Session started — shell: $SHELL_BIN"
  echo ""

  # Clean PATH — prevent Android /system/bin leaking into chroot
  export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

  exec chroot "$ARCH_PATH" "$SHELL_BIN" -l
}
