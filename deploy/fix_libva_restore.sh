#!/bin/bash
# Restore Plex's original libva (undo the symlinks from test_qsv4.sh)

echo "=== Current state ==="
ls -la /usr/lib/plexmediaserver/lib/libva*
echo ""

# Restore originals if backups exist
if [[ -f /usr/lib/plexmediaserver/lib/libva.so.2.plex-orig ]]; then
    cp /usr/lib/plexmediaserver/lib/libva.so.2.plex-orig /usr/lib/plexmediaserver/lib/libva.so.2
    cp /usr/lib/plexmediaserver/lib/libva-drm.so.2.plex-orig /usr/lib/plexmediaserver/lib/libva-drm.so.2
    echo "Restored Plex's original libva from backups"
else
    echo "No backups found - libva may already be original"
fi

echo ""
echo "=== After restore ==="
ls -la /usr/lib/plexmediaserver/lib/libva*
echo ""

echo "=== System ffmpeg check ==="
which ffmpeg 2>&1
ffmpeg -version 2>&1 | head -1
echo ""

echo "=== System ffmpeg VAAPI test ==="
LIBVA_DRIVER_NAME=iHD LIBVA_DRIVERS_PATH=/usr/lib/x86_64-linux-gnu/dri \
    ffmpeg -vaapi_device /dev/dri/renderD128 \
    -f lavfi -i color=c=blue:s=1920x1080:d=2 \
    -vf 'format=nv12,hwupload' \
    -c:v h264_vaapi -frames:v 30 \
    -f null - 2>&1 | tail -5
echo ""

echo "=== System ffmpeg HEVC VAAPI test ==="
LIBVA_DRIVER_NAME=iHD LIBVA_DRIVERS_PATH=/usr/lib/x86_64-linux-gnu/dri \
    ffmpeg -vaapi_device /dev/dri/renderD128 \
    -f lavfi -i color=c=red:s=1920x1080:d=2 \
    -vf 'format=nv12,hwupload' \
    -c:v hevc_vaapi -frames:v 30 \
    -f null - 2>&1 | tail -5
echo ""

echo "=== All good ==="
