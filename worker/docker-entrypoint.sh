#!/bin/bash
set -e

echo "========================================="
echo "  PlexBeam GPU Worker - Docker Start"
echo "========================================="

HW_ACCEL="${PLEX_WORKER_HW_ACCEL:-nvenc}"

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
elif [ "$HW_ACCEL" = "qsv" ]; then
    if [ -e /dev/dri/renderD128 ]; then
        echo "[+] Render device found: /dev/dri/renderD128"
        ls -la /dev/dri/ 2>/dev/null || true
    else
        echo "[!] WARNING: /dev/dri/renderD128 not found. Intel GPU may not be accessible."
        echo "    Ensure /dev/dri is passed through to the container."
    fi
elif [ "$HW_ACCEL" = "vaapi" ]; then
    if [ -e /dev/dri/renderD128 ]; then
        echo "[+] Render device found: /dev/dri/renderD128"
        ls -la /dev/dri/ 2>/dev/null || true
    else
        echo "[!] WARNING: /dev/dri/renderD128 not found."
    fi
    if [ -e /dev/dxg ]; then
        echo "[+] WSL2 GPU device found: /dev/dxg"
    fi
    if [ -d /usr/lib/wsl/lib ]; then
        echo "[+] WSL2 libraries found: /usr/lib/wsl/lib"
    else
        echo "[!] WARNING: /usr/lib/wsl/lib not mounted. VAAPI D3D12 backend needs this."
        echo "    Mount with: -v /usr/lib/wsl:/usr/lib/wsl"
    fi
    echo "[*] VAAPI driver: ${LIBVA_DRIVER_NAME:-auto}"
    if command -v vainfo &>/dev/null; then
        echo "[*] VAAPI info:"
        vainfo --display drm --device /dev/dri/renderD128 2>&1 | head -20 || true
    fi
elif [ "$HW_ACCEL" = "none" ]; then
    echo "[*] Software transcoding mode (no GPU)"
fi

# --- FFmpeg Validation ---
echo ""
echo "[*] Checking FFmpeg..."
FFMPEG_PATH="${PLEX_WORKER_FFMPEG_PATH:-ffmpeg}"

if command -v "$FFMPEG_PATH" &>/dev/null; then
    FFMPEG_VERSION=$("$FFMPEG_PATH" -version 2>/dev/null | head -n1)
    echo "[+] ${FFMPEG_VERSION}"

    echo "[*] Available hardware accelerations:"
    "$FFMPEG_PATH" -hwaccels 2>/dev/null | tail -n +2 | sed 's/^/    /' || true

    # Check for expected encoder
    case "$HW_ACCEL" in
        nvenc)
            if "$FFMPEG_PATH" -encoders 2>/dev/null | grep -q h264_nvenc; then
                echo "[+] h264_nvenc encoder available"
            else
                echo "[!] WARNING: h264_nvenc encoder not found in FFmpeg"
            fi
            ;;
        qsv)
            if "$FFMPEG_PATH" -encoders 2>/dev/null | grep -q h264_qsv; then
                echo "[+] h264_qsv encoder available"
            else
                echo "[!] WARNING: h264_qsv encoder not found in FFmpeg"
            fi
            ;;
        vaapi)
            if "$FFMPEG_PATH" -encoders 2>/dev/null | grep -q h264_vaapi; then
                echo "[+] h264_vaapi encoder available"
            else
                echo "[!] WARNING: h264_vaapi encoder not found in FFmpeg"
            fi
            ;;
    esac
else
    echo "[!] ERROR: FFmpeg not found at '${FFMPEG_PATH}'"
    exit 1
fi

# --- Create directories ---
echo ""
echo "[*] Ensuring directories exist..."
mkdir -p "${PLEX_WORKER_TEMP_DIR:-/app/transcode_temp}"
mkdir -p "${PLEX_WORKER_LOG_DIR:-/app/logs}"

echo ""
echo "[*] Starting PlexBeam worker on port ${PLEX_WORKER_PORT:-8765}..."
echo "========================================="
echo ""

exec python3 worker.py "$@"
