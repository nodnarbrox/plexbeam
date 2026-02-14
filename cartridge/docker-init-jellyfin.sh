#!/usr/bin/with-contenv bash
# ============================================================================
# PlexBeam Cartridge — Jellyfin Docker Container Init
# ============================================================================
# Runs every container start via /custom-cont-init.d/. Bakes the cartridge
# shim and configures Jellyfin to use it as its ffmpeg path.
#
# Strategy:
#   1. Find jellyfin-ffmpeg binary
#   2. Bake all 7 placeholders into the cartridge template
#   3. Write active shim to /opt/plexbeam/cartridge-active.sh
#   4. Update encoding.xml <EncoderAppPath> to point at the shim
#
# Required env vars:
#   PLEXBEAM_WORKER_URL       - Remote GPU worker URL
#   PLEXBEAM_API_KEY          - API key for worker auth
#   PLEXBEAM_SHARED_SEGMENT_DIR - Shared segment directory (optional)
# ============================================================================

echo "========================================="
echo "  PlexBeam Cartridge — Jellyfin Init"
echo "========================================="

# --- Configuration -----------------------------------------------------------
CARTRIDGE_HOME="/opt/plexbeam"
LOG_BASE="/var/log/plexbeam"

WORKER_URL="${PLEXBEAM_WORKER_URL:-}"
API_KEY="${PLEXBEAM_API_KEY:-}"
SHARED_DIR="${PLEXBEAM_SHARED_SEGMENT_DIR:-}"
UPDATE_REPO="${PLEXBEAM_UPDATE_REPO:-local}"
CALLBACK_URL="${PLEXBEAM_CALLBACK_URL:-}"
WORKER_POOL="${PLEXBEAM_WORKER_POOL:-}"

# --- Find jellyfin-ffmpeg ----------------------------------------------------
JELLYFIN_FFMPEG=""
for candidate in \
    /usr/lib/jellyfin-ffmpeg/ffmpeg \
    /usr/bin/ffmpeg; do
    if [[ -x "$candidate" ]]; then
        JELLYFIN_FFMPEG="$candidate"
        break
    fi
done

if [[ -z "$JELLYFIN_FFMPEG" ]]; then
    echo "[!] ERROR: Cannot find jellyfin-ffmpeg"
    exit 1
fi

echo "[+] Jellyfin ffmpeg: ${JELLYFIN_FFMPEG}"

# --- Ensure directories -----------------------------------------------------
echo "[*] Setting up directories..."
mkdir -p "${LOG_BASE}/sessions"
mkdir -p "${CARTRIDGE_HOME}"

# --- Back up real ffmpeg and replace with shim -------------------------------
# Jellyfin 10.11+ uses the --ffmpeg CLI arg (hardcoded by linuxserver image),
# which takes precedence over encoding.xml EncoderAppPath. So we must replace
# the actual binary — same strategy as the Plex cartridge.
REAL_FFMPEG="${JELLYFIN_FFMPEG}.real"
if [[ -x "$JELLYFIN_FFMPEG" ]] && ! grep -q "PLEXBEAM" "$JELLYFIN_FFMPEG" 2>/dev/null; then
    # It's a real binary, back it up
    cp -p "$JELLYFIN_FFMPEG" "$REAL_FFMPEG"
    echo "[+] Backed up real ffmpeg to: ${REAL_FFMPEG}"
elif [[ -x "$REAL_FFMPEG" ]]; then
    echo "[+] Real ffmpeg backup already exists: ${REAL_FFMPEG}"
else
    echo "[!] ERROR: Cannot find real ffmpeg to back up"
    exit 1
fi

# --- Bake cartridge shim -----------------------------------------------------
TEMPLATE="${CARTRIDGE_HOME}/cartridge.sh.orig"
SHIM_PATH="${CARTRIDGE_HOME}/cartridge-active.sh"

if [[ ! -f "$TEMPLATE" ]]; then
    echo "[!] ERROR: Pristine template not found at ${TEMPLATE}"
    exit 1
fi

echo "[*] Baking all placeholders into cartridge shim..."
# REAL_TRANSCODER points to the .real backup so the cartridge can fall back
sed \
    -e "s|__SERVER_TYPE__|jellyfin|g" \
    -e "s|__REAL_TRANSCODER_PATH__|${REAL_FFMPEG}|g" \
    -e "s|__CARTRIDGE_HOME__|${CARTRIDGE_HOME}|g" \
    -e "s|__UPDATE_REPO__|${UPDATE_REPO}|g" \
    -e "s|__REMOTE_WORKER_URL__|${WORKER_URL}|g" \
    -e "s|__REMOTE_API_KEY__|${API_KEY}|g" \
    -e "s|__SHARED_SEGMENT_DIR__|${SHARED_DIR}|g" \
    -e "s|__CALLBACK_URL__|${CALLBACK_URL}|g" \
    -e "s|__WORKER_POOL__|${WORKER_POOL}|g" \
    "$TEMPLATE" > "$SHIM_PATH"

chmod 755 "$SHIM_PATH"
echo "[+] Shim installed at: ${SHIM_PATH}"

# Replace the real ffmpeg binary with our shim
cp "$SHIM_PATH" "$JELLYFIN_FFMPEG"
chmod 755 "$JELLYFIN_FFMPEG"
echo "[+] Replaced ${JELLYFIN_FFMPEG} with cartridge shim"

