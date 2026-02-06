#!/usr/bin/env bash
# ============================================================================
# PLEX CARTRIDGE v3.0 — Remote GPU Transcoding with Self-Healing
# ============================================================================
# Slots into Plex's transcoder binary location. Captures transcode requests
# and dispatches them to a remote GPU worker via HTTP API.
#
# FEATURES:
#   • Survives Plex updates (watchdog detects & re-installs automatically)
#   • Remote GPU dispatch via HTTP API (cross-platform support)
#   • Fallback to local transcoding if worker unavailable
#   • Learns argument patterns from captured sessions
#   • Checksums the real binary to detect Plex version changes
#
# This file is the TEMPLATE. install.sh bakes in paths at install time.
# ============================================================================

set -euo pipefail

# --- Configuration (baked in by install.sh) ----------------------------------
CARTRIDGE_VERSION="3.0.0"
REAL_TRANSCODER="__REAL_TRANSCODER_PATH__"
CARTRIDGE_HOME="__CARTRIDGE_HOME__"
LOG_BASE="/var/log/plex-cartridge"
UPDATE_REPO="__UPDATE_REPO__"

# Remote GPU Worker Settings
REMOTE_WORKER_URL="__REMOTE_WORKER_URL__"
REMOTE_API_KEY="__REMOTE_API_KEY__"
REMOTE_TIMEOUT=5                    # Seconds to wait for worker response
FALLBACK_TO_LOCAL=true              # If true, use local transcoder on failure
SHARED_SEGMENT_DIR="__SHARED_SEGMENT_DIR__"  # Where worker writes segments

# --- Runtime vars ------------------------------------------------------------
SESSION_ID="$(date +%Y%m%d_%H%M%S)_$$"
SESSION_DIR="${LOG_BASE}/sessions/${SESSION_ID}"

# --- Logging helper ----------------------------------------------------------
log_event() {
    local level="$1"
    shift
    echo "$(date -Iseconds) | ${level} | $*" >> "${LOG_BASE}/cartridge_events.log"
}

# --- Self-heal check: is the real transcoder still there? --------------------
if [[ ! -x "$REAL_TRANSCODER" ]]; then
    TRANSCODER_DIR="$(dirname "$REAL_TRANSCODER")"
    POSSIBLE_NEW=""

    for candidate in \
        "${TRANSCODER_DIR}/Plex Transcoder.real" \
        "${TRANSCODER_DIR}/Plex Transcoder.backup" \
        "${TRANSCODER_DIR}/../Plex Transcoder"; do
        if [[ -x "$candidate" ]] && file "$candidate" 2>/dev/null | grep -qiE "ELF|Mach-O"; then
            POSSIBLE_NEW="$candidate"
            break
        fi
    done

    if [[ -n "$POSSIBLE_NEW" ]]; then
        REAL_TRANSCODER="$POSSIBLE_NEW"
        log_event "SELF-HEAL" "Found real transcoder at: $POSSIBLE_NEW"
    else
        echo "CARTRIDGE FATAL: Real transcoder not found. Run: sudo ${CARTRIDGE_HOME}/install.sh" >&2
        log_event "FATAL" "Real transcoder missing: $REAL_TRANSCODER"
        exit 1
    fi
fi

# --- Version fingerprint check -----------------------------------------------
FINGERPRINT_FILE="${LOG_BASE}/.binary_fingerprint"
CURRENT_FINGERPRINT=$(md5sum "$REAL_TRANSCODER" 2>/dev/null | awk '{print $1}' || shasum "$REAL_TRANSCODER" 2>/dev/null | awk '{print $1}' || echo "unknown")

if [[ -f "$FINGERPRINT_FILE" ]]; then
    STORED_FINGERPRINT=$(cat "$FINGERPRINT_FILE")
    if [[ "$CURRENT_FINGERPRINT" != "$STORED_FINGERPRINT" ]] && [[ "$CURRENT_FINGERPRINT" != "unknown" ]]; then
        log_event "PLEX-UPDATE" "Binary changed: ${STORED_FINGERPRINT} → ${CURRENT_FINGERPRINT}"
        echo "$CURRENT_FINGERPRINT" > "$FINGERPRINT_FILE"

        PLEX_VERSION=$(strings "$REAL_TRANSCODER" 2>/dev/null | grep -oP '^\d+\.\d+\.\d+\.\d+-[0-9a-f]+' | head -1 || echo "unknown")
        log_event "PLEX-VERSION" "${PLEX_VERSION}"
    fi
fi

# --- Create session directory ------------------------------------------------
mkdir -p "$SESSION_DIR"

