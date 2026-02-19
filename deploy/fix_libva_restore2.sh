#!/bin/bash
# Restore Plex's original libva and fix LD_LIBRARY_PATH contamination

echo "=== Remove symlinks and restore originals ==="
rm -f /usr/lib/plexmediaserver/lib/libva.so.2
rm -f /usr/lib/plexmediaserver/lib/libva-drm.so.2
mv /usr/lib/plexmediaserver/lib/libva.so.2.plex-orig /usr/lib/plexmediaserver/lib/libva.so.2
mv /usr/lib/plexmediaserver/lib/libva-drm.so.2.plex-orig /usr/lib/plexmediaserver/lib/libva-drm.so.2
echo "Done"

echo ""
echo "=== After restore ==="
ls -la /usr/lib/plexmediaserver/lib/libva*
echo ""
file /usr/lib/plexmediaserver/lib/libva.so.2

echo ""
echo "=== Check LD config ==="
ldconfig -p | grep gcompat
echo "---"
# Check if Plex's lib dir is in the global LD path
cat /etc/ld.so.conf.d/*.conf 2>/dev/null | head -20
echo "---"
echo "LD_LIBRARY_PATH=$LD_LIBRARY_PATH"

echo ""
echo "=== Test system ffmpeg WITHOUT Plex LD path ==="
LD_LIBRARY_PATH="" ffmpeg -version 2>&1 | head -1
echo ""

echo "=== Test system ffmpeg VAAPI ==="
LD_LIBRARY_PATH="" \
    LIBVA_DRIVER_NAME=iHD LIBVA_DRIVERS_PATH=/usr/lib/x86_64-linux-gnu/dri \
    ffmpeg -vaapi_device /dev/dri/renderD128 \
    -f lavfi -i color=c=blue:s=1920x1080:d=2 \
    -vf 'format=nv12,hwupload' \
    -c:v h264_vaapi -frames:v 30 \
    -f null - 2>&1 | tail -5
echo ""
echo "=== Done ==="
