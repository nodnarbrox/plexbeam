#!/bin/bash
CARTRIDGE="/usr/lib/plexmediaserver/Plex Transcoder"

# Fix template placeholders
sed -i 's|__SERVER_TYPE__|plex|g' "$CARTRIDGE"
sed -i 's|__REAL_TRANSCODER_PATH__|/usr/lib/plexmediaserver/Plex Transcoder.real|g' "$CARTRIDGE"
sed -i 's|__CARTRIDGE_HOME__|/opt/plex-cartridge|g' "$CARTRIDGE"
sed -i 's|__UPDATE_REPO__|local|g' "$CARTRIDGE"
sed -i 's|__REMOTE_WORKER_URL__||g' "$CARTRIDGE"
sed -i 's|__REMOTE_API_KEY__||g' "$CARTRIDGE"
sed -i 's|__SHARED_SEGMENT_DIR__||g' "$CARTRIDGE"
sed -i 's|__CALLBACK_URL__||g' "$CARTRIDGE"
sed -i 's|__WORKER_POOL__||g' "$CARTRIDGE"

echo "=== Verify ==="
grep -n 'SERVER_TYPE=\|REAL_TRANSCODER=\|CARTRIDGE_HOME=\|UPDATE_REPO=\|REMOTE_WORKER_URL=\|WORKER_POOL=\|FALLBACK_TO_LOCAL=' "$CARTRIDGE" | head -15

echo ""
echo "=== Check for remaining template placeholders ==="
grep -c '__' "$CARTRIDGE"
grep -n '__' "$CARTRIDGE" | head -10
