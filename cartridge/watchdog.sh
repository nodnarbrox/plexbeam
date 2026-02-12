#!/usr/bin/env bash
# ============================================================================
# PLEXBEAM CARTRIDGE — Watchdog Daemon (Plex only)
# ============================================================================
# Monitors the Plex transcoder binary. When Plex updates overwrite the
# cartridge, the watchdog detects it and re-installs automatically.
#
# Also handles:
#   • Checking for cartridge updates (GitHub or local)
#   • Pruning old session logs (keeps disk usage sane)
#   • Health checks on the cartridge pipeline
#
# Runs as a systemd service or standalone background process.
#
# Usage:
#   ./watchdog.sh                  # Run in foreground (for testing)
#   ./watchdog.sh --daemon         # Fork to background
#   ./watchdog.sh --once           # Single check then exit
# ============================================================================

set -euo pipefail

# --- Configuration -----------------------------------------------------------
LOG_BASE="/var/log/plex-cartridge"
EVENTS_LOG="${LOG_BASE}/cartridge_events.log"
WATCHDOG_LOG="${LOG_BASE}/watchdog.log"
META_FILE="${LOG_BASE}/.install_meta"
FINGERPRINT_FILE="${LOG_BASE}/.binary_fingerprint"
PID_FILE="${LOG_BASE}/.watchdog.pid"

# Timing
CHECK_INTERVAL=30          # Seconds between binary checks
UPDATE_CHECK_INTERVAL=3600 # Seconds between update checks (1 hour)
LOG_PRUNE_DAYS=30          # Delete session logs older than this
LOG_PRUNE_INTERVAL=86400   # Prune check every 24 hours

# Thresholds
MAX_LOG_SIZE_MB=500        # Warn if logs exceed this

# --- Parse args ---------------------------------------------------------------
DAEMON_MODE=false
ONCE_MODE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --daemon|-d) DAEMON_MODE=true; shift ;;
        --once) ONCE_MODE=true; shift ;;
        --stop)
            if [[ -f "$PID_FILE" ]]; then
                kill "$(cat "$PID_FILE")" 2>/dev/null && echo "Watchdog stopped." || echo "Not running."
                rm -f "$PID_FILE"
            else
                echo "No PID file found."
            fi
            exit 0
            ;;
        -h|--help)
            echo "Usage: ./watchdog.sh [--daemon|--once|--stop]"
            echo ""
            echo "  --daemon    Fork to background"
            echo "  --once      Single check then exit"
            echo "  --stop      Stop running watchdog"
            exit 0
            ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

# --- Logging helper -----------------------------------------------------------
log() {
    local level="$1"
    shift
    local msg="$(date -Iseconds) | WATCHDOG | ${level} | $*"
    echo "$msg" >> "$WATCHDOG_LOG"
    if [[ "$DAEMON_MODE" == false ]]; then
        echo "$msg"
    fi
}

# --- Check prerequisites -----------------------------------------------------
if [[ ! -f "$META_FILE" ]]; then
    echo "ERROR: Cartridge not installed. Run install.sh first."
    exit 1
fi

source "$META_FILE"

# Validate required vars from meta
: "${TRANSCODER_PATH:?META missing TRANSCODER_PATH}"
: "${BACKUP_PATH:?META missing BACKUP_PATH}"
: "${CARTRIDGE_HOME:?META missing CARTRIDGE_HOME}"

# --- Daemon mode: fork --------------------------------------------------------
if [[ "$DAEMON_MODE" == true ]]; then
    # Check for existing watchdog
    if [[ -f "$PID_FILE" ]]; then
        OLD_PID=$(cat "$PID_FILE")
        if kill -0 "$OLD_PID" 2>/dev/null; then
            echo "Watchdog already running (PID $OLD_PID)"
            exit 0
        fi
    fi
    
    # Fork
    nohup "$0" </dev/null >> "$WATCHDOG_LOG" 2>&1 &
    CHILD_PID=$!
    echo "$CHILD_PID" > "$PID_FILE"
    echo "Watchdog started (PID $CHILD_PID)"
    echo "Log: $WATCHDOG_LOG"
    exit 0
fi

# Write PID for non-daemon mode too
echo $$ > "$PID_FILE"
trap 'rm -f "$PID_FILE"' EXIT

log "INFO" "Watchdog starting (PID $$)"
log "INFO" "Monitoring: ${TRANSCODER_PATH}"
log "INFO" "Cartridge home: ${CARTRIDGE_HOME}"

