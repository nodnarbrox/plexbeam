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

# Save original args before any modification — used by fast-start transcoder
ORIGINAL_ARGS=("$@")

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
PLEXBEAM_BEAM_DIRECT="${PLEXBEAM_BEAM_DIRECT:-false}"  # Set true for single tunnel worker
REMOTE_API_KEY="__REMOTE_API_KEY__"
REMOTE_TIMEOUT=5                    # Seconds to wait for worker response
FALLBACK_TO_LOCAL=true              # If true, use local transcoder on failure
SHARED_SEGMENT_DIR="__SHARED_SEGMENT_DIR__"  # Where worker writes segments
CALLBACK_URL="__CALLBACK_URL__"     # URL for worker to reach media server (beam mode manifest callbacks)
WORKER_POOL="__WORKER_POOL__"      # Comma-separated worker URLs (@local = disk access, no upload)

# Pull mode: cloud workers (HTTPS) download chunks via S3 pre-signed URLs.
# The S3 pull proxy runs on localhost — cartridge uploads to it, gets back an S3 URL.
# No AWS creds in the cartridge; they live only in the pull proxy process.
PULL_PROXY_URL="${PLEXBEAM_PULL_PROXY_URL:-http://127.0.0.1:8780}"  # S3 pull proxy (localhost)
PULL_DIR="${PLEXBEAM_PULL_DIR:-/tmp/plexbeam-pull}"  # Local staging dir for copy-remux

# Environment overrides (for testing without re-install)
[[ -n "${PLEXBEAM_WORKER_POOL:-}" ]] && WORKER_POOL="$PLEXBEAM_WORKER_POOL"
[[ -n "${PLEXBEAM_REMOTE_WORKER_URL:-}" ]] && REMOTE_WORKER_URL="$PLEXBEAM_REMOTE_WORKER_URL"

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

# Multi-GPU state
declare -a POOL_URLS=()          # Worker URLs from WORKER_POOL
declare -a POOL_TAGS=()          # Tags per worker ("local" or "remote")
declare -a LIVE_WORKERS=()       # URLs that passed health check
declare -a LIVE_TAGS=()          # Tags for live workers
declare -a MULTI_JOB_IDS=()     # Job IDs for each worker (for cleanup)
declare -a MULTI_STREAM_PIDS=() # Background curl PIDs for beam streams

# --- Cleanup trap: cancel worker job when cartridge is killed ----------------
_cleanup_remote() {
    # Kill ALL background jobs (segment downloads, streaming curl, etc.)
    jobs -p 2>/dev/null | xargs -r kill 2>/dev/null || true
    if [[ -n "${STREAM_PID:-}" ]]; then
        kill "$STREAM_PID" 2>/dev/null || true
    fi
    # Cancel multi-GPU worker jobs
    for i in "${!MULTI_JOB_IDS[@]}"; do
        local jid="${MULTI_JOB_IDS[$i]}"
        local wurl="${LIVE_WORKERS[$i]:-}"
        if [[ -n "$jid" ]] && [[ -n "$wurl" ]]; then
            curl -sf -X DELETE "${wurl}/job/${jid}" &>/dev/null || true
        fi
    done
    for pid in "${MULTI_STREAM_PIDS[@]}"; do
        [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    done
    # Single-worker cleanup
    if [[ "$DISPATCHED_TO_REMOTE" == "true" ]] && [[ -n "${REMOTE_WORKER_URL:-}" ]]; then
        curl -sf -X DELETE "${REMOTE_WORKER_URL}/job/${SESSION_ID}" &>/dev/null || true
    fi
    # Clean up S3 pull files via proxy
    if [[ -n "${PULL_PROXY_URL:-}" ]]; then
        curl -sf -X DELETE "${PULL_PROXY_URL}/upload/${SESSION_ID}.mkv" &>/dev/null || true
        for jid in "${MULTI_JOB_IDS[@]}"; do
            curl -sf -X DELETE "${PULL_PROXY_URL}/upload/${jid}.mkv" &>/dev/null || true
        done
    fi
    # Clean up local URL files
    if [[ -d "${PULL_DIR:-}" ]]; then
        rm -f "${PULL_DIR}/${SESSION_ID}"*.url 2>/dev/null || true
        for jid in "${MULTI_JOB_IDS[@]}"; do
            rm -f "${PULL_DIR}/${jid}".url 2>/dev/null || true
        done
    fi
    # Kill staged upload if still running
    if [[ -n "${STAGED_UPLOAD_PID:-}" ]]; then
        kill "$STAGED_UPLOAD_PID" 2>/dev/null || true
    fi
    # Clean up staged file on worker
    if [[ -n "${STAGED_SESSION_ID:-}" ]] && [[ -n "${LIVE_WORKERS[0]:-}" ]]; then
        curl -sf -X DELETE "${LIVE_WORKERS[0]}/beam/stage/${STAGED_SESSION_ID}" &>/dev/null || true
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
SKIP_TO_SEGMENT=0

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
        -skip_to_segment)
            SKIP_TO_SEGMENT="$arg"
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
    echo "WORKER_POOL:    ${WORKER_POOL:-none}"
    echo ""
    echo "ARGC: $#"
    echo ""
    ARG_NUM=0
    for arg in "$@"; do
        printf "  argv[%3d] = %s\n" "$ARG_NUM" "$arg"
        ARG_NUM=$((ARG_NUM + 1))
    done
} > "${SESSION_DIR}/00_session.log"

# --- Parse JSON files list without jq ----------------------------------------
# Input: {"files":["a.m4s","b.m4s",...]}  Output: one file per line
parse_segment_list() {
    echo "$1" | sed 's/.*\[//; s/\].*//' | tr ',' '\n' | tr -d '"' | tr -d ' ' | grep -v '^$'
}

# --- Build JSON array from bash array (no jq dependency) --------------------
# Usage: json_array "${arr[@]}" → ["val1","val2","val3"]
json_array() {
    local result="["
    local first=true
    for item in "$@"; do
        if [[ "$first" == "true" ]]; then
            first=false
        else
            result+=","
        fi
        # Escape backslashes and quotes for JSON
        item="${item//\\/\\\\}"
        item="${item//\"/\\\"}"
        result+="\"${item}\""
    done
    result+="]"
    echo "$result"
}

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

    # Parse segment filenames from JSON (no jq dependency)
    local seg_files
    seg_files=$(parse_segment_list "$seg_list")
    [[ -z "$seg_files" ]] && return

    # Separate into: manifest (always re-download), init, and media segments
    local manifest_segs=()
    local init_segs=()
    local media_segs=()
    while IFS= read -r seg; do
        [[ -z "$seg" ]] && continue
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
    done <<< "$seg_files"

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

# ============================================================================
# MULTI-GPU DISTRIBUTED TRANSCODING
# ============================================================================

# --- Parse worker pool into arrays ------------------------------------------
parse_worker_pool() {
    local pool="$1"
    POOL_URLS=()
    POOL_TAGS=()

    IFS=',' read -ra entries <<< "$pool"
    for entry in "${entries[@]}"; do
        entry=$(echo "$entry" | xargs)  # trim whitespace
        [[ -z "$entry" ]] && continue
        if [[ "$entry" == *@local ]]; then
            POOL_URLS+=("${entry%@local}")
            POOL_TAGS+=("local")
        elif [[ "$entry" == *@beam ]]; then
            POOL_URLS+=("${entry%@beam}")
            POOL_TAGS+=("beam")
        else
            POOL_URLS+=("$entry")
            POOL_TAGS+=("remote")
        fi
    done
}

# --- Health check all pool workers ------------------------------------------
health_check_workers() {
    LIVE_WORKERS=()
    LIVE_TAGS=()

    for i in "${!POOL_URLS[@]}"; do
        local url="${POOL_URLS[$i]}"
        local tag="${POOL_TAGS[$i]}"
        local health
        health=$(curl -sf --connect-timeout 2 "${url}/health" 2>/dev/null || echo "")
        if [[ -n "$health" ]]; then
            LIVE_WORKERS+=("$url")
            LIVE_TAGS+=("$tag")
            local hw
            hw=$(echo "$health" | grep -o '"hw_accel":"[^"]*"' | cut -d'"' -f4 || echo "?")
            log_event "MULTI-GPU" "Worker alive: ${url} (${tag}, ${hw})"
        else
            log_event "MULTI-GPU" "Worker unreachable: ${url}"
        fi
    done

    log_event "MULTI-GPU" "${#LIVE_WORKERS[@]}/${#POOL_URLS[@]} workers alive"
}