# --- Update encoding.xml ----------------------------------------------------
# Jellyfin stores config in /config (linuxserver mount) or /etc/jellyfin
ENCODING_XML=""
for candidate in \
    /config/encoding.xml \
    /config/data/encoding.xml \
    /etc/jellyfin/encoding.xml; do
    if [[ -f "$candidate" ]]; then
        ENCODING_XML="$candidate"
        break
    fi
done

if [[ -n "$ENCODING_XML" ]]; then
    echo "[*] Updating encoding.xml: ${ENCODING_XML}"
    # Back up
    cp -p "$ENCODING_XML" "${ENCODING_XML}.plexbeam-backup" 2>/dev/null || true

    if grep -q "<EncoderAppPath>" "$ENCODING_XML" 2>/dev/null; then
        sed -i "s|<EncoderAppPath>[^<]*</EncoderAppPath>|<EncoderAppPath>${SHIM_PATH}</EncoderAppPath>|" "$ENCODING_XML"
    else
        # Insert EncoderAppPath before closing </EncodingOptions> or </ServerConfiguration>
        if grep -q "</EncodingOptions>" "$ENCODING_XML" 2>/dev/null; then
            sed -i "s|</EncodingOptions>|  <EncoderAppPath>${SHIM_PATH}</EncoderAppPath>\n</EncodingOptions>|" "$ENCODING_XML"
        fi
    fi
    echo "[+] encoding.xml updated"
else
    echo "[*] encoding.xml not found (first run — Jellyfin will create it)"
    echo "[*] Set FFmpeg path in Dashboard → Playback: ${SHIM_PATH}"

    # Try to create a minimal encoding.xml for first run
    ENCODING_DIR="/config"
    if [[ -d "$ENCODING_DIR" ]]; then
        cat > "${ENCODING_DIR}/encoding.xml" << XMLEOF
<?xml version="1.0" encoding="utf-8"?>
<EncodingOptions xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
  <EncoderAppPath>${SHIM_PATH}</EncoderAppPath>
  <EncoderAppPathDisplay>${SHIM_PATH}</EncoderAppPathDisplay>
</EncodingOptions>
XMLEOF
        chown abc:abc "${ENCODING_DIR}/encoding.xml" 2>/dev/null || true
        echo "[+] Created encoding.xml with shim path"
    fi
fi

# Ensure encoding.xml is owned by Jellyfin user (linuxserver runs as abc)
if [[ -n "${ENCODING_XML:-}" ]]; then
    chown abc:abc "$ENCODING_XML" 2>/dev/null || true
    chown abc:abc "${ENCODING_XML}.plexbeam-backup" 2>/dev/null || true
fi

# --- Write install metadata -------------------------------------------------
echo "[*] Writing install metadata..."
cat > "${LOG_BASE}/.install_meta" << 'METAEOF'
INSTALL_DATE="__DATE__"
SERVER_TYPE="jellyfin"
TRANSCODER_PATH="__FFMPEG_PATH__"
BACKUP_PATH="__FFMPEG_PATH__"
PLEX_USER="abc"
CARTRIDGE_HOME="__CARTRIDGE_HOME__"
CARTRIDGE_VERSION="3.1.0"
UPDATE_REPO="__UPDATE_REPO__"
PLEX_VERSION="n/a"
REMOTE_WORKER_URL="__WORKER_URL__"
REMOTE_API_KEY="__API_KEY__"
SHARED_SEGMENT_DIR="__SHARED_DIR__"
CALLBACK_URL="__CALLBACK_URL__"
WORKER_POOL="__WORKER_POOL__"
METAEOF
sed -i \
    -e "s|__DATE__|$(date -Iseconds)|" \
    -e "s|__FFMPEG_PATH__|${JELLYFIN_FFMPEG}|g" \
    -e "s|__CARTRIDGE_HOME__|${CARTRIDGE_HOME}|" \
    -e "s|__UPDATE_REPO__|${UPDATE_REPO}|" \
    -e "s|__WORKER_URL__|${WORKER_URL}|" \
    -e "s|__API_KEY__|${API_KEY}|" \
    -e "s|__SHARED_DIR__|${SHARED_DIR}|" \
    -e "s|__CALLBACK_URL__|${CALLBACK_URL}|" \
    -e "s|__WORKER_POOL__|${WORKER_POOL}|" \
    "${LOG_BASE}/.install_meta"

echo "[+] Metadata written to: ${LOG_BASE}/.install_meta"

# --- Set ownership (linuxserver uses abc:abc) --------------------------------
echo "[*] Setting file ownership..."
chown -R abc:abc "${LOG_BASE}" 2>/dev/null || true
chown -R abc:abc "${CARTRIDGE_HOME}" 2>/dev/null || true

# --- Verify ------------------------------------------------------------------
echo "[*] Verifying installation..."
ISSUES=0

if [[ -x "$SHIM_PATH" ]] && grep -q "PLEXBEAM CARTRIDGE" "$SHIM_PATH" 2>/dev/null; then
    echo "[+] Cartridge shim installed"
else
    echo "[!] Cartridge shim missing or invalid"
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
    echo "  PlexBeam Cartridge — JELLYFIN READY"
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