# --- Core: Check if cartridge is still in place -------------------------------
check_cartridge_installed() {
    # The transcoder path should be a shell script (our cartridge), not an ELF binary
    if [[ ! -f "$TRANSCODER_PATH" ]]; then
        log "ALERT" "Transcoder binary MISSING at ${TRANSCODER_PATH}"
        return 1
    fi
    
    # Check if it's our cartridge or the real binary
    # Note: Only check for ELF/Mach-O, not "executable" (shell scripts also show as executable)
    if file "$TRANSCODER_PATH" 2>/dev/null | grep -qiE "ELF|Mach-O"; then
        # It's a binary — Plex overwrote us!
        log "ALERT" "Plex overwrote cartridge with new binary!"
        return 1
    fi
    
    # Check if it contains our signature
    if grep -q "PLEXBEAM CARTRIDGE" "$TRANSCODER_PATH" 2>/dev/null; then
        return 0  # Cartridge is in place
    else
        log "ALERT" "Transcoder exists but isn't our cartridge"
        return 1
    fi
}

# --- Core: Re-install cartridge after Plex update ----------------------------
reinstall_cartridge() {
    log "INFO" "Re-installing cartridge..."
    
    # The file at TRANSCODER_PATH is now Plex's new binary
    # Back it up as the new .real
    if file "$TRANSCODER_PATH" 2>/dev/null | grep -qiE "ELF|Mach-O|executable"; then
        # New binary from Plex — update our backup
        local NEW_FINGERPRINT=$(md5sum "$TRANSCODER_PATH" 2>/dev/null | awk '{print $1}' || echo "unknown")
        local OLD_FINGERPRINT=$(cat "$FINGERPRINT_FILE" 2>/dev/null || echo "none")
        
        log "INFO" "New Plex binary detected: ${OLD_FINGERPRINT} → ${NEW_FINGERPRINT}"
        
        # Detect Plex version from new binary
        local PLEX_VER=$(strings "$TRANSCODER_PATH" 2>/dev/null | grep -oP '^\d+\.\d+\.\d+\.\d+-[0-9a-f]+' | head -1 || echo "unknown")
        log "INFO" "New Plex version: ${PLEX_VER}"
        
        # Back up the new binary
        cp -p "$TRANSCODER_PATH" "$BACKUP_PATH"
        log "INFO" "Backed up new binary to: ${BACKUP_PATH}"
        
        # Update fingerprint
        echo "$NEW_FINGERPRINT" > "$FINGERPRINT_FILE"
        
        # Record version history
        echo "$(date -Iseconds)|${PLEX_VER}|${NEW_FINGERPRINT}" >> "${LOG_BASE}/.plex_version_history"
    fi
    
    # Install the cartridge
    local CARTRIDGE_SRC="${CARTRIDGE_HOME}/cartridge.sh"
    if [[ ! -f "$CARTRIDGE_SRC" ]]; then
        log "ERROR" "Cartridge source not found at: ${CARTRIDGE_SRC}"
        return 1
    fi
    
    # Bake in the paths
    sed \
        -e "s|__REAL_TRANSCODER_PATH__|${BACKUP_PATH}|g" \
        -e "s|__CARTRIDGE_HOME__|${CARTRIDGE_HOME}|g" \
        -e "s|__UPDATE_REPO__|${UPDATE_REPO:-local}|g" \
        "$CARTRIDGE_SRC" > "$TRANSCODER_PATH"
    
    chmod 755 "$TRANSCODER_PATH"
    chown "${PLEX_USER:-plex}:${PLEX_USER:-plex}" "$TRANSCODER_PATH" 2>/dev/null || true
    
    # Verify
    if grep -q "PLEXBEAM CARTRIDGE" "$TRANSCODER_PATH" 2>/dev/null; then
        log "INFO" "Cartridge re-installed successfully"
        echo "$(date -Iseconds) | REINSTALL | success | Plex binary backed up and cartridge restored" >> "$EVENTS_LOG"
        return 0
    else
        log "ERROR" "Re-install verification failed!"
        return 1
    fi
}

