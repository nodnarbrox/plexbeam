#!/usr/bin/env bash
# ============================================================================
# PLEX CARTRIDGE v3 — Installer with Remote GPU Support
# ============================================================================
# Auto-detects Plex, installs the cartridge, sets up the watchdog to
# survive Plex updates, and configures remote GPU worker.
#
# Usage: sudo ./install.sh [--worker URL] [--api-key KEY] [--repo URL] [--no-watchdog]
# ============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

LOG_BASE="/var/log/plex-cartridge"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CARTRIDGE_SRC="${SCRIPT_DIR}/plex_cartridge.sh"

# Defaults
UPDATE_REPO="local"
INSTALL_WATCHDOG=true
REMOTE_WORKER_URL=""
REMOTE_API_KEY=""
SHARED_SEGMENT_DIR=""

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --worker)
            REMOTE_WORKER_URL="$2"
            shift 2
            ;;
        --api-key)
            REMOTE_API_KEY="$2"
            shift 2
            ;;
        --shared-dir)
            SHARED_SEGMENT_DIR="$2"
            shift 2
            ;;
        --repo)
            UPDATE_REPO="$2"
            shift 2
            ;;
        --no-watchdog)
            INSTALL_WATCHDOG=false
            shift
            ;;
        -h|--help)
            echo "Usage: sudo ./install.sh [OPTIONS]"
            echo ""
            echo "Remote GPU Options:"
            echo "  --worker URL       Remote GPU worker URL (e.g., http://192.168.1.100:8765)"
            echo "  --api-key KEY      API key for worker authentication"
            echo "  --shared-dir PATH  Shared directory for segment output (SMB/NFS mount)"
            echo ""
            echo "Update Options:"
            echo "  --repo URL         GitHub repo or local path for auto-updates"
            echo "                     Example: https://github.com/you/plex-remote-gpu"
            echo "                     Example: /home/you/plex-remote-gpu-dev"
            echo ""
            echo "Other Options:"
            echo "  --no-watchdog      Skip watchdog installation"
            exit 0
            ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

echo ""
echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}║${RESET}  ${BOLD}PLEX CARTRIDGE v3 — Remote GPU Installer${RESET}                    ${CYAN}║${RESET}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${RESET}"
echo ""

# --- Check root --------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}ERROR:${RESET} Must run as root (sudo ./install.sh)"
    exit 1
fi

# --- [1/9] Detect Plex -------------------------------------------------------
echo -e "${BOLD}[1/9] Detecting Plex installation...${RESET}"

TRANSCODER_PATH=""
PLEX_USER=""

SEARCH_PATHS=(
    "/usr/lib/plexmediaserver"
    "/usr/lib/plexmediaserver/Resources"
    "/opt/plex/Application/Resources"
    "/Applications/Plex Media Server.app/Contents/Resources"
    "/Applications/Plex Media Server.app/Contents/MacOS"
    "/volume1/@appstore/PlexMediaServer/Resources"
    "/share/PlexMediaServer/Resources"
)

TRANSCODER_NAMES=(
    "Plex Transcoder"
    "Plex New Transcoder"
)

for search_dir in "${SEARCH_PATHS[@]}"; do
    for tname in "${TRANSCODER_NAMES[@]}"; do
        candidate="${search_dir}/${tname}"
        if [[ -f "$candidate" ]]; then
            if file "$candidate" 2>/dev/null | grep -qiE "ELF|Mach-O|executable"; then
                TRANSCODER_PATH="$candidate"
                echo -e "  ${GREEN}✓${RESET} Found binary: ${TRANSCODER_PATH}"
                break 2
            elif grep -q "PLEX CARTRIDGE" "$candidate" 2>/dev/null; then
                if [[ -f "${candidate}.real" ]]; then
                    TRANSCODER_PATH="$candidate"
                    echo -e "  ${YELLOW}!${RESET} Cartridge already installed at: ${TRANSCODER_PATH}"
                    echo -e "  ${GREEN}✓${RESET} Will re-install (upgrade)"
                    break 2
                fi
            fi
        fi
    done
done

