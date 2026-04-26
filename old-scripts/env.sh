#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║  ArchDroid — core/env.sh                                        ║
# ║  Shared environment: colors, helpers, config, logging           ║
# ╚══════════════════════════════════════════════════════════════════╝

# ─── COLORS ─────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# ─── LOGGING ─────────────────────────────────────────────────────────────────
ARCHDROID_STATE="${ARCHDROID_STATE:-/data/local/archdroid-state}"
LOG_DIR="${ARCHDROID_STATE}/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/archdroid-$(date +%Y-%m-%d).log"

_log() {
  local level="$1"; shift
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] $*" >> "$LOG_FILE"
}

ok()      { echo -e "${GREEN}  ✔  $*${RESET}";  _log "OK"   "$*"; }
warn()    { echo -e "${YELLOW}  ⚠  $*${RESET}"; _log "WARN" "$*"; }
fail()    { echo -e "${RED}  ✘  $*${RESET}";    _log "ERR"  "$*"; }
info()    { echo -e "${CYAN}  ▶  $*${RESET}";   _log "INFO" "$*"; }
section() { echo -e "\n${BOLD}${CYAN}═══ $* ═══${RESET}\n"; _log "---" "$*"; }
banner()  {
  echo -e "${BOLD}${CYAN}"
  echo "  ╔══════════════════════════════════════════════════╗"
  printf  "  ║  %-48s║\n" "$*"
  echo "  ╚══════════════════════════════════════════════════╝"
  echo -e "${RESET}"
}

# ─── CONFIG ─────────────────────────────────────────────────────────────────
CONF_FILE="/data/local/archdroid.conf"

# Defaults
ARCH_PATH="/data/local/arch"
ARCHDROID_VERSION="1.1.0"

# Load user config if exists
if [ -f "$CONF_FILE" ]; then
  source "$CONF_FILE"
fi

export ARCH_PATH ARCHDROID_VERSION ARCHDROID_STATE LOG_FILE

# ─── ROOT CHECK ──────────────────────────────────────────────────────────────
require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    fail "ArchDroid requires root. Run: su → archdroid $*"
    exit 1
  fi
}

# ─── ROOTFS VALIDATION ───────────────────────────────────────────────────────
require_rootfs() {
  if [ ! -d "$ARCH_PATH/etc" ] || [ ! -d "$ARCH_PATH/usr" ]; then
    fail "No Arch rootfs found at: $ARCH_PATH"
    info "Run: archdroid init"
    exit 1
  fi
}
