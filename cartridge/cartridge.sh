#!/usr/bin/env bash
# ============================================================================
# PLEXBEAM CARTRIDGE v3.1 — Remote GPU Transcoding (Plex + Jellyfin)
# ============================================================================
# Universal cartridge that works with both Plex and Jellyfin. Captures
# transcode requests and dispatches them to a remote GPU worker via HTTP API.
#
# FEATURES:
#   • Plex: Survives updates (watchdog detects & re-installs automatically)
#   • Jellyfin: Shim script pointed to by encoding.xml (no binary replace)
#   • Remote GPU dispatch via HTTP API (cross-platform support)
#   • Fallback to local transcoding if worker unavailable
#   • Learns argument patterns from captured sessions
#
# This file is the TEMPLATE. install.sh bakes in paths at install time.
# ============================================================================

set -euo pipefail

# --- Configuration (baked in by install.sh) ----------------------------------
CARTRIDGE_VERSION="3.1.0"
SERVER_TYPE="__SERVER_TYPE__"
REAL_TRANSCODER="__REAL_TRANSCODER_PATH__"
CARTRIDGE_HOME="__CARTRIDGE_HOME__"
UPDATE_REPO="__UPDATE_REPO__"

# Log dir depends on server type
if [[ "$SERVER_TYPE" == "jellyfin" ]]; then
    LOG_BASE="/var/log/plexbeam"
else
    LOG_BASE="/var/log/plex-cartridge"
fi

# Remote GPU Worker Settings
REMOTE_WORKER_URL="__REMOTE_WORKER_URL__"
REMOTE_API_KEY="__REMOTE_API_KEY__"
REMOTE_TIMEOUT=5                    # Seconds to wait for worker response
FALLBACK_TO_LOCAL=true              # If true, use local transcoder on failure
SHARED_SEGMENT_DIR="__SHARED_SEGMENT_DIR__"  # Where worker writes segments
CALLBACK_URL="__CALLBACK_URL__"     # URL for worker to reach media server (beam mode manifest callbacks)

# --- Runtime vars ------------------------------------------------------------
SESSION_ID="$(date +%Y%m%d_%H%M%S)_$$"
SESSION_DIR="${LOG_BASE}/sessions/${SESSION_ID}"
DISPATCHED_TO_REMOTE=false
STREAM_PID=""
declare -A BEAM_DOWNLOADED=()  # Track which beam segments we've already downloaded
MANIFEST_CALLBACK_URL=""       # Plex's -manifest_name callback URL (for registering DASH manifest)
LAST_MANIFEST_HASH=""          # Track manifest changes for re-posting
BEAM_MANIFEST_POSTED=false     # Track whether initial manifest has been posted (gate on segments existing)
PROGRESS_URL=""                # Plex's -progressurl callback (keeps session alive)

# --- Cleanup trap: cancel worker job when cartridge is killed ----------------
_cleanup_remote() {
    # Kill ALL background jobs (segment downloads, streaming curl, etc.)
    jobs -p 2>/dev/null | xargs -r kill 2>/dev/null || true
    if [[ -n "${STREAM_PID:-}" ]]; then
        kill "$STREAM_PID" 2>/dev/null || true
    fi
    if [[ "$DISPATCHED_TO_REMOTE" == "true" ]] && [[ -n "${REMOTE_WORKER_URL:-}" ]]; then
        curl -sf -X DELETE "${REMOTE_WORKER_URL}/job/${SESSION_ID}" &>/dev/null || true
    fi
}
trap _cleanup_remote EXIT

# --- Logging helper ----------------------------------------------------------
log_event() {
    local level="$1"
    shift
    echo "$(date -Iseconds) | ${level} | $*" >> "${LOG_BASE}/cartridge_events.log"
}

# --- Self-heal check (Plex only): is the real transcoder still there? --------
# Jellyfin doesn't replace a binary, so no self-heal needed.
if [[ "$SERVER_TYPE" == "plex" ]]; then
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

    # --- Version fingerprint check (Plex only) --------------------------------
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
        -codec:0|-codec:v:0|-c:v|-c:v:0|-vcodec)
            VIDEO_CODEC_OUT="$arg"
            ;;
        -codec:1|-codec:a:0|-c:a|-c:a:0|-acodec|-codec:#*)
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
        -manifest_name)
            MANIFEST_CALLBACK_URL="$arg"
            ;;
        -progressurl)
            PROGRESS_URL="$arg"
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

