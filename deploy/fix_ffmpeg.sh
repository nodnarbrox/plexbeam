#!/bin/bash
set -e

echo "=== Current ffmpeg situation ==="
ls -lh /usr/bin/ffmpeg /bin/ffmpeg 2>/dev/null
echo ""

echo "=== Remove Plex-owned ffmpeg package ==="
apt-get remove -y ffmpeg 2>&1 || true
echo ""

echo "=== Make sure Ubuntu sources are available ==="
grep -r "ubuntu" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null | grep -v "^#" | head -5
echo ""

echo "=== Install real ffmpeg from Ubuntu repos ==="
apt-get update -qq 2>&1 | tail -3
apt-get install -y ffmpeg 2>&1 | tail -10
echo ""

echo "=== Verify new ffmpeg ==="
ls -lh /usr/bin/ffmpeg
file /usr/bin/ffmpeg
ffmpeg -version 2>&1 | head -3
echo ""

echo "=== Ensure VAAPI libraries are installed ==="
apt-get install -y libva-drm2 libva2 vainfo intel-media-va-driver-non-free 2>&1 | tail -5
echo ""

echo "=== Test VAAPI with system ffmpeg ==="
LIBVA_DRIVER_NAME=iHD LIBVA_DRIVERS_PATH=/usr/lib/x86_64-linux-gnu/dri \
    ffmpeg -vaapi_device /dev/dri/renderD128 \
    -f lavfi -i color=c=blue:s=1920x1080:d=2 \
    -vf 'format=nv12,hwupload' \
    -c:v h264_vaapi -frames:v 30 \
    -f null - 2>&1 | tail -5
echo ""

echo "=== Test HEVC VAAPI ==="
LIBVA_DRIVER_NAME=iHD LIBVA_DRIVERS_PATH=/usr/lib/x86_64-linux-gnu/dri \
    ffmpeg -vaapi_device /dev/dri/renderD128 \
    -f lavfi -i color=c=red:s=1920x1080:d=2 \
    -vf 'format=nv12,hwupload' \
    -c:v hevc_vaapi -frames:v 30 \
    -f null - 2>&1 | tail -5
echo ""

echo "=== DONE ==="
