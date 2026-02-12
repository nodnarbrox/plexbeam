#!/usr/bin/env bash
# ============================================================================
# PLEXBEAM CARTRIDGE v3.1 — Uninstaller (Plex + Jellyfin)
# ============================================================================
# Ejects the cartridge, stops the watchdog (Plex), restores original state.
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

CARTRIDGE_HOME="/opt/plex-cartridge"  # May be overridden by .install_meta
SERVER_TYPE="plex"  # Default; overridden by .install_meta if present

# Try to load server type from metadata to determine log base
for meta_candidate in \
    "/var/log/plex-cartridge/.install_meta" \
    "/var/log/plexbeam/.install_meta"; do
    if [[ -f "$meta_candidate" ]]; then
        _server_type=$(grep "^SERVER_TYPE=" "$meta_candidate" 2>/dev/null | cut -d= -f2 || true)
        if [[ -n "$_server_type" ]]; then
            SERVER_TYPE="$_server_type"
        fi
        break
    fi
done

if [[ "$SERVER_TYPE" == "jellyfin" ]]; then
    LOG_BASE="/var/log/plexbeam"
    CARTRIDGE_HOME="/opt/plexbeam"
else
    LOG_BASE="/var/log/plex-cartridge"
    CARTRIDGE_HOME="/opt/plex-cartridge"
fi

META_FILE="${LOG_BASE}/.install_meta"

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
echo -e "${CYAN}║${RESET}  ${BOLD}PLEXBEAM CARTRIDGE — Uninstaller (${SERVER_TYPE})${RESET}                    ${CYAN}║${RESET}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${RESET}"
echo ""

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}ERROR:${RESET} Must run as root (sudo ./uninstall.sh)"
    exit 1
fi

# --- [1/5] Stop watchdog (Plex only) -----------------------------------------
echo -e "${BOLD}[1/5] Stopping watchdog...${RESET}"

if [[ "$SERVER_TYPE" == "plex" ]]; then
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
else
    echo -e "  ${DIM}Jellyfin — no watchdog to stop${RESET}"
fi

# --- [2/5] Restore original state -------------------------------------------
echo -e "${BOLD}[2/5] Restoring original configuration...${RESET}"

if [[ -f "$META_FILE" ]]; then
    source "$META_FILE"
fi

if [[ "$SERVER_TYPE" == "jellyfin" ]]; then
    # Jellyfin: restore encoding.xml, remove shim
    SHIM_PATH="${CARTRIDGE_HOME}/cartridge-active.sh"

    # Restore encoding.xml from backup
    ENCODING_BACKUP=""
    for candidate in \
        /config/encoding.xml.plexbeam-backup \
        /config/data/encoding.xml.plexbeam-backup \
        /etc/jellyfin/encoding.xml.plexbeam-backup; do
        if [[ -f "$candidate" ]]; then
            ENCODING_BACKUP="$candidate"
            break
        fi
    done

    if [[ -n "$ENCODING_BACKUP" ]]; then
        ENCODING_XML="${ENCODING_BACKUP%.plexbeam-backup}"
        mv "$ENCODING_BACKUP" "$ENCODING_XML"
        echo -e "  ${GREEN}✓${RESET} encoding.xml restored from backup"
    else
        # Try to reset EncoderAppPath to default
        for candidate in \
            /config/encoding.xml \
            /config/data/encoding.xml \
            /etc/jellyfin/encoding.xml; do
            if [[ -f "$candidate" ]] && grep -q "$SHIM_PATH" "$candidate" 2>/dev/null; then
                sed -i "s|<EncoderAppPath>[^<]*</EncoderAppPath>|<EncoderAppPath>/usr/lib/jellyfin-ffmpeg/ffmpeg</EncoderAppPath>|" "$candidate"
                echo -e "  ${GREEN}✓${RESET} encoding.xml reset to default ffmpeg path"
                break
            fi
        done
    fi

    # Remove the shim
    if [[ -f "$SHIM_PATH" ]]; then
        rm -f "$SHIM_PATH"
        echo -e "  ${GREEN}✓${RESET} Cartridge shim removed"
    fi
else
    # Plex: restore original binary
    if [[ -z "${BACKUP_PATH:-}" ]]; then
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

if [[ "$SERVER_TYPE" == "plex" ]]; then
    if file "${TRANSCODER_PATH:-}" 2>/dev/null | grep -qiE "ELF|Mach-O|executable"; then
        echo -e "  ${GREEN}✓${RESET} Real transcoder is in place"
    else
        echo -e "  ${RED}✗${RESET} WARNING: Transcoder may not be correct"
    fi

    if ! systemctl is-active plex-cartridge-watchdog.service &>/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${RESET} No watchdog running"
    fi
else
    echo -e "  ${GREEN}✓${RESET} Jellyfin cartridge removed"
fi

# --- Done --------------------------------------------------------------------
echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}║${RESET}  ${BOLD}CARTRIDGE EJECTED${RESET}                                          ${GREEN}║${RESET}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${RESET}"
echo ""
if [[ "$SERVER_TYPE" == "jellyfin" ]]; then
    echo "  Jellyfin is back to its default ffmpeg."
else
    echo "  Plex is back to its original transcoder."
fi
echo "  No restart needed."
echo ""
if [[ "$PURGE_ALL" != true ]]; then
    echo -e "  ${DIM}To fully clean up: sudo ./uninstall.sh --purge${RESET}"
    echo ""
fi
