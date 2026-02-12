#!/usr/bin/with-contenv bash
# ============================================================================
# PlexBeam Cartridge — Docker Container Init
# ============================================================================
# Runs every container start via /custom-cont-init.d/. Installs the cartridge
# non-interactively using environment variables.
#
# S6 execution order in linuxserver/plex:
#   init-plex-update → this script → svc-plex starts
# So Plex binaries are already in place when we run.
#
# Strategy:
#   The watchdog's reinstall_cartridge() only bakes 3 of 6 placeholders
#   (__REAL_TRANSCODER_PATH__, __CARTRIDGE_HOME__, __UPDATE_REPO__).
#   We create a pre-baked template at CARTRIDGE_HOME/cartridge.sh with
#   the 3 Docker env vars already filled. When the watchdog reads this after
#   a Plex update, it fills the remaining 3 path placeholders — all 6 resolved.
#
# Required env vars:
#   PLEXBEAM_WORKER_URL       - Remote GPU worker URL
#   PLEXBEAM_API_KEY          - API key for worker auth
#   PLEXBEAM_SHARED_SEGMENT_DIR - Shared segment directory (optional)
# ============================================================================

echo "========================================="
echo "  PlexBeam Cartridge — Docker Init"
echo "========================================="

# --- Configuration -----------------------------------------------------------
CARTRIDGE_HOME="/opt/plex-cartridge"
LOG_BASE="/var/log/plex-cartridge"
TRANSCODER_DIR="/usr/lib/plexmediaserver"
TRANSCODER_PATH="${TRANSCODER_DIR}/Plex Transcoder"
BACKUP_PATH="${TRANSCODER_PATH}.real"

WORKER_URL="${PLEXBEAM_WORKER_URL:-}"
API_KEY="${PLEXBEAM_API_KEY:-}"
SHARED_DIR="${PLEXBEAM_SHARED_SEGMENT_DIR:-}"
UPDATE_REPO="${PLEXBEAM_UPDATE_REPO:-local}"

# --- Validate ----------------------------------------------------------------
if [[ ! -d "$TRANSCODER_DIR" ]]; then
    echo "[!] ERROR: Plex directory not found at ${TRANSCODER_DIR}"
    echo "    Is this running inside the linuxserver/plex image?"
    exit 1
fi

if [[ ! -f "$TRANSCODER_PATH" ]] && [[ ! -f "$BACKUP_PATH" ]]; then
    echo "[!] ERROR: No Plex Transcoder binary found"
    echo "    Plex may not have been initialized yet"
    exit 1
fi

# --- Ensure directories -----------------------------------------------------
echo "[*] Setting up directories..."
mkdir -p "${LOG_BASE}/sessions"
mkdir -p "${CARTRIDGE_HOME}"

# --- Back up real transcoder (idempotent) ------------------------------------
echo "[*] Checking Plex Transcoder binary..."

if [[ -f "$BACKUP_PATH" ]] && file "$BACKUP_PATH" 2>/dev/null | grep -qiE "ELF"; then
    echo "[+] Existing backup valid: ${BACKUP_PATH}"
elif [[ -f "$TRANSCODER_PATH" ]] && file "$TRANSCODER_PATH" 2>/dev/null | grep -qiE "ELF"; then
    cp -p "$TRANSCODER_PATH" "$BACKUP_PATH"
    echo "[+] Backed up real transcoder to: ${BACKUP_PATH}"
elif [[ -f "$TRANSCODER_PATH" ]] && grep -q "PLEXBEAM CARTRIDGE" "$TRANSCODER_PATH" 2>/dev/null; then
    echo "[+] Cartridge already in place (previous run)"
    if [[ ! -f "$BACKUP_PATH" ]]; then
        echo "[!] ERROR: Cartridge installed but no backup binary found"
        exit 1
    fi
else
    echo "[!] ERROR: Cannot identify Plex Transcoder at ${TRANSCODER_PATH}"
    exit 1
fi

# --- Fingerprint the real binary ---------------------------------------------
echo "[*] Fingerprinting Plex binary..."
FINGERPRINT=$(md5sum "$BACKUP_PATH" 2>/dev/null | awk '{print $1}' || echo "unknown")
PLEX_VERSION=$(strings "$BACKUP_PATH" 2>/dev/null | grep -oP '^\d+\.\d+\.\d+\.\d+-[0-9a-f]+' | head -1 || echo "unknown")
echo "[+] Plex version: ${PLEX_VERSION}"
echo "[+] Binary fingerprint: ${FINGERPRINT}"

echo "$FINGERPRINT" > "${LOG_BASE}/.binary_fingerprint"
echo "$(date -Iseconds)|${PLEX_VERSION}|${FINGERPRINT}" >> "${LOG_BASE}/.plex_version_history"

# --- Pre-bake template with Docker env vars ----------------------------------
# The .orig file is the pristine template from the image build.
# We bake the 4 Docker env vars into CARTRIDGE_HOME/cartridge.sh so that
# when the watchdog's reinstall_cartridge() runs, it only needs to fill the
# 3 path placeholders (__REAL_TRANSCODER_PATH__, __CARTRIDGE_HOME__, __UPDATE_REPO__).

