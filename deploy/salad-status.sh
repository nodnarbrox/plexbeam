#!/usr/bin/env bash
# Check status of PlexBeam workers on SaladCloud
#
# Usage: bash deploy/salad-status.sh
#
# Env vars:
#   SALAD_API_KEY     - SaladCloud API key (required)
#   SALAD_ORG         - Organization slug (default: jessicacodes)
#   SALAD_PROJECT     - Project name (default: default)

set -euo pipefail

SALAD_ORG="${SALAD_ORG:-jessicacodes}"
SALAD_PROJECT="${SALAD_PROJECT:-default}"
SALAD_API_BASE="https://api.salad.com/api/public"

if [ -z "${SALAD_API_KEY:-}" ]; then
    echo "ERROR: SALAD_API_KEY env var is required"
    exit 1
fi

api() {
    local method="$1" path="$2"
    shift 2
    curl -s -X "$method" \
        -H "Salad-Api-Key: $SALAD_API_KEY" \
        -H "Content-Type: application/json" \
        "$SALAD_API_BASE$path" \
        "$@"
}

echo "=== PlexBeam SaladCloud Status ==="
echo "Org: $SALAD_ORG | Project: $SALAD_PROJECT"
echo ""

# List all container groups
RESP=$(api GET "/organizations/$SALAD_ORG/projects/$SALAD_PROJECT/containers")

# Extract plexbeam groups
GROUPS=$(echo "$RESP" | grep -o '"name"[[:space:]]*:[[:space:]]*"plexbeam-worker-[^"]*"' | sed 's/.*"name"[[:space:]]*:[[:space:]]*"//' | sed 's/"//')

if [ -z "$GROUPS" ]; then
    echo "No PlexBeam worker groups found."
    exit 0
fi

GATEWAY_URLS=()

printf "%-25s %-12s %-10s %s\n" "GROUP" "STATUS" "REPLICAS" "GATEWAY URL"
printf "%-25s %-12s %-10s %s\n" "-----" "------" "--------" "-----------"

while IFS= read -r GROUP_NAME; do
    STATUS_RESP=$(api GET "/organizations/$SALAD_ORG/projects/$SALAD_PROJECT/containers/$GROUP_NAME")

    STATUS=$(echo "$STATUS_RESP" | grep -o '"status"[[:space:]]*:[[:space:]]*"[^"]*"' | tail -1 | sed 's/.*"status"[[:space:]]*:[[:space:]]*"//' | sed 's/"//')
    REPLICAS=$(echo "$STATUS_RESP" | grep -o '"replicas"[[:space:]]*:[[:space:]]*[0-9]*' | head -1 | sed 's/.*"replicas"[[:space:]]*:[[:space:]]*//')
    GATEWAY_URL=$(echo "$STATUS_RESP" | grep -o '"access_domain_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"access_domain_name"[[:space:]]*:[[:space:]]*"//' | sed 's/"//')

    DISPLAY_URL="${GATEWAY_URL:-(pending)}"
    if [ -n "$GATEWAY_URL" ]; then
        FULL_URL="https://$GATEWAY_URL"
        GATEWAY_URLS+=("$FULL_URL")
        DISPLAY_URL="$FULL_URL"
    fi

    printf "%-25s %-12s %-10s %s\n" "$GROUP_NAME" "${STATUS:-unknown}" "${REPLICAS:-?}" "$DISPLAY_URL"
done <<< "$GROUPS"

echo ""

# Health check running workers
if [ ${#GATEWAY_URLS[@]} -gt 0 ]; then
    echo "=== Health Checks ==="
    for URL in "${GATEWAY_URLS[@]}"; do
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$URL/health" 2>/dev/null || echo "000")
        if [ "$HTTP_CODE" = "200" ]; then
            echo "  $URL/health -> OK (200)"
        else
            echo "  $URL/health -> FAIL ($HTTP_CODE)"
        fi
    done
    echo ""

    echo "=== WORKER_POOL URLs ==="
    POOL=$(IFS=,; echo "${GATEWAY_URLS[*]}")
    echo "  $POOL"
fi
