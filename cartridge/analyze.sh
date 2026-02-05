#!/usr/bin/env bash
# ============================================================================
# PLEX CARTRIDGE — Analyzer
# ============================================================================
# Reads everything the cartridge captured and shows you the full picture:
# what Plex is actually doing, what patterns emerge, and what you'd need
# to handle if building a remote transcoder.
#
# Usage: ./analyze.sh [--detail SESSION_ID] [--json] [--remote-feasibility]
# ============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

LOG_BASE="/var/log/plex-cartridge"
SESSIONS_DIR="${LOG_BASE}/sessions"

# --- Parse args ---------------------------------------------------------------
DETAIL_SESSION=""
JSON_MODE=false
FEASIBILITY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --detail)
            DETAIL_SESSION="$2"
            shift 2
            ;;
        --json)
            JSON_MODE=true
            shift
            ;;
        --remote-feasibility)
            FEASIBILITY=true
            shift
            ;;
        -h|--help)
            echo "Usage: ./analyze.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --detail SESSION_ID    Show full details for one session"
            echo "  --json                 Output as JSON (for piping to tools)"
            echo "  --remote-feasibility   Analyze whether remote transcoding is viable"
            echo "  -h, --help             This help"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# --- Check for data -----------------------------------------------------------
if [[ ! -d "$SESSIONS_DIR" ]] || [[ -z "$(ls -A "$SESSIONS_DIR" 2>/dev/null)" ]]; then
    echo ""
    echo -e "${YELLOW}No sessions captured yet.${RESET}"
    echo ""
    echo "Play something in Plex that triggers a transcode, then run this again."
    echo ""
    echo "Quick ways to force a transcode:"
    echo "  • Play from a phone on cellular (usually forces 720p transcode)"
    echo "  • In Plex Web: Settings → Quality → set to 2Mbps 720p"
    echo "  • Play an MKV with PGS subtitles (forces burn-in transcode)"
    echo "  • Play HEVC content on a device that only supports H.264"
    exit 0
fi

# --- Detail mode: show one session --------------------------------------------
if [[ -n "$DETAIL_SESSION" ]]; then
    SESSION_PATH="${SESSIONS_DIR}/${DETAIL_SESSION}"
    if [[ ! -d "$SESSION_PATH" ]]; then
        echo -e "${RED}Session not found:${RESET} ${DETAIL_SESSION}"
        echo "Available sessions:"
        ls -1 "$SESSIONS_DIR" | head -20
        exit 1
    fi
    
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${RESET}"
    echo -e "  ${BOLD}Session Detail: ${DETAIL_SESSION}${RESET}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${RESET}"
    
    for logfile in "$SESSION_PATH"/*.log; do
        echo ""
        echo -e "${MAGENTA}--- $(basename "$logfile") ---${RESET}"
        cat "$logfile"
    done
    exit 0
fi

# --- Overview mode: analyze all sessions --------------------------------------

echo ""
echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}║${RESET}  ${BOLD}PLEX CARTRIDGE — Analysis Report${RESET}                            ${CYAN}║${RESET}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${RESET}"
echo ""

TOTAL_SESSIONS=$(ls -d "${SESSIONS_DIR}"/*/ 2>/dev/null | wc -l)
echo -e "${BOLD}Sessions captured: ${TOTAL_SESSIONS}${RESET}"
echo ""

if [[ "$TOTAL_SESSIONS" -eq 0 ]]; then
    echo "No sessions to analyze."
    exit 0
fi

# --- Collect stats from all sessions ------------------------------------------
declare -A CODEC_COUNT
declare -A TYPE_COUNT
declare -A HW_COUNT
declare -A SUB_COUNT
declare -A EXIT_COUNT

DURATIONS=()
ARG_PATTERNS=()
UNIQUE_ENV_VARS=()
SESSIONS_WITH_ERRORS=0

