#!/bin/bash
set -e

echo "========================================="
echo "  PlexBeam GPU Worker - Tunnel Mode"
echo "========================================="

HW_ACCEL="${PLEX_WORKER_HW_ACCEL:-nvenc}"
PORT="${PLEX_WORKER_PORT:-8765}"

# --- GPU Validation ---
echo ""
echo "[*] Hardware acceleration: ${HW_ACCEL}"

if [ "$HW_ACCEL" = "nvenc" ]; then
    if command -v nvidia-smi &>/dev/null; then
        echo "[+] NVIDIA GPU detected:"
        nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader 2>/dev/null || true
    else
        echo "[!] WARNING: nvidia-smi not found. NVIDIA GPU may not be accessible."
        echo "    Ensure nvidia-container-toolkit is installed on the host"
        echo "    and the container is started with GPU support."
    fi
fi

# --- FFmpeg Validation ---
echo ""
echo "[*] Checking FFmpeg..."
FFMPEG_PATH="${PLEX_WORKER_FFMPEG_PATH:-ffmpeg}"

if command -v "$FFMPEG_PATH" &>/dev/null; then
    FFMPEG_VERSION=$("$FFMPEG_PATH" -version 2>/dev/null | head -n1)
    echo "[+] ${FFMPEG_VERSION}"

    if "$FFMPEG_PATH" -encoders 2>/dev/null | grep -q h264_nvenc; then
        echo "[+] h264_nvenc encoder available"
    else
        echo "[!] WARNING: h264_nvenc encoder not found in FFmpeg"
    fi

    if "$FFMPEG_PATH" -decoders 2>/dev/null | grep -q h264_cuvid; then
        echo "[+] h264_cuvid decoder available (NVDEC)"
    fi
else
    echo "[!] ERROR: FFmpeg not found at '${FFMPEG_PATH}'"
    exit 1
fi

# --- Create directories ---
echo ""
echo "[*] Ensuring directories exist..."
mkdir -p "${PLEX_WORKER_TEMP_DIR:-/app/transcode_temp}"
mkdir -p "${PLEX_WORKER_LOG_DIR:-/app/logs}"

# --- Start worker ---
echo ""
echo "[*] Starting PlexBeam worker on port ${PORT}..."
python3 worker.py "$@" &
WORKER_PID=$!

# Wait for worker to be healthy
echo "[*] Waiting for worker health check..."
for i in $(seq 1 30); do
    if curl -sf http://localhost:${PORT}/health >/dev/null 2>&1; then
        echo "[+] Worker is healthy"
        break
    fi
    if ! kill -0 $WORKER_PID 2>/dev/null; then
        echo "[!] Worker process died during startup"
        exit 1
    fi
    sleep 1
done

if ! curl -sf http://localhost:${PORT}/health >/dev/null 2>&1; then
    echo "[!] Worker failed to become healthy after 30s"
    kill $WORKER_PID 2>/dev/null || true
    exit 1
fi

# --- Start Cloudflare Tunnel ---
echo ""
echo "========================================="
echo "  Starting Cloudflare Tunnel"
echo "========================================="

TUNNEL_LOG="/app/logs/cloudflared.log"
TUNNEL_URL_FILE="/app/logs/tunnel_url.txt"

if [ -n "${CLOUDFLARE_TUNNEL_TOKEN:-}" ]; then
    # Named tunnel (requires Cloudflare account + tunnel setup)
    echo "[*] Using named tunnel (token provided)"
    cloudflared tunnel run --token "$CLOUDFLARE_TUNNEL_TOKEN" \
        > "$TUNNEL_LOG" 2>&1 &
    TUNNEL_PID=$!

    # Named tunnels have pre-configured URLs; extract from dashboard or config
    echo "[*] Named tunnel started (pid=${TUNNEL_PID})"
    echo "[*] Tunnel URL is configured in your Cloudflare dashboard"
else
    # Quick tunnel (no account needed — generates random URL)
    echo "[*] Using quick tunnel (no account needed)"
    cloudflared tunnel --url http://localhost:${PORT} \
        --no-autoupdate \
        > "$TUNNEL_LOG" 2>&1 &
    TUNNEL_PID=$!

    # Wait for tunnel URL to appear in logs
    echo "[*] Waiting for tunnel URL..."
    TUNNEL_URL=""
    for i in $(seq 1 60); do
        if [ -f "$TUNNEL_LOG" ]; then
            TUNNEL_URL=$(grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' "$TUNNEL_LOG" 2>/dev/null | head -1)
            if [ -n "$TUNNEL_URL" ]; then
                break
            fi
        fi
        if ! kill -0 $TUNNEL_PID 2>/dev/null; then
            echo "[!] Cloudflared process died during startup"
            echo "[!] Log output:"
            cat "$TUNNEL_LOG" 2>/dev/null || true
            # Continue without tunnel — worker still accessible on LAN
            break
        fi
        sleep 1
    done

    if [ -n "$TUNNEL_URL" ]; then
        echo "$TUNNEL_URL" > "$TUNNEL_URL_FILE"
        echo ""
        echo "========================================="
        echo "  TUNNEL URL: ${TUNNEL_URL}"
        echo "========================================="
        echo ""
        echo "  Add to WORKER_POOL:"
        echo "    ${TUNNEL_URL}@beam"
        echo ""
        echo "  Or use as single worker:"
        echo "    PLEXBEAM_REMOTE_WORKER_URL=${TUNNEL_URL}"
        echo "    PLEXBEAM_BEAM_DIRECT=true"
        echo ""
        echo "  Health check:"
        echo "    curl ${TUNNEL_URL}/health"
        echo "========================================="
    else
        echo "[!] Could not detect tunnel URL after 60s"
        echo "[*] Worker is still accessible on LAN at http://localhost:${PORT}"
        echo "[*] Check $TUNNEL_LOG for cloudflared output"
    fi
fi

echo ""
echo "[*] Worker PID: ${WORKER_PID}, Tunnel PID: ${TUNNEL_PID:-none}"
echo "[*] Ready for transcoding jobs"

# Wait for worker process — if it dies, container exits for restart
wait $WORKER_PID
EXIT_CODE=$?
echo "[!] Worker process exited with code ${EXIT_CODE}"

# Clean up tunnel
if [ -n "${TUNNEL_PID:-}" ]; then
    kill $TUNNEL_PID 2>/dev/null || true
fi

exit $EXIT_CODE
