#!/bin/bash
# Patch the installed Plex Transcoder cartridge to add VAAPI hardware encoding on local fallback
# Run inside container 121

CARTRIDGE="/usr/lib/plexmediaserver/Plex Transcoder"

# Find the line number of the old fallback block
OLD_START=$(grep -n '# Fall back to local transcoder if needed' "$CARTRIDGE" | cut -d: -f1)
if [[ -z "$OLD_START" ]]; then
    echo "ERROR: Could not find fallback section"
    exit 1
fi

# Find the end of the old block (the 'fi' that closes it)
# Count from OLD_START to find matching fi
OLD_END=""
DEPTH=0
LINE_NUM=0
while IFS= read -r line; do
    LINE_NUM=$((LINE_NUM + 1))
    if [[ $LINE_NUM -lt $OLD_START ]]; then continue; fi

    # Count if/fi depth
    if echo "$line" | grep -qE '^\s*if\s'; then
        DEPTH=$((DEPTH + 1))
    fi
    if echo "$line" | grep -qE '^\s*fi\s*$'; then
        DEPTH=$((DEPTH - 1))
        if [[ $DEPTH -eq 0 ]]; then
            OLD_END=$LINE_NUM
            break
        fi
    fi
done < "$CARTRIDGE"

if [[ -z "$OLD_END" ]]; then
    echo "ERROR: Could not find end of fallback block"
    exit 1
fi

echo "Replacing lines $OLD_START-$OLD_END in $CARTRIDGE"

# Build the new fallback block
NEW_BLOCK='# Fall back to local transcoder if needed
if [[ "$USE_REMOTE" == "false" ]] || [[ "$REMOTE_SUCCESS" == "false" ]]; then

    # Force VAAPI hardware encoding on local fallback if Plex sent libx264
    # This ensures the local Intel GPU handles both decode AND encode
    LOCAL_ARGS=("$@")
    VAAPI_REWRITE=false

    if [[ -e /dev/dri/renderD128 ]]; then
        declare -a REWRITTEN_ARGS=()
        HAS_VAAPI_INIT=false

        for arg in "${LOCAL_ARGS[@]}"; do
            if [[ "$arg" == "libx264" ]]; then
                REWRITTEN_ARGS+=("h264_vaapi")
                VAAPI_REWRITE=true
            else
                REWRITTEN_ARGS+=("$arg")
            fi
            if [[ "$arg" == *"init_hw_device"* ]] && [[ "$arg" == *"vaapi"* ]]; then
                HAS_VAAPI_INIT=true
            fi
        done

        if [[ "$VAAPI_REWRITE" == "true" ]]; then
            # Inject VAAPI init if Plex didn'\''t include it
            if [[ "$HAS_VAAPI_INIT" == "false" ]]; then
                declare -a FINAL_ARGS=()
                FINAL_ARGS+=("-init_hw_device" "vaapi=vaapi:/dev/dri/renderD128,driver=iHD")
                FINAL_ARGS+=("-filter_hw_device" "vaapi")
                FINAL_ARGS+=("${REWRITTEN_ARGS[@]}")
                REWRITTEN_ARGS=("${FINAL_ARGS[@]}")
            fi
            LOCAL_ARGS=("${REWRITTEN_ARGS[@]}")
            log_event "LOCAL" "Rewrote libx264 → h264_vaapi for local GPU fallback"
        fi
    fi

    {
        echo ""
        echo "═══════════════════════════════════════════════════════════════"
        echo "  LOCAL TRANSCODER EXECUTION"
        echo "═══════════════════════════════════════════════════════════════"
        echo ""
        echo "Started:  $(date -Iseconds)"
        echo "Binary:   ${REAL_TRANSCODER}"
        echo "VAAPI:    ${VAAPI_REWRITE}"
    } >> "${SESSION_DIR}/00_session.log"

    "$REAL_TRANSCODER" "${LOCAL_ARGS[@]}" 2> >(tee "${SESSION_DIR}/stderr.log" >&2)
    EXIT_CODE=$?

    {
        echo "Finished: $(date -Iseconds)"
        echo "Exit:     ${EXIT_CODE}"
    } >> "${SESSION_DIR}/00_session.log"
fi'

# Replace: delete old lines, insert new block
{
    head -n $((OLD_START - 1)) "$CARTRIDGE"
    echo "$NEW_BLOCK"
    tail -n +$((OLD_END + 1)) "$CARTRIDGE"
} > "${CARTRIDGE}.new"

mv "${CARTRIDGE}.new" "$CARTRIDGE"
chmod +x "$CARTRIDGE"

echo "Patch applied successfully. Verify with: grep -n 'h264_vaapi\|VAAPI_REWRITE' \"$CARTRIDGE\""
