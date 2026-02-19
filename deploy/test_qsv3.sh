#!/bin/bash
# Fix: Override Plex's bundled libva with system libva

echo "=== Plex libva version ==="
ls -la /usr/lib/plexmediaserver/lib/libva*
echo ""

echo "=== System libva version ==="
ls -la /lib/x86_64-linux-gnu/libva*
echo ""

echo "=== System driver path ==="
ls /usr/lib/x86_64-linux-gnu/dri/iHD* 2>/dev/null
echo ""

echo "=== Test 1: LIBVA_DRIVERS_PATH ==="
LIBVA_DRIVERS_PATH=/usr/lib/x86_64-linux-gnu/dri \
    "/usr/lib/plexmediaserver/Plex Transcoder.real" -vaapi_device /dev/dri/renderD128 \
    -f lavfi -i color=c=blue:s=320x240:d=1 \
    -vf 'format=nv12,hwupload' \
    -c:v h264_vaapi -frames:v 1 \
    -f null - 2>&1 | tail -5
echo ""

echo "=== Test 2: LD_PRELOAD system libva ==="
LD_PRELOAD="/lib/x86_64-linux-gnu/libva.so.2 /lib/x86_64-linux-gnu/libva-drm.so.2" \
    "/usr/lib/plexmediaserver/Plex Transcoder.real" -vaapi_device /dev/dri/renderD128 \
    -f lavfi -i color=c=blue:s=320x240:d=1 \
    -vf 'format=nv12,hwupload' \
    -c:v h264_vaapi -frames:v 1 \
    -f null - 2>&1 | tail -5
echo ""

echo "=== Test 3: Replace Plex libva with system symlinks ==="
echo "(dry-run only - showing what would be done)"
echo "mv /usr/lib/plexmediaserver/lib/libva.so.2 /usr/lib/plexmediaserver/lib/libva.so.2.bak"
echo "mv /usr/lib/plexmediaserver/lib/libva-drm.so.2 /usr/lib/plexmediaserver/lib/libva-drm.so.2.bak"
echo "ln -s /lib/x86_64-linux-gnu/libva.so.2 /usr/lib/plexmediaserver/lib/libva.so.2"
echo "ln -s /lib/x86_64-linux-gnu/libva-drm.so.2 /usr/lib/plexmediaserver/lib/libva-drm.so.2"