# --- Parse arguments to extract key info -------------------------------------
INPUT_FILE=""
OUTPUT_TARGET=""
VIDEO_CODEC_OUT=""
AUDIO_CODEC=""
SEGMENT_TYPE=""
HW_ACCEL=""
SUBTITLE_MODE=""
BITRATE=""
RESOLUTION=""
SEGMENT_DURATION="4"
TRANSCODE_TYPE="unknown"
TONE_MAP=""
SEEK_POSITION=""
SESSION_TOKEN=""
OUTPUT_DIR=""

PREV_ARG=""
declare -a RAW_ARGS=()

for arg in "$@"; do
    RAW_ARGS+=("$arg")

    case "$PREV_ARG" in
        -i)
            INPUT_FILE="$arg"
            ;;
        -codec:0|-c:v|-vcodec)
            VIDEO_CODEC_OUT="$arg"
            ;;
        -codec:1|-c:a|-acodec|-codec:#*)
            AUDIO_CODEC="$arg"
            ;;
        -maxrate:0|-b:v)
            BITRATE="$arg"
            ;;
        -segment_time|-hls_time)
            SEGMENT_DURATION="$arg"
            if [[ "$PREV_ARG" == "-hls_time" ]]; then
                SEGMENT_TYPE="hls"
            fi
            ;;
        -ss)
            SEEK_POSITION="$arg"
            ;;
    esac

    case "$arg" in
        -hwaccel|*vaapi*|*nvdec*|*cuda*|*qsv*|*videotoolbox*)
            HW_ACCEL="$arg"
            ;;
        *filter_complex*|*scale*|*overlay*|*subtitles*|*ass=*|*sub2video*)
            if [[ "$arg" == *subtitle* ]] || [[ "$arg" == *ass=* ]] || [[ "$arg" == *sub2video* ]]; then
                SUBTITLE_MODE="burn-in"
            fi
            ;;
        *tonemap*|*zscale*|*libplacebo*)
            TONE_MAP="$arg"
            ;;
        *720*|*1080*|*480*|*2160*|*4[kK]*)
            RESOLUTION="$arg"
            ;;
        *.m3u8)
            TRANSCODE_TYPE="hls"
            OUTPUT_TARGET="$arg"
            OUTPUT_DIR="$(dirname "$arg")"
            ;;
        *.mpd)
            TRANSCODE_TYPE="dash"
            OUTPUT_TARGET="$arg"
            OUTPUT_DIR="$(dirname "$arg")"
            ;;
        *Transcode/Sessions*)
            if [[ -z "$OUTPUT_DIR" ]]; then
                OUTPUT_DIR="$(dirname "$arg")"
            fi
            ;;
    esac

    PREV_ARG="$arg"
done

# Last argument is typically the output
[[ -z "$OUTPUT_TARGET" ]] && OUTPUT_TARGET="${!#}"

# --- Capture session info ----------------------------------------------------
{
    echo "═══════════════════════════════════════════════════════════════"
    echo "  PLEX CARTRIDGE v${CARTRIDGE_VERSION} — Session ${SESSION_ID}"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    echo "TIMESTAMP:      $(date -Iseconds)"
    echo "INPUT:          ${INPUT_FILE:-unknown}"
    echo "OUTPUT:         ${OUTPUT_TARGET:-unknown}"
    echo "VIDEO_CODEC:    ${VIDEO_CODEC_OUT:-passthrough}"
    echo "AUDIO_CODEC:    ${AUDIO_CODEC:-passthrough}"
    echo "BITRATE:        ${BITRATE:-default}"
    echo "RESOLUTION:     ${RESOLUTION:-source}"
    echo "HW_ACCEL:       ${HW_ACCEL:-none}"
    echo "SUBTITLES:      ${SUBTITLE_MODE:-none}"
    echo "TONE_MAP:       ${TONE_MAP:-none}"
    echo "TYPE:           ${TRANSCODE_TYPE}"
    echo "REMOTE_WORKER:  ${REMOTE_WORKER_URL:-none}"
    echo ""
    echo "ARGC: $#"
    echo ""
    ARG_NUM=0
    for arg in "$@"; do
        printf "  argv[%3d] = %s\n" "$ARG_NUM" "$arg"
        ARG_NUM=$((ARG_NUM + 1))
    done
} > "${SESSION_DIR}/00_session.log"