# Try running process
if [[ -z "$TRANSCODER_PATH" ]]; then
    RUNNING_PATH=$(pgrep -a -f "Plex Transcoder" 2>/dev/null | head -1 | awk '{print $2}' || true)
    if [[ -n "$RUNNING_PATH" ]] && [[ -f "$RUNNING_PATH" ]]; then
        TRANSCODER_PATH="$RUNNING_PATH"
        echo -e "  ${GREEN}✓${RESET} Found via process: ${TRANSCODER_PATH}"
    fi
fi

# Try package manager
if [[ -z "$TRANSCODER_PATH" ]]; then
    PKG_PATH=$(dpkg -L plexmediaserver 2>/dev/null | grep "Plex Transcoder" | head -1 || true)
    [[ -z "$PKG_PATH" ]] && PKG_PATH=$(rpm -ql PlexMediaServer 2>/dev/null | grep "Plex Transcoder" | head -1 || true)
    if [[ -n "$PKG_PATH" ]] && [[ -f "$PKG_PATH" ]]; then
        TRANSCODER_PATH="$PKG_PATH"
        echo -e "  ${GREEN}✓${RESET} Found via package: ${TRANSCODER_PATH}"
    fi
fi

# Manual fallback
if [[ -z "$TRANSCODER_PATH" ]]; then
    echo ""
    echo -e "${YELLOW}Could not auto-detect Plex Transcoder.${RESET}"
    echo ""
    echo "Common locations:"
    echo "  Linux:    /usr/lib/plexmediaserver/Plex Transcoder"
    echo "  Docker:   (same, inside the container)"
    echo "  macOS:    /Applications/Plex Media Server.app/Contents/MacOS/Plex Transcoder"
    echo ""
    read -rp "Enter full path to Plex Transcoder binary: " TRANSCODER_PATH
    if [[ ! -f "$TRANSCODER_PATH" ]]; then
        echo -e "${RED}ERROR:${RESET} Not found: ${TRANSCODER_PATH}"
        exit 1
    fi
fi

# --- [2/9] Detect Plex user --------------------------------------------------
echo -e "${BOLD}[2/9] Detecting Plex service user...${RESET}"

PLEX_USER=$(stat -c '%U' "$TRANSCODER_PATH" 2>/dev/null || stat -f '%Su' "$TRANSCODER_PATH" 2>/dev/null || echo "plex")
echo -e "  ${GREEN}✓${RESET} Plex user: ${PLEX_USER}"

# --- [3/9] Set up cartridge home ---------------------------------------------
echo -e "${BOLD}[3/9] Setting up cartridge home...${RESET}"

CARTRIDGE_HOME="/opt/plex-cartridge"
mkdir -p "$CARTRIDGE_HOME"

# Copy all cartridge files to permanent home
for f in plex_cartridge.sh analyze.sh install.sh uninstall.sh watchdog.sh; do
    if [[ -f "${SCRIPT_DIR}/${f}" ]]; then
        cp "${SCRIPT_DIR}/${f}" "${CARTRIDGE_HOME}/${f}"
        chmod +x "${CARTRIDGE_HOME}/${f}"
    fi
done

# Copy README if present
[[ -f "${SCRIPT_DIR}/README.md" ]] && cp "${SCRIPT_DIR}/README.md" "${CARTRIDGE_HOME}/"

echo -e "  ${GREEN}✓${RESET} Cartridge home: ${CARTRIDGE_HOME}"

# --- [4/9] Back up real transcoder --------------------------------------------
echo -e "${BOLD}[4/9] Backing up real transcoder...${RESET}"

BACKUP_PATH="${TRANSCODER_PATH}.real"

if [[ -f "$BACKUP_PATH" ]] && file "$BACKUP_PATH" 2>/dev/null | grep -qiE "ELF|Mach-O|executable"; then
    echo -e "  ${GREEN}✓${RESET} Existing backup valid: ${BACKUP_PATH}"
elif file "$TRANSCODER_PATH" 2>/dev/null | grep -qiE "ELF|Mach-O|executable"; then
    cp -p "$TRANSCODER_PATH" "$BACKUP_PATH"
    echo -e "  ${GREEN}✓${RESET} Backed up to: ${BACKUP_PATH}"
