#!/usr/bin/env bash
# ============================================================================
# PLEX CARTRIDGE v2 — Uninstaller
# ============================================================================
# Ejects the cartridge, stops the watchdog, restores original transcoder.
#
# Usage: sudo ./uninstall.sh [--keep-logs] [--purge]
# ============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

LOG_BASE="/var/log/plex-cartridge"
META_FILE="${LOG_BASE}/.install_meta"
CARTRIDGE_HOME="/opt/plex-cartridge"

KEEP_LOGS=false
PURGE_ALL=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep-logs) KEEP_LOGS=true; shift ;;
        --purge) PURGE_ALL=true; shift ;;
        -h|--help)
            echo "Usage: sudo ./uninstall.sh [--keep-logs] [--purge]"
            echo ""
            echo "  --keep-logs  Remove cartridge but preserve all captured logs"
            echo "  --purge      Remove everything including logs and cartridge home"
            exit 0
            ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

echo ""
echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}║${RESET}  ${BOLD}PLEX CARTRIDGE v2 — Uninstaller${RESET}                             ${CYAN}║${RESET}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${RESET}"
echo ""

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}ERROR:${RESET} Must run as root (sudo ./uninstall.sh)"
    exit 1
fi

# --- [1/5] Stop watchdog -----------------------------------------------------
echo -e "${BOLD}[1/5] Stopping watchdog...${RESET}"

# Systemd
if systemctl is-active plex-cartridge-watchdog.service &>/dev/null; then
    systemctl stop plex-cartridge-watchdog.service
    systemctl disable plex-cartridge-watchdog.service
    rm -f /etc/systemd/system/plex-cartridge-watchdog.service
    systemctl daemon-reload
    echo -e "  ${GREEN}✓${RESET} Systemd watchdog stopped and removed"
elif [[ -f "${LOG_BASE}/.watchdog.pid" ]]; then
    WPID=$(cat "${LOG_BASE}/.watchdog.pid")
    kill "$WPID" 2>/dev/null && echo -e "  ${GREEN}✓${RESET} Watchdog process stopped (PID $WPID)" || echo -e "  ${DIM}Watchdog was not running${RESET}"
    rm -f "${LOG_BASE}/.watchdog.pid"
else
    echo -e "  ${DIM}No watchdog found${RESET}"
fi

# Remove cron entry if present
if crontab -l 2>/dev/null | grep -q "plex-cartridge"; then
    crontab -l 2>/dev/null | grep -v "plex-cartridge" | crontab -
    echo -e "  ${GREEN}✓${RESET} Cron watchdog removed"
fi

# --- [2/5] Restore transcoder ------------------------------------------------
echo -e "${BOLD}[2/5] Restoring original transcoder...${RESET}"

if [[ -f "$META_FILE" ]]; then
    source "$META_FILE"
else
    # Find it manually
    for candidate in \
        "/usr/lib/plexmediaserver/Plex Transcoder.real" \
        "/usr/lib/plexmediaserver/Resources/Plex Transcoder.real" \
        "/Applications/Plex Media Server.app/Contents/MacOS/Plex Transcoder.real"; do
        if [[ -f "$candidate" ]]; then
            BACKUP_PATH="$candidate"
            TRANSCODER_PATH="${candidate%.real}"
            break
        fi
    done
fi

if [[ -z "${BACKUP_PATH:-}" ]] || [[ ! -f "${BACKUP_PATH:-}" ]]; then
    echo -e "${RED}ERROR:${RESET} Cannot find backup transcoder."
    echo "  You may need to reinstall Plex Media Server."
    exit 1
fi

if file "$BACKUP_PATH" 2>/dev/null | grep -qiE "ELF|Mach-O|executable"; then
    mv "$BACKUP_PATH" "$TRANSCODER_PATH"
    echo -e "  ${GREEN}✓${RESET} Original transcoder restored"
    echo -e "  ${GREEN}✓${RESET} Verified: $(file "$TRANSCODER_PATH" | cut -d: -f2 | xargs)"
else
    echo -e "${RED}ERROR:${RESET} Backup doesn't look valid: $(file "$BACKUP_PATH")"
    exit 1
fi

# --- [3/5] Handle logs -------------------------------------------------------
echo -e "${BOLD}[3/5] Handling captured data...${RESET}"

if [[ -d "${LOG_BASE}/sessions" ]]; then
    SESSION_COUNT=$(ls -d "${LOG_BASE}/sessions/"*/ 2>/dev/null | wc -l || echo 0)
    LOG_SIZE=$(du -sh "$LOG_BASE" 2>/dev/null | awk '{print $1}' || echo "?")
    echo "  Sessions captured: ${SESSION_COUNT}"
    echo "  Total log size:    ${LOG_SIZE}"
fi

if [[ "$PURGE_ALL" == true ]]; then
    rm -rf "$LOG_BASE"
    echo -e "  ${GREEN}✓${RESET} All logs deleted"
elif [[ "$KEEP_LOGS" == true ]]; then
    echo -e "  ${GREEN}✓${RESET} Logs preserved at: ${LOG_BASE}"
else
    echo ""
    read -rp "  Delete captured logs? (y/N): " DELETE_LOGS
    if [[ "${DELETE_LOGS,,}" == "y" ]]; then
        rm -rf "$LOG_BASE"
        echo -e "  ${GREEN}✓${RESET} Logs deleted"
    else
        echo -e "  ${GREEN}✓${RESET} Logs preserved at: ${LOG_BASE}"
    fi
fi

# --- [4/5] Handle cartridge home ---------------------------------------------
echo -e "${BOLD}[4/5] Handling cartridge installation...${RESET}"

if [[ "$PURGE_ALL" == true ]]; then
    rm -rf "$CARTRIDGE_HOME"
    echo -e "  ${GREEN}✓${RESET} Cartridge home removed: ${CARTRIDGE_HOME}"
    
    # Clean up any backup copies
    rm -rf "${CARTRIDGE_HOME}.backup."* 2>/dev/null || true
else
    echo -e "  ${DIM}Cartridge files preserved at: ${CARTRIDGE_HOME}${RESET}"
    echo -e "  ${DIM}(use --purge to remove everything)${RESET}"
fi

# --- [5/5] Final verification ------------------------------------------------
echo -e "${BOLD}[5/5] Verification...${RESET}"

if file "$TRANSCODER_PATH" 2>/dev/null | grep -qiE "ELF|Mach-O|executable"; then
    echo -e "  ${GREEN}✓${RESET} Real transcoder is in place"
else
    echo -e "  ${RED}✗${RESET} WARNING: Transcoder may not be correct"
fi

if ! systemctl is-active plex-cartridge-watchdog.service &>/dev/null 2>&1; then
    echo -e "  ${GREEN}✓${RESET} No watchdog running"
fi

# --- Done --------------------------------------------------------------------
echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}║${RESET}  ${BOLD}CARTRIDGE EJECTED${RESET}                                          ${GREEN}║${RESET}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo "  Plex is back to its original transcoder."
echo "  No restart needed."
echo ""
if [[ "$PURGE_ALL" != true ]]; then
    echo -e "  ${DIM}To fully clean up: sudo ./uninstall.sh --purge${RESET}"
    echo ""
fi