# --- Remote dispatch function ------------------------------------------------
dispatch_to_remote_worker() {
    local worker_url="${REMOTE_WORKER_URL}"

    if [[ -z "$worker_url" ]] || [[ "$worker_url" == __* ]]; then
        return 1  # No worker configured
    fi

    # Check worker health
    local health_check
    health_check=$(curl -sf --connect-timeout 2 "${worker_url}/health" 2>/dev/null || echo "")

    if [[ -z "$health_check" ]]; then
        log_event "REMOTE" "Worker not reachable: ${worker_url}"
        return 1
    fi

    log_event "REMOTE" "Dispatching job ${SESSION_ID} to ${worker_url}"

    # Build job JSON
    local job_json
    job_json=$(cat << JOBEOF
{
    "job_id": "${SESSION_ID}",
    "input": {
        "type": "file",
        "path": "${INPUT_FILE}"
    },
    "output": {
        "type": "${TRANSCODE_TYPE}",
        "path": "${OUTPUT_DIR}",
        "segment_duration": ${SEGMENT_DURATION}
    },
    "arguments": {
        "video_codec": "${VIDEO_CODEC_OUT:-h264}",
        "audio_codec": "${AUDIO_CODEC:-aac}",
        "video_bitrate": "${BITRATE:-}",
        "resolution": "${RESOLUTION:-}",
        "seek": ${SEEK_POSITION:-null},
        "tone_mapping": $([ -n "$TONE_MAP" ] && echo "true" || echo "false"),
        "subtitle": {
            "mode": "${SUBTITLE_MODE:-none}"
        },
        "raw_args": $(printf '%s\n' "${RAW_ARGS[@]}" | jq -R . | jq -s .)
    },
    "metadata": {
        "cartridge_version": "${CARTRIDGE_VERSION}",
        "plex_session": "${SESSION_ID}"
    }
}
JOBEOF
)

    echo "$job_json" > "${SESSION_DIR}/01_job_request.json"

    # Build curl headers
    local curl_args=(-sf -X POST)
    curl_args+=(-H "Content-Type: application/json")

    if [[ -n "$REMOTE_API_KEY" ]] && [[ "$REMOTE_API_KEY" != "__REMOTE_API_KEY__" ]]; then
        curl_args+=(-H "X-API-Key: ${REMOTE_API_KEY}")
    fi

    curl_args+=(--connect-timeout "$REMOTE_TIMEOUT")
    curl_args+=(--max-time 30)
    curl_args+=(-d "$job_json")
    curl_args+=("${worker_url}/transcode")

    # Submit job
    local response
    response=$(curl "${curl_args[@]}" 2>/dev/null || echo "")

    if [[ -z "$response" ]]; then
        log_event "REMOTE" "Failed to submit job to worker"
        return 1
    fi

    echo "$response" > "${SESSION_DIR}/02_job_response.json"

    local job_status
    job_status=$(echo "$response" | grep -o '"status":"[^"]*"' | cut -d'"' -f4 || echo "")

    if [[ "$job_status" == "queued" ]] || [[ "$job_status" == "running" ]]; then
        log_event "REMOTE" "Job ${SESSION_ID} submitted successfully (status: ${job_status})"

        # Poll for completion
        local poll_count=0
        local max_polls=7200  # 2 hours at 1 second intervals

        while [[ $poll_count -lt $max_polls ]]; do
            sleep 1
            poll_count=$((poll_count + 1))

            local status_response
            status_response=$(curl -sf --connect-timeout 2 "${worker_url}/status/${SESSION_ID}" 2>/dev/null || echo "")

            if [[ -n "$status_response" ]]; then
                job_status=$(echo "$status_response" | grep -o '"status":"[^"]*"' | cut -d'"' -f4 || echo "")

                case "$job_status" in
                    completed)
                        log_event "REMOTE" "Job ${SESSION_ID} completed successfully"
                        echo "$status_response" > "${SESSION_DIR}/03_job_completed.json"
                        return 0
                        ;;
                    failed)
                        local error_msg
                        error_msg=$(echo "$status_response" | grep -o '"error":"[^"]*"' | cut -d'"' -f4 || echo "unknown")
                        log_event "REMOTE" "Job ${SESSION_ID} failed: ${error_msg}"
                        echo "$status_response" > "${SESSION_DIR}/03_job_failed.json"
                        return 1
                        ;;
                    cancelled)
                        log_event "REMOTE" "Job ${SESSION_ID} was cancelled"
                        return 1
                        ;;
                esac

                # Log progress periodically
                if [[ $((poll_count % 30)) -eq 0 ]]; then
                    local progress
                    progress=$(echo "$status_response" | grep -o '"progress":[0-9.]*' | cut -d':' -f2 || echo "0")
                    log_event "REMOTE" "Job ${SESSION_ID} progress: ${progress}%"
                fi
            fi
        done

        log_event "REMOTE" "Job ${SESSION_ID} timed out after ${max_polls} seconds"
        return 1
    else
        log_event "REMOTE" "Job submission failed with status: ${job_status}"
        return 1
    fi
}

