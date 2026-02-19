#!/bin/bash
PREFS="/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/Preferences.xml"

echo "=== Plex Hardware Transcoding Settings ==="
if [[ -f "$PREFS" ]]; then
    # Check for hardware acceleration setting
    grep -oP 'HardwareAcceleratedCodecs="\K[^"]*' "$PREFS" && echo "(HW codecs enabled)" || echo "HardwareAcceleratedCodecs not set"
    grep -oP 'HardwareAcceleratedEncoders="\K[^"]*' "$PREFS" && echo "(HW encoders enabled)" || echo "HardwareAcceleratedEncoders not set"
    # Show all transcoder-related settings
    echo ""
    echo "=== All Transcoder Prefs ==="
    grep -oP '[A-Za-z]*[Tt]ranscod[^=]*="[^"]*"' "$PREFS" | head -20
    echo ""
    echo "=== Hardware related ==="
    grep -oP '[A-Za-z]*[Hh]ardware[^=]*="[^"]*"' "$PREFS"
else
    echo "Preferences.xml not found at: $PREFS"
    find / -name "Preferences.xml" -path "*/Plex*" 2>/dev/null
fi