# --- Core: Check for cartridge updates ----------------------------------------
check_for_updates() {
    local UPDATE_REPO="${UPDATE_REPO:-}"
    
    if [[ -z "$UPDATE_REPO" ]] || [[ "$UPDATE_REPO" == "local" ]]; then
        return 0  # No remote updates configured
    fi
    
    log "INFO" "Checking for cartridge updates..."
    
    # Determine update source
    local REMOTE_VERSION_URL=""
    local REMOTE_ARCHIVE_URL=""
    
    if [[ "$UPDATE_REPO" == *"github.com"* ]]; then
        # GitHub repo — check releases API
        local REPO_PATH=$(echo "$UPDATE_REPO" | sed 's|.*github.com/||' | sed 's|\.git$||')
        REMOTE_VERSION_URL="https://api.github.com/repos/${REPO_PATH}/releases/latest"
        
        if command -v curl &>/dev/null; then
            local RESPONSE=$(curl -sf --connect-timeout 10 "$REMOTE_VERSION_URL" 2>/dev/null || echo "")
            if [[ -n "$RESPONSE" ]]; then
                local REMOTE_VERSION=$(echo "$RESPONSE" | grep -oP '"tag_name":\s*"v?\K[^"]+' | head -1 || echo "")
                local LOCAL_VERSION=$(grep "^CARTRIDGE_VERSION=" "${CARTRIDGE_HOME}/cartridge.sh" 2>/dev/null | cut -d'"' -f2 || echo "0.0.0")
                
                if [[ -n "$REMOTE_VERSION" ]] && [[ "$REMOTE_VERSION" != "$LOCAL_VERSION" ]]; then
                    log "UPDATE" "New version available: ${LOCAL_VERSION} → ${REMOTE_VERSION}"
                    echo "$(date -Iseconds) | UPDATE-AVAILABLE | ${LOCAL_VERSION} → ${REMOTE_VERSION}" >> "$EVENTS_LOG"
                    
                    # Download the tarball
                    local DOWNLOAD_URL=$(echo "$RESPONSE" | grep -oP '"tarball_url":\s*"\K[^"]+' | head -1 || echo "")
                    if [[ -n "$DOWNLOAD_URL" ]]; then
                        local TMP_DIR=$(mktemp -d)
                        if curl -sfL --connect-timeout 30 "$DOWNLOAD_URL" | tar xz -C "$TMP_DIR" --strip-components=1 2>/dev/null; then
                            # Validate the download has our expected files
                            if [[ -f "${TMP_DIR}/cartridge.sh" ]] && grep -q "PLEXBEAM CARTRIDGE" "${TMP_DIR}/cartridge.sh"; then
                                # Back up current version
                                cp -r "${CARTRIDGE_HOME}" "${CARTRIDGE_HOME}.backup.$(date +%Y%m%d)" 2>/dev/null || true
                                
                                # Copy new files (preserve install meta)
                                for f in cartridge.sh analyze.sh install.sh uninstall.sh watchdog.sh; do
                                    if [[ -f "${TMP_DIR}/${f}" ]]; then
                                        cp "${TMP_DIR}/${f}" "${CARTRIDGE_HOME}/${f}"
                                        chmod +x "${CARTRIDGE_HOME}/${f}"
                                    fi
                                done
                                
                                log "UPDATE" "Updated to v${REMOTE_VERSION}"
                                echo "$(date -Iseconds) | UPDATED | v${REMOTE_VERSION}" >> "$EVENTS_LOG"
                                
                                # Re-install cartridge with new version
                                reinstall_cartridge
                            else
                                log "WARN" "Downloaded update failed validation — skipping"
                            fi
                        else
                            log "WARN" "Failed to download update from ${DOWNLOAD_URL}"
                        fi
                        rm -rf "$TMP_DIR"
                    fi
                else
                    log "INFO" "Cartridge is up to date (v${LOCAL_VERSION})"
                fi
            else
                log "WARN" "Could not reach update server"
            fi
        else
            log "WARN" "curl not available — cannot check for updates"
        fi
    elif [[ -d "$UPDATE_REPO" ]]; then
        # Local directory — just copy if newer
        if [[ -f "${UPDATE_REPO}/cartridge.sh" ]]; then
            local REMOTE_VERSION=$(grep "^CARTRIDGE_VERSION=" "${UPDATE_REPO}/cartridge.sh" | cut -d'"' -f2 || echo "0.0.0")
            local LOCAL_VERSION=$(grep "^CARTRIDGE_VERSION=" "${CARTRIDGE_HOME}/cartridge.sh" | cut -d'"' -f2 || echo "0.0.0")
            
            if [[ "$REMOTE_VERSION" != "$LOCAL_VERSION" ]]; then
                log "UPDATE" "Local update: ${LOCAL_VERSION} → ${REMOTE_VERSION}"
                for f in cartridge.sh analyze.sh install.sh uninstall.sh watchdog.sh; do
                    [[ -f "${UPDATE_REPO}/${f}" ]] && cp "${UPDATE_REPO}/${f}" "${CARTRIDGE_HOME}/${f}" && chmod +x "${CARTRIDGE_HOME}/${f}"
                done
                reinstall_cartridge
            fi
        fi
    fi
}