for session_dir in "${SESSIONS_DIR}"/*/; do
    SESSION_NAME=$(basename "$session_dir")
    
    # Parse summary if available
    if [[ -f "${session_dir}/SUMMARY.log" ]]; then
        while IFS= read -r line; do
            case "$line" in
                *"Video Out:"*)
                    val=$(echo "$line" | sed 's/.*Video Out:\s*//' | xargs)
                    CODEC_COUNT["$val"]=$(( ${CODEC_COUNT["$val"]:-0} + 1 ))
                    ;;
                *"Type:"*)
                    val=$(echo "$line" | sed 's/.*Type:\s*//' | xargs)
                    TYPE_COUNT["$val"]=$(( ${TYPE_COUNT["$val"]:-0} + 1 ))
                    ;;
                *"HW Accel:"*)
                    val=$(echo "$line" | sed 's/.*HW Accel:\s*//' | xargs)
                    HW_COUNT["$val"]=$(( ${HW_COUNT["$val"]:-0} + 1 ))
                    ;;
                *"Subtitles:"*)
                    val=$(echo "$line" | sed 's/.*Subtitles:\s*//' | xargs)
                    SUB_COUNT["$val"]=$(( ${SUB_COUNT["$val"]:-0} + 1 ))
                    ;;
                *"Exit Code:"*)
                    val=$(echo "$line" | sed 's/.*Exit Code:\s*//' | xargs)
                    EXIT_COUNT["$val"]=$(( ${EXIT_COUNT["$val"]:-0} + 1 ))
                    if [[ "$val" != "0" ]]; then
                        SESSIONS_WITH_ERRORS=$((SESSIONS_WITH_ERRORS + 1))
                    fi
                    ;;
                *"Duration:"*)
                    val=$(echo "$line" | sed 's/.*Duration:\s*//' | sed 's/ms//' | xargs)
                    DURATIONS+=("$val")
                    ;;
            esac
        done < "${session_dir}/SUMMARY.log"
    fi
    
    # Count unique arg patterns from raw args
    if [[ -f "${session_dir}/01_arguments_raw.log" ]]; then
        argc=$(grep "^ARGC:" "${session_dir}/01_arguments_raw.log" | awk '{print $2}' || echo "?")
        ARG_PATTERNS+=("$argc")
    fi
done

# --- Print: Codec Distribution ------------------------------------------------
echo -e "${BOLD}┌─ Video Codecs Used ─────────────────────────────────────────┐${RESET}"
for codec in "${!CODEC_COUNT[@]}"; do
    count=${CODEC_COUNT[$codec]}
    pct=$((count * 100 / TOTAL_SESSIONS))
    bar=$(printf '█%.0s' $(seq 1 $((pct / 5 + 1))))
    printf "  %-20s %3d sessions (%2d%%) %s\n" "$codec" "$count" "$pct" "$bar"
done
echo ""

# --- Print: Transcode Type Distribution ---------------------------------------
echo -e "${BOLD}┌─ Transcode Types ──────────────────────────────────────────┐${RESET}"
for ttype in "${!TYPE_COUNT[@]}"; do
    count=${TYPE_COUNT[$ttype]}
    pct=$((count * 100 / TOTAL_SESSIONS))
    bar=$(printf '█%.0s' $(seq 1 $((pct / 5 + 1))))
    printf "  %-20s %3d sessions (%2d%%) %s\n" "$ttype" "$count" "$pct" "$bar"
done
echo ""

# --- Print: Hardware Acceleration ---------------------------------------------
echo -e "${BOLD}┌─ Hardware Acceleration ────────────────────────────────────┐${RESET}"
for hw in "${!HW_COUNT[@]}"; do
    count=${HW_COUNT[$hw]}
    printf "  %-30s %3d sessions\n" "$hw" "$count"
done
echo ""

# --- Print: Subtitle Modes ---------------------------------------------------
echo -e "${BOLD}┌─ Subtitle Handling ────────────────────────────────────────┐${RESET}"
for sub in "${!SUB_COUNT[@]}"; do
    count=${SUB_COUNT[$sub]}
    printf "  %-20s %3d sessions\n" "$sub" "$count"