TEMPLATE="${CARTRIDGE_HOME}/cartridge.sh.orig"
PREBAKED="${CARTRIDGE_HOME}/cartridge.sh"

if [[ ! -f "$TEMPLATE" ]]; then
    echo "[!] ERROR: Pristine template not found at ${TEMPLATE}"
    exit 1
fi

echo "[*] Baking Docker env vars into cartridge template..."
sed \
    -e "s|__SERVER_TYPE__|plex|g" \
    -e "s|__REMOTE_WORKER_URL__|${WORKER_URL}|g" \
    -e "s|__REMOTE_API_KEY__|${API_KEY}|g" \
    -e "s|__SHARED_SEGMENT_DIR__|${SHARED_DIR}|g" \
    "$TEMPLATE" > "$PREBAKED"

chmod +x "$PREBAKED"
echo "[+] Pre-baked template ready (path placeholders remain for watchdog)"

# --- Install fully-baked cartridge as the active transcoder ------------------
echo "[*] Installing cartridge as active transcoder..."
sed \
    -e "s|__SERVER_TYPE__|plex|g" \
    -e "s|__REAL_TRANSCODER_PATH__|${BACKUP_PATH}|g" \
    -e "s|__CARTRIDGE_HOME__|${CARTRIDGE_HOME}|g" \
    -e "s|__UPDATE_REPO__|${UPDATE_REPO}|g" \
    -e "s|__REMOTE_WORKER_URL__|${WORKER_URL}|g" \
    -e "s|__REMOTE_API_KEY__|${API_KEY}|g" \
    -e "s|__SHARED_SEGMENT_DIR__|${SHARED_DIR}|g" \
    "$TEMPLATE" > "$TRANSCODER_PATH"

chmod 755 "$TRANSCODER_PATH"
echo "[+] Cartridge installed at: ${TRANSCODER_PATH}"

# --- Write install metadata (source'd by watchdog.sh:86) --------------------
echo "[*] Writing install metadata..."
cat > "${LOG_BASE}/.install_meta" << 'METAEOF'
INSTALL_DATE="__DATE__"
SERVER_TYPE="plex"
TRANSCODER_PATH="__TRANSCODER_PATH__"
BACKUP_PATH="__BACKUP_PATH__"
PLEX_USER="abc"
CARTRIDGE_HOME="__CARTRIDGE_HOME__"
CARTRIDGE_VERSION="3.1.0"
UPDATE_REPO="__UPDATE_REPO__"
PLEX_VERSION="__PLEX_VERSION__"
REMOTE_WORKER_URL="__WORKER_URL__"
REMOTE_API_KEY="__API_KEY__"
SHARED_SEGMENT_DIR="__SHARED_DIR__"
METAEOF
# Fill in actual values (sed is safer than heredoc expansion for paths with spaces)
sed -i \
    -e "s|__DATE__|$(date -Iseconds)|" \
    -e "s|__TRANSCODER_PATH__|${TRANSCODER_PATH}|" \
    -e "s|__BACKUP_PATH__|${BACKUP_PATH}|" \
    -e "s|__CARTRIDGE_HOME__|${CARTRIDGE_HOME}|" \
    -e "s|__UPDATE_REPO__|${UPDATE_REPO}|" \
    -e "s|__PLEX_VERSION__|${PLEX_VERSION}|" \
    -e "s|__WORKER_URL__|${WORKER_URL}|" \
    -e "s|__API_KEY__|${API_KEY}|" \
    -e "s|__SHARED_DIR__|${SHARED_DIR}|" \
    "${LOG_BASE}/.install_meta"

echo "[+] Metadata written to: ${LOG_BASE}/.install_meta"

# --- Set ownership (linuxserver uses abc:abc) --------------------------------
echo "[*] Setting file ownership..."
chown -R abc:abc "${LOG_BASE}" 2>/dev/null || true
chown -R abc:abc "${CARTRIDGE_HOME}" 2>/dev/null || true
chown abc:abc "$TRANSCODER_PATH" 2>/dev/null || true

# --- Verify ------------------------------------------------------------------
echo "[*] Verifying installation..."
ISSUES=0

if grep -q "PLEXBEAM CARTRIDGE" "$TRANSCODER_PATH" 2>/dev/null; then
    echo "[+] Cartridge in transcoder slot"
else
    echo "[!] Cartridge NOT in place"
    ISSUES=$((ISSUES + 1))
fi

if [[ -x "$BACKUP_PATH" ]]; then
    echo "[+] Real transcoder backed up"
else
    echo "[!] Real transcoder backup missing"
    ISSUES=$((ISSUES + 1))
fi

if [[ -f "${LOG_BASE}/.install_meta" ]]; then
    echo "[+] Install metadata present"
else
    echo "[!] Install metadata missing"
    ISSUES=$((ISSUES + 1))
fi

echo ""
if [[ $ISSUES -eq 0 ]]; then
    echo "========================================="
    echo "  PlexBeam Cartridge — READY"
    echo "========================================="
    if [[ -n "$WORKER_URL" ]]; then
        echo "  Worker: ${WORKER_URL}"
    else
        echo "  Mode: local transcoding only"
    fi
    echo ""
else
    echo "========================================="
    echo "  PlexBeam Cartridge — ${ISSUES} ISSUE(S)"
    echo "========================================="
    echo ""
fi
