#!/bin/bash
# Quick QSV encode test inside LXC 121
FFMPEG="/usr/lib/plexmediaserver/Plex Transcoder.real"

echo "=== Testing VAAPI H264 encode ==="
"$FFMPEG" -vaapi_device /dev/dri/renderD128 \
    -f lavfi -i color=c=blue:s=1920x1080:d=2 \
    -vf 'format=nv12,hwupload' \
    -c:v h264_vaapi -frames:v 30 \
    -f null - 2>&1 | tail -5

echo ""
echo "=== Testing VAAPI HEVC encode ==="
"$FFMPEG" -vaapi_device /dev/dri/renderD128 \
    -f lavfi -i color=c=red:s=1920x1080:d=2 \
    -vf 'format=nv12,hwupload' \
    -c:v hevc_vaapi -frames:v 30 \
    -f null - 2>&1 | tail -5

echo ""
echo "=== Testing VAAPI H264 decode + encode ==="
"$FFMPEG" -hwaccel vaapi -hwaccel_device /dev/dri/renderD128 -hwaccel_output_format vaapi \
    -f lavfi -i color=c=green:s=1920x1080:d=2 \
    -vf 'format=nv12|vaapi,hwupload' \
    -c:v h264_vaapi -frames:v 30 \
    -f null - 2>&1 | tail -5

echo ""
echo "=== QSV test complete ==="
