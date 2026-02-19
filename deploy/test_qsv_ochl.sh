#!/bin/bash
# Trigger a Plex transcode and watch the cartridge log for QSV usage

echo "=== Recent cartridge sessions ==="
ls -lt /tmp/plex/Transcode/Sync+/ 2>/dev/null | head -10 || \
ls -lt /tmp/plextranscode/ 2>/dev/null | head -10 || \
ls -lt /tmp/ 2>/dev/null | grep -i plex | head -10
echo ""

echo "=== Last session log ==="
LATEST=$(ls -td /tmp/plex/Transcode/Sync+/*/  2>/dev/null | head -1)
if [[ -n "$LATEST" ]]; then
    echo "Session: $LATEST"
    echo "--- cartridge log ---"
    cat "${LATEST}cartridge.log" 2>/dev/null | tail -30
    echo "--- stderr ---"
    cat "${LATEST}stderr.log" 2>/dev/null | tail -20
else
    echo "No session dirs found"
    # Try to find them
    find /tmp -name "cartridge.log" 2>/dev/null | head -5
fi
echo ""

echo "=== Check cartridge QSV settings ==="
grep -n "QSV_REWRITE\|LOCAL_BINARY\|LIBVA\|/dev/dri" "/usr/lib/plexmediaserver/Plex Transcoder" | head -15