else
    echo -e "  ${YELLOW}!${RESET} Transcoder isn't a binary (already shimmed?) — checking backup..."
    if [[ -f "$BACKUP_PATH" ]]; then
        echo -e "  ${GREEN}✓${RESET} Using existing backup"
    else
        echo -e "${RED}ERROR:${RESET} No valid transcoder binary found."
        exit 1
    fi
fi

# Fingerprint the real binary
FINGERPRINT=$(md5sum "$BACKUP_PATH" 2>/dev/null | awk '{print $1}' || shasum "$BACKUP_PATH" 2>/dev/null | awk '{print $1}' || echo "unknown")
PLEX_VERSION=$(strings "$BACKUP_PATH" 2>/dev/null | grep -oP '^\d+\.\d+\.\d+\.\d+-[0-9a-f]+' | head -1 || echo "unknown")
echo -e "  ${DIM}Binary fingerprint: ${FINGERPRINT}${RESET}"
echo -e "  ${DIM}Plex version: ${PLEX_VERSION}${RESET}"

# --- [5/9] Configure remote worker -------------------------------------------
echo -e "${BOLD}[5/9] Configuring remote GPU worker...${RESET}"

if [[ -z "$REMOTE_WORKER_URL" ]]; then
    echo ""
    echo -e "${CYAN}Remote GPU transcoding is optional but recommended for performance.${RESET}"
    echo ""
    echo "If you have a remote GPU worker running, enter its URL."
    echo "Otherwise, leave blank to use local transcoding only."
    echo ""
    read -rp "Remote worker URL (e.g., http://192.168.1.100:8765) [skip]: " REMOTE_WORKER_URL

    if [[ -n "$REMOTE_WORKER_URL" ]] && [[ -z "$REMOTE_API_KEY" ]]; then
        read -rp "API key for worker (leave blank for none): " REMOTE_API_KEY
    fi
fi

if [[ -n "$REMOTE_WORKER_URL" ]]; then
    # Test connectivity
    echo -e "  Testing worker connectivity..."
    WORKER_HEALTH=$(curl -sf --connect-timeout 5 "${REMOTE_WORKER_URL}/health" 2>/dev/null || echo "")

    if [[ -n "$WORKER_HEALTH" ]]; then
        WORKER_VERSION=$(echo "$WORKER_HEALTH" | grep -o '"version":"[^"]*"' | cut -d'"' -f4 || echo "unknown")
        WORKER_HW=$(echo "$WORKER_HEALTH" | grep -o '"hw_accel":"[^"]*"' | cut -d'"' -f4 || echo "unknown")
        echo -e "  ${GREEN}✓${RESET} Worker reachable: v${WORKER_VERSION} (${WORKER_HW})"
    else
        echo -e "  ${YELLOW}!${RESET} Worker not reachable at: ${REMOTE_WORKER_URL}"
        echo -e "  ${DIM}  Will use local transcoding as fallback${RESET}"
    fi
else
    echo -e "  ${DIM}No remote worker configured — local transcoding only${RESET}"
fi

# --- [6/9] Install cartridge -------------------------------------------------
echo -e "${BOLD}[6/9] Installing cartridge...${RESET}"

mkdir -p "${LOG_BASE}/sessions"
chown -R "${PLEX_USER}:${PLEX_USER}" "${LOG_BASE}" 2>/dev/null || true
chmod -R 755 "${LOG_BASE}"

# Bake paths into the cartridge
sed \
    -e "s|__REAL_TRANSCODER_PATH__|${BACKUP_PATH}|g" \
    -e "s|__CARTRIDGE_HOME__|${CARTRIDGE_HOME}|g" \
    -e "s|__UPDATE_REPO__|${UPDATE_REPO}|g" \
    -e "s|__REMOTE_WORKER_URL__|${REMOTE_WORKER_URL}|g" \
    -e "s|__REMOTE_API_KEY__|${REMOTE_API_KEY}|g" \
    -e "s|__SHARED_SEGMENT_DIR__|${SHARED_SEGMENT_DIR}|g" \
    "${CARTRIDGE_HOME}/plex_cartridge.sh" > "$TRANSCODER_PATH"

chmod 755 "$TRANSCODER_PATH"
chown "${PLEX_USER}:${PLEX_USER}" "$TRANSCODER_PATH" 2>/dev/null || true