# --- Core: Prune old logs -----------------------------------------------------
prune_old_logs() {
    local SESSIONS_DIR="${LOG_BASE}/sessions"
    if [[ ! -d "$SESSIONS_DIR" ]]; then
        return 0
    fi
    
    local BEFORE_COUNT=$(ls -d "${SESSIONS_DIR}"/*/ 2>/dev/null | wc -l)
    
    # Delete sessions older than LOG_PRUNE_DAYS
    find "$SESSIONS_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +${LOG_PRUNE_DAYS} -exec rm -rf {} + 2>/dev/null || true
    
    local AFTER_COUNT=$(ls -d "${SESSIONS_DIR}"/*/ 2>/dev/null | wc -l)
    local PRUNED=$((BEFORE_COUNT - AFTER_COUNT))
    
    if [[ $PRUNED -gt 0 ]]; then
        log "PRUNE" "Removed ${PRUNED} sessions older than ${LOG_PRUNE_DAYS} days"
    fi
    
    # Check total log size
    local LOG_SIZE_KB=$(du -sk "$LOG_BASE" 2>/dev/null | awk '{print $1}' || echo 0)
    local LOG_SIZE_MB=$((LOG_SIZE_KB / 1024))
    
    if [[ $LOG_SIZE_MB -gt $MAX_LOG_SIZE_MB ]]; then
        log "WARN" "Log directory is ${LOG_SIZE_MB}MB (threshold: ${MAX_LOG_SIZE_MB}MB)"
        echo "$(date -Iseconds) | DISK-WARN | Logs at ${LOG_SIZE_MB}MB" >> "$EVENTS_LOG"
    fi
}

# --- Core: Health check -------------------------------------------------------
health_check() {
    local issues=0
    
    # Check cartridge is in place
    if ! check_cartridge_installed; then
        issues=$((issues + 1))
    fi
    
    # Check real binary exists
    if [[ ! -x "$BACKUP_PATH" ]]; then
        log "HEALTH" "Real transcoder missing at: $BACKUP_PATH"
        issues=$((issues + 1))
    fi
    
    # Check log directory is writable
    if [[ ! -w "$LOG_BASE" ]]; then
        log "HEALTH" "Log directory not writable: $LOG_BASE"
        issues=$((issues + 1))
    fi
    
    # Check cartridge source exists
    if [[ ! -f "${CARTRIDGE_HOME}/cartridge.sh" ]]; then
        log "HEALTH" "Cartridge source missing from: ${CARTRIDGE_HOME}"
        issues=$((issues + 1))
    fi
    
    if [[ $issues -eq 0 ]]; then
        log "HEALTH" "All checks passed"
    else
        log "HEALTH" "${issues} issue(s) detected"
    fi
    
    return $issues
}

# --- Single check mode --------------------------------------------------------
if [[ "$ONCE_MODE" == true ]]; then
    echo "Running single check..."
    
    if ! check_cartridge_installed; then
        echo "Cartridge not in place — reinstalling..."
        reinstall_cartridge
    else
        echo "Cartridge is in place."
    fi
    
    health_check
    prune_old_logs
    check_for_updates
    
    echo "Done."
    exit 0
fi

# --- Main loop ----------------------------------------------------------------
log "INFO" "Entering main loop (interval: ${CHECK_INTERVAL}s)"

LAST_UPDATE_CHECK=0
LAST_PRUNE_CHECK=0

while true; do
    NOW=$(date +%s)
    
    # 1. Check if cartridge is still in place
    if ! check_cartridge_installed; then
        log "ALERT" "Cartridge displaced — attempting reinstall"
        if reinstall_cartridge; then
            log "INFO" "Auto-reinstall successful"
        else
            log "ERROR" "Auto-reinstall FAILED — manual intervention needed"
            # Don't spam — wait longer before retrying
            sleep 300
        fi
    fi
    
    # 2. Periodic update check
    if [[ $((NOW - LAST_UPDATE_CHECK)) -ge $UPDATE_CHECK_INTERVAL ]]; then
        check_for_updates
        LAST_UPDATE_CHECK=$NOW
    fi
    
    # 3. Periodic log pruning
    if [[ $((NOW - LAST_PRUNE_CHECK)) -ge $LOG_PRUNE_INTERVAL ]]; then
        prune_old_logs
        LAST_PRUNE_CHECK=$NOW
    fi
    
    sleep "$CHECK_INTERVAL"
done