# --- Main execution logic ----------------------------------------------------
TRANSCODE_START=$(date +%s%N)
USE_REMOTE=false
REMOTE_SUCCESS=false

# Try remote dispatch first if configured and video transcoding is needed
# Skip remote for video copy (direct stream) — segments must stay on Plex's filesystem
if [[ -n "$REMOTE_WORKER_URL" ]] && [[ "$REMOTE_WORKER_URL" != __* ]] && [[ "$VIDEO_CODEC_OUT" != "copy" ]] && [[ -n "$VIDEO_CODEC_OUT" ]]; then
    USE_REMOTE=true

    {
        echo "═══════════════════════════════════════════════════════════════"
        echo "  REMOTE DISPATCH"
        echo "═══════════════════════════════════════════════════════════════"
        echo ""
        echo "Worker URL:  ${REMOTE_WORKER_URL}"
        echo "Started:     $(date -Iseconds)"
    } >> "${SESSION_DIR}/00_session.log"

    if dispatch_to_remote_worker; then
        REMOTE_SUCCESS=true
        EXIT_CODE=0

        {
            echo "Result:      SUCCESS (remote)"
            echo "Finished:    $(date -Iseconds)"
        } >> "${SESSION_DIR}/00_session.log"
    else
        {
            echo "Result:      FAILED (remote)"
            echo "Fallback:    ${FALLBACK_TO_LOCAL}"
        } >> "${SESSION_DIR}/00_session.log"

        if [[ "$FALLBACK_TO_LOCAL" != "true" ]]; then
            log_event "REMOTE" "Remote failed and fallback disabled — exiting"
            exit 1
        fi

        log_event "REMOTE" "Remote failed — falling back to local transcoder"
    fi
fi

# Fall back to local transcoder if needed
if [[ "$USE_REMOTE" == "false" ]] || [[ "$REMOTE_SUCCESS" == "false" ]]; then
    {
        echo ""
        echo "═══════════════════════════════════════════════════════════════"
        echo "  LOCAL TRANSCODER EXECUTION"
        echo "═══════════════════════════════════════════════════════════════"
        echo ""
        echo "Started:  $(date -Iseconds)"
        echo "Binary:   ${REAL_TRANSCODER}"
    } >> "${SESSION_DIR}/00_session.log"

    "$REAL_TRANSCODER" "$@" 2> >(tee "${SESSION_DIR}/stderr.log" >&2)
    EXIT_CODE=$?

    {
        echo "Finished: $(date -Iseconds)"
        echo "Exit:     ${EXIT_CODE}"
    } >> "${SESSION_DIR}/00_session.log"
fi

TRANSCODE_END=$(date +%s%N)
DURATION_MS=$(( (TRANSCODE_END - TRANSCODE_START) / 1000000 ))

# --- Write session summary ---------------------------------------------------
{
    echo ""
    echo "┌─────────────────────────────────────────────────────────────┐"
    echo "│  SESSION SUMMARY: ${SESSION_ID}"
    echo "├─────────────────────────────────────────────────────────────┤"
    echo "│  Duration:   ${DURATION_MS}ms"
    echo "│  Exit Code:  ${EXIT_CODE}"
    echo "│  Mode:       $([ "$REMOTE_SUCCESS" == "true" ] && echo "REMOTE" || echo "LOCAL")"
    echo "│  Input:      ${INPUT_FILE:-unknown}"
    echo "│  Video Out:  ${VIDEO_CODEC_OUT:-passthrough}"
    echo "│  Type:       ${TRANSCODE_TYPE}"
    echo "│  Cartridge:  v${CARTRIDGE_VERSION}"
    echo "└─────────────────────────────────────────────────────────────┘"
} > "${SESSION_DIR}/SUMMARY.log"

# --- Append to master log ----------------------------------------------------
printf "%s | exit=%d | dur=%dms | mode=%s | codec=%s | type=%s | input=%s\n" \
    "$(date -Iseconds)" \
    "$EXIT_CODE" \
    "$DURATION_MS" \
    "$([ "$REMOTE_SUCCESS" == "true" ] && echo "remote" || echo "local")" \
    "${VIDEO_CODEC_OUT:-pass}" \
    "${TRANSCODE_TYPE}" \
    "$(basename "${INPUT_FILE:-unknown}")" \
    >> "${LOG_BASE}/master.log"

exit $EXIT_CODE
