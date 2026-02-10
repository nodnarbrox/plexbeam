#!/bin/bash
# Patch v2: Full VAAPI pipeline rewrite for non-Plex Pass local fallback
CARTRIDGE="/usr/lib/plexmediaserver/Plex Transcoder"
TEMPLATE="/opt/plex-cartridge/plex_cartridge.sh"

# Extract the fallback block from the template
TMPL_START=$(grep -n '# Fall back to local transcoder if needed' "$TEMPLATE" | cut -d: -f1)
TMPL_END=$(grep -n 'TRANSCODE_END=\$(date' "$TEMPLATE" | cut -d: -f1)
TMPL_END=$((TMPL_END - 1))

# Find the same block in the installed cartridge
INST_START=$(grep -n '# Fall back to local transcoder if needed' "$CARTRIDGE" | cut -d: -f1)
INST_END=$(grep -n 'TRANSCODE_END=\$(date' "$CARTRIDGE" | cut -d: -f1)
INST_END=$((INST_END - 1))

if [[ -z "$TMPL_START" ]] || [[ -z "$INST_START" ]]; then
    echo "ERROR: Could not find fallback section"
    exit 1
fi

echo "Template: lines $TMPL_START-$TMPL_END"
echo "Installed: replacing lines $INST_START-$INST_END"

{
    head -n $((INST_START - 1)) "$CARTRIDGE"
    sed -n "${TMPL_START},${TMPL_END}p" "$TEMPLATE"
    tail -n +$((INST_END + 1)) "$CARTRIDGE"
} > "${CARTRIDGE}.new"

mv "${CARTRIDGE}.new" "$CARTRIDGE"
chmod +x "$CARTRIDGE"

# Syntax check
if bash -n "$CARTRIDGE" 2>&1; then
    echo "Syntax: OK"
else
    echo "ERROR: Syntax check failed!"
    exit 1
fi

COUNT=$(grep -c 'h264_vaapi\|VAAPI_REWRITE\|scale_vaapi\|global_quality' "$CARTRIDGE")
echo "Patch applied: $COUNT VAAPI references found"