# Resolve relative output paths to absolute so the remote worker knows where
# to write segments.  Plex sets CWD to its transcode session directory and
# passes a relative path like "dash".  Without this, the worker writes to its
# own working directory and Plex never sees the segments.
if [[ -n "$OUTPUT_TARGET" ]] && [[ "$OUTPUT_TARGET" != /* ]] && [[ "$OUTPUT_TARGET" != http* ]]; then
    OUTPUT_TARGET="$(pwd)/$OUTPUT_TARGET"
    # Update the last raw_arg to the absolute path
    RAW_ARGS[-1]="$OUTPUT_TARGET"
    OUTPUT_DIR="$(dirname "$OUTPUT_TARGET")"
fi

# --- Capture session info ----------------------------------------------------
{
    echo "═══════════════════════════════════════════════════════════════"
    echo "  PLEXBEAM CARTRIDGE v${CARTRIDGE_VERSION} — Session ${SESSION_ID}"
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

# --- Beam segment download helper --------------------------------------------
beam_download_segments() {
    local worker_url="$1"
    local target_dir="$2"

    # List available segments from worker
    local seg_list
    seg_list=$(curl -sf --connect-timeout 2 "${worker_url}/beam/segments/${SESSION_ID}" 2>/dev/null || echo "")

    if [[ -z "$seg_list" ]] || [[ "$seg_list" == '{"files":[]}' ]]; then
        return
    fi

    # Parse segment filenames from JSON using jq
    local seg_files
    seg_files=$(echo "$seg_list" | jq -r '.files[]' 2>/dev/null) || return

    # Separate into: manifest (always re-download), init, and media segments
    local manifest_segs=()
    local init_segs=()
    local media_segs=()
    for seg in $seg_files; do
        if [[ "$seg" == *.mpd ]] || [[ "$seg" == *.m3u8 ]]; then
            # Always re-download manifest (it updates as new segments appear)
            manifest_segs+=("$seg")
        elif [[ -z "${BEAM_DOWNLOADED[$seg]:-}" ]]; then
            if [[ "$seg" == init-* ]]; then
                init_segs+=("$seg")
            else
                media_segs+=("$seg")
            fi
        fi
    done

    # Sort media segments by segment NUMBER across streams so audio (stream1)
    # and video (stream0) are interleaved: 0-00001, 1-00001, 0-00002, 1-00002...
    # Without this, all stream0 segments download before any stream1, causing
    # audio to lag far behind video.
    if [[ ${#media_segs[@]} -gt 0 ]]; then
        local sorted_segs
        sorted_segs=$(printf '%s\n' "${media_segs[@]}" | sort -t'-' -k3,3n -k2,2)
        media_segs=()
        while IFS= read -r seg; do
            media_segs+=("$seg")
        done <<< "$sorted_segs"
    fi

    # Download manifest synchronously (small file, needed for POST below)
    for seg in "${manifest_segs[@]}"; do
        curl -sf --connect-timeout 2 --max-time 3 \
            "${worker_url}/beam/segment/${SESSION_ID}/${seg}" \
            -o "${target_dir}/${seg}" 2>/dev/null || true
    done

    # Download init segments SYNCHRONOUSLY (small files, must exist before manifest POST)
    for seg in "${init_segs[@]}"; do
        curl -sf "${worker_url}/beam/segment/${SESSION_ID}/${seg}" \
            -o "${target_dir}/${seg}" 2>/dev/null || true
        BEAM_DOWNLOADED[$seg]=1
    done

    # Download media segments.
    # Before initial manifest POST: download synchronously so files exist when Plex
    # tells the client about them. After manifest posted: background (non-blocking).
    local started=0
    for seg in "${media_segs[@]}"; do
        if [[ $started -ge 8 ]]; then
            break  # Download more on next poll cycle
        fi
        if [[ "$BEAM_MANIFEST_POSTED" == "false" ]]; then
            # Synchronous: ensure segments exist on disk before we POST manifest
            curl -sf "${worker_url}/beam/segment/${SESSION_ID}/${seg}" \
                -o "${target_dir}/${seg}" 2>/dev/null || true
        else
            # Background: manifest already posted, don't block the poll loop
            curl -sf "${worker_url}/beam/segment/${SESSION_ID}/${seg}" \
                -o "${target_dir}/${seg}" 2>/dev/null &
        fi
        BEAM_DOWNLOADED[$seg]=1
        started=$((started + 1))
    done

    # POST manifest to Plex's callback URL.
    # CRITICAL: Only post AFTER init + media segments exist on disk.
    # If we post early, Plex tells the client "segments ready" but files are 404.
    if [[ -n "${MANIFEST_CALLBACK_URL:-}" ]] && [[ -f "${target_dir}/output.mpd" ]]; then
        local should_post=false

        if [[ "$BEAM_MANIFEST_POSTED" == "false" ]]; then
            # First POST: gate on init + media segments existing in target dir
            local has_init=false has_media=false
            for f in "${target_dir}"/init-stream*.m4s; do
                [[ -f "$f" ]] && has_init=true && break
            done
            for f in "${target_dir}"/chunk-stream*.m4s; do
                [[ -f "$f" ]] && has_media=true && break
            done
            if [[ "$has_init" == "true" ]] && [[ "$has_media" == "true" ]]; then
                should_post=true
            fi
        else
            # Subsequent POSTs: manifest already registered, just update if changed
            should_post=true
        fi

        if [[ "$should_post" == "true" ]]; then
            local manifest_hash
            manifest_hash=$(md5sum "${target_dir}/output.mpd" 2>/dev/null | cut -d' ' -f1)
            if [[ "${manifest_hash}" != "${LAST_MANIFEST_HASH:-}" ]]; then
                curl -sf -X POST \
                    -H "Content-Type: application/dash+xml" \
                    --data-binary @"${target_dir}/output.mpd" \
                    "${MANIFEST_CALLBACK_URL}" 2>/dev/null || true
                LAST_MANIFEST_HASH="${manifest_hash}"
                if [[ "$BEAM_MANIFEST_POSTED" == "false" ]]; then
                    log_event "BEAM" "Initial manifest posted (init + media segments ready in ${target_dir})"
                    BEAM_MANIFEST_POSTED=true
                fi
            fi
        fi
    fi
}

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

    # Build job JSON (beam_stream=true: worker won't enqueue, waits for /beam/stream)
    local use_beam_stream=false
    if [[ -n "$INPUT_FILE" ]] && [[ -f "$INPUT_FILE" ]]; then
        use_beam_stream=true
    fi

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
    "source": "${SERVER_TYPE}",
    "beam_stream": ${use_beam_stream},
    "callback_url": $(if [[ -n "$CALLBACK_URL" ]] && [[ "$CALLBACK_URL" != "__CALLBACK_URL__" ]]; then echo "\"${CALLBACK_URL}\""; else echo "null"; fi),
    "metadata": {
        "cartridge_version": "${CARTRIDGE_VERSION}",
        "session_id": "${SESSION_ID}"
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

    if [[ "$job_status" == "queued" ]] || [[ "$job_status" == "running" ]] || [[ "$job_status" == "pending" ]]; then
        DISPATCHED_TO_REMOTE=true
        log_event "REMOTE" "Job ${SESSION_ID} submitted successfully (status: ${job_status})"

        # Start streaming input file to worker in background (beam mode)
        if [[ "$use_beam_stream" == "true" ]]; then
            # Throttle upload to leave bandwidth for segment downloads.
            # On WiFi (~16 Mbps), limiting upload to 1M leaves ~1 MB/s for downloads.
            # Set PLEXBEAM_UPLOAD_RATE=0 to disable throttling (e.g., wired Ethernet).
            local upload_rate="${PLEXBEAM_UPLOAD_RATE:-0}"
            log_event "BEAM" "Streaming input: ${INPUT_FILE} (upload_rate=${upload_rate})"
            curl -sf -X POST \
                --connect-timeout "$REMOTE_TIMEOUT" \
                --max-time 7200 \
                --limit-rate "$upload_rate" \
                -T "$INPUT_FILE" \
                "${worker_url}/beam/stream/${SESSION_ID}" \
                > "${SESSION_DIR}/01_beam_stream.json" 2>/dev/null &
            STREAM_PID=$!
        fi

        # Poll for completion (0.25s interval for faster segment detection)
        local poll_count=0
        local max_polls=28800  # 2 hours at 0.25 second intervals

        while [[ $poll_count -lt $max_polls ]]; do
            sleep 0.25
            poll_count=$((poll_count + 1))

            local status_response
            status_response=$(curl -sf --connect-timeout 2 "${worker_url}/status/${SESSION_ID}" 2>/dev/null || echo "")

            if [[ -n "$status_response" ]]; then
                job_status=$(echo "$status_response" | grep -o '"status":"[^"]*"' | cut -d'"' -f4 || echo "")

                case "$job_status" in
                    completed)
                        log_event "REMOTE" "Job ${SESSION_ID} completed successfully"
                        echo "$status_response" > "${SESSION_DIR}/03_job_completed.json"
                        # Download any remaining segments from worker
                        if [[ -n "$OUTPUT_DIR" ]]; then
                            beam_download_segments "$worker_url" "$OUTPUT_DIR"
                            log_event "BEAM" "Final segment download: ${#BEAM_DOWNLOADED[@]} files"
                        fi
                        # Wait for streaming curl to finish
                        if [[ -n "${STREAM_PID:-}" ]]; then
                            wait "$STREAM_PID" 2>/dev/null || true
                            STREAM_PID=""
                        fi
                        # Final progress line so media server knows encoding finished
                        printf "frame=9999 fps=0.0 q=-1.0 size=N/A time=99:99:99.99 bitrate=N/A speed=0.0x\n" >&2
                        return 0
                        ;;
                    failed)
                        local error_msg
                        error_msg=$(echo "$status_response" | grep -o '"error":"[^"]*"' | cut -d'"' -f4 || echo "unknown")
                        log_event "REMOTE" "Job ${SESSION_ID} failed: ${error_msg}"
                        echo "$status_response" > "${SESSION_DIR}/03_job_failed.json"
                        if [[ -n "${STREAM_PID:-}" ]]; then
                            kill "$STREAM_PID" 2>/dev/null || true
                            STREAM_PID=""
                        fi
                        return 1
                        ;;
                    cancelled)
                        log_event "REMOTE" "Job ${SESSION_ID} was cancelled"
                        if [[ -n "${STREAM_PID:-}" ]]; then
                            kill "$STREAM_PID" 2>/dev/null || true
                            STREAM_PID=""
                        fi
                        return 1
                        ;;
                    running)
                        # Emit ffmpeg-compatible progress on stderr every ~1s (every 4th poll)
                        if [[ $((poll_count % 4)) -eq 0 ]]; then
                            local p_fps="" p_speed="" p_otms="" p_frame=""
                            p_fps=$(echo "$status_response" | grep -o '"fps":[0-9][0-9.]*' | head -1 | cut -d':' -f2) || true
                            p_speed=$(echo "$status_response" | grep -o '"speed":[0-9][0-9.]*' | head -1 | cut -d':' -f2) || true
                            p_otms=$(echo "$status_response" | grep -o '"out_time_ms":[0-9][0-9]*' | head -1 | cut -d':' -f2) || true
                            p_frame=$(echo "$status_response" | grep -o '"frame":[0-9][0-9]*' | head -1 | cut -d':' -f2) || true
                            : "${p_fps:=0}" "${p_speed:=0}" "${p_otms:=0}" "${p_frame:=0}"

                            # Convert out_time_ms (microseconds despite name) to HH:MM:SS.ff
                            local ts=$((p_otms / 1000000))
                            local time_str
                            time_str=$(printf "%02d:%02d:%02d.%02d" \
                                $((ts / 3600)) $(( (ts % 3600) / 60 )) $((ts % 60)) \
                                $(( (p_otms % 1000000) / 10000 )) )

                            printf "frame=%s fps=%s q=-1.0 size=N/A time=%s bitrate=N/A speed=%sx\n" \
                                "$p_frame" "$p_fps" "$time_str" "$p_speed" >&2

                            # POST progress to Plex's -progressurl callback.
                            # This keeps the transcode session alive — without it,
                            # Plex times out and kills the session after ~60s.
                            # Always POST even with out_time=0 (during seeks) to
                            # prevent Plex from killing us while ffmpeg seeks.
                            if [[ -n "${PROGRESS_URL:-}" ]]; then
                                curl -sf -X POST \
                                    --connect-timeout 1 --max-time 2 \
                                    -d "frame=${p_frame}&fps=${p_fps}&speed=${p_speed}x&out_time_us=${p_otms}&progress=continue" \
                                    "${PROGRESS_URL}" 2>/dev/null &
                            fi
                        fi

                        # Beam mode: download segments progressively as they appear
                        if [[ -n "$OUTPUT_DIR" ]]; then
                            beam_download_segments "$worker_url" "$OUTPUT_DIR"
                        fi
                        ;;
                esac

                # Log progress periodically
                if [[ $((poll_count % 120)) -eq 0 ]]; then
                    local progress
                    progress=$(echo "$status_response" | grep -o '"progress":[0-9.]*' | cut -d':' -f2 || echo "0")
                    log_event "REMOTE" "Job ${SESSION_ID} progress: ${progress}%"
                fi
            fi
        done

        # Wait for streaming curl to finish
        if [[ -n "${STREAM_PID:-}" ]]; then
            wait "$STREAM_PID" 2>/dev/null || true
            STREAM_PID=""
        fi

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

    LOCAL_ARGS=("$@")
    QSV_REWRITE=false

    if [[ "$SERVER_TYPE" == "plex" ]]; then
        # -------------------------------------------------------------------
        # QSV hardware encoding rewrite for Plex local fallback
        # Without Plex Pass, Plex sends libx264/libx265 (CPU encode) + CPU scale.
        # This rewrites the full pipeline to use QSV GPU decode + scale_qsv + encode,
        # so users get hardware transcoding locally without Plex Pass.
        #
        # Also fixes 3 Plex crash bugs:
        #   aac_lc → aac (Plex codec name not in system ffmpeg)
        #   ochl → out_channel_layout (Plex custom audio filter param)
        #   -time_delta stripped (Plex DASH muxer option)
        #
        # Rewrites:
        #   libx264 → h264_qsv, libx265 → hevc_qsv
        #   scale=w=W:h=H → hwupload + scale_qsv=w=W:h=H
        #   -crf N → -global_quality (N+2), clamped 1-51
        #   Removes -preset, -x264opts, -x265-params (not QSV-compatible)
        #   Adds -init_hw_device qsv=hw + -filter_hw_device hw
        # -------------------------------------------------------------------

        if [[ -e /dev/dri/renderD128 ]]; then
            # Check if libx264 or libx265 is in the args (no Plex Pass HW encoding)
            NEEDS_REWRITE=false
            for arg in "${LOCAL_ARGS[@]}"; do
                if [[ "$arg" == "libx264" ]] || [[ "$arg" == "libx265" ]]; then
                    NEEDS_REWRITE=true
                    break
                fi
            done

            if [[ "$NEEDS_REWRITE" == "true" ]]; then
                QSV_REWRITE=true
                declare -a REWRITTEN_ARGS=()
                SKIP_NEXT=false
                CRF_VALUE=""
                CODEC_REWRITES=""

                for i in "${!LOCAL_ARGS[@]}"; do
                    if [[ "$SKIP_NEXT" == "true" ]]; then
                        SKIP_NEXT=false
                        continue
                    fi

                    cur_arg="${LOCAL_ARGS[$i]}"
                    nxt_arg="${LOCAL_ARGS[$((i+1))]:-}"

                    # Replace libx264 → h264_qsv
                    if [[ "$cur_arg" == "libx264" ]]; then
                        REWRITTEN_ARGS+=("h264_qsv")
                        CODEC_REWRITES="${CODEC_REWRITES} libx264→h264_qsv"
                        continue
                    fi

                    # Replace libx265 → hevc_qsv
                    if [[ "$cur_arg" == "libx265" ]]; then
                        REWRITTEN_ARGS+=("hevc_qsv")
                        CODEC_REWRITES="${CODEC_REWRITES} libx265→hevc_qsv"
                        continue
                    fi

                    # Fix aac_lc → aac (Plex codec name not in system ffmpeg)
                    if [[ "$cur_arg" == "aac_lc" ]]; then
                        REWRITTEN_ARGS+=("aac")
                        CODEC_REWRITES="${CODEC_REWRITES} aac_lc→aac"
                        continue
                    fi

                    # Fix ochl → out_chlayout in audio filter_complex values
                    if [[ "$cur_arg" == *"ochl="* ]]; then
                        REWRITTEN_ARGS+=("${cur_arg//ochl=/out_chlayout=}")
                        continue
                    fi

                    # Skip x264/x265-specific options (flag + value pairs)
                    if [[ "$cur_arg" == -x264opts* ]] || [[ "$cur_arg" == -x265-params* ]] || [[ "$cur_arg" == -preset* ]]; then
                        SKIP_NEXT=true
                        CODEC_REWRITES="${CODEC_REWRITES} strip:${cur_arg}"
                        continue
                    fi

                    # Extract CRF value then replace with global_quality (crf + 2)
                    if [[ "$cur_arg" == -crf* ]]; then
                        CRF_VALUE="$nxt_arg"
                        if [[ "$CRF_VALUE" =~ ^[0-9]+$ ]]; then
                            GQ=$((CRF_VALUE + 2))
                            (( GQ < 1 )) && GQ=1
                            (( GQ > 51 )) && GQ=51
                        else
                            GQ=21  # fallback: CRF 19 default → 21
                        fi
                        REWRITTEN_ARGS+=("-global_quality:0")
                        REWRITTEN_ARGS+=("$GQ")
                        SKIP_NEXT=true
                        CODEC_REWRITES="${CODEC_REWRITES} crf:${CRF_VALUE}→gq:${GQ}"
                        continue
                    fi

                    # Replace any existing -init_hw_device with QSV
                    if [[ "$cur_arg" == "-init_hw_device" ]]; then
                        REWRITTEN_ARGS+=("-init_hw_device")
                        REWRITTEN_ARGS+=("qsv=hw")
                        SKIP_NEXT=true
                        continue
                    fi

                    # Replace -filter_hw_device value with QSV device name
                    if [[ "$cur_arg" == "-filter_hw_device" ]]; then
                        REWRITTEN_ARGS+=("-filter_hw_device")
                        REWRITTEN_ARGS+=("hw")
                        SKIP_NEXT=true
                        continue
                    fi

                    # Rewrite video filter_complex: hwupload + scale_qsv pipeline
                    if [[ "$cur_arg" == "-filter_complex" ]] && [[ "$nxt_arg" == *"scale=w="* ]] && [[ "$nxt_arg" == "[0:0]"* ]]; then
                        SCALE_W=$(echo "$nxt_arg" | grep -oP 'scale=w=\K\d+')
                        SCALE_H=$(echo "$nxt_arg" | grep -oP ':h=\K\d+')
                        # Extract output label from original filter (e.g. [1], [vout])
                        FILTER_LABEL=$(echo "$nxt_arg" | grep -oP '\[[^\]]+\]$')
                        [[ -z "$FILTER_LABEL" ]] && FILTER_LABEL="[1]"

                        if [[ -n "$SCALE_W" ]] && [[ -n "$SCALE_H" ]]; then
                            REWRITTEN_ARGS+=("-filter_complex")
                            REWRITTEN_ARGS+=("[0:0]format=nv12,hwupload=extra_hw_frames=64,scale_qsv=w=${SCALE_W}:h=${SCALE_H}${FILTER_LABEL}")
                            SKIP_NEXT=true
                            CODEC_REWRITES="${CODEC_REWRITES} scale→scale_qsv:${SCALE_W}x${SCALE_H}"
                            continue
                        fi
                    fi

                    REWRITTEN_ARGS+=("$cur_arg")
                done

                # Inject -init_hw_device qsv=hw if not already present
                HAS_HW_INIT=false
                for arg in "${REWRITTEN_ARGS[@]}"; do
                    if [[ "$arg" == "-init_hw_device" ]]; then
                        HAS_HW_INIT=true
                        break
                    fi
                done

                if [[ "$HAS_HW_INIT" == "false" ]]; then
                    declare -a FINAL_ARGS=()
                    FINAL_ARGS+=("-init_hw_device" "qsv=hw")
                    FINAL_ARGS+=("-filter_hw_device" "hw")
                    FINAL_ARGS+=("${REWRITTEN_ARGS[@]}")
                    REWRITTEN_ARGS=("${FINAL_ARGS[@]}")
                fi

                # Strip Plex-specific flags that system ffmpeg doesn't understand
                declare -a CLEAN_ARGS=()
                SKIP_NEXT_CLEAN=false
                STRIPPED_FLAGS=""
                for i in "${!REWRITTEN_ARGS[@]}"; do
                    if [[ "$SKIP_NEXT_CLEAN" == "true" ]]; then
                        SKIP_NEXT_CLEAN=false
                        continue
                    fi
                    ca="${REWRITTEN_ARGS[$i]}"
                    # Remove Plex-specific flags (flag + value pairs)
                    if [[ "$ca" == "-loglevel_plex" ]] || [[ "$ca" == "-progressurl" ]] || [[ "$ca" == "-time_delta" ]] || [[ "$ca" == "-delete_removed" ]] || [[ "$ca" == "-skip_to_segment" ]] || [[ "$ca" == "-manifest_name" ]]; then
                        SKIP_NEXT_CLEAN=true
                        STRIPPED_FLAGS="${STRIPPED_FLAGS} ${ca}"
                        continue
                    fi
                    # Strip -loglevel quiet (we inject -loglevel warning instead)
                    if [[ "$ca" == "-loglevel" ]] && [[ "${REWRITTEN_ARGS[$((i+1))]:-}" == "quiet" ]]; then
                        SKIP_NEXT_CLEAN=true
                        STRIPPED_FLAGS="${STRIPPED_FLAGS} -loglevel:quiet"
                        continue
                    fi
                    CLEAN_ARGS+=("$ca")
                done

                # Inject -loglevel warning for better debugging
                declare -a FINAL_CLEAN=("-loglevel" "warning")
                FINAL_CLEAN+=("${CLEAN_ARGS[@]}")

                LOCAL_ARGS=("${FINAL_CLEAN[@]}")
                log_event "LOCAL" "QSV rewrite:${CODEC_REWRITES} | stripped:${STRIPPED_FLAGS} (system ffmpeg)"
            fi
        fi
    fi
    # Jellyfin: no arg rewriting needed — standard ffmpeg args pass through clean

    # Choose local binary
    if [[ "$SERVER_TYPE" == "plex" ]] && [[ "$QSV_REWRITE" == "true" ]] && [[ -x /usr/bin/ffmpeg ]]; then
        # Use system ffmpeg for QSV (Plex's musl libc can't load glibc VA drivers)
        LOCAL_BINARY="/usr/bin/ffmpeg"
    else
        LOCAL_BINARY="$REAL_TRANSCODER"
    fi

    {
        echo ""
        echo "═══════════════════════════════════════════════════════════════"
        echo "  LOCAL TRANSCODER EXECUTION"
        echo "═══════════════════════════════════════════════════════════════"
        echo ""
        echo "Started:  $(date -Iseconds)"
        echo "Binary:   ${LOCAL_BINARY}"
        echo "Server:   ${SERVER_TYPE}"
        echo "QSV:      ${QSV_REWRITE}"
    } >> "${SESSION_DIR}/00_session.log"

    if [[ "$QSV_REWRITE" == "true" ]]; then
        {
            echo "Rewritten args:"
            local_idx=0
            for arg in "${LOCAL_ARGS[@]}"; do
                printf "  argv[%3d] = %s\n" "$local_idx" "$arg"
                local_idx=$((local_idx + 1))
            done
        } >> "${SESSION_DIR}/00_session.log"
    fi

    if [[ "$QSV_REWRITE" == "true" ]]; then
        # System ffmpeg needs LIBVA_DRIVER_NAME to find the correct VA driver
        LIBVA_DRIVER_NAME=iHD LIBVA_DRIVERS_PATH=/usr/lib/x86_64-linux-gnu/dri "$LOCAL_BINARY" "${LOCAL_ARGS[@]}" 2> >(tee "${SESSION_DIR}/stderr.log" >&2)
    else
        "$LOCAL_BINARY" "${LOCAL_ARGS[@]}" 2> >(tee "${SESSION_DIR}/stderr.log" >&2)
    fi
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