# --- Get video duration using ffprobe or worker /probe endpoint -------------
get_video_duration() {
    local input="$1"
    local duration=""

    # Try local ffprobe first (Plex's ffmpeg can do -i probe)
    if [[ -x "$REAL_TRANSCODER" ]]; then
        duration=$("$REAL_TRANSCODER" -v error -show_entries format=duration -of csv=p=0 -i "$input" 2>/dev/null || true)
        # Plex Transcoder might not support -show_entries, try stderr parse
        if [[ -z "$duration" ]] || [[ "$duration" == "N/A" ]]; then
            # Disable pipefail: ffmpeg exits non-zero (no output args) which
            # kills the whole pipeline under set -eo pipefail, discarding the
            # Duration line that grep already captured.
            duration=$(set +o pipefail; "$REAL_TRANSCODER" -i "$input" 2>&1 | grep -oP 'Duration: \K[0-9]+:[0-9]+:[0-9]+\.[0-9]+' | head -1 || true)
            if [[ -n "$duration" ]]; then
                # Convert HH:MM:SS.ff to seconds
                IFS=':.' read -r h m s f <<< "$duration"
                duration=$(( 10#$h * 3600 + 10#$m * 60 + 10#$s ))
            fi
        fi
    fi

    # Try system ffprobe
    if [[ -z "$duration" ]] && command -v ffprobe &>/dev/null; then
        duration=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$input" 2>/dev/null || echo "")
    fi

    # Try a @local worker's /probe endpoint
    if [[ -z "$duration" ]] || [[ "$duration" == "N/A" ]]; then
        for i in "${!LIVE_WORKERS[@]}"; do
            if [[ "${LIVE_TAGS[$i]}" == "local" ]]; then
                local probe_resp
                probe_resp=$(curl -sf --connect-timeout 3 --get --data-urlencode "path=${input}" "${LIVE_WORKERS[$i]}/probe" 2>/dev/null || echo "")
                if [[ -n "$probe_resp" ]]; then
                    duration=$(echo "$probe_resp" | grep -o '"duration":[0-9.]*' | cut -d':' -f2)
                    [[ -n "$duration" ]] && break
                fi
            fi
        done
    fi

    # Try Plex API when input is a Plex HTTP URL
    # Extract part ID and token from URLs like:
    #   http://127.0.0.1:32400/library/parts/82744/0/file.mp4?X-Plex-Token=TOKEN
    if [[ -z "$duration" ]] || [[ "$duration" == "N/A" ]]; then
        if [[ "$input" =~ /library/parts/([0-9]+)/ ]]; then
            local _part_id="${BASH_REMATCH[1]}"
            local _plex_token=""
            if [[ "$input" =~ X-Plex-Token=([^&]+) ]]; then
                _plex_token="${BASH_REMATCH[1]}"
            fi
            local _plex_base=""
            if [[ "$input" =~ (https?://[^/]+) ]]; then
                _plex_base="${BASH_REMATCH[1]}"
            fi
            if [[ -n "$_plex_base" ]] && [[ -n "$_plex_token" ]]; then
                # Query each library section for the matching part ID
                local _sections
                _sections=$(curl -sf --connect-timeout 3 "${_plex_base}/library/sections?X-Plex-Token=${_plex_token}" 2>/dev/null \
                    | grep -oP 'key="\K[0-9]+' || true)
                for _sec in $_sections; do
                    local _dur_ms
                    _dur_ms=$(curl -sf --connect-timeout 5 "${_plex_base}/library/sections/${_sec}/all?X-Plex-Token=${_plex_token}" 2>/dev/null \
                        | grep -oP "id=\"${_part_id}\"[^>]*duration=\"\K[0-9]+" | head -1 || true)
                    if [[ -n "$_dur_ms" ]] && [[ "$_dur_ms" -gt 0 ]]; then
                        # Plex API returns milliseconds, convert to seconds
                        duration=$(( _dur_ms / 1000 ))
                        log_event "PROBE" "Got duration ${duration}s from Plex API (part ${_part_id})"
                        break
                    fi
                done
            fi
        fi
    fi

    # Return integer seconds (truncate decimals)
    if [[ -n "$duration" ]] && [[ "$duration" != "N/A" ]]; then
        printf "%.0f" "$duration"
    else
        echo ""
    fi
}

# --- Compute time splits for N workers -------------------------------------
# Sets SPLIT_SS[] and SPLIT_T[] arrays
compute_splits() {
    local total_duration="$1"
    local seek="${2:-0}"
    local n_workers="$3"

    declare -g -a SPLIT_SS=()
    declare -g -a SPLIT_T=()

    local remaining=$((total_duration - seek))
    if [[ $remaining -le 0 ]]; then
        SPLIT_SS=("$seek")
        SPLIT_T=("$total_duration")
        return
    fi

    local split_size=$((remaining / n_workers))
    # Minimum 30s per split to avoid tiny chunks
    if [[ $split_size -lt 30 ]]; then
        split_size=$remaining
        n_workers=1
    fi

    for (( w=0; w<n_workers; w++ )); do
        SPLIT_SS+=( $((seek + w * split_size)) )
        if [[ $w -eq $((n_workers - 1)) ]]; then
            # Last worker gets the remainder
            SPLIT_T+=( $((remaining - w * split_size)) )
        else
            SPLIT_T+=( "$split_size" )
        fi
    done

    log_event "MULTI-GPU" "Splits: ${n_workers} workers, ${split_size}s each (duration=${total_duration}s, seek=${seek}s)"
    for (( w=0; w<${#SPLIT_SS[@]}; w++ )); do
        log_event "MULTI-GPU" "  Worker ${w}: ss=${SPLIT_SS[$w]} t=${SPLIT_T[$w]}"
    done
}

# --- Convert Plex hex stream IDs (#0xNN) to decimal (#N) -------------------
# Plex uses hex stream specifiers like #0x02 that standard ffmpeg doesn't understand
convert_hex_stream_ids() {
    local s="$1"
    while [[ "$s" =~ \#0x([0-9a-fA-F]+) ]]; do
        local hex="${BASH_REMATCH[1]}"
        local dec
        dec=$(printf '%d' "0x${hex}" 2>/dev/null || echo "$hex")
        s="${s/\#0x${hex}/\#${dec}}"
    done
    echo "$s"
}

# --- Submit job to one worker -----------------------------------------------
submit_worker_job() {
    local worker_url="$1"
    local worker_tag="$2"
    local job_id="$3"
    local worker_idx="$4"
    local total_workers="$5"
    local ss="${6:-0}"
    local t="${7:-0}"

    local use_beam_stream=false
    local use_pull_url=""
    local use_staged_input=""

    # Staged mode: file already uploaded to worker — no beam/pull needed
    if [[ -n "${STAGED_SESSION_ID:-}" ]]; then
        use_staged_input="${STAGED_SESSION_ID}"
    elif [[ "$worker_tag" == "remote" || "$worker_tag" == "beam" ]] && [[ -n "$INPUT_FILE" ]]; then
        # @beam workers: always beam stream (even over HTTPS via Cloudflare Tunnel)
        if [[ "$worker_tag" == "beam" ]]; then
            if [[ -f "$INPUT_FILE" ]] || [[ "$INPUT_FILE" =~ ^https?:// ]]; then
                use_beam_stream=true
                log_event "MULTI-GPU" "Worker ${worker_idx}: beam stream via tunnel"
            fi
        # Untagged remote cloud workers (HTTPS URLs): use S3 pull mode if proxy URL file exists
        elif [[ "${worker_url}" =~ ^https:// ]] && [[ -f "${PULL_DIR}/${job_id}.url" ]]; then
            use_pull_url=$(cat "${PULL_DIR}/${job_id}.url" 2>/dev/null)
            log_event "MULTI-GPU" "Worker ${worker_idx}: using S3 pull mode"
        # LAN remote workers: beam stream (POST input to worker)
        elif [[ -f "$INPUT_FILE" ]] || [[ "$INPUT_FILE" =~ ^https?:// ]]; then
            use_beam_stream=true
        fi
    fi

    # Build modified raw_args for each worker type:
    # - Local: inject -ss/-t, replace output path with "dash" (worker resolves to temp_dir)
    # - Remote: replace output path with "dash" (beam mode redirects to temp_dir)
    local raw_args_json
    declare -a mod_args=()
    local found_input=false
    local mod_args_t_added=""

    # For beam streams, detect the audio stream index from filter_complex
    # so we can remap it to 0:a:0 (the remuxed MKV may have different indices)
    local audio_stream_idx=""
    if [[ "$use_beam_stream" == "true" ]]; then
        for a in "${RAW_ARGS[@]}"; do
            # filter_complex like [0:2] aresample=... tells us stream 2 is audio
            if [[ "$a" == *'aresample'* ]] && [[ "$a" =~ \[0:([0-9]+)\] ]]; then
                audio_stream_idx="${BASH_REMATCH[1]}"
                break
            fi
            # Also check hex form [0:#0xNN]
            if [[ "$a" == *'aresample'* ]] && [[ "$a" =~ \[0:\#0x([0-9a-fA-F]+)\] ]]; then
                audio_stream_idx=$(printf '%d' "0x${BASH_REMATCH[1]}" 2>/dev/null)
                break
            fi
        done
    fi

    # Staged or local workers get -ss/-t injected (file-based seeking).
    # Beam stream workers DON'T (the stream is pre-seeked by copy_remux_pipe).
    local inject_seek=false
    if [[ "$worker_tag" == "local" ]] || [[ -n "$use_staged_input" ]]; then
        inject_seek=true
    fi

    for a in "${RAW_ARGS[@]}"; do
        # Hex stream IDs (#0xNN) and stream index remapping handled by the worker
        if [[ "$found_input" == "false" ]] && [[ "$a" == "-i" ]]; then
            # Inject -ss before -i for file-based seeking (local + staged)
            if [[ "$inject_seek" == "true" ]] && [[ "$ss" -gt 0 ]]; then
                mod_args+=("-ss" "$ss")
            fi
            mod_args+=("$a")
            found_input=true
        elif [[ "$found_input" == "true" ]] && [[ -z "$mod_args_t_added" ]]; then
            mod_args+=("$a")
            # Inject -t after input path to limit duration (local + staged)
            if [[ "$inject_seek" == "true" ]]; then
                mod_args+=("-t" "$t")
            fi
            mod_args_t_added=1
        else
            mod_args+=("$a")
        fi
    done

    # Replace the output path (last arg) with "dash" so the worker writes
    # to its own temp_dir/{job_id}/output.mpd. The cartridge then downloads
    # segments via /beam/segments/ endpoint from ALL workers (local or remote).
    if [[ ${#mod_args[@]} -gt 0 ]]; then
        local last_arg="${mod_args[-1]}"
        if [[ "$last_arg" == *.mpd ]] || [[ "$last_arg" == *.m3u8 ]] || [[ "$last_arg" == */Transcode/* ]]; then
            mod_args[-1]="dash"
        fi
    fi

    raw_args_json=$(json_array "${mod_args[@]}")

    local job_json
    job_json=$(cat << JOBEOF
{
    "job_id": "${job_id}",
    "input": {
        "type": "file",
        "path": "${INPUT_FILE}"
    },
    "output": {
        "type": "unknown",
        "path": "",
        "segment_duration": ${SEGMENT_DURATION}
    },
    "arguments": {
        "video_codec": "${VIDEO_CODEC_OUT:-h264}",
        "audio_codec": "${AUDIO_CODEC:-aac}",
        "video_bitrate": "${BITRATE:-}",
        "resolution": "${RESOLUTION:-}",
        "seek": ${ss:-null},
        "tone_mapping": $([ -n "$TONE_MAP" ] && echo "true" || echo "false"),
        "subtitle": {
            "mode": "${SUBTITLE_MODE:-none}"
        },
        "raw_args": ${raw_args_json}
    },
    "source": "${SERVER_TYPE}",
    "beam_stream": ${use_beam_stream},
    "pull_url": $(if [[ -n "$use_pull_url" ]]; then echo "\"${use_pull_url}\""; else echo "null"; fi),
    "staged_input": $(if [[ -n "$use_staged_input" ]]; then echo "\"${use_staged_input}\""; else echo "null"; fi),
    "callback_url": $(if [[ -n "$CALLBACK_URL" ]] && [[ "$CALLBACK_URL" != "__CALLBACK_URL__" ]]; then echo "\"${CALLBACK_URL}\""; else echo "null"; fi),
    "metadata": {
        "cartridge_version": "${CARTRIDGE_VERSION}",
        "session_id": "${SESSION_ID}",
        "split_info": {
            "worker_index": ${worker_idx},
            "total_workers": ${total_workers},
            "ss": ${ss},
            "t": ${t}
        }
    }
}
JOBEOF
)

    # Build curl headers
    local curl_args=(-sf -X POST -H "Content-Type: application/json")
    if [[ -n "$REMOTE_API_KEY" ]] && [[ "$REMOTE_API_KEY" != __* ]]; then
        curl_args+=(-H "X-API-Key: ${REMOTE_API_KEY}")
    fi
    curl_args+=(--connect-timeout "$REMOTE_TIMEOUT" --max-time 30 -d "$job_json")
    curl_args+=("${worker_url}/transcode")

    local response
    response=$(curl "${curl_args[@]}" 2>/dev/null || echo "")

    if [[ -z "$response" ]]; then
        log_event "MULTI-GPU" "Worker ${worker_idx} (${worker_url}): job submit failed"
        return 1
    fi

    local job_status
    job_status=$(echo "$response" | grep -o '"status":"[^"]*"' | cut -d'"' -f4 || echo "")
    if [[ "$job_status" == "queued" ]] || [[ "$job_status" == "running" ]] || [[ "$job_status" == "pending" ]]; then
        log_event "MULTI-GPU" "Worker ${worker_idx} (${worker_url}): job ${job_id} submitted (${job_status})"
        return 0
    else
        log_event "MULTI-GPU" "Worker ${worker_idx} (${worker_url}): unexpected status ${job_status}"
        return 1
    fi
}

# --- Copy-remux a time range and pipe to worker beam endpoint ---------------
copy_remux_pipe() {
    local worker_url="$1"
    local job_id="$2"
    local ss="$3"
    local t="$4"
    local worker_idx="$5"

    local upload_rate="${PLEXBEAM_UPLOAD_RATE:-0}"

    log_event "MULTI-GPU" "Worker ${worker_idx}: copy-remux ss=${ss} t=${t} → beam stream"

    # Use Plex's ffmpeg or system ffmpeg for the copy-remux
    local remux_bin="$REAL_TRANSCODER"
    if [[ -x /usr/bin/ffmpeg ]]; then
        remux_bin="/usr/bin/ffmpeg"
    fi

    # Copy-remux: extract time range as MKV, pipe to worker's beam stream
    # -map 0 = copy ALL streams to preserve original stream indices
    # -c copy = no decode/encode, just repackage (~100x realtime)
    "$remux_bin" -v error -ss "$ss" -i "$INPUT_FILE" -t "$t" \
        -map 0 -c copy -f matroska pipe:1 2>/dev/null | \
    curl -sfg --http1.1 -X POST \
        --connect-timeout "$REMOTE_TIMEOUT" \
        --max-time 7200 \
        --limit-rate "$upload_rate" \
        -T - \
        "${worker_url}/beam/stream/${job_id}" \
        > /dev/null 2>&1

    local rc=$?
    if [[ $rc -eq 0 ]]; then
        log_event "MULTI-GPU" "Worker ${worker_idx}: beam stream completed"
    else
        log_event "MULTI-GPU" "Worker ${worker_idx}: beam stream failed (rc=${rc})"
    fi
    return $rc
}

# --- Copy-remux a time range, upload to S3 via pull proxy, store URL ---------
# Writes the pre-signed S3 URL to /tmp/plexbeam-pull/{job_id}.url
copy_remux_and_upload() {
    local job_id="$1"
    local ss="$2"
    local t="$3"
    local worker_idx="$4"

    mkdir -p "$PULL_DIR"

    log_event "MULTI-GPU" "Worker ${worker_idx}: copy-remux ss=${ss} t=${t} → S3 upload"

    local remux_bin="$REAL_TRANSCODER"
    if [[ -x /usr/bin/ffmpeg ]]; then
        remux_bin="/usr/bin/ffmpeg"
    fi

    # Copy-remux and pipe directly to S3 pull proxy (no temp file needed)
    local response
    response=$("$remux_bin" -v error -ss "$ss" -i "$INPUT_FILE" -t "$t" \
        -map 0 -c copy -f matroska pipe:1 2>/dev/null | \
    curl -sf -X PUT \
        --connect-timeout 5 \
        --max-time 600 \
        -H "Transfer-Encoding: chunked" \
        -T - \
        "${PULL_PROXY_URL}/upload/${job_id}.mkv" 2>/dev/null)

    local rc=$?
    if [[ $rc -eq 0 ]] && [[ -n "$response" ]]; then
        # Extract URL from JSON response {"url": "https://...", ...}
        local s3_url
        s3_url=$(echo "$response" | grep -o '"url":"[^"]*"' | cut -d'"' -f4)
        if [[ -n "$s3_url" ]]; then
            echo "$s3_url" > "${PULL_DIR}/${job_id}.url"
            log_event "MULTI-GPU" "Worker ${worker_idx}: S3 upload done → ${job_id}.mkv"
            return 0
        fi
    fi

    log_event "MULTI-GPU" "Worker ${worker_idx}: S3 upload failed (rc=${rc})"
    return 1
}

# --- Download segments from one worker with per-stream offset renaming ------
beam_download_worker_segments() {
    local worker_url="$1"
    local job_id="$2"
    local target_dir="$3"
    local worker_idx="$4"
    local -n downloaded_ref="$5"     # nameref to associative array
    local -n stream_offsets_ref="$6"  # nameref to associative array: "w{N}_s{S}" → offset

    local seg_list
    seg_list=$(curl -sf --connect-timeout 2 "${worker_url}/beam/segments/${job_id}" 2>/dev/null || echo "")
    if [[ -z "$seg_list" ]] || [[ "$seg_list" == '{"files":[]}' ]]; then
        return
    fi

    local seg_files
    seg_files=$(parse_segment_list "$seg_list")
    [[ -z "$seg_files" ]] && return

    local key="" seg=""
    while IFS= read -r seg; do
        [[ -z "$seg" ]] && continue
        key="w${worker_idx}_${seg}"

        # Skip already-downloaded
        [[ -n "${downloaded_ref[$key]:-}" ]] && continue

        # Manifest: only from worker 0
        if [[ "$seg" == *.mpd ]] || [[ "$seg" == *.m3u8 ]]; then
            if [[ "$worker_idx" -eq 0 ]]; then
                curl -sf --connect-timeout 2 --max-time 3 \
                    "${worker_url}/beam/segment/${job_id}/${seg}" \
                    -o "${target_dir}/${seg}" 2>/dev/null || true
                downloaded_ref[$key]=1
            fi
            continue
        fi

        # Init segments: only from worker 0 (identical codec params)
        if [[ "$seg" == init-* ]]; then
            if [[ "$worker_idx" -eq 0 ]]; then
                curl -sf "${worker_url}/beam/segment/${job_id}/${seg}" \
                    -o "${target_dir}/${seg}" 2>/dev/null || true
                downloaded_ref[$key]=1
            fi
            continue
        fi

        # Media segments: download and rename with per-stream offset
        # chunk-stream0-00001.m4s → chunk-stream0-XXXXX.m4s
        local stream_id seg_num offset new_num new_name
        if [[ "$seg" =~ chunk-stream([0-9]+)-([0-9]+)\.m4s ]]; then
            stream_id="${BASH_REMATCH[1]}"
            seg_num="${BASH_REMATCH[2]}"
            seg_num=$((10#$seg_num))

            # Get per-stream offset for this worker
            offset=${stream_offsets_ref["w${worker_idx}_s${stream_id}"]:-0}
            new_num=$((seg_num + offset))
            new_name=$(printf "chunk-stream%s-%05d.m4s" "$stream_id" "$new_num")

            # Track per-stream segment count for this worker
            local count_key="w${worker_idx}_s${stream_id}_count"
            local cur_count=${stream_offsets_ref["$count_key"]:-0}
            stream_offsets_ref["$count_key"]=$((cur_count + 1))
        else
            new_name="$seg"
        fi

        curl -sf "${worker_url}/beam/segment/${job_id}/${seg}" \
            -o "${target_dir}/${new_name}" 2>/dev/null &
        downloaded_ref[$key]=1
    done <<< "$seg_files"

    # Wait for background downloads to complete
    wait 2>/dev/null || true
}

# ============================================================================
# MULTI-GPU DISPATCH — SELECTABLE STRATEGIES
# ============================================================================
# Controlled by PLEXBEAM_MULTI_MODE env var:
#   A = Simple chunked (300s default, round-robin)
#   B = Speed-weighted big split (calibration, 2 big pieces)
#   C = Full BitTorrent (calibration + queues + prefetch + endgame + stealing)
# Default: C
# ============================================================================

# --- Shared helpers for chunk-based modes (A and C) -------------------------
# These rely on dynamic-scoped variables from the calling function:
#   n_workers, n_chunks, staging_dir, next_processable,
#   cumulative_vid_offset, cumulative_aud_offset, total_segs_output,
#   WS_CHUNK_*, WS_WORKER_*, MULTI_JOB_IDS, MULTI_STREAM_PIDS

_ws_assign_chunk() {
    local w=$1 c=$2
    local jid="${SESSION_ID}_c${c}"
    local wurl="${LIVE_WORKERS[$w]}"
    local wtag="${LIVE_TAGS[$w]}"

    WS_CHUNK_STATE[$c]="encoding"
    WS_CHUNK_WORKER[$c]=$w
    WS_CHUNK_JOB_ID[$c]="$jid"
    WS_CHUNK_START_TIME[$c]=$(date +%s)
    WS_WORKER_BUSY[$w]=1
    WS_WORKER_CHUNK[$w]=$c

    # Track for cleanup trap
    MULTI_JOB_IDS+=("$jid")

    log_event "MULTI-GPU" "Assign chunk ${c} (ss=${WS_CHUNK_SS[$c]} t=${WS_CHUNK_T[$c]}) → worker ${w} (${wtag})"

    # For cloud workers (HTTPS, non-beam): upload chunk to S3 first, THEN submit job with the S3 URL.
    # For @beam and LAN workers: submit job first, then stream input in background.
    if [[ "$wtag" == "remote" ]] && [[ "${wurl}" =~ ^https:// ]] && [[ -n "$PULL_PROXY_URL" ]]; then
        # S3 pull mode: upload chunk to S3 via local proxy (blocking)
        copy_remux_and_upload "$jid" "${WS_CHUNK_SS[$c]}" "${WS_CHUNK_T[$c]}" "$w"
        if [[ $? -ne 0 ]]; then
            log_event "MULTI-GPU" "S3 upload failed for chunk ${c} to worker ${w}"
            WS_CHUNK_STATE[$c]="pending"
            WS_CHUNK_WORKER[$c]=-1
            WS_WORKER_BUSY[$w]=0
            WS_WORKER_CHUNK[$w]=-1
            return 1
        fi
    fi

    if ! submit_worker_job "$wurl" "$wtag" "$jid" "$c" "$n_chunks" "${WS_CHUNK_SS[$c]}" "${WS_CHUNK_T[$c]}"; then
        log_event "MULTI-GPU" "Failed to submit chunk ${c} to worker ${w}"
        WS_CHUNK_STATE[$c]="pending"
        WS_CHUNK_WORKER[$c]=-1
        WS_WORKER_BUSY[$w]=0
        WS_WORKER_CHUNK[$w]=-1
        return 1
    fi

    # Start beam stream for remote/beam workers — SKIP if staged (file already on worker)
    if [[ -z "${STAGED_SESSION_ID:-}" ]]; then
        if { [[ "$wtag" == "remote" ]] && ! [[ "${wurl}" =~ ^https:// ]]; } || [[ "$wtag" == "beam" ]]; then
            if [[ -f "$INPUT_FILE" ]] || [[ "$INPUT_FILE" =~ ^https?:// ]]; then
                copy_remux_pipe "$wurl" "$jid" "${WS_CHUNK_SS[$c]}" "${WS_CHUNK_T[$c]}" "$w" &
                WS_WORKER_STREAM_PID[$w]=$!
                MULTI_STREAM_PIDS+=("$!")
            fi
        fi
    fi
}

_ws_download_chunk_bg() {
    local w=$1 c=$2
    local wurl="${LIVE_WORKERS[$w]}"
    local jid="${WS_CHUNK_JOB_ID[$c]}"
    local chunk_staging="${staging_dir}/chunk_${c}"
    local done_file="${staging_dir}/.chunk_${c}_done"
    mkdir -p "$chunk_staging"

    # Run download in background subshell
    # Disable ALL strict mode — subshell inherits set -euo pipefail:
    #   set -e = errexit (exits on any command failure)
    #   set -u = nounset (exits on any unset variable reference)
    #   set -o pipefail (exits on pipe failures)
    # All three must be disabled or the subshell dies silently.
    (
        set +e
        set +u
        set +o pipefail
        trap 'echo "[DL] chunk ${c} EXIT code=$? line=$LINENO" >> "'"${staging_dir}"'/.dl_debug.log" 2>/dev/null' EXIT
        echo "[DL] chunk ${c} subshell started: jid=${jid} wurl=${wurl} staging=${chunk_staging}" >> "${staging_dir}/.dl_debug.log" 2>/dev/null

        seg_list=$(curl -sf --connect-timeout 5 "${wurl}/beam/segments/${jid}" 2>/dev/null || echo "")
        if [[ -z "$seg_list" ]] || [[ "$seg_list" == '{"files":[]}' ]]; then
            echo "0 0" > "$done_file"
            echo "[DL] chunk ${c} jid=${jid}: empty seg_list from ${wurl}" >> "${staging_dir}/.dl_debug.log" 2>/dev/null
            exit 0
        fi

        seg_files=$(parse_segment_list "$seg_list" || true)
        seg_count=$(echo "$seg_files" | grep -c '.' 2>/dev/null || echo "0")
        echo "[DL] chunk ${c}: seg_list=${#seg_list} bytes, parsed=${seg_count} files" >> "${staging_dir}/.dl_debug.log" 2>/dev/null
        if [[ -z "$seg_files" ]]; then
            echo "0 0" > "$done_file"
            exit 0
        fi

        vid_count=0
        aud_count=0
        batch=0
        while IFS= read -r seg; do
            [[ -z "$seg" ]] && continue
            curl -sf --connect-timeout 5 --max-time 30 \
                "${wurl}/beam/segment/${jid}/${seg}" \
                -o "${chunk_staging}/${seg}" 2>/dev/null &
            if [[ "$seg" =~ chunk-stream0- ]]; then
                vid_count=$((vid_count + 1))
            elif [[ "$seg" =~ chunk-stream1- ]]; then
                aud_count=$((aud_count + 1))
            fi
            batch=$((batch + 1))
            if (( batch >= 20 )); then
                wait 2>/dev/null || true
                batch=0
            fi
        done <<< "$seg_files"
        wait 2>/dev/null || true

        echo "${vid_count} ${aud_count}" > "$done_file"
        echo "[DL] chunk ${c}: done ${vid_count} vid + ${aud_count} aud" >> "${staging_dir}/.dl_debug.log" 2>/dev/null

        # Cleanup worker job
        curl -sf -X DELETE "${wurl}/job/${jid}" &>/dev/null || true
    ) 2>>"${staging_dir}/.dl_stderr_${c}.log" &
    WS_DOWNLOAD_PID[$c]=$!
    log_event "MULTI-GPU" "Started background download for chunk ${c} (pid=${WS_DOWNLOAD_PID[$c]})"
}

# Check if any background downloads have finished, mark chunks completed
_ws_check_downloads() {
    for c in "${!WS_DOWNLOAD_PID[@]}"; do
        [[ "${WS_CHUNK_STATE[$c]}" == "downloading" ]] || continue
        local dpid="${WS_DOWNLOAD_PID[$c]}"
        if ! kill -0 "$dpid" 2>/dev/null; then
            wait "$dpid" 2>/dev/null || true
            local done_file="${staging_dir}/.chunk_${c}_done"
            if [[ -f "$done_file" ]]; then
                read -r vid_count aud_count < "$done_file"
                WS_CHUNK_VID[$c]=${vid_count:-0}
                WS_CHUNK_AUD[$c]=${aud_count:-0}
                rm -f "$done_file"
            else
                WS_CHUNK_VID[$c]=0
                WS_CHUNK_AUD[$c]=0
            fi
            WS_CHUNK_STATE[$c]="completed"
            chunks_completed=$((chunks_completed + 1))
            unset "WS_DOWNLOAD_PID[$c]"
            log_event "MULTI-GPU" "Downloaded chunk ${c}: ${WS_CHUNK_VID[$c]} vid + ${WS_CHUNK_AUD[$c]} aud segments"
        fi
    done
}

_ws_process_ready_chunks() {
    while [[ $next_processable -lt $n_chunks ]] && \
          [[ "${WS_CHUNK_STATE[$next_processable]}" == "completed" ]]; do
        local c=$next_processable
        local chunk_staging="${staging_dir}/chunk_${c}"

        # Move/rename segments with cumulative offset
        local seg=""
        for seg_file in "${chunk_staging}"/chunk-stream*.m4s; do
            [[ -f "$seg_file" ]] || continue
            seg=$(basename "$seg_file")

            if [[ "$seg" =~ chunk-stream([0-9]+)-([0-9]+)\.m4s ]]; then
                local sid="${BASH_REMATCH[1]}"
                local num=$((10#${BASH_REMATCH[2]}))
                local offset=0
                if [[ "$sid" == "0" ]]; then
                    offset=$cumulative_vid_offset
                else
                    offset=$cumulative_aud_offset
                fi
                local new_num=$((num + offset))
                local new_name
                new_name=$(printf "chunk-stream%s-%05d.m4s" "$sid" "$new_num")
                mv "$seg_file" "${OUTPUT_DIR}/${new_name}" 2>/dev/null || \
                    cp "$seg_file" "${OUTPUT_DIR}/${new_name}" 2>/dev/null
                total_segs_output=$((total_segs_output + 1))
            fi
        done

        # Copy init segments from chunk 0 only
        if [[ $c -eq 0 ]]; then
            for init_file in "${chunk_staging}"/init-stream*.m4s; do
                [[ -f "$init_file" ]] || continue
                cp "$init_file" "${OUTPUT_DIR}/" 2>/dev/null
            done
            # Copy manifest from chunk 0 as base, fix startNumber for skip_to_segment
            if [[ -f "${chunk_staging}/output.mpd" ]]; then
                cp "${chunk_staging}/output.mpd" "${OUTPUT_DIR}/output.mpd" 2>/dev/null
                if [[ $skip_base -gt 0 ]]; then
                    sed -i "s/startNumber=\"1\"/startNumber=\"$((skip_base + 1))\"/" "${OUTPUT_DIR}/output.mpd" 2>/dev/null
                fi
            fi
        fi

        # Advance cumulative offsets
        cumulative_vid_offset=$((cumulative_vid_offset + WS_CHUNK_VID[$c]))
        cumulative_aud_offset=$((cumulative_aud_offset + WS_CHUNK_AUD[$c]))

        log_event "MULTI-GPU" "Processed chunk ${c} → output (vid_off=${cumulative_vid_offset} aud_off=${cumulative_aud_offset})"

        next_processable=$((next_processable + 1))
    done

    # POST manifest to Plex after init + media segments exist
    if [[ -n "${MANIFEST_CALLBACK_URL:-}" ]] && [[ -f "${OUTPUT_DIR}/output.mpd" ]]; then
        local should_post=false
        if [[ "$BEAM_MANIFEST_POSTED" == "false" ]]; then
            local has_init=false has_media=false
            for f in "${OUTPUT_DIR}"/init-stream*.m4s; do
                [[ -f "$f" ]] && has_init=true && break
            done
            for f in "${OUTPUT_DIR}"/chunk-stream*.m4s; do
                [[ -f "$f" ]] && has_media=true && break
            done
            [[ "$has_init" == "true" ]] && [[ "$has_media" == "true" ]] && should_post=true
        else
            should_post=true
        fi

        if [[ "$should_post" == "true" ]]; then
            local manifest_hash
            manifest_hash=$(md5sum "${OUTPUT_DIR}/output.mpd" 2>/dev/null | cut -d' ' -f1)
            if [[ "${manifest_hash}" != "${LAST_MANIFEST_HASH:-}" ]]; then
                curl -sf -X POST \
                    -H "Content-Type: application/dash+xml" \
                    --data-binary @"${OUTPUT_DIR}/output.mpd" \
                    "${MANIFEST_CALLBACK_URL}" 2>/dev/null || true
                LAST_MANIFEST_HASH="${manifest_hash}"
                if [[ "$BEAM_MANIFEST_POSTED" == "false" ]]; then
                    log_event "MULTI-GPU" "Initial manifest posted"
                    BEAM_MANIFEST_POSTED=true
                fi
            fi
        fi
    fi
}

# ============================================================================
# MODE A: Simple Chunked (300s default, round-robin work stealing)
# ============================================================================
_dispatch_chunked_simple() {
    local n_workers=${#LIVE_WORKERS[@]}
    local chunk_dur="${PLEXBEAM_CHUNK_DURATION:-300}"

    log_event "MODE-A" "Starting chunked dispatch: ${n_workers} workers, ${chunk_dur}s chunks"

    # --- Get video duration ---
    local duration
    duration=$(get_video_duration "$INPUT_FILE")
    if [[ -z "$duration" ]] || [[ "$duration" -le 0 ]]; then
        log_event "MODE-A" "Cannot determine duration — falling back to single worker"
        return 1
    fi
    log_event "MODE-A" "Input duration: ${duration}s"

    # --- Compute seek offset ---
    local seek_sec=0
    if [[ -n "$SEEK_POSITION" ]]; then
        seek_sec=$(printf "%.0f" "$SEEK_POSITION" 2>/dev/null || echo "0")
    fi

    local remaining=$((duration - seek_sec))
    if [[ $remaining -le 0 ]]; then
        log_event "MODE-A" "Nothing to encode after seek"
        return 1
    fi

    # --- Create chunk queue ---
    local n_chunks=$(( (remaining + chunk_dur - 1) / chunk_dur ))
    if [[ $n_chunks -le 1 ]]; then
        log_event "MODE-A" "Only 1 chunk needed — falling back to single worker"
        return 1
    fi

    declare -a WS_CHUNK_SS=()
    declare -a WS_CHUNK_T=()
    declare -a WS_CHUNK_STATE=()
    declare -a WS_CHUNK_WORKER=()
    declare -a WS_CHUNK_JOB_ID=()
    declare -a WS_CHUNK_START_TIME=()
    declare -a WS_CHUNK_VID=()
    declare -a WS_CHUNK_AUD=()

    for (( c=0; c<n_chunks; c++ )); do
        local ss=$((seek_sec + c * chunk_dur))
        local t=$chunk_dur
        if [[ $((ss + t)) -gt $duration ]]; then
            t=$((duration - ss))
        fi
        WS_CHUNK_SS+=("$ss")
        WS_CHUNK_T+=("$t")
        WS_CHUNK_STATE+=("pending")
        WS_CHUNK_WORKER+=(-1)
        WS_CHUNK_JOB_ID+=("")
        WS_CHUNK_VID+=(0)
        WS_CHUNK_AUD+=(0)
    done

    log_event "MODE-A" "Created ${n_chunks} chunks: ss=${seek_sec}, dur=${remaining}s, chunk=${chunk_dur}s"

    # --- Worker state ---
    declare -a WS_WORKER_BUSY=()
    declare -a WS_WORKER_CHUNK=()
    declare -a WS_WORKER_STREAM_PID=()
    declare -A WS_DOWNLOAD_PID=()
    for (( w=0; w<n_workers; w++ )); do
        WS_WORKER_BUSY+=(0)
        WS_WORKER_CHUNK+=(-1)
        WS_WORKER_STREAM_PID+=("")
    done

    DISPATCHED_TO_REMOTE=true

    local staging_dir="${OUTPUT_DIR}/staging"
    mkdir -p "$staging_dir"

    local next_processable=0
    local skip_base=0
    [[ "$SKIP_TO_SEGMENT" -gt 0 ]] 2>/dev/null && skip_base=$((SKIP_TO_SEGMENT - 1))
    local cumulative_vid_offset=$skip_base
    local cumulative_aud_offset=$skip_base
    local chunks_completed=0
    local total_segs_output=0

    log_event "MODE-A" "Segment offset base: ${skip_base} (skip_to_segment=${SKIP_TO_SEGMENT})"

    # ===== Main poll loop =====
    local ws_start_epoch
    ws_start_epoch=$(date +%s)
    log_event "MODE-A" "Entering poll loop"

    local poll_count=0
    local max_polls=28800
    local fail_count=0
    local max_fails=$((n_chunks * 2))

    while [[ $poll_count -lt $max_polls ]]; do
        sleep 0.25
        poll_count=$((poll_count + 1))

        local total_fps=0

        # --- Assign chunks to idle workers ---
        for (( w=0; w<n_workers; w++ )); do
            [[ ${WS_WORKER_BUSY[$w]} -ne 0 ]] && continue

            local found=-1
            for (( c=0; c<n_chunks; c++ )); do
                if [[ "${WS_CHUNK_STATE[$c]}" == "pending" ]]; then
                    found=$c
                    break
                fi
            done

            [[ $found -lt 0 ]] && continue
            _ws_assign_chunk "$w" "$found"
        done

        # --- Poll busy workers ---
        for (( w=0; w<n_workers; w++ )); do
            [[ ${WS_WORKER_BUSY[$w]} -eq 0 ]] && continue

            local c=${WS_WORKER_CHUNK[$w]}
            local jid="${WS_CHUNK_JOB_ID[$c]}"
            local wurl="${LIVE_WORKERS[$w]}"

            local status_resp
            status_resp=$(curl -sf --connect-timeout 2 --max-time 5 "${wurl}/status/${jid}" 2>/dev/null || echo "")
            [[ -z "$status_resp" ]] && continue

            local wstatus
            wstatus=$(echo "$status_resp" | grep -o '"status":"[^"]*"' | cut -d'"' -f4 || echo "")

            case "$wstatus" in
                completed)
                    log_event "MODE-A" "Worker ${w} finished chunk ${c}"

                    if [[ -n "${WS_WORKER_STREAM_PID[$w]}" ]]; then
                        kill "${WS_WORKER_STREAM_PID[$w]}" 2>/dev/null || true
                        wait "${WS_WORKER_STREAM_PID[$w]}" 2>/dev/null || true
                        WS_WORKER_STREAM_PID[$w]=""
                    fi

                    _ws_download_chunk_bg "$w" "$c"
                    WS_CHUNK_STATE[$c]="downloading"
                    WS_WORKER_BUSY[$w]=0
                    WS_WORKER_CHUNK[$w]=-1
                    ;;
                failed)
                    local err_msg
                    err_msg=$(echo "$status_resp" | grep -o '"error":"[^"]*"' | cut -d'"' -f4 || echo "unknown")
                    log_event "MODE-A" "Worker ${w} failed chunk ${c}: ${err_msg}"

                    if [[ -n "${WS_WORKER_STREAM_PID[$w]}" ]]; then
                        kill "${WS_WORKER_STREAM_PID[$w]}" 2>/dev/null || true
                        WS_WORKER_STREAM_PID[$w]=""
                    fi

                    WS_CHUNK_STATE[$c]="pending"
                    WS_CHUNK_WORKER[$c]=-1
                    WS_WORKER_BUSY[$w]=0
                    WS_WORKER_CHUNK[$w]=-1
                    fail_count=$((fail_count + 1))

                    if [[ $fail_count -ge $max_fails ]]; then
                        log_event "MODE-A" "Too many failures (${fail_count}) — aborting"
                        return 1
                    fi
                    ;;
                running)
                    local wfps
                    wfps=$(echo "$status_resp" | grep -o '"fps":[0-9][0-9.]*' | head -1 | cut -d':' -f2 || echo "0")
                    total_fps=$(echo "$total_fps + ${wfps:-0}" | bc 2>/dev/null || echo "$total_fps")
                    ;;
            esac
        done

        _ws_check_downloads
        _ws_process_ready_chunks

        # --- Progress reporting (every ~1s) ---
        if [[ $((poll_count % 4)) -eq 0 ]]; then
            local busy_count=0
            for (( w=0; w<n_workers; w++ )); do
                [[ ${WS_WORKER_BUSY[$w]} -ne 0 ]] && busy_count=$((busy_count + 1))
            done

            # Calculate meaningful out_time so Plex sees progress advancing
            local out_time_s=$((next_processable * chunk_dur))
            if [[ $next_processable -lt $n_chunks ]] && [[ -n "${WS_CHUNK_START_TIME[$next_processable]:-}" ]]; then
                local now_e wall_e chunk_e
                now_e=$(date +%s)
                wall_e=$((now_e - WS_CHUNK_START_TIME[$next_processable]))
                chunk_e=$wall_e
                (( chunk_e > chunk_dur )) && chunk_e=$chunk_dur
                out_time_s=$((out_time_s + chunk_e))
            fi
            local out_time_us=$((out_time_s * 1000000))
            local elapsed_s=$(( $(date +%s) - ws_start_epoch ))
            local speed_val="0.0"
            (( elapsed_s > 0 )) && speed_val=$(awk "BEGIN{printf \"%.1f\", ${out_time_s}/${elapsed_s}}")
            local time_str
            time_str=$(printf "%02d:%02d:%02d.00" \
                $((out_time_s / 3600)) $(( (out_time_s % 3600) / 60 )) $((out_time_s % 60)))

            printf "frame=0 fps=%s q=-1.0 size=N/A time=%s bitrate=N/A speed=%sx    [%d/%d chunks, %d active]\n" \
                "${total_fps}" "$time_str" "$speed_val" "$chunks_completed" "$n_chunks" "$busy_count" >&2

            if [[ -n "${PROGRESS_URL:-}" ]]; then
                curl -sf -X POST \
                    --connect-timeout 1 --max-time 2 \
                    -d "frame=0&fps=${total_fps}&speed=${speed_val}x&out_time_us=${out_time_us}&progress=continue" \
                    "${PROGRESS_URL}" 2>/dev/null &
            fi
        fi

        # --- Termination ---
        if [[ $chunks_completed -ge $n_chunks ]]; then
            _ws_process_ready_chunks

            log_event "MODE-A" "All ${n_chunks} chunks completed! ${total_segs_output} segments output"

            if [[ -n "${MANIFEST_CALLBACK_URL:-}" ]] && [[ -f "${OUTPUT_DIR}/output.mpd" ]]; then
                curl -sf -X POST \
                    -H "Content-Type: application/dash+xml" \
                    --data-binary @"${OUTPUT_DIR}/output.mpd" \
                    "${MANIFEST_CALLBACK_URL}" 2>/dev/null || true
            fi

            rm -rf "$staging_dir" 2>/dev/null || true

            printf "frame=9999 fps=0.0 q=-1.0 size=N/A time=99:99:99.99 bitrate=N/A speed=0.0x\n" >&2
            return 0
        fi

        if [[ $((poll_count % 120)) -eq 0 ]]; then
            log_event "MODE-A" "Progress: ${chunks_completed}/${n_chunks} chunks, ${total_segs_output} segs output, proc=${next_processable}"
        fi
    done

    log_event "MODE-A" "Timed out after ${max_polls} polls"
    for (( w=0; w<n_workers; w++ )); do
        if [[ ${WS_WORKER_BUSY[$w]} -ne 0 ]]; then
            local c=${WS_WORKER_CHUNK[$w]}
            curl -sf -X DELETE "${LIVE_WORKERS[$w]}/job/${WS_CHUNK_JOB_ID[$c]}" &>/dev/null || true
        fi
    done
    return 1
}

# ============================================================================
# MODE B: Speed-Weighted Big Split (calibration, proportional)
# ============================================================================

_weighted_update_offsets() {
    local w=$1
    local next_w=$((w + 1))

    [[ $next_w -ge ${#LIVE_WORKERS[@]} ]] && return
    [[ -n "${W_STREAM_OFFSETS["w${next_w}_s0"]+_}" ]] && return

    local vid_offset=${W_STREAM_OFFSETS["w${w}_s0"]:-0}
    local aud_offset=${W_STREAM_OFFSETS["w${w}_s1"]:-0}
    local vid_count=${W_STREAM_OFFSETS["w${w}_s0_count"]:-0}
    local aud_count=${W_STREAM_OFFSETS["w${w}_s1_count"]:-0}

    W_STREAM_OFFSETS["w${next_w}_s0"]=$((vid_offset + vid_count))
    W_STREAM_OFFSETS["w${next_w}_s1"]=$((aud_offset + aud_count))

    log_event "MODE-B" "Offsets for worker ${next_w}: vid=${W_STREAM_OFFSETS["w${next_w}_s0"]} aud=${W_STREAM_OFFSETS["w${next_w}_s1"]}"
}

_dispatch_weighted_split() {
    local n_workers=${#LIVE_WORKERS[@]}

    log_event "MODE-B" "Starting weighted-split dispatch: ${n_workers} workers"

    # --- Get video duration ---
    local duration
    duration=$(get_video_duration "$INPUT_FILE")
    if [[ -z "$duration" ]] || [[ "$duration" -le 0 ]]; then
        log_event "MODE-B" "Cannot determine duration -- falling back"
        return 1
    fi
    log_event "MODE-B" "Input duration: ${duration}s"

    local seek_sec=0
    if [[ -n "$SEEK_POSITION" ]]; then
        seek_sec=$(printf "%.0f" "$SEEK_POSITION" 2>/dev/null || echo "0")
    fi

    local remaining=$((duration - seek_sec))
    if [[ $remaining -le 0 ]]; then
        log_event "MODE-B" "Nothing to encode after seek"
        return 1
    fi

    if [[ $remaining -lt $((n_workers * 30)) ]]; then
        log_event "MODE-B" "Remaining ${remaining}s too short for ${n_workers} workers"
        return 1
    fi

    DISPATCHED_TO_REMOTE=true

    # ===== PHASE 1: Calibration =====
    log_event "MODE-B" "Phase 1: Calibrating ${n_workers} workers (15s test chunks)"

    local cal_duration=15
    declare -a CAL_FPS=()
    declare -a CAL_JOB_IDS=()
    declare -a CAL_STREAM_PIDS=()

    for (( w=0; w<n_workers; w++ )); do
        local cal_jid="${SESSION_ID}_cal${w}"
        local wurl="${LIVE_WORKERS[$w]}"
        local wtag="${LIVE_TAGS[$w]}"

        CAL_JOB_IDS+=("$cal_jid")
        CAL_FPS+=(0)
        CAL_STREAM_PIDS+=("")

        if ! submit_worker_job "$wurl" "$wtag" "$cal_jid" "$w" "$n_workers" 0 "$cal_duration"; then
            log_event "MODE-B" "Calibration submit failed for worker ${w}"
            continue
        fi

        if { [[ "$wtag" == "remote" ]] || [[ "$wtag" == "beam" ]]; } && { [[ -f "$INPUT_FILE" ]] || [[ "$INPUT_FILE" =~ ^https?:// ]]; }; then
            copy_remux_pipe "$wurl" "$cal_jid" 0 "$cal_duration" "$w" &
            CAL_STREAM_PIDS[$w]=$!
        fi
    done

    # Poll calibration jobs
    local cal_polls=0
    local cal_max_polls=240
    declare -a CAL_DONE=()
    for (( w=0; w<n_workers; w++ )); do
        CAL_DONE+=(false)
    done

    while [[ $cal_polls -lt $cal_max_polls ]]; do
        sleep 0.25
        cal_polls=$((cal_polls + 1))

        local all_done=true
        for (( w=0; w<n_workers; w++ )); do
            [[ "${CAL_DONE[$w]}" == "true" ]] && continue
            all_done=false

            local wurl="${LIVE_WORKERS[$w]}"
            local cal_jid="${CAL_JOB_IDS[$w]}"
            local status_resp
            status_resp=$(curl -sf --connect-timeout 2 --max-time 5 "${wurl}/status/${cal_jid}" 2>/dev/null || echo "")
            [[ -z "$status_resp" ]] && continue

            local wstatus
            wstatus=$(echo "$status_resp" | grep -o '"status":"[^"]*"' | cut -d'"' -f4 || echo "")

            case "$wstatus" in
                running)
                    local wfps
                    wfps=$(echo "$status_resp" | grep -o '"fps":[0-9][0-9.]*' | head -1 | cut -d':' -f2 || echo "0")
                    if [[ -n "$wfps" ]] && [[ "$wfps" != "0" ]] && [[ "$wfps" != "0.0" ]]; then
                        CAL_FPS[$w]=$(printf "%.0f" "$wfps" 2>/dev/null || echo "30")
                        [[ ${CAL_FPS[$w]} -lt 1 ]] && CAL_FPS[$w]=1
                        CAL_DONE[$w]=true
                        log_event "MODE-B" "Worker ${w} calibration: ${CAL_FPS[$w]} fps"
                    fi
                    ;;
                completed)
                    if [[ ${CAL_FPS[$w]} -eq 0 ]]; then
                        local final_fps
                        final_fps=$(echo "$status_resp" | grep -o '"fps":[0-9][0-9.]*' | head -1 | cut -d':' -f2 || echo "")
                        if [[ -n "$final_fps" ]] && [[ "$final_fps" != "0" ]] && [[ "$final_fps" != "0.0" ]]; then
                            CAL_FPS[$w]=$(printf "%.0f" "$final_fps" 2>/dev/null || echo "30")
                            [[ ${CAL_FPS[$w]} -lt 1 ]] && CAL_FPS[$w]=1
                        else
                            CAL_FPS[$w]=30
                        fi
                    fi
                    CAL_DONE[$w]=true
                    log_event "MODE-B" "Worker ${w} calibration completed: ${CAL_FPS[$w]} fps"
                    ;;
                failed)
                    CAL_FPS[$w]=30
                    CAL_DONE[$w]=true
                    log_event "MODE-B" "Worker ${w} calibration failed, using default 30 fps"
                    ;;
            esac
        done

        [[ "$all_done" == "true" ]] && break
    done

    # Cleanup calibration jobs
    for (( w=0; w<n_workers; w++ )); do
        local wurl="${LIVE_WORKERS[$w]}"
        local cal_jid="${CAL_JOB_IDS[$w]}"

        if [[ -n "${CAL_STREAM_PIDS[$w]}" ]]; then
            kill "${CAL_STREAM_PIDS[$w]}" 2>/dev/null || true
            wait "${CAL_STREAM_PIDS[$w]}" 2>/dev/null || true
        fi

        curl -sf -X DELETE "${wurl}/job/${cal_jid}" &>/dev/null || true

        if [[ ${CAL_FPS[$w]} -eq 0 ]]; then
            CAL_FPS[$w]=30
            log_event "MODE-B" "Worker ${w}: no FPS reading, defaulting to 30"
        fi
    done

    local fps_summary=""
    for (( w=0; w<n_workers; w++ )); do
        fps_summary="${fps_summary} w${w}=${CAL_FPS[$w]}"
    done
    log_event "MODE-B" "Calibration results:${fps_summary}"

    # ===== PHASE 2: Calculate proportional splits =====
    local total_fps=0
    for (( w=0; w<n_workers; w++ )); do
        total_fps=$((total_fps + CAL_FPS[$w]))
    done

    if [[ $total_fps -le 0 ]]; then
        log_event "MODE-B" "Total FPS is 0 -- cannot split"
        return 1
    fi

    declare -a W_SS=()
    declare -a W_T=()
    local cursor=$seek_sec

    for (( w=0; w<n_workers; w++ )); do
        W_SS+=("$cursor")

        if [[ $w -eq $((n_workers - 1)) ]]; then
            W_T+=( $((duration - cursor)) )
        else
            local share
            share=$(echo "scale=0; ${CAL_FPS[$w]} * ${remaining} / ${total_fps}" | bc 2>/dev/null || echo "0")
            [[ $share -lt 30 ]] && share=30
            local left=$((duration - cursor))
            [[ $share -gt $((left - 30)) ]] && share=$((left - 30))
            W_T+=("$share")
            cursor=$((cursor + share))
        fi
    done

    for (( w=0; w<n_workers; w++ )); do
        log_event "MODE-B" "Worker ${w} (${CAL_FPS[$w]} fps): ss=${W_SS[$w]} t=${W_T[$w]} (${LIVE_TAGS[$w]})"
    done

    # ===== PHASE 3: Submit real jobs =====
    log_event "MODE-B" "Phase 3: Submitting real jobs"

    declare -a W_JOB_IDS=()
    declare -a W_STREAM_PIDS=()
    declare -a W_STATUS=()
    declare -a W_OTMS=()

    for (( w=0; w<n_workers; w++ )); do
        local jid="${SESSION_ID}_w${w}"
        local wurl="${LIVE_WORKERS[$w]}"
        local wtag="${LIVE_TAGS[$w]}"

        W_JOB_IDS+=("$jid")
        W_STREAM_PIDS+=("")
        W_STATUS+=("pending")

        MULTI_JOB_IDS+=("$jid")

        if ! submit_worker_job "$wurl" "$wtag" "$jid" "$w" "$n_workers" "${W_SS[$w]}" "${W_T[$w]}"; then
            log_event "MODE-B" "Failed to submit job to worker ${w}"
            W_STATUS[$w]="failed"
            continue
        fi

        W_STATUS[$w]="running"

        if { [[ "$wtag" == "remote" ]] || [[ "$wtag" == "beam" ]]; } && { [[ -f "$INPUT_FILE" ]] || [[ "$INPUT_FILE" =~ ^https?:// ]]; }; then
            copy_remux_pipe "$wurl" "$jid" "${W_SS[$w]}" "${W_T[$w]}" "$w" &
            W_STREAM_PIDS[$w]=$!
            MULTI_STREAM_PIDS+=("$!")
        fi
    done

    local any_running=false
    for (( w=0; w<n_workers; w++ )); do
        [[ "${W_STATUS[$w]}" == "running" ]] && any_running=true && break
    done
    if [[ "$any_running" == "false" ]]; then
        log_event "MODE-B" "No workers successfully started -- aborting"
        return 1
    fi

    # ===== PHASE 4: Poll loop =====
    log_event "MODE-B" "Phase 4: Polling for completion"

    declare -A W_DOWNLOADED=()
    declare -A W_STREAM_OFFSETS=()

    local skip_base=0
    [[ "$SKIP_TO_SEGMENT" -gt 0 ]] 2>/dev/null && skip_base=$((SKIP_TO_SEGMENT - 1))
    W_STREAM_OFFSETS["w0_s0"]=$skip_base
    W_STREAM_OFFSETS["w0_s1"]=$skip_base
    log_event "MODE-B" "Segment offset base: ${skip_base} (skip_to_segment=${SKIP_TO_SEGMENT})"

    local wb_start_epoch
    wb_start_epoch=$(date +%s)
    local poll_count=0
    local max_polls=28800
    local workers_completed=0
    local workers_failed=0

    declare -a W_FINAL_DOWNLOADED=()
    for (( w=0; w<n_workers; w++ )); do
        W_FINAL_DOWNLOADED+=(false)
    done

    while [[ $poll_count -lt $max_polls ]]; do
        sleep 0.25
        poll_count=$((poll_count + 1))

        local combined_fps=0

        for (( w=0; w<n_workers; w++ )); do
            [[ "${W_STATUS[$w]}" == "completed" ]] && continue
            [[ "${W_STATUS[$w]}" == "failed" ]] && continue

            local wurl="${LIVE_WORKERS[$w]}"
            local jid="${W_JOB_IDS[$w]}"

            local status_resp
            status_resp=$(curl -sf --connect-timeout 2 --max-time 5 "${wurl}/status/${jid}" 2>/dev/null || echo "")
            [[ -z "$status_resp" ]] && continue

            local wstatus
            wstatus=$(echo "$status_resp" | grep -o '"status":"[^"]*"' | cut -d'"' -f4 || echo "")

            case "$wstatus" in
                completed)
                    log_event "MODE-B" "Worker ${w} completed"

                    if [[ -n "${W_STREAM_PIDS[$w]}" ]]; then
                        wait "${W_STREAM_PIDS[$w]}" 2>/dev/null || true
                        W_STREAM_PIDS[$w]=""
                    fi

                    W_STATUS[$w]="completed"
                    workers_completed=$((workers_completed + 1))

                    _weighted_update_offsets "$w"

                    beam_download_worker_segments "$wurl" "$jid" "$OUTPUT_DIR" "$w" W_DOWNLOADED W_STREAM_OFFSETS
                    W_FINAL_DOWNLOADED[$w]=true
                    ;;
                failed)
                    local err_msg
                    err_msg=$(echo "$status_resp" | grep -o '"error":"[^"]*"' | cut -d'"' -f4 || echo "unknown")
                    log_event "MODE-B" "Worker ${w} failed: ${err_msg}"

                    if [[ -n "${W_STREAM_PIDS[$w]}" ]]; then
                        kill "${W_STREAM_PIDS[$w]}" 2>/dev/null || true
                        W_STREAM_PIDS[$w]=""
                    fi

                    W_STATUS[$w]="failed"
                    workers_failed=$((workers_failed + 1))
                    ;;
                running)
                    local wfps
                    wfps=$(echo "$status_resp" | grep -o '"fps":[0-9][0-9.]*' | head -1 | cut -d':' -f2 || echo "0")
                    combined_fps=$(echo "$combined_fps + ${wfps:-0}" | bc 2>/dev/null || echo "$combined_fps")
                    W_OTMS[$w]=$(echo "$status_resp" | grep -o '"out_time_ms":[0-9][0-9]*' | head -1 | cut -d':' -f2 || echo "0")

                    if [[ -n "${W_STREAM_OFFSETS["w${w}_s0"]+_}" ]]; then
                        beam_download_worker_segments "$wurl" "$jid" "$OUTPUT_DIR" "$w" W_DOWNLOADED W_STREAM_OFFSETS
                    fi
                    ;;
            esac
        done

        # --- Manifest POST ---
        if [[ -n "${MANIFEST_CALLBACK_URL:-}" ]] && [[ -f "${OUTPUT_DIR}/output.mpd" ]]; then
            local should_post=false
            if [[ "$BEAM_MANIFEST_POSTED" == "false" ]]; then
                local has_init=false has_media=false
                for f in "${OUTPUT_DIR}"/init-stream*.m4s; do
                    [[ -f "$f" ]] && has_init=true && break
                done
                for f in "${OUTPUT_DIR}"/chunk-stream*.m4s; do
                    [[ -f "$f" ]] && has_media=true && break
                done
                [[ "$has_init" == "true" ]] && [[ "$has_media" == "true" ]] && should_post=true
            else
                should_post=true
            fi

            if [[ "$should_post" == "true" ]]; then
                local manifest_hash
                manifest_hash=$(md5sum "${OUTPUT_DIR}/output.mpd" 2>/dev/null | cut -d' ' -f1)
                if [[ "${manifest_hash}" != "${LAST_MANIFEST_HASH:-}" ]]; then
                    curl -sf -X POST \
                        -H "Content-Type: application/dash+xml" \
                        --data-binary @"${OUTPUT_DIR}/output.mpd" \
                        "${MANIFEST_CALLBACK_URL}" 2>/dev/null || true
                    LAST_MANIFEST_HASH="${manifest_hash}"
                    if [[ "$BEAM_MANIFEST_POSTED" == "false" ]]; then
                        log_event "MODE-B" "Initial manifest posted"
                        BEAM_MANIFEST_POSTED=true
                    fi
                fi
            fi
        fi

        # --- Progress reporting ---
        if [[ $((poll_count % 4)) -eq 0 ]]; then
            local active_count=0
            for (( w=0; w<n_workers; w++ )); do
                [[ "${W_STATUS[$w]}" == "running" ]] && active_count=$((active_count + 1))
            done

            # Calculate meaningful out_time from best worker progress
            local best_otms=0
            for (( w=0; w<n_workers; w++ )); do
                local w_otms=${W_OTMS[$w]:-0}
                (( w_otms > best_otms )) && best_otms=$w_otms
            done
            local out_time_s=$((best_otms / 1000000))
            local out_time_us=$best_otms
            local elapsed_s=$(( $(date +%s) - wb_start_epoch ))
            local speed_val="0.0"
            (( elapsed_s > 0 )) && speed_val=$(awk "BEGIN{printf \"%.1f\", ${out_time_s}/${elapsed_s}}")
            local time_str
            time_str=$(printf "%02d:%02d:%02d.00" \
                $((out_time_s / 3600)) $(( (out_time_s % 3600) / 60 )) $((out_time_s % 60)))

            printf "frame=0 fps=%s q=-1.0 size=N/A time=%s bitrate=N/A speed=%sx    [%d/%d workers done, %d active]\n" \
                "${combined_fps}" "$time_str" "$speed_val" "$workers_completed" "$n_workers" "$active_count" >&2

            if [[ -n "${PROGRESS_URL:-}" ]]; then
                curl -sf -X POST \
                    --connect-timeout 1 --max-time 2 \
                    -d "frame=0&fps=${combined_fps}&speed=${speed_val}x&out_time_us=${out_time_us}&progress=continue" \
                    "${PROGRESS_URL}" 2>/dev/null &
            fi
        fi

        # --- Termination ---
        local all_finished=true
        for (( w=0; w<n_workers; w++ )); do
            if [[ "${W_STATUS[$w]}" != "completed" ]] && [[ "${W_STATUS[$w]}" != "failed" ]]; then
                all_finished=false
                break
            fi
        done

        [[ "$all_finished" == "true" ]] && break

        if [[ $((poll_count % 120)) -eq 0 ]]; then
            log_event "MODE-B" "Progress: ${workers_completed}/${n_workers} done, ${workers_failed} failed"
        fi
    done

    # ===== Final downloads =====
    for (( w=0; w<n_workers; w++ )); do
        if [[ "${W_STATUS[$w]}" == "completed" ]] && [[ "${W_FINAL_DOWNLOADED[$w]}" == "false" ]]; then
            _weighted_update_offsets "$w"
            beam_download_worker_segments "${LIVE_WORKERS[$w]}" "${W_JOB_IDS[$w]}" "$OUTPUT_DIR" "$w" W_DOWNLOADED W_STREAM_OFFSETS
        fi
    done

    if [[ -n "${MANIFEST_CALLBACK_URL:-}" ]] && [[ -f "${OUTPUT_DIR}/output.mpd" ]]; then
        curl -sf -X POST \
            -H "Content-Type: application/dash+xml" \
            --data-binary @"${OUTPUT_DIR}/output.mpd" \
            "${MANIFEST_CALLBACK_URL}" 2>/dev/null || true
    fi

    printf "frame=9999 fps=0.0 q=-1.0 size=N/A time=99:99:99.99 bitrate=N/A speed=0.0x\n" >&2

    if [[ $workers_completed -eq 0 ]]; then
        log_event "MODE-B" "All workers failed"
        return 1
    fi

    if [[ $workers_failed -gt 0 ]]; then
        log_event "MODE-B" "Completed with ${workers_failed} failed workers (${workers_completed}/${n_workers} succeeded)"
    else
        log_event "MODE-B" "All ${n_workers} workers completed successfully"
    fi

    log_event "MODE-B" "Total segments downloaded: ${#W_DOWNLOADED[@]}"
    return 0
}

# ============================================================================
# MODE C: BitTorrent-style (calibration + queues + prefetch + endgame + steal)
# ============================================================================

_bt_distribute_proportionally() {
    local n_workers=$1
    local n_chunks=$2

    local -a pending=()
    for (( c=0; c<n_chunks; c++ )); do
        [[ "${WS_CHUNK_STATE[$c]}" == "pending" ]] && pending+=("$c")
    done

    local remaining=${#pending[@]}
    [[ $remaining -eq 0 ]] && return

    local total_fps=0
    for (( w=0; w<n_workers; w++ )); do
        local fps_int
        fps_int=$(printf "%.0f" "${BT_WORKER_FPS[$w]}" 2>/dev/null || echo "0")
        total_fps=$((total_fps + fps_int))
    done

    if [[ $total_fps -le 0 ]]; then
        total_fps=$n_workers
        for (( w=0; w<n_workers; w++ )); do
            BT_WORKER_FPS[$w]=1
        done
    fi

    local -a shares=()
    local assigned=0
    local fastest_w=0
    local fastest_fps=0
    for (( w=0; w<n_workers; w++ )); do
        local fps_int
        fps_int=$(printf "%.0f" "${BT_WORKER_FPS[$w]}" 2>/dev/null || echo "0")
        local share=$((remaining * fps_int / total_fps))
        shares+=("$share")
        assigned=$((assigned + share))
        if [[ $fps_int -gt $fastest_fps ]]; then
            fastest_fps=$fps_int
            fastest_w=$w
        fi
    done

    local leftover=$((remaining - assigned))
    shares[$fastest_w]=$(( ${shares[$fastest_w]} + leftover ))

    local idx=0
    for (( w=0; w<n_workers; w++ )); do
        local share=${shares[$w]}
        for (( s=0; s<share && idx<remaining; s++, idx++ )); do
            eval "BT_QUEUE_W${w}+=( ${pending[$idx]} )"
        done
    done

    local dist_msg="Distributed ${remaining} chunks:"
    for (( w=0; w<n_workers; w++ )); do
        local qlen
        eval "qlen=\${#BT_QUEUE_W${w}[@]}"
        dist_msg+=" W${w}=${qlen}"
    done
    log_event "MODE-C" "$dist_msg"
}

# Sets BT_STEAL_RESULT (must NOT be called via $() — subshell kills queue updates)
_bt_steal_work() {
    local thief=$1
    local n_workers=$2
    BT_STEAL_RESULT=-1

    local best_w=-1
    local best_len=0

    for (( w=0; w<n_workers; w++ )); do
        [[ $w -eq $thief ]] && continue
        local qlen
        eval "qlen=\${#BT_QUEUE_W${w}[@]}"
        if [[ $qlen -gt $best_len ]]; then
            best_len=$qlen
            best_w=$w
        fi
    done

    if [[ $best_w -ge 0 ]] && [[ $best_len -gt 0 ]]; then
        # Copy queue to temp array, pop last, write back
        local _tmp_q=()
        eval "_tmp_q=( \"\${BT_QUEUE_W${best_w}[@]}\" )"
        local stolen="${_tmp_q[-1]}"
        # Only steal chunks that are still pending
        if [[ "${WS_CHUNK_STATE[$stolen]:-}" != "pending" ]]; then
            # Remove non-pending chunk and return nothing
            _tmp_q=("${_tmp_q[@]:0:${#_tmp_q[@]}-1}")
            eval "BT_QUEUE_W${best_w}=( \"\${_tmp_q[@]}\" )"
            return
        fi
        _tmp_q=("${_tmp_q[@]:0:${#_tmp_q[@]}-1}")
        eval "BT_QUEUE_W${best_w}=( \"\${_tmp_q[@]}\" )"
        local new_len=${#_tmp_q[@]}
        log_event "MODE-C" "Worker ${thief} stole chunk ${stolen} from worker ${best_w} (was ${best_len}, now ${new_len})"
        BT_STEAL_RESULT="$stolen"
    fi
}

_bt_prefetch_next() {
    local w=$1
    local n_workers=$2

    [[ "${LIVE_TAGS[$w]}" != "remote" ]] && [[ "${LIVE_TAGS[$w]}" != "beam" ]] && return
    { [[ ! -f "$INPUT_FILE" ]] && [[ ! "$INPUT_FILE" =~ ^https?:// ]]; } && return

    if [[ -n "${BT_PREFETCH_PID[$w]:-}" ]]; then
        if kill -0 "${BT_PREFETCH_PID[$w]}" 2>/dev/null; then
            return
        fi
        BT_PREFETCH_PID[$w]=""
    fi

    local next_chunk
    eval "next_chunk=\${BT_QUEUE_W${w}[0]:-}"
    [[ -z "$next_chunk" ]] && return

    local prefetch_jid="${SESSION_ID}_pre${next_chunk}"
    BT_PREFETCH_JOB[$w]="$prefetch_jid"
    BT_PREFETCH_CHUNK[$w]="$next_chunk"

    local wurl="${LIVE_WORKERS[$w]}"
    local ss="${WS_CHUNK_SS[$next_chunk]}"
    local t="${WS_CHUNK_T[$next_chunk]}"

    log_event "MODE-C" "Prefetching chunk ${next_chunk} input for worker ${w} (ss=${ss} t=${t})"

    submit_worker_job "$wurl" "remote" "$prefetch_jid" "$next_chunk" "$n_workers" "$ss" "$t" || {
        BT_PREFETCH_JOB[$w]=""
        BT_PREFETCH_CHUNK[$w]=""
        return
    }

    copy_remux_pipe "$wurl" "$prefetch_jid" "$ss" "$t" "$w" &
    BT_PREFETCH_PID[$w]=$!
    MULTI_STREAM_PIDS+=("$!")
    MULTI_JOB_IDS+=("$prefetch_jid")
}

_bt_endgame_check() {
    local n_workers=$1
    local n_chunks=$2

    local pending_count=0 idle_workers=() encoding_chunks=()
    for (( c=0; c<n_chunks; c++ )); do
        [[ "${WS_CHUNK_STATE[$c]}" == "pending" ]] && pending_count=$((pending_count + 1))
    done
    [[ $pending_count -gt 0 ]] && return

    for (( w=0; w<n_workers; w++ )); do
        if [[ ${WS_WORKER_BUSY[$w]} -eq 0 ]]; then
            idle_workers+=("$w")
        fi
    done
    [[ ${#idle_workers[@]} -eq 0 ]] && return

    for (( c=0; c<n_chunks; c++ )); do
        if [[ "${WS_CHUNK_STATE[$c]}" == "encoding" ]]; then
            encoding_chunks+=("$c")
        fi
    done
    [[ ${#encoding_chunks[@]} -eq 0 ]] && return

    local slowest_chunk=-1
    local slowest_fps=999999
    for c in "${encoding_chunks[@]}"; do
        local cw=${WS_CHUNK_WORKER[$c]}
        local wfps
        wfps=$(printf "%.0f" "${BT_WORKER_FPS[$cw]}" 2>/dev/null || echo "0")
        [[ "${BT_ENDGAME_DUPED[$c]:-0}" == "1" ]] && continue
        if [[ $wfps -lt $slowest_fps ]]; then
            slowest_fps=$wfps
            slowest_chunk=$c
        fi
    done

    [[ $slowest_chunk -lt 0 ]] && return

    local dup_w=${idle_workers[0]}
    local dup_jid="${SESSION_ID}_dup${slowest_chunk}"
    local wurl="${LIVE_WORKERS[$dup_w]}"
    local wtag="${LIVE_TAGS[$dup_w]}"
    local ss="${WS_CHUNK_SS[$slowest_chunk]}"
    local t="${WS_CHUNK_T[$slowest_chunk]}"

    log_event "MODE-C" "Endgame: duplicating chunk ${slowest_chunk} (fps=${slowest_fps}) to worker ${dup_w}"

    BT_ENDGAME_DUPED[$slowest_chunk]=1

    BT_DUP_CHUNK[$dup_w]=$slowest_chunk
    BT_DUP_JOB[$dup_w]="$dup_jid"
    MULTI_JOB_IDS+=("$dup_jid")

    WS_WORKER_BUSY[$dup_w]=1
    WS_WORKER_CHUNK[$dup_w]=$slowest_chunk

    if ! submit_worker_job "$wurl" "$wtag" "$dup_jid" "$slowest_chunk" "$n_chunks" "$ss" "$t"; then
        log_event "MODE-C" "Endgame: failed to submit dup for chunk ${slowest_chunk}"
        WS_WORKER_BUSY[$dup_w]=0
        WS_WORKER_CHUNK[$dup_w]=-1
        return
    fi

    if { [[ "$wtag" == "remote" ]] || [[ "$wtag" == "beam" ]]; } && { [[ -f "$INPUT_FILE" ]] || [[ "$INPUT_FILE" =~ ^https?:// ]]; }; then
        copy_remux_pipe "$wurl" "$dup_jid" "$ss" "$t" "$dup_w" &
        WS_WORKER_STREAM_PID[$dup_w]=$!
        MULTI_STREAM_PIDS+=("$!")
    fi
}

_dispatch_bittorrent() {
    # Ignore SIGPIPE so Plex closing stderr doesn't kill us.
    # Plex closes the transcoder's pipes after ~150s if no client is
    # requesting segments, but Mode C needs to continue regardless.
    trap '' PIPE

    local n_workers=${#LIVE_WORKERS[@]}
    local chunk_dur="${PLEXBEAM_CHUNK_DURATION:-300}"

    log_event "MODE-C" "Starting BitTorrent-style dispatch: ${n_workers} workers, ${chunk_dur}s chunks"

    # ===== Phase 0: Setup =====
    local duration
    duration=$(get_video_duration "$INPUT_FILE")
    if [[ -z "$duration" ]] || [[ "$duration" -le 0 ]]; then
        log_event "MODE-C" "Cannot determine duration -- falling back to single worker"
        return 1
    fi
    log_event "MODE-C" "Input duration: ${duration}s"

    local seek_sec=0
    if [[ -n "$SEEK_POSITION" ]]; then
        seek_sec=$(printf "%.0f" "$SEEK_POSITION" 2>/dev/null || echo "0")
    fi

    local remaining=$((duration - seek_sec))
    if [[ $remaining -le 0 ]]; then
        log_event "MODE-C" "Nothing to encode after seek"
        return 1
    fi

    local n_chunks=$(( (remaining + chunk_dur - 1) / chunk_dur ))
    if [[ $n_chunks -le 1 ]]; then
        log_event "MODE-C" "Only 1 chunk needed -- falling back to single worker"
        return 1
    fi

    # Per-chunk state (same names as Mode A for shared helper compatibility)
    declare -a WS_CHUNK_SS=()
    declare -a WS_CHUNK_T=()
    declare -a WS_CHUNK_STATE=()
    declare -a WS_CHUNK_WORKER=()
    declare -a WS_CHUNK_JOB_ID=()
    declare -a WS_CHUNK_START_TIME=()
    declare -a WS_CHUNK_VID=()
    declare -a WS_CHUNK_AUD=()

    for (( c=0; c<n_chunks; c++ )); do
        local ss=$((seek_sec + c * chunk_dur))
        local t=$chunk_dur
        if [[ $((ss + t)) -gt $duration ]]; then
            t=$((duration - ss))
        fi
        WS_CHUNK_SS+=("$ss")
        WS_CHUNK_T+=("$t")
        WS_CHUNK_STATE+=("pending")
        WS_CHUNK_WORKER+=(-1)
        WS_CHUNK_JOB_ID+=("")
        WS_CHUNK_VID+=(0)
        WS_CHUNK_AUD+=(0)
    done

    log_event "MODE-C" "Created ${n_chunks} chunks: ss=${seek_sec}, dur=${remaining}s, chunk=${chunk_dur}s"

    # Per-worker state
    declare -a WS_WORKER_BUSY=()
    declare -a WS_WORKER_CHUNK=()
    declare -a WS_WORKER_STREAM_PID=()
    declare -a BT_WORKER_FPS=()
    declare -a BT_WORKER_CALIBRATED=()
    declare -a BT_PREFETCH_PID=()
    declare -a BT_PREFETCH_JOB=()
    declare -a BT_PREFETCH_CHUNK=()
    declare -a BT_DUP_CHUNK=()
    declare -a BT_DUP_JOB=()
    declare -A BT_ENDGAME_DUPED=()
    declare -A WS_DOWNLOAD_PID=()
    BT_STEAL_RESULT=-1

    for (( w=0; w<n_workers; w++ )); do
        WS_WORKER_BUSY+=(0)
        WS_WORKER_CHUNK+=(-1)
        WS_WORKER_STREAM_PID+=("")
        BT_WORKER_FPS+=(0)
        BT_WORKER_CALIBRATED+=(0)
        BT_PREFETCH_PID+=("")
        BT_PREFETCH_JOB+=("")
        BT_PREFETCH_CHUNK+=("")
        BT_DUP_CHUNK+=(-1)
        BT_DUP_JOB+=("")
        eval "declare -a BT_QUEUE_W${w}=()"
    done

    DISPATCHED_TO_REMOTE=true

    # ===== Phase 0.5: Fast-start — real transcoder for instant playback =====
    # Start IMMEDIATELY before any uploads. Plex kills the session if no
    # segments arrive within ~120-180s. The real Plex transcoder (local CPU)
    # produces segments within seconds. Once GPU workers take over, we kill it.
    local fast_start_pid=""
    if [[ -x "$REAL_TRANSCODER" ]]; then
        "$REAL_TRANSCODER" "${ORIGINAL_ARGS[@]}" 2>>"${SESSION_DIR}/fast_start.log" &
        fast_start_pid=$!
        log_event "MODE-C" "Fast-start: real transcoder pid=${fast_start_pid}"
    fi

    # ===== Staged upload: optional single-worker optimization =====
    # Upload file ONCE and have all NVENC sessions read from local disk.
    # Only used when PLEXBEAM_STAGED_UPLOAD=1 because the blocking upload
    # is slower than parallel beam streams for most bandwidth scenarios.
    STAGED_SESSION_ID=""
    STAGED_UPLOAD_PID=""
    local unique_urls
    unique_urls=$(printf '%s\n' "${LIVE_WORKERS[@]}" | sort -u | wc -l)
    if [[ "${PLEXBEAM_STAGED_UPLOAD:-0}" == "1" ]] && [[ "$unique_urls" -eq 1 ]] && [[ "$n_workers" -ge 2 ]] && [[ -f "$INPUT_FILE" ]]; then
        local stage_url="${LIVE_WORKERS[0]}"
        STAGED_SESSION_ID="${SESSION_ID}"
        log_event "MODE-C" "Single-worker pool detected (${n_workers}x ${stage_url}) — staging file in background"

        local upload_rate="${PLEXBEAM_UPLOAD_RATE:-0}"
        local rate_flag=""
        [[ "$upload_rate" != "0" ]] && rate_flag="--limit-rate ${upload_rate}"

        # Upload full file to worker in BACKGROUND (fast-start keeps Plex happy meanwhile)
        (
            local stage_start=$(date +%s)
            # Pipe through cat to force chunked transfer encoding.
            # Cloudflare Tunnel returns 413 for large Content-Length uploads.
            cat "$INPUT_FILE" | \
            curl -sfg --http1.1 -X PUT \
                --connect-timeout "$REMOTE_TIMEOUT" \
                --max-time 14400 \
                ${rate_flag} \
                -T - \
                "${stage_url}/beam/stage/${STAGED_SESSION_ID}" \
                > /dev/null 2>&1
            local stage_rc=$?
            local stage_end=$(date +%s)
            local stage_dur=$((stage_end - stage_start))
            if [[ $stage_rc -eq 0 ]]; then
                echo "$(date -Iseconds) | MODE-C | Staged upload complete in ${stage_dur}s" >> "${LOG_BASE}/cartridge_events.log"
            else
                echo "$(date -Iseconds) | MODE-C | Staged upload FAILED rc=${stage_rc}" >> "${LOG_BASE}/cartridge_events.log"
            fi
        ) &
        STAGED_UPLOAD_PID=$!
        log_event "MODE-C" "Staged upload started in background (pid=${STAGED_UPLOAD_PID})"
    fi

    local staging_dir="${OUTPUT_DIR}/staging"
    mkdir -p "$staging_dir"

    local next_processable=0
    local skip_base=0
    [[ "$SKIP_TO_SEGMENT" -gt 0 ]] 2>/dev/null && skip_base=$((SKIP_TO_SEGMENT - 1))
    local cumulative_vid_offset=$skip_base
    local cumulative_aud_offset=$skip_base
    local chunks_completed=0
    local total_segs_output=0

    log_event "MODE-C" "Segment offset base: ${skip_base} (skip_to_segment=${SKIP_TO_SEGMENT})"

    local calibration_complete=false
    local distribution_done=false

    # ===== Phase 1: Wait for staged upload, then assign chunks =====
    if [[ -n "$STAGED_UPLOAD_PID" ]]; then
        log_event "MODE-C" "Waiting for staged upload to complete before assigning chunks..."
        wait "$STAGED_UPLOAD_PID" 2>/dev/null
        local stage_rc=$?
        STAGED_UPLOAD_PID=""
        if [[ $stage_rc -ne 0 ]]; then
            log_event "MODE-C" "Staged upload process failed — falling back to beam streaming"
            STAGED_SESSION_ID=""
        fi
    fi

    local cal_chunks=$n_workers
    if [[ $cal_chunks -gt $n_chunks ]]; then
        cal_chunks=$n_chunks
    fi

    for (( c=0; c<cal_chunks; c++ )); do
        _ws_assign_chunk "$c" "$c"
    done

    log_event "MODE-C" "Calibration: assigned ${cal_chunks} initial chunks (one per worker)"

    # ===== Phase 1b: Progressive download for chunk 0 =====
    # Plex kills the session if no segments appear in the output directory within
    # ~60-120s.  Mode C's normal flow waits for entire chunks to complete before
    # downloading (~90s for a 300s chunk).  This background loop progressively
    # downloads chunk 0 segments as they're produced, writes init+first media
    # segments to OUTPUT_DIR, and POSTs the manifest to keep Plex alive.
    local c0_jid="${WS_CHUNK_JOB_ID[0]}"
    local c0_wurl="${LIVE_WORKERS[${WS_CHUNK_WORKER[0]}]}"
    local c0_staging="${staging_dir}/chunk_0"
    mkdir -p "$c0_staging"

    (
        set +e; set +u; set +o pipefail
        downloaded=""
        manifest_posted=false
        c0_skip_base=${skip_base}
        fast_pid=${fast_start_pid:-}

        while true; do
            sleep 2

            seg_list=$(curl -sf --connect-timeout 2 "${c0_wurl}/beam/segments/${c0_jid}" 2>/dev/null || echo "")
            [[ -z "$seg_list" ]] || [[ "$seg_list" == '{"files":[]}' ]] && continue

            seg_files=$(echo "$seg_list" | sed 's/.*\[//;s/\].*//;s/"//g' | tr ',' '\n' | grep -v '^$' || true)
            [[ -z "$seg_files" ]] && continue

            while IFS= read -r seg; do
                [[ -z "$seg" ]] && continue
                [[ "$seg" == "output.mpd" ]] && continue
                { echo "$downloaded" | grep -qF "$seg" 2>/dev/null; } 2>/dev/null && continue

                # Download to staging
                curl -sf --connect-timeout 5 --max-time 30 \
                    "${c0_wurl}/beam/segment/${c0_jid}/${seg}" \
                    -o "${c0_staging}/${seg}" 2>/dev/null || continue
                downloaded="${downloaded}${seg}
"

                # Copy chunk 0 segments to OUTPUT_DIR with skip_to_segment offset
                # so segment numbering matches what Plex expects.
                if [[ "$seg" =~ ^chunk-stream([0-9]+)-([0-9]+)\.m4s$ ]]; then
                    local_sid="${BASH_REMATCH[1]}"
                    local_num=$((10#${BASH_REMATCH[2]} + c0_skip_base))
                    out_name=$(printf "chunk-stream%s-%05d.m4s" "$local_sid" "$local_num")
                    cp "${c0_staging}/${seg}" "${OUTPUT_DIR}/${out_name}" 2>/dev/null
                else
                    # init segments — copy as-is
                    cp "${c0_staging}/${seg}" "${OUTPUT_DIR}/${seg}" 2>/dev/null
                fi
            done <<< "$seg_files"

            # Re-download and POST manifest every poll cycle so Plex knows
            # about newly produced segments (SegmentTimeline grows as ffmpeg
            # encodes more data — Plex needs periodic updates).
            if [[ -n "${MANIFEST_CALLBACK_URL:-}" ]]; then
                first_seg=$(printf "chunk-stream0-%05d.m4s" "$((1 + c0_skip_base))")
                if [[ -f "${OUTPUT_DIR}/init-stream0.m4s" ]] && \
                   [[ -f "${OUTPUT_DIR}/${first_seg}" ]]; then
                    curl -sf "${c0_wurl}/beam/segment/${c0_jid}/output.mpd" \
                        -o "${OUTPUT_DIR}/output.mpd" 2>/dev/null
                    if [[ -f "${OUTPUT_DIR}/output.mpd" ]] && [[ $c0_skip_base -gt 0 ]]; then
                        sed -i "s/startNumber=\"1\"/startNumber=\"$((c0_skip_base + 1))\"/" "${OUTPUT_DIR}/output.mpd" 2>/dev/null
                    fi
                    if [[ -f "${OUTPUT_DIR}/output.mpd" ]]; then
                        curl -sf -X POST \
                            -H "Content-Type: application/dash+xml" \
                            --data-binary @"${OUTPUT_DIR}/output.mpd" \
                            "${MANIFEST_CALLBACK_URL}" 2>/dev/null || true
                        if [[ "$manifest_posted" != "true" ]]; then
                            manifest_posted=true
                            # NOTE: Do NOT kill fast-start here. The fast-start holds
                            # Plex's HTTP pipeline connection (-manifest_name with
                            # X-Plex-Http-Pipeline=infinite). Killing it drops the
                            # pipeline, and Plex interprets that as a crash, killing
                            # the entire session. Fast-start is killed at Mode C
                            # completion instead (line ~2786).
                            echo "[PROGRESSIVE] initial manifest posted (first_seg=${first_seg}, startNumber=$((c0_skip_base + 1)))" >> "${staging_dir}/.dl_debug.log" 2>/dev/null
                        fi
                    fi
                fi
            fi

            # Check if chunk 0 job completed — stop progressive download
            c0_status=$(curl -sf --connect-timeout 1 "${c0_wurl}/status/${c0_jid}" 2>/dev/null | \
                grep -o '"status":"[^"]*"' | cut -d'"' -f4 || echo "")
            if [[ "$c0_status" == "completed" ]] || [[ "$c0_status" == "cancelled" ]] || [[ "$c0_status" == "failed" ]]; then
                echo "[PROGRESSIVE] chunk 0 ended (status=$c0_status), exiting" >> "${staging_dir}/.dl_debug.log" 2>/dev/null
                break
            fi
        done
    ) &
    local progressive_pid=$!
    log_event "MODE-C" "Started progressive download for chunk 0 (pid=${progressive_pid})"

    # ===== Main poll loop =====
    local bt_start_epoch
    bt_start_epoch=$(date +%s)
    log_event "MODE-C" "Entering BitTorrent poll loop"

    # Disable errexit in poll loop — Plex may close our stderr pipe at any time
    # (no client connected), and we must continue regardless.
    set +e

    local poll_count=0
    local max_polls=28800
    local fail_count=0
    local max_fails=$((n_chunks * 2))

    while [[ $poll_count -lt $max_polls ]]; do
        sleep 0.25
        poll_count=$((poll_count + 1))

        local total_fps=0

        # --- Poll busy workers ---
        for (( w=0; w<n_workers; w++ )); do
            [[ ${WS_WORKER_BUSY[$w]} -eq 0 ]] && continue

            local c=${WS_WORKER_CHUNK[$w]}
            local wurl="${LIVE_WORKERS[$w]}"

            # Determine job_id (could be a dup job)
            local jid
            if [[ "${BT_DUP_CHUNK[$w]:-}" -ge 0 ]] && [[ -n "${BT_DUP_JOB[$w]:-}" ]] && [[ ${BT_DUP_CHUNK[$w]} -eq $c ]]; then
                jid="${BT_DUP_JOB[$w]}"
            else
                jid="${WS_CHUNK_JOB_ID[$c]}"
            fi

            local status_resp
            status_resp=$(curl -sf --connect-timeout 2 --max-time 5 "${wurl}/status/${jid}" 2>/dev/null || echo "")
            [[ -z "$status_resp" ]] && continue

            local wstatus
            wstatus=$(echo "$status_resp" | grep -o '"status":"[^"]*"' | cut -d'"' -f4 || echo "")

            case "$wstatus" in
                completed)
                    local final_fps
                    final_fps=$(echo "$status_resp" | grep -o '"fps":[0-9][0-9.]*' | head -1 | cut -d':' -f2 || echo "0")
                    if [[ -n "$final_fps" ]] && [[ "$final_fps" != "0" ]]; then
                        BT_WORKER_FPS[$w]="$final_fps"
                    fi
                    BT_WORKER_CALIBRATED[$w]=1

                    log_event "MODE-C" "Worker ${w} finished chunk ${c} (fps=${BT_WORKER_FPS[$w]})"

                    # If chunk already completed by another worker (endgame race)
                    if [[ "${WS_CHUNK_STATE[$c]}" == "completed" ]]; then
                        log_event "MODE-C" "Endgame: chunk ${c} already completed, discarding dup from worker ${w}"
                        curl -sf -X DELETE "${wurl}/job/${jid}" &>/dev/null || true
                        if [[ -n "${WS_WORKER_STREAM_PID[$w]:-}" ]]; then
                            kill "${WS_WORKER_STREAM_PID[$w]}" 2>/dev/null || true
                            WS_WORKER_STREAM_PID[$w]=""
                        fi
                        WS_WORKER_BUSY[$w]=0
                        WS_WORKER_CHUNK[$w]=-1
                        BT_DUP_CHUNK[$w]=-1
                        BT_DUP_JOB[$w]=""
                        continue
                    fi

                    if [[ -n "${WS_WORKER_STREAM_PID[$w]:-}" ]]; then
                        kill "${WS_WORKER_STREAM_PID[$w]}" 2>/dev/null || true
                        wait "${WS_WORKER_STREAM_PID[$w]}" 2>/dev/null || true
                        WS_WORKER_STREAM_PID[$w]=""
                    fi

                    # If dup winner, cancel the original
                    if [[ -n "${BT_DUP_JOB[$w]:-}" ]] && [[ "${BT_DUP_CHUNK[$w]:-}" -eq "$c" ]]; then
                        local orig_w=${WS_CHUNK_WORKER[$c]}
                        local orig_jid="${WS_CHUNK_JOB_ID[$c]}"
                        if [[ $orig_w -ge 0 ]] && [[ $orig_w -ne $w ]]; then
                            curl -sf -X DELETE "${LIVE_WORKERS[$orig_w]}/job/${orig_jid}" &>/dev/null || true
                            if [[ -n "${WS_WORKER_STREAM_PID[$orig_w]:-}" ]]; then
                                kill "${WS_WORKER_STREAM_PID[$orig_w]}" 2>/dev/null || true
                                WS_WORKER_STREAM_PID[$orig_w]=""
                            fi
                            WS_WORKER_BUSY[$orig_w]=0
                            WS_WORKER_CHUNK[$orig_w]=-1
                            log_event "MODE-C" "Endgame: cancelled original chunk ${c} on worker ${orig_w}"
                        fi
                        WS_CHUNK_JOB_ID[$c]="$jid"
                        WS_CHUNK_WORKER[$c]=$w
                        BT_DUP_CHUNK[$w]=-1
                        BT_DUP_JOB[$w]=""
                    fi

                    _ws_download_chunk_bg "$w" "$c"
                    WS_CHUNK_STATE[$c]="downloading"

                    # Free worker immediately so it can take next chunk
                    WS_WORKER_BUSY[$w]=0
                    WS_WORKER_CHUNK[$w]=-1

                    # Clean up dead prefetch PID
                    if [[ -n "${BT_PREFETCH_PID[$w]:-}" ]]; then
                        if ! kill -0 "${BT_PREFETCH_PID[$w]}" 2>/dev/null; then
                            BT_PREFETCH_PID[$w]=""
                        fi
                    fi
                    ;;

                failed)
                    local err_msg
                    err_msg=$(echo "$status_resp" | grep -o '"error":"[^"]*"' | cut -d'"' -f4 || echo "unknown")
                    log_event "MODE-C" "Worker ${w} failed chunk ${c}: ${err_msg}"

                    if [[ -n "${WS_WORKER_STREAM_PID[$w]:-}" ]]; then
                        kill "${WS_WORKER_STREAM_PID[$w]}" 2>/dev/null || true
                        WS_WORKER_STREAM_PID[$w]=""
                    fi

                    # If dup failed, just free the worker
                    if [[ -n "${BT_DUP_JOB[$w]:-}" ]] && [[ "${BT_DUP_CHUNK[$w]:-}" -eq "$c" ]]; then
                        BT_DUP_CHUNK[$w]=-1
                        BT_DUP_JOB[$w]=""
                        WS_WORKER_BUSY[$w]=0
                        WS_WORKER_CHUNK[$w]=-1
                        fail_count=$((fail_count + 1))
                        continue
                    fi

                    WS_CHUNK_STATE[$c]="pending"
                    WS_CHUNK_WORKER[$c]=-1
                    WS_WORKER_BUSY[$w]=0
                    WS_WORKER_CHUNK[$w]=-1
                    fail_count=$((fail_count + 1))

                    if [[ ${BT_WORKER_CALIBRATED[$w]} -eq 0 ]]; then
                        BT_WORKER_CALIBRATED[$w]=1
                        BT_WORKER_FPS[$w]=1
                    fi

                    if [[ $fail_count -ge $max_fails ]]; then
                        log_event "MODE-C" "Too many failures (${fail_count}) -- aborting"
                        return 1
                    fi
                    ;;

                running)
                    local wfps
                    wfps=$(echo "$status_resp" | grep -o '"fps":[0-9][0-9.]*' | head -1 | cut -d':' -f2 || echo "0")
                    if [[ -n "$wfps" ]] && [[ "$wfps" != "0" ]]; then
                        BT_WORKER_FPS[$w]="$wfps"
                    fi
                    local fps_int
                    fps_int=$(printf "%.0f" "${wfps:-0}" 2>/dev/null || echo "0")
                    total_fps=$((total_fps + fps_int))

                    # Prefetch next chunk for remote workers
                    if [[ "$distribution_done" == "true" ]]; then
                        _bt_prefetch_next "$w" "$n_workers"
                    fi
                    ;;
            esac
        done

        # --- Orphan chunk scanner (defense in depth) ---
        # Detect chunks stuck in "encoding" whose worker has moved on.
        # Guards against any code path that overwrites WS_WORKER_CHUNK.
        for (( _oc=0; _oc<n_chunks; _oc++ )); do
            [[ "${WS_CHUNK_STATE[$_oc]}" != "encoding" ]] && continue
            local _ow=${WS_CHUNK_WORKER[$_oc]}
            [[ $_ow -lt 0 ]] && continue
            # Not orphaned if worker is tracking this chunk
            [[ "${WS_WORKER_CHUNK[$_ow]}" == "$_oc" ]] && continue
            # If worker is busy with a different chunk, skip (can't interfere)
            [[ ${WS_WORKER_BUSY[$_ow]} -ne 0 ]] && continue

            # Worker is idle and not tracking this chunk — poll directly
            local _ojid="${WS_CHUNK_JOB_ID[$_oc]}"
            local _owurl="${LIVE_WORKERS[$_ow]}"
            local _oresp
            _oresp=$(curl -sf --connect-timeout 1 "${_owurl}/status/${_ojid}" 2>/dev/null || echo "")
            [[ -z "$_oresp" ]] && continue

            local _ostatus
            _ostatus=$(echo "$_oresp" | grep -o '"status":"[^"]*"' | cut -d'"' -f4 || echo "")

            if [[ "$_ostatus" == "completed" ]]; then
                local _ofps
                _ofps=$(echo "$_oresp" | grep -o '"fps":[0-9][0-9.]*' | head -1 | cut -d':' -f2 || echo "0")
                log_event "MODE-C" "Orphan chunk ${_oc} completed on worker ${_ow} (fps=${_ofps})"
                if [[ ${BT_WORKER_CALIBRATED[$_ow]} -eq 0 ]]; then
                    BT_WORKER_CALIBRATED[$_ow]=1
                    [[ -n "$_ofps" ]] && [[ "$_ofps" != "0" ]] && BT_WORKER_FPS[$_ow]="$_ofps"
                fi
                if [[ -n "${WS_WORKER_STREAM_PID[$_ow]:-}" ]]; then
                    kill "${WS_WORKER_STREAM_PID[$_ow]}" 2>/dev/null || true
                    WS_WORKER_STREAM_PID[$_ow]=""
                fi
                _ws_download_chunk_bg "$_ow" "$_oc"
                WS_CHUNK_STATE[$_oc]="downloading"
            elif [[ "$_ostatus" == "failed" ]]; then
                log_event "MODE-C" "Orphan chunk ${_oc} FAILED on worker ${_ow}"
                WS_CHUNK_STATE[$_oc]="pending"
                WS_CHUNK_WORKER[$_oc]=-1
                fail_count=$((fail_count + 1))
            elif [[ "$_ostatus" == "running" ]]; then
                # Still running but lost tracking — re-link worker
                log_event "MODE-C" "Orphan chunk ${_oc} still running on worker ${_ow} — re-linking"
                WS_WORKER_BUSY[$_ow]=1
                WS_WORKER_CHUNK[$_ow]=$_oc
            fi
        done

        # --- Check calibration completion ---
        if [[ "$calibration_complete" == "false" ]]; then
            local all_cal=true
            for (( w=0; w<n_workers; w++ )); do
                if [[ ${BT_WORKER_CALIBRATED[$w]} -eq 0 ]]; then
                    all_cal=false
                    break
                fi
            done
            if [[ "$all_cal" == "true" ]]; then
                calibration_complete=true
                local fps_summary=""
                for (( w=0; w<n_workers; w++ )); do
                    fps_summary+=" W${w}=${BT_WORKER_FPS[$w]}"
                done
                log_event "MODE-C" "Calibration complete:${fps_summary}"
            fi
        fi

        # --- Distribute remaining chunks (once) ---
        if [[ "$calibration_complete" == "true" ]] && [[ "$distribution_done" == "false" ]]; then
            _bt_distribute_proportionally "$n_workers" "$n_chunks"
            distribution_done=true
        fi

        # --- Assignment: assign from per-worker queues ---
        for (( w=0; w<n_workers; w++ )); do
            [[ ${WS_WORKER_BUSY[$w]} -ne 0 ]] && continue

            local next_chunk=""

            # Check for prefetched chunk ready for this worker
            if [[ -n "${BT_PREFETCH_CHUNK[$w]:-}" ]] && [[ "${BT_PREFETCH_CHUNK[$w]}" != "" ]]; then
                local pchunk="${BT_PREFETCH_CHUNK[$w]}"
                if [[ "${WS_CHUNK_STATE[$pchunk]}" == "pending" ]]; then
                    local pjid="${BT_PREFETCH_JOB[$w]}"

                    WS_CHUNK_STATE[$pchunk]="encoding"
                    WS_CHUNK_WORKER[$pchunk]=$w
                    WS_CHUNK_JOB_ID[$pchunk]="$pjid"
                    WS_WORKER_BUSY[$w]=1
                    WS_WORKER_CHUNK[$w]=$pchunk

                    if [[ -n "${BT_PREFETCH_PID[$w]:-}" ]]; then
                        WS_WORKER_STREAM_PID[$w]="${BT_PREFETCH_PID[$w]}"
                    fi

                    local front
                    eval "front=\${BT_QUEUE_W${w}[0]:-}"
                    if [[ "$front" == "$pchunk" ]]; then
                        eval "BT_QUEUE_W${w}=( \"\${BT_QUEUE_W${w}[@]:1}\" )"
                    fi

                    BT_PREFETCH_PID[$w]=""
                    BT_PREFETCH_JOB[$w]=""
                    BT_PREFETCH_CHUNK[$w]=""

                    log_event "MODE-C" "Activated prefetched chunk ${pchunk} on worker ${w}"
                    continue
                else
                    if [[ -n "${BT_PREFETCH_PID[$w]:-}" ]]; then
                        kill "${BT_PREFETCH_PID[$w]}" 2>/dev/null || true
                    fi
                    local pfj="${BT_PREFETCH_JOB[$w]}"
                    if [[ -n "$pfj" ]]; then
                        curl -sf -X DELETE "${LIVE_WORKERS[$w]}/job/${pfj}" &>/dev/null || true
                    fi
                    BT_PREFETCH_PID[$w]=""
                    BT_PREFETCH_JOB[$w]=""
                    BT_PREFETCH_CHUNK[$w]=""
                fi
            fi

            if [[ "$distribution_done" == "true" ]]; then
                eval "next_chunk=\${BT_QUEUE_W${w}[0]:-}"
                if [[ -n "$next_chunk" ]]; then
                    if [[ "${WS_CHUNK_STATE[$next_chunk]}" == "pending" ]]; then
                        eval "BT_QUEUE_W${w}=( \"\${BT_QUEUE_W${w}[@]:1}\" )"
                        _ws_assign_chunk "$w" "$next_chunk"
                        continue
                    else
                        eval "BT_QUEUE_W${w}=( \"\${BT_QUEUE_W${w}[@]:1}\" )"
                    fi
                fi

                _bt_steal_work "$w" "$n_workers"
                if [[ "$BT_STEAL_RESULT" != "-1" ]] && [[ "${WS_CHUNK_STATE[$BT_STEAL_RESULT]}" == "pending" ]]; then
                    _ws_assign_chunk "$w" "$BT_STEAL_RESULT"
                    continue
                fi
            else
                for (( c=0; c<n_chunks; c++ )); do
                    if [[ "${WS_CHUNK_STATE[$c]}" == "pending" ]]; then
                        _ws_assign_chunk "$w" "$c"
                        break
                    fi
                done
            fi
        done

        # --- Endgame ---
        if [[ "$distribution_done" == "true" ]]; then
            _bt_endgame_check "$n_workers" "$n_chunks"
        fi

        # --- Check background downloads ---
        _ws_check_downloads

        # --- Process ready chunks ---
        _ws_process_ready_chunks

        # --- Progress ---
        if [[ $((poll_count % 4)) -eq 0 ]]; then
            local busy_count=0
            for (( w=0; w<n_workers; w++ )); do
                [[ ${WS_WORKER_BUSY[$w]} -ne 0 ]] && busy_count=$((busy_count + 1))
            done

            local q_info=""
            for (( w=0; w<n_workers; w++ )); do
                local qlen
                eval "qlen=\${#BT_QUEUE_W${w}[@]}"
                q_info+=" Q${w}=${qlen}"
            done

            # Calculate meaningful out_time so Plex sees progress advancing
            # Base: processed chunks * chunk_dur
            local out_time_s=$((next_processable * chunk_dur))
            # Add estimate from earliest running chunk
            if [[ $next_processable -lt $n_chunks ]] && [[ -n "${WS_CHUNK_START_TIME[$next_processable]:-}" ]]; then
                local now_epoch wall_elapsed chunk_est
                now_epoch=$(date +%s)
                wall_elapsed=$((now_epoch - WS_CHUNK_START_TIME[$next_processable]))
                # Estimate: wall time * speed (assume at least 1x if we have fps)
                chunk_est=$wall_elapsed
                (( chunk_est > chunk_dur )) && chunk_est=$chunk_dur
                out_time_s=$((out_time_s + chunk_est))
            fi
            local out_time_us=$((out_time_s * 1000000))
            local elapsed_s=$(( $(date +%s) - bt_start_epoch ))
            local speed_val="0.0"
            (( elapsed_s > 0 )) && speed_val=$(awk "BEGIN{printf \"%.1f\", ${out_time_s}/${elapsed_s}}")
            local time_str
            time_str=$(printf "%02d:%02d:%02d.00" \
                $((out_time_s / 3600)) $(( (out_time_s % 3600) / 60 )) $((out_time_s % 60)))

            printf "frame=0 fps=%s q=-1.0 size=N/A time=%s bitrate=N/A speed=%sx    [%d/%d chunks, %d active,%s]\n" \
                "${total_fps}" "$time_str" "$speed_val" "$chunks_completed" "$n_chunks" "$busy_count" "$q_info" >&2 2>/dev/null || true

            if [[ -n "${PROGRESS_URL:-}" ]]; then
                curl -sf -X POST \
                    --connect-timeout 1 --max-time 2 \
                    -d "frame=0&fps=${total_fps}&speed=${speed_val}x&out_time_us=${out_time_us}&progress=continue" \
                    "${PROGRESS_URL}" 2>/dev/null &
            fi
        fi

        # --- Termination ---
        if [[ $chunks_completed -ge $n_chunks ]]; then
            _ws_process_ready_chunks

            # Kill progressive download for chunk 0
            kill "$progressive_pid" 2>/dev/null || true
            wait "$progressive_pid" 2>/dev/null || true

            # Kill fast-start transcoder if still running
            if [[ -n "${fast_start_pid:-}" ]] && kill -0 "$fast_start_pid" 2>/dev/null; then
                kill "$fast_start_pid" 2>/dev/null || true
                wait "$fast_start_pid" 2>/dev/null || true
                log_event "MODE-C" "Killed fast-start transcoder (completion)"
            fi

            log_event "MODE-C" "All ${n_chunks} chunks completed! ${total_segs_output} segments output"

            if [[ -n "${MANIFEST_CALLBACK_URL:-}" ]] && [[ -f "${OUTPUT_DIR}/output.mpd" ]]; then
                curl -sf -X POST \
                    -H "Content-Type: application/dash+xml" \
                    --data-binary @"${OUTPUT_DIR}/output.mpd" \
                    "${MANIFEST_CALLBACK_URL}" 2>/dev/null || true
            fi

            for (( w=0; w<n_workers; w++ )); do
                if [[ -n "${BT_PREFETCH_PID[$w]:-}" ]]; then
                    kill "${BT_PREFETCH_PID[$w]}" 2>/dev/null || true
                fi
            done

            rm -rf "$staging_dir" 2>/dev/null || true

            printf "frame=9999 fps=0.0 q=-1.0 size=N/A time=99:99:99.99 bitrate=N/A speed=0.0x\n" >&2
            return 0
        fi

        if [[ $((poll_count % 120)) -eq 0 ]]; then
            local cal_status=""
            if [[ "$calibration_complete" == "false" ]]; then
                cal_status=" (calibrating)"
            fi
            log_event "MODE-C" "Progress: ${chunks_completed}/${n_chunks} chunks, ${total_segs_output} segs, proc=${next_processable}${cal_status}"
        fi
    done

    # Timeout
    kill "$progressive_pid" 2>/dev/null || true
    wait "$progressive_pid" 2>/dev/null || true
    # Kill fast-start transcoder if still running
    if [[ -n "${fast_start_pid:-}" ]] && kill -0 "$fast_start_pid" 2>/dev/null; then
        kill "$fast_start_pid" 2>/dev/null || true
        wait "$fast_start_pid" 2>/dev/null || true
    fi
    log_event "MODE-C" "Timed out after ${max_polls} polls"
    for (( w=0; w<n_workers; w++ )); do
        if [[ ${WS_WORKER_BUSY[$w]} -ne 0 ]]; then
            local c=${WS_WORKER_CHUNK[$w]}
            local jid="${WS_CHUNK_JOB_ID[$c]}"
            curl -sf -X DELETE "${LIVE_WORKERS[$w]}/job/${jid}" &>/dev/null || true
        fi
        if [[ -n "${BT_PREFETCH_JOB[$w]:-}" ]]; then
            curl -sf -X DELETE "${LIVE_WORKERS[$w]}/job/${BT_PREFETCH_JOB[$w]}" &>/dev/null || true
        fi
        if [[ -n "${BT_PREFETCH_PID[$w]:-}" ]]; then
            kill "${BT_PREFETCH_PID[$w]}" 2>/dev/null || true
        fi
    done
    return 1
}

# ============================================================================
# MODE SELECTOR
# ============================================================================
dispatch_multi_gpu() {
    local mode="${PLEXBEAM_MULTI_MODE:-C}"
    log_event "MULTI-GPU" "Dispatch mode: ${mode} (${#LIVE_WORKERS[@]} workers)"
    case "$mode" in
        A|a) _dispatch_chunked_simple "$@" ;;
        B|b) _dispatch_weighted_split "$@" ;;
        C|c) _dispatch_bittorrent "$@" ;;
        *)   _dispatch_bittorrent "$@" ;;
    esac
}


# --- Remote dispatch function (single worker) -------------------------------
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
    local use_pull_url=""
    if [[ -n "$INPUT_FILE" ]]; then
        # PLEXBEAM_BEAM_DIRECT=true: force beam stream for single HTTPS worker (e.g. Cloudflare Tunnel)
        if [[ "${PLEXBEAM_BEAM_DIRECT:-}" == "true" ]] && { [[ -f "$INPUT_FILE" ]] || [[ "$INPUT_FILE" =~ ^https?:// ]]; }; then
            use_beam_stream=true
            log_event "REMOTE" "Beam direct mode: streaming to tunnel worker"
        # Cloud workers (HTTPS URLs): upload to S3 via pull proxy, get pre-signed URL
        elif [[ "${worker_url}" =~ ^https:// ]] && [[ -n "$PULL_PROXY_URL" ]]; then
            log_event "REMOTE" "Uploading to S3 for cloud worker..."
            copy_remux_and_upload "$SESSION_ID" "0" "0" "0"
            if [[ -f "${PULL_DIR}/${SESSION_ID}.url" ]]; then
                use_pull_url=$(cat "${PULL_DIR}/${SESSION_ID}.url")
                log_event "REMOTE" "Using S3 pull mode for cloud worker"
            else
                log_event "REMOTE" "S3 upload failed, falling back to beam stream"
                use_beam_stream=true
            fi
        elif [[ -f "$INPUT_FILE" ]] || [[ "$INPUT_FILE" =~ ^https?:// ]]; then
            use_beam_stream=true
        fi
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
        "raw_args": $(json_array "${RAW_ARGS[@]}")
    },
    "source": "${SERVER_TYPE}",
    "beam_stream": ${use_beam_stream},
    "pull_url": $(if [[ -n "$use_pull_url" ]]; then echo "\"${use_pull_url}\""; else echo "null"; fi),
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
            if [[ "$INPUT_FILE" =~ ^https?:// ]]; then
                # HTTP input: pipe through ffmpeg copy-remux to MKV, then to worker
                local remux_bin="$REAL_TRANSCODER"
                if [[ -x /usr/bin/ffmpeg ]]; then remux_bin="/usr/bin/ffmpeg"; fi
                "$remux_bin" -v error -i "$INPUT_FILE" \
                    -map 0 -c copy -f matroska pipe:1 2>/dev/null | \
                curl -sg --http1.1 -X POST \
                    --connect-timeout "$REMOTE_TIMEOUT" \
                    --max-time 7200 \
                    --limit-rate "$upload_rate" \
                    -T - \
                    "${worker_url}/beam/stream/${SESSION_ID}" \
                    > "${SESSION_DIR}/01_beam_stream.json" 2>"${SESSION_DIR}/01_beam_stream_err.log" &
            else
                # Use cat|curl -T - instead of curl -T file to force chunked
                # transfer encoding. Cloudflare Tunnel returns 413 for large
                # Content-Length uploads but allows chunked streams.
                cat "$INPUT_FILE" | \
                curl -sg --http1.1 -X POST \
                    --connect-timeout "$REMOTE_TIMEOUT" \
                    --max-time 7200 \
                    --limit-rate "$upload_rate" \
                    -T - \
                    "${worker_url}/beam/stream/${SESSION_ID}" \
                    > "${SESSION_DIR}/01_beam_stream.json" 2>"${SESSION_DIR}/01_beam_stream_err.log" &
            fi
            STREAM_PID=$!
        fi

        # Poll for completion (0.25s interval for faster segment detection)
        local poll_count=0
        local max_polls=28800  # 2 hours at 0.25 second intervals

        while [[ $poll_count -lt $max_polls ]]; do
            sleep 0.25
            poll_count=$((poll_count + 1))

            local status_response
            status_response=$(curl -sf --connect-timeout 2 --max-time 5 "${worker_url}/status/${SESSION_ID}" 2>/dev/null || echo "")

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
                    pending|queued)
                        # Emit keepalive progress to stderr so Plex doesn't kill us
                        # while waiting for beam stream to start the job on the worker
                        if [[ $((poll_count % 4)) -eq 0 ]]; then
                            printf "frame=0 fps=0.0 q=-1.0 size=N/A time=00:00:00.00 bitrate=N/A speed=0.0x\n" >&2
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

# Only attempt remote dispatch for actual video transcoding (not copy/direct stream)
if [[ "$VIDEO_CODEC_OUT" != "copy" ]] && [[ -n "$VIDEO_CODEC_OUT" ]]; then

    # --- Try multi-GPU first if worker pool is configured ---
    if [[ -n "$WORKER_POOL" ]] && [[ "$WORKER_POOL" != __* ]]; then
        parse_worker_pool "$WORKER_POOL"

        if [[ ${#POOL_URLS[@]} -ge 2 ]]; then
            health_check_workers

            # Sort workers: fastest GPU first (chunk 0 must finish first for output)
            # nvenc/cuda first, then qsv, then vaapi, then unknown
            if [[ ${#LIVE_WORKERS[@]} -ge 2 ]]; then
                _nv_w=(); _nv_t=(); _qs_w=(); _qs_t=(); _va_w=(); _va_t=(); _ot_w=(); _ot_t=()
                for i in "${!LIVE_WORKERS[@]}"; do
                    _health=$(curl -sf --connect-timeout 1 "${LIVE_WORKERS[$i]}/health" 2>/dev/null || true)
                    if [[ "${_health:-}" == *'"nvenc"'* ]] || [[ "${_health:-}" == *'"cuda"'* ]]; then
                        _nv_w+=("${LIVE_WORKERS[$i]}"); _nv_t+=("${LIVE_TAGS[$i]}")
                    elif [[ "${_health:-}" == *'"qsv"'* ]]; then
                        _qs_w+=("${LIVE_WORKERS[$i]}"); _qs_t+=("${LIVE_TAGS[$i]}")
                    elif [[ "${_health:-}" == *'"vaapi"'* ]]; then
                        _va_w+=("${LIVE_WORKERS[$i]}"); _va_t+=("${LIVE_TAGS[$i]}")
                    else
                        _ot_w+=("${LIVE_WORKERS[$i]}"); _ot_t+=("${LIVE_TAGS[$i]}")
                    fi
                done
                LIVE_WORKERS=()
                LIVE_TAGS=()
                if [[ ${#_nv_w[@]} -gt 0 ]]; then LIVE_WORKERS+=("${_nv_w[@]}"); LIVE_TAGS+=("${_nv_t[@]}"); fi
                if [[ ${#_qs_w[@]} -gt 0 ]]; then LIVE_WORKERS+=("${_qs_w[@]}"); LIVE_TAGS+=("${_qs_t[@]}"); fi
                if [[ ${#_va_w[@]} -gt 0 ]]; then LIVE_WORKERS+=("${_va_w[@]}"); LIVE_TAGS+=("${_va_t[@]}"); fi
                if [[ ${#_ot_w[@]} -gt 0 ]]; then LIVE_WORKERS+=("${_ot_w[@]}"); LIVE_TAGS+=("${_ot_t[@]}"); fi
                log_event "MULTI-GPU" "Sorted workers: ${LIVE_WORKERS[*]}"
            fi

            if [[ ${#LIVE_WORKERS[@]} -ge 2 ]]; then
                USE_REMOTE=true

                {
                    echo "═══════════════════════════════════════════════════════════════"
                    echo "  MULTI-GPU DISPATCH mode=${PLEXBEAM_MULTI_MODE:-C} (${#LIVE_WORKERS[@]} workers)"
                    echo "═══════════════════════════════════════════════════════════════"
                    echo ""
                    for i in "${!LIVE_WORKERS[@]}"; do
                        echo "  Worker ${i}: ${LIVE_WORKERS[$i]} (${LIVE_TAGS[$i]})"
                    done
                    echo "Started:     $(date -Iseconds)"
                } >> "${SESSION_DIR}/00_session.log"

                if dispatch_multi_gpu; then
                    REMOTE_SUCCESS=true
                    EXIT_CODE=0

                    {
                        echo "Result:      SUCCESS (multi-gpu)"
                        echo "Finished:    $(date -Iseconds)"
                    } >> "${SESSION_DIR}/00_session.log"
                else
                    {
                        echo "Result:      FAILED (multi-gpu)"
                        echo "Fallback:    single worker"
                    } >> "${SESSION_DIR}/00_session.log"
                    log_event "MULTI-GPU" "Multi-GPU failed — falling back to single worker"
                    USE_REMOTE=false
                fi
            else
                log_event "MULTI-GPU" "Only ${#LIVE_WORKERS[@]} worker(s) alive — need 2+ for multi-GPU"
            fi
        fi
    fi

    # --- Fall back to single-worker dispatch ---
    if [[ "$USE_REMOTE" == "false" ]] && [[ -n "$REMOTE_WORKER_URL" ]] && [[ "$REMOTE_WORKER_URL" != __* ]]; then
        USE_REMOTE=true

        {
            echo "═══════════════════════════════════════════════════════════════"
            echo "  REMOTE DISPATCH (single worker)"
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

        # Detect local GPU: NVENC takes priority over QSV/VAAPI
        GPU_TYPE="none"
        if [[ -e /dev/nvidia0 ]]; then
            GPU_TYPE="nvenc"
        elif [[ -e /dev/dri/renderD128 ]]; then
            GPU_TYPE="qsv"
        fi

        if [[ "$GPU_TYPE" != "none" ]]; then
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

                # GPU-specific encoder names
                if [[ "$GPU_TYPE" == "nvenc" ]]; then
                    ENC_H264="h264_nvenc"
                    ENC_H265="hevc_nvenc"
                else
                    ENC_H264="h264_qsv"
                    ENC_H265="hevc_qsv"
                fi

                for i in "${!LOCAL_ARGS[@]}"; do
                    if [[ "$SKIP_NEXT" == "true" ]]; then
                        SKIP_NEXT=false
                        continue
                    fi

                    cur_arg="${LOCAL_ARGS[$i]}"
                    nxt_arg="${LOCAL_ARGS[$((i+1))]:-}"

                    # Replace libx264 → GPU encoder
                    if [[ "$cur_arg" == "libx264" ]]; then
                        REWRITTEN_ARGS+=("$ENC_H264")
                        CODEC_REWRITES="${CODEC_REWRITES} libx264→${ENC_H264}"
                        continue
                    fi

                    # Replace libx265 → GPU encoder
                    if [[ "$cur_arg" == "libx265" ]]; then
                        REWRITTEN_ARGS+=("$ENC_H265")
                        CODEC_REWRITES="${CODEC_REWRITES} libx265→${ENC_H265}"
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

                    # CRF → GPU quality mapping
                    if [[ "$cur_arg" == -crf* ]]; then
                        CRF_VALUE="$nxt_arg"
                        if [[ "$GPU_TYPE" == "nvenc" ]]; then
                            # NVENC: -crf N → -qp N (constqp mode; direct mapping)
                            QP="${CRF_VALUE:-21}"
                            (( QP < 1 )) && QP=1
                            (( QP > 51 )) && QP=51
                            REWRITTEN_ARGS+=("-qp")
                            REWRITTEN_ARGS+=("$QP")
                            CODEC_REWRITES="${CODEC_REWRITES} crf:${CRF_VALUE}→qp:${QP}"
                        else
                            # QSV: -crf N → -global_quality N+2
                            if [[ "$CRF_VALUE" =~ ^[0-9]+$ ]]; then
                                GQ=$((CRF_VALUE + 2))
                                (( GQ < 1 )) && GQ=1
                                (( GQ > 51 )) && GQ=51
                            else
                                GQ=21  # fallback: CRF 19 default → 21
                            fi
                            REWRITTEN_ARGS+=("-global_quality:0")
                            REWRITTEN_ARGS+=("$GQ")
                            CODEC_REWRITES="${CODEC_REWRITES} crf:${CRF_VALUE}→gq:${GQ}"
                        fi
                        SKIP_NEXT=true
                        continue
                    fi

                    # QSV-only: replace -init_hw_device / -filter_hw_device
                    # NVENC: strip these (not needed for NVENC with CPU decode)
                    if [[ "$cur_arg" == "-init_hw_device" ]]; then
                        if [[ "$GPU_TYPE" == "qsv" ]]; then
                            REWRITTEN_ARGS+=("-init_hw_device")
                            REWRITTEN_ARGS+=("qsv=hw")
                        fi
                        SKIP_NEXT=true
                        continue
                    fi
                    if [[ "$cur_arg" == "-filter_hw_device" ]]; then
                        if [[ "$GPU_TYPE" == "qsv" ]]; then
                            REWRITTEN_ARGS+=("-filter_hw_device")
                            REWRITTEN_ARGS+=("hw")
                        fi
                        SKIP_NEXT=true
                        continue
                    fi

                    # Rewrite video filter_complex scale pipeline
                    if [[ "$cur_arg" == "-filter_complex" ]] && [[ "$nxt_arg" == *"scale=w="* ]] && [[ "$nxt_arg" == "[0:0]"* ]]; then
                        SCALE_W=$(echo "$nxt_arg" | grep -oP 'scale=w=\K\d+')
                        SCALE_H=$(echo "$nxt_arg" | grep -oP ':h=\K\d+')
                        # Extract output label from original filter (e.g. [1], [vout])
                        FILTER_LABEL=$(echo "$nxt_arg" | grep -oP '\[[^\]]+\]$')
                        [[ -z "$FILTER_LABEL" ]] && FILTER_LABEL="[1]"

                        if [[ -n "$SCALE_W" ]] && [[ -n "$SCALE_H" ]]; then
                            REWRITTEN_ARGS+=("-filter_complex")
                            if [[ "$GPU_TYPE" == "nvenc" ]]; then
                                # NVENC: CPU scale then hwupload; NVENC accepts nv12 directly
                                REWRITTEN_ARGS+=("[0:0]scale=w=${SCALE_W}:h=${SCALE_H},format=nv12,hwupload_cuda${FILTER_LABEL}")
                                CODEC_REWRITES="${CODEC_REWRITES} scale→hwupload_cuda:${SCALE_W}x${SCALE_H}"
                            else
                                # QSV: hwupload + scale_qsv
                                REWRITTEN_ARGS+=("[0:0]format=nv12,hwupload=extra_hw_frames=64,scale_qsv=w=${SCALE_W}:h=${SCALE_H}${FILTER_LABEL}")
                                CODEC_REWRITES="${CODEC_REWRITES} scale→scale_qsv:${SCALE_W}x${SCALE_H}"
                            fi
                            SKIP_NEXT=true
                            continue
                        fi
                    fi

                    REWRITTEN_ARGS+=("$cur_arg")
                done

                if [[ "$GPU_TYPE" == "qsv" ]]; then
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
                elif [[ "$GPU_TYPE" == "nvenc" ]]; then
                    # NVENC: inject -hwaccel cuda before -i for hw decode path
                    # (uses CPU decode by default; hwaccel only helps if NVDEC available)
                    # Also add -delay 0 -bf 0 for low-latency streaming
                    declare -a FINAL_ARGS=()
                    FINAL_ARGS+=("-hwaccel" "cuda" "-hwaccel_output_format" "cuda")
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
                log_event "LOCAL" "${GPU_TYPE^^} rewrite:${CODEC_REWRITES} | stripped:${STRIPPED_FLAGS} (system ffmpeg)"
            fi
        fi
    fi
    # Jellyfin: no arg rewriting needed — standard ffmpeg args pass through clean

    # Choose local binary
    # Plex's bundled transcoder uses musl libc and cannot load glibc GPU drivers.
    # Use system ffmpeg for any HW rewrite (QSV or NVENC).
    if [[ "$SERVER_TYPE" == "plex" ]] && [[ "$QSV_REWRITE" == "true" ]] && [[ -x /usr/bin/ffmpeg ]]; then
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
        echo "GPU:      ${GPU_TYPE:-none}"
        echo "HW:       ${QSV_REWRITE}"
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

    if [[ "$QSV_REWRITE" == "true" ]] && [[ "${GPU_TYPE:-}" == "qsv" ]]; then
        # QSV/VAAPI: system ffmpeg needs LIBVA env vars to find the iHD driver
        LIBVA_DRIVER_NAME=iHD LIBVA_DRIVERS_PATH=/usr/lib/x86_64-linux-gnu/dri "$LOCAL_BINARY" "${LOCAL_ARGS[@]}" 2> >(tee "${SESSION_DIR}/stderr.log" >&2)
    else
        # NVENC or Plex transcoder: no special env needed
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
    echo "│  Mode:       $(if [[ ${#MULTI_JOB_IDS[@]} -gt 0 ]]; then echo "MULTI-GPU (${#MULTI_JOB_IDS[@]} workers)"; elif [[ "$REMOTE_SUCCESS" == "true" ]]; then echo "REMOTE"; else echo "LOCAL"; fi)"
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
    "$(if [[ ${#MULTI_JOB_IDS[@]} -gt 0 ]]; then echo "multi-gpu-${#MULTI_JOB_IDS[@]}"; elif [[ "$REMOTE_SUCCESS" == "true" ]]; then echo "remote"; else echo "local"; fi)" \
    "${VIDEO_CODEC_OUT:-pass}" \
    "${TRANSCODE_TYPE}" \
    "$(basename "${INPUT_FILE:-unknown}")" \
    >> "${LOG_BASE}/master.log"

exit $EXIT_CODE
