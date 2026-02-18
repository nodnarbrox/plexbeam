#!/usr/bin/env bash
# Stop and delete all PlexBeam workers on SaladCloud
#
# Usage: bash deploy/salad-teardown.sh [--force]
#
# Env vars:
#   SALAD_API_KEY     - SaladCloud API key (required)
#   SALAD_ORG         - Organization slug (default: jessicacodes)
#   SALAD_PROJECT     - Project name (default: default)

set -euo pipefail

FORCE=false
for arg in "$@"; do
    [ "$arg" = "--force" ] && FORCE=true
done

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

echo "=== PlexBeam SaladCloud Teardown ==="
echo "Org: $SALAD_ORG | Project: $SALAD_PROJECT"
echo ""

# List all container groups
RESP=$(api GET "/organizations/$SALAD_ORG/projects/$SALAD_PROJECT/containers")

# Extract plexbeam groups
GROUPS=$(echo "$RESP" | grep -o '"name"[[:space:]]*:[[:space:]]*"plexbeam-worker-[^"]*"' | sed 's/.*"name"[[:space:]]*:[[:space:]]*"//' | sed 's/"//')

if [ -z "$GROUPS" ]; then
    echo "No PlexBeam worker groups found. Nothing to tear down."
    exit 0
fi

GROUP_COUNT=$(echo "$GROUPS" | wc -l)
echo "Found $GROUP_COUNT PlexBeam worker group(s):"
echo "$GROUPS" | sed 's/^/  /'
echo ""

if [ "$FORCE" = false ]; then
    read -r -p "Delete all $GROUP_COUNT groups? [y/N] " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
fi

# Stop and delete each group
while IFS= read -r GROUP_NAME; do
    echo "Stopping $GROUP_NAME..."
    api POST "/organizations/$SALAD_ORG/projects/$SALAD_PROJECT/containers/$GROUP_NAME/stop" > /dev/null 2>&1 || true

    echo "Deleting $GROUP_NAME..."
    api DELETE "/organizations/$SALAD_ORG/projects/$SALAD_PROJECT/containers/$GROUP_NAME" > /dev/null 2>&1

    if [ $? -eq 0 ]; then
        echo "  Deleted $GROUP_NAME"
    else
        echo "  WARNING: Failed to delete $GROUP_NAME"
    fi
done <<< "$GROUPS"

echo ""
echo "Teardown complete. All PlexBeam workers removed from SaladCloud."
echo ""
echo "Remember to remove SaladCloud URLs from your WORKER_POOL config."