done
echo ""

# --- Print: Exit Codes -------------------------------------------------------
echo -e "${BOLD}┌─ Exit Codes ──────────────────────────────────────────────┐${RESET}"
for code in "${!EXIT_COUNT[@]}"; do
    count=${EXIT_COUNT[$code]}
    if [[ "$code" == "0" ]]; then
        echo -e "  ${GREEN}Exit ${code}${RESET}  (success)    ${count} sessions"
    else
        echo -e "  ${RED}Exit ${code}${RESET}  (error)      ${count} sessions"
    fi
done
echo ""

# --- Print: Timing Analysis --------------------------------------------------
if [[ ${#DURATIONS[@]} -gt 0 ]]; then
    echo -e "${BOLD}┌─ Timing ──────────────────────────────────────────────────┐${RESET}"
    
    # Sort durations
    IFS=$'\n' SORTED_DURATIONS=($(sort -n <<<"${DURATIONS[*]}")); unset IFS
    
    MIN_DUR=${SORTED_DURATIONS[0]}
    MAX_DUR=${SORTED_DURATIONS[-1]}
    
    # Calculate average
    TOTAL_DUR=0
    for d in "${DURATIONS[@]}"; do
        TOTAL_DUR=$((TOTAL_DUR + d))
    done
    AVG_DUR=$((TOTAL_DUR / ${#DURATIONS[@]}))
    
    # Median
    MID_IDX=$(( ${#SORTED_DURATIONS[@]} / 2 ))
    MEDIAN_DUR=${SORTED_DURATIONS[$MID_IDX]}
    
    echo "  Fastest session:  ${MIN_DUR}ms"
    echo "  Slowest session:  ${MAX_DUR}ms"
    echo "  Average:          ${AVG_DUR}ms"
    echo "  Median:           ${MEDIAN_DUR}ms"
    echo "  Total sessions:   ${#DURATIONS[@]}"
    echo ""
fi

# --- Print: Session List ------------------------------------------------------
echo -e "${BOLD}┌─ All Sessions ────────────────────────────────────────────┐${RESET}"
echo ""
printf "  ${DIM}%-26s %-8s %-10s %-12s %-8s${RESET}\n" "SESSION ID" "EXIT" "DURATION" "CODEC" "TYPE"
echo -e "  ${DIM}──────────────────────────────────────────────────────────────${RESET}"

for session_dir in "${SESSIONS_DIR}"/*/; do
    SESSION_NAME=$(basename "$session_dir")
    
    if [[ -f "${session_dir}/SUMMARY.log" ]]; then
        exit_code=$(grep "Exit Code:" "${session_dir}/SUMMARY.log" | sed 's/.*Exit Code:\s*//' | tr -d '│ ' || echo "?")
        duration=$(grep "Duration:" "${session_dir}/SUMMARY.log" | sed 's/.*Duration:\s*//' | tr -d '│ ' || echo "?")
        codec=$(grep "Video Out:" "${session_dir}/SUMMARY.log" | sed 's/.*Video Out:\s*//' | tr -d '│ ' || echo "?")
        ttype=$(grep "Type:" "${session_dir}/SUMMARY.log" | sed 's/.*Type:\s*//' | tr -d '│ ' || echo "?")
        
        if [[ "$exit_code" == "0" ]]; then
            printf "  %-26s ${GREEN}%-8s${RESET} %-10s %-12s %-8s\n" "$SESSION_NAME" "$exit_code" "$duration" "$codec" "$ttype"
        else
            printf "  %-26s ${RED}%-8s${RESET} %-10s %-12s %-8s\n" "$SESSION_NAME" "$exit_code" "$duration" "$codec" "$ttype"
        fi
    else
        printf "  %-26s ${DIM}(no summary)${RESET}\n" "$SESSION_NAME"
    fi
done

echo ""
echo -e "  ${DIM}View details: ./analyze.sh --detail SESSION_ID${RESET}"
echo ""

# --- Remote Feasibility Analysis ----------------------------------------------
if [[ "$FEASIBILITY" == true ]]; then
    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}║${RESET}  ${BOLD}REMOTE TRANSCODING FEASIBILITY${RESET}                              ${CYAN}║${RESET}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${RESET}"
    echo ""
    
    # Analyze what would need to be handled remotely
    HLS_COUNT=${TYPE_COUNT["hls"]:-0}
    DASH_COUNT=${TYPE_COUNT["dash"]:-0}
    BURNIN_COUNT=${SUB_COUNT["burn-in"]:-0}
    HW_NONE=${HW_COUNT["none/software"]:-0}
    
    echo -e "${BOLD}Findings:${RESET}"
    echo ""
    
    # HLS/DASH segment handling
    SEGMENT_SESSIONS=$((HLS_COUNT + DASH_COUNT))
    if [[ $SEGMENT_SESSIONS -gt 0 ]]; then
        SEGMENT_PCT=$((SEGMENT_SESSIONS * 100 / TOTAL_SESSIONS))
        echo -e "  ${YELLOW}⚠ ${RESET} ${SEGMENT_PCT}% of sessions use segmented output (HLS/DASH)"
        echo "     → This is the hardest part to handle remotely"
        echo "     → Segments must arrive within ~2-4 seconds or playback stalls"
        echo "     → Your network latency to the remote GPU is critical"
        echo ""
    fi
    
    # Subtitle burn-in
    if [[ $BURNIN_COUNT -gt 0 ]]; then
        BURNIN_PCT=$((BURNIN_COUNT * 100 / TOTAL_SESSIONS))
        echo -e "  ${YELLOW}⚠ ${RESET} ${BURNIN_PCT}% of sessions burn in subtitles"
        echo "     → Remote worker needs access to subtitle files"
        echo "     → Must transfer .srt/.ass files alongside the job request"
        echo ""
    fi
    
    # HW acceleration usage
    if [[ $HW_NONE -gt 0 ]]; then
        SW_PCT=$((HW_NONE * 100 / TOTAL_SESSIONS))
        echo -e "  ${GREEN}✓${RESET}  ${SW_PCT}% of sessions use software encoding"
        echo "     → Good: these are the easiest to offload to a remote GPU"
        echo ""
    fi
    
    # Timing analysis for remote feasibility
    if [[ ${#DURATIONS[@]} -gt 0 ]] && [[ $AVG_DUR -gt 0 ]]; then
        echo -e "  ${BOLD}Timing budget:${RESET}"
        echo "     Average transcode startup: ~${AVG_DUR}ms"
        
        if [[ $AVG_DUR -lt 3000 ]]; then
            echo -e "     ${GREEN}✓${RESET} Fast enough — you have headroom for network overhead"
            echo "       Remote latency budget: ~$((3000 - AVG_DUR))ms for network + queue"
        elif [[ $AVG_DUR -lt 8000 ]]; then
            echo -e "     ${YELLOW}⚠${RESET} Tight — remote GPU must be very fast and low-latency"
            echo "       Limited network budget remaining"
        else
            echo -e "     ${RED}✗${RESET} Already slow locally — remote will be worse"
            echo "       Consider pre-transcoding (Optimized Versions) instead"
        fi
        echo ""
    fi
    
    # Overall verdict
    echo -e "${BOLD}Verdict:${RESET}"
    echo ""
    if [[ $SEGMENT_SESSIONS -gt $((TOTAL_SESSIONS / 2)) ]]; then
        echo -e "  ${YELLOW}CHALLENGING${RESET} — Most of your transcodes are segmented (HLS/DASH)."
        echo "  Remote transcoding is possible but requires:"
        echo "    • Sub-50ms network latency to remote GPU"
        echo "    • Persistent connection (not cold-start per job)"
        echo "    • Careful segment buffering/pre-fetch strategy"
        echo ""
        echo "  Consider the pre-transcode pipeline as a safer alternative."
    else
        echo -e "  ${GREEN}FEASIBLE${RESET} — Your usage pattern looks workable for remote transcoding."
        echo "  Key requirements:"
        echo "    • Same-LAN or very fast network to remote GPU"
        echo "    • Job queue with <500ms dispatch latency"
    fi
    echo ""
fi

# --- Master log summary -------------------------------------------------------
if [[ -f "${LOG_BASE}/master.log" ]]; then
    echo -e "${BOLD}┌─ Master Log (last 10 entries) ────────────────────────────┐${RESET}"
    echo ""
    tail -10 "${LOG_BASE}/master.log" | while IFS= read -r line; do
        echo "  $line"
    done
    echo ""
fi

# --- Learned Patterns Report --------------------------------------------------
KNOWN_PATTERNS="${LOG_BASE}/.known_patterns"
if [[ -f "$KNOWN_PATTERNS" ]] && [[ -s "$KNOWN_PATTERNS" ]]; then
    PATTERN_COUNT=$(wc -l < "$KNOWN_PATTERNS")
    echo -e "${BOLD}┌─ Learned Argument Patterns (${PATTERN_COUNT} unique) ─────────────────┐${RESET}"
    echo ""
    printf "  ${DIM}%-12s %-22s %-10s %-10s${RESET}\n" "HASH" "FIRST SEEN" "TYPE" "CODEC"
    echo -e "  ${DIM}──────────────────────────────────────────────────────────────${RESET}"
    
    while IFS='|' read -r hash date ttype codec args; do
        short_hash="${hash:0:10}"
        short_date=$(echo "$date" | cut -dT -f1)
        printf "  %-12s %-22s %-10s %-10s\n" "$short_hash" "$short_date" "$ttype" "$codec"
    done < "$KNOWN_PATTERNS"
    
    echo ""
    echo -e "  ${DIM}New patterns = Plex changed its transcoder arguments.${RESET}"
    echo -e "  ${DIM}If you're building a remote shim, each pattern is a code path to handle.${RESET}"
    echo ""
fi

# --- Plex Version History -----------------------------------------------------
VERSION_HISTORY="${LOG_BASE}/.plex_version_history"
if [[ -f "$VERSION_HISTORY" ]] && [[ -s "$VERSION_HISTORY" ]]; then
    echo -e "${BOLD}┌─ Plex Version History ────────────────────────────────────┐${RESET}"
    echo ""
    while IFS='|' read -r date version hash; do
        printf "  %-22s  Plex %-30s  %s\n" "$(echo "$date" | cut -dT -f1)" "$version" "${hash:0:10}..."
    done < "$VERSION_HISTORY"
    echo ""
fi

# --- Cartridge Events ---------------------------------------------------------
EVENTS_LOG="${LOG_BASE}/cartridge_events.log"
if [[ -f "$EVENTS_LOG" ]] && [[ -s "$EVENTS_LOG" ]]; then
    EVENT_COUNT=$(wc -l < "$EVENTS_LOG")
    echo -e "${BOLD}┌─ Cartridge Events (last 15 of ${EVENT_COUNT}) ─────────────────────┐${RESET}"
    echo ""
    tail -15 "$EVENTS_LOG" | while IFS= read -r line; do
        # Color-code by type
        if [[ "$line" == *"ALERT"* ]] || [[ "$line" == *"FATAL"* ]]; then
            echo -e "  ${RED}${line}${RESET}"
        elif [[ "$line" == *"REINSTALL"* ]] || [[ "$line" == *"SELF-HEAL"* ]]; then
            echo -e "  ${YELLOW}${line}${RESET}"
        elif [[ "$line" == *"UPDATE"* ]]; then
            echo -e "  ${CYAN}${line}${RESET}"
        elif [[ "$line" == *"NEW-PATTERN"* ]]; then
            echo -e "  ${MAGENTA}${line}${RESET}"
        else
            echo "  ${line}"
        fi
    done
    echo ""
fi

echo -e "${DIM}Logs: ${LOG_BASE}/sessions/${RESET}"
echo -e "${DIM}Run with --remote-feasibility for remote GPU analysis${RESET}"
echo ""