# Save fingerprint
echo "$FINGERPRINT" > "${LOG_BASE}/.binary_fingerprint"

# Record version
echo "$(date -Iseconds)|${PLEX_VERSION}|${FINGERPRINT}" >> "${LOG_BASE}/.plex_version_history"

echo -e "  ${GREEN}✓${RESET} Cartridge installed"

# --- [7/9] Write metadata -----------------------------------------------------
echo -e "${BOLD}[7/9] Writing install metadata...${RESET}"

cat > "${LOG_BASE}/.install_meta" << EOF
INSTALL_DATE=$(date -Iseconds)
TRANSCODER_PATH=${TRANSCODER_PATH}
BACKUP_PATH=${BACKUP_PATH}
PLEX_USER=${PLEX_USER}
CARTRIDGE_HOME=${CARTRIDGE_HOME}
CARTRIDGE_VERSION=3.0.0
UPDATE_REPO=${UPDATE_REPO}
PLEX_VERSION=${PLEX_VERSION}
REMOTE_WORKER_URL=${REMOTE_WORKER_URL}
REMOTE_API_KEY=${REMOTE_API_KEY}
SHARED_SEGMENT_DIR=${SHARED_SEGMENT_DIR}
EOF

echo -e "  ${GREEN}✓${RESET} Metadata saved"

# --- [8/9] Install watchdog ---------------------------------------------------
if [[ "$INSTALL_WATCHDOG" == true ]]; then
    echo -e "${BOLD}[8/9] Setting up watchdog...${RESET}"

    # Try systemd first
    if command -v systemctl &>/dev/null && [[ -d /etc/systemd/system ]]; then
        cat > /etc/systemd/system/plex-cartridge-watchdog.service << UNIT
[Unit]
Description=Plex Cartridge Watchdog — Survives Plex Updates
After=plexmediaserver.service
Wants=plexmediaserver.service

[Service]
Type=simple
ExecStart=${CARTRIDGE_HOME}/watchdog.sh
ExecStop=${CARTRIDGE_HOME}/watchdog.sh --stop
Restart=always
RestartSec=10
User=root
StandardOutput=append:${LOG_BASE}/watchdog.log
StandardError=append:${LOG_BASE}/watchdog.log

# Hardening
NoNewPrivileges=no
ProtectSystem=full
ReadWritePaths=${LOG_BASE} ${CARTRIDGE_HOME}

[Install]
WantedBy=multi-user.target
UNIT

        systemctl daemon-reload
        systemctl enable plex-cartridge-watchdog.service
        systemctl start plex-cartridge-watchdog.service

        WATCHDOG_STATUS=$(systemctl is-active plex-cartridge-watchdog.service 2>/dev/null || echo "unknown")
        if [[ "$WATCHDOG_STATUS" == "active" ]]; then
            echo -e "  ${GREEN}✓${RESET} Watchdog running (systemd)"
            echo -e "  ${DIM}  systemctl status plex-cartridge-watchdog${RESET}"
        else
            echo -e "  ${YELLOW}!${RESET} Watchdog installed but status: ${WATCHDOG_STATUS}"
            echo -e "  ${DIM}  Check: journalctl -u plex-cartridge-watchdog${RESET}"
        fi
    else
        # Fallback: cron job
        echo "  No systemd — installing cron watchdog..."

        CRON_LINE="* * * * * ${CARTRIDGE_HOME}/watchdog.sh --once >> ${LOG_BASE}/watchdog.log 2>&1"
        (crontab -l 2>/dev/null | grep -v "plex-cartridge"; echo "$CRON_LINE") | crontab -

        echo -e "  ${GREEN}✓${RESET} Watchdog cron installed (checks every minute)"
    fi
else
    echo -e "${BOLD}[8/9] Skipping watchdog (--no-watchdog)${RESET}"
fi

# --- [9/9] Verify everything -------------------------------------------------
echo -e "${BOLD}[9/9] Verification...${RESET}"

ISSUES=0

# Cartridge in place?
if grep -q "PLEX CARTRIDGE" "$TRANSCODER_PATH" 2>/dev/null; then
    echo -e "  ${GREEN}✓${RESET} Cartridge in transcoder slot"
