#!/bin/bash
# Debug VAAPI issue

echo "=== Device permissions ==="
ls -la /dev/dri/
echo ""

echo "=== Try as root with system ffmpeg ==="
ffmpeg -vaapi_device /dev/dri/renderD128 \
    -f lavfi -i color=c=blue:s=320x240:d=1 \
    -vf 'format=nv12,hwupload' \
    -c:v h264_vaapi -frames:v 1 \
    -f null - 2>&1 | tail -5
echo ""

echo "=== Try as plex user with system ffmpeg ==="
su -s /bin/bash plex -c 'ffmpeg -vaapi_device /dev/dri/renderD128 -f lavfi -i color=c=blue:s=320x240:d=1 -vf "format=nv12,hwupload" -c:v h264_vaapi -frames:v 1 -f null - 2>&1' | tail -5
echo ""

echo "=== Plex transcoder LIBVA info ==="
LIBVA_DRIVER_NAME=iHD "/usr/lib/plexmediaserver/Plex Transcoder.real" -vaapi_device /dev/dri/renderD128 \
    -f lavfi -i color=c=blue:s=320x240:d=1 \
    -vf 'format=nv12,hwupload' \
    -c:v h264_vaapi -frames:v 1 \
    -f null - 2>&1 | tail -8
echo ""

echo "=== Check libva in Plex's ffmpeg ==="
ldd "/usr/lib/plexmediaserver/Plex Transcoder.real" 2>&1 | grep -i va
echo ""

echo "=== LD_LIBRARY_PATH Plex ==="
ls /usr/lib/plexmediaserver/lib/ 2>/dev/null | grep -i va | head -10
echo ""

echo "=== System libva ==="
ldconfig -p | grep libva | head -10
