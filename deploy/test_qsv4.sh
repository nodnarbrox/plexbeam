#!/bin/bash
# Diagnose Plex libc and fix libva

echo "=== Plex binary dynamic linker ==="
file "/usr/lib/plexmediaserver/Plex Transcoder.real"
echo ""

echo "=== Plex libc ==="
ldd "/usr/lib/plexmediaserver/Plex Transcoder.real" 2>&1 | grep -i libc
echo ""

echo "=== System glibc version ==="
ldd --version 2>&1 | head -1
echo ""

echo "=== Plex bundled libva details ==="
file /usr/lib/plexmediaserver/lib/libva.so.2
readelf -d /usr/lib/plexmediaserver/lib/libva.so.2 2>/dev/null | grep NEEDED
echo ""

echo "=== System libva details ==="
file /lib/x86_64-linux-gnu/libva.so.2.2000.0
readelf -d /lib/x86_64-linux-gnu/libva.so.2.2000.0 2>/dev/null | grep NEEDED
echo ""

echo "=== Try: Remove Plex libva, let it use system ==="
# Backup first
cp /usr/lib/plexmediaserver/lib/libva.so.2 /usr/lib/plexmediaserver/lib/libva.so.2.plex-orig
cp /usr/lib/plexmediaserver/lib/libva-drm.so.2 /usr/lib/plexmediaserver/lib/libva-drm.so.2.plex-orig

# Replace with system symlinks
ln -sf /lib/x86_64-linux-gnu/libva.so.2 /usr/lib/plexmediaserver/lib/libva.so.2
ln -sf /lib/x86_64-linux-gnu/libva-drm.so.2 /usr/lib/plexmediaserver/lib/libva-drm.so.2

ls -la /usr/lib/plexmediaserver/lib/libva*
echo ""

echo "=== Test Plex transcoder with system libva ==="
"/usr/lib/plexmediaserver/Plex Transcoder.real" -vaapi_device /dev/dri/renderD128 \
    -f lavfi -i color=c=blue:s=320x240:d=1 \
    -vf 'format=nv12,hwupload' \
    -c:v h264_vaapi -frames:v 1 \
    -f null - 2>&1 | tail -8
echo ""
echo "EXIT=$?"