else
    echo -e "  ${RED}✗${RESET} Cartridge NOT in place"
    ISSUES=$((ISSUES + 1))
fi

# Real binary accessible?
if [[ -x "$BACKUP_PATH" ]]; then
    echo -e "  ${GREEN}✓${RESET} Real transcoder backed up"
else
    echo -e "  ${RED}✗${RESET} Real transcoder backup missing"
    ISSUES=$((ISSUES + 1))
fi

# Log dir writable?
if [[ -w "$LOG_BASE" ]]; then
    echo -e "  ${GREEN}✓${RESET} Log directory writable"
else
    echo -e "  ${RED}✗${RESET} Log directory not writable"
    ISSUES=$((ISSUES + 1))
fi

# Cartridge home in place?
if [[ -f "${CARTRIDGE_HOME}/plex_cartridge.sh" ]]; then
    echo -e "  ${GREEN}✓${RESET} Cartridge home intact"
else
    echo -e "  ${RED}✗${RESET} Cartridge home missing files"
    ISSUES=$((ISSUES + 1))
fi

# --- Done --------------------------------------------------------------------
echo ""
if [[ $ISSUES -eq 0 ]]; then
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${GREEN}║${RESET}  ${BOLD}CARTRIDGE v3 INSTALLED — REMOTE GPU READY${RESET}                  ${GREEN}║${RESET}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${RESET}"
else
    echo -e "${YELLOW}╔═══════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${YELLOW}║${RESET}  ${BOLD}INSTALLED WITH ${ISSUES} WARNING(S)${RESET}                               ${YELLOW}║${RESET}"
    echo -e "${YELLOW}╚═══════════════════════════════════════════════════════════════╝${RESET}"
fi

echo ""
echo -e "  ${BOLD}What's new in v3:${RESET}"
echo ""
echo -e "  🖥️  ${BOLD}Remote GPU Transcoding${RESET}"
if [[ -n "$REMOTE_WORKER_URL" ]]; then
    echo "     Worker: ${REMOTE_WORKER_URL}"
    echo "     Transcode jobs are dispatched to your GPU worker over HTTP."
    echo "     Falls back to local transcoding if worker is unavailable."
else
    echo "     Not configured — using local transcoding."
    echo "     To enable: sudo ./install.sh --worker http://192.168.1.100:8765"
fi
echo ""
echo -e "  🛡️  ${BOLD}Plex updates can't kill it${RESET}"
echo "     The watchdog detects when Plex overwrites the transcoder"
echo "     and re-installs the cartridge within 30 seconds."
echo ""
echo -e "  🔄  ${BOLD}Self-updating${RESET}"
if [[ "$UPDATE_REPO" != "local" ]]; then
    echo "     Pulls updates from: ${UPDATE_REPO}"
    echo "     Checks every hour. Falls back safely on failure."
else
    echo "     Currently set to local mode (no remote updates)."
    echo "     To enable: sudo ./install.sh --repo https://github.com/you/plex-remote-gpu"
fi
echo ""
echo -e "  ${BOLD}Quick commands:${RESET}"
echo ""
echo -e "    ${CYAN}sudo ${CARTRIDGE_HOME}/analyze.sh${RESET}                    # See captured data"
echo -e "    ${CYAN}sudo ${CARTRIDGE_HOME}/analyze.sh --remote-feasibility${RESET} # Can I go remote?"
echo -e "    ${CYAN}sudo ${CARTRIDGE_HOME}/watchdog.sh --once${RESET}             # Manual health check"
echo -e "    ${CYAN}sudo ${CARTRIDGE_HOME}/uninstall.sh${RESET}                   # Eject cartridge"
echo -e "    ${CYAN}cat ${LOG_BASE}/cartridge_events.log${RESET}       # Event history"
echo -e "    ${CYAN}cat ${LOG_BASE}/master.log${RESET}                 # One-line per transcode"
echo ""
echo -e "  ${DIM}Cartridge home: ${CARTRIDGE_HOME}${RESET}"
echo -e "  ${DIM}Logs: ${LOG_BASE}${RESET}"
echo -e "  ${DIM}No Plex restart needed.${RESET}"
echo ""
