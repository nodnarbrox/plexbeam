#!/usr/bin/env bash
# Deploy PlexBeam workers to SaladCloud
#
# Usage: bash deploy/salad-deploy.sh [NUM_WORKERS] [--skip-build] [--skip-push]
#
# Env vars:
#   SALAD_API_KEY     - SaladCloud API key (required)
#   SALAD_ORG         - Organization slug (default: jessicacodes)
#   SALAD_PROJECT     - Project name (default: default)
#   DOCKER_IMAGE      - Image name (default: nodnarb/plexbeam-worker:saladcloud)

set -euo pipefail

NUM_WORKERS="${1:-3}"
SKIP_BUILD=false
SKIP_PUSH=false

for arg in "$@"; do
    case "$arg" in
        --skip-build) SKIP_BUILD=true ;;
        --skip-push)  SKIP_PUSH=true ;;
    esac
done

# Config
SALAD_ORG="${SALAD_ORG:-jessicacodes}"
SALAD_PROJECT="${SALAD_PROJECT:-default}"
SALAD_API_BASE="https://api.salad.com/api/public"
DOCKER_IMAGE="${DOCKER_IMAGE:-nodnarbrox/plexbeam-worker:saladcloud}"

# GPU classes ordered by preference (best value first)
GPU_CLASSES='["cb6c1931-89b6-4f76-976f-54047320ccc6","f51baccc-dc95-40fb-a5d1-6d0ee0db31d2","951131f6-5acf-489c-b303-0906be8b26ef","3eae6ce4-aa14-4c7d-b502-131730c9af48","f474c159-1600-460c-9f84-b7f585750be9"]'

if [ -z "${SALAD_API_KEY:-}" ]; then
    echo "ERROR: SALAD_API_KEY env var is required"
    echo "  export SALAD_API_KEY=your-api-key"
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

echo "=== PlexBeam SaladCloud Deploy ==="
echo "Workers: $NUM_WORKERS | Org: $SALAD_ORG | Project: $SALAD_PROJECT"
echo ""

# Step 1: Build Docker image
if [ "$SKIP_BUILD" = false ]; then
    echo "[1/4] Building Docker image..."
    REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
    docker build -f "$REPO_ROOT/worker/Dockerfile.saladcloud" \
        -t "$DOCKER_IMAGE" "$REPO_ROOT/worker"
    echo "  Built: $DOCKER_IMAGE"
else
    echo "[1/4] Skipping build (--skip-build)"
fi

# Step 2: Push to Docker Hub
if [ "$SKIP_PUSH" = false ]; then
    echo "[2/4] Pushing to Docker Hub..."
    docker push "$DOCKER_IMAGE"
    echo "  Pushed: $DOCKER_IMAGE"
else
    echo "[2/4] Skipping push (--skip-push)"
fi

# Step 3: Create container groups
echo "[3/4] Creating $NUM_WORKERS container groups..."
CREATED_GROUPS=()

for i in $(seq 0 $((NUM_WORKERS - 1))); do
    GROUP_NAME="plexbeam-worker-$i"
    echo "  Creating $GROUP_NAME..."

    PAYLOAD=$(cat <<EOF
{
  "name": "$GROUP_NAME",
  "display_name": "PlexBeam Worker $i",
  "container": {
    "image": "docker.io/$DOCKER_IMAGE",
    "resources": {
      "cpu": 4,
      "memory": 8192,
      "gpu_classes": $GPU_CLASSES
    },
    "environment_variables": {
      "PLEX_WORKER_HW_ACCEL": "nvenc",
      "PLEX_WORKER_HOST": "::",
      "PLEX_WORKER_PORT": "8765"
    },
    "registry_authentication": {
      "docker_hub": {
        "username": "${DOCKER_USER:-nodnarbrox}",
        "personal_access_token": "${DOCKER_PAT}"
      }
    }
  },
  "autostart_policy": true,
  "restart_policy": "always",
  "replicas": 1,
  "networking": {
    "protocol": "http",
    "port": 8765,
    "auth": false,
    "server_response_timeout": 100000,
    "client_request_timeout": 100000
  },
  "liveness_probe": {
    "http": { "path": "/health", "port": 8765, "scheme": "http", "headers": [] },
    "initial_delay_seconds": 30,
    "period_seconds": 10,
    "timeout_seconds": 5,
    "success_threshold": 1,
    "failure_threshold": 3
  },
  "readiness_probe": {
    "http": { "path": "/health", "port": 8765, "scheme": "http", "headers": [] },
    "initial_delay_seconds": 15,
    "period_seconds": 5,
    "timeout_seconds": 3,
    "success_threshold": 1,
    "failure_threshold": 3
  }
}
EOF
)

    RESP=$(api POST "/organizations/$SALAD_ORG/projects/$SALAD_PROJECT/containers" -d "$PAYLOAD")

    # Check for errors
    if echo "$RESP" | grep -q '"error"'; then
        echo "    ERROR: $RESP"
        # If already exists, try to start it instead
        if echo "$RESP" | grep -q 'already exists'; then
            echo "    Group already exists, will start it..."
        else
            continue
        fi
    else
        echo "    Created successfully"
    fi

    CREATED_GROUPS+=("$GROUP_NAME")
done

# Step 4: Start container groups and wait for gateway URLs
echo "[4/4] Starting container groups and waiting for gateway URLs..."

for GROUP_NAME in "${CREATED_GROUPS[@]}"; do
    echo "  Starting $GROUP_NAME..."
    api POST "/organizations/$SALAD_ORG/projects/$SALAD_PROJECT/containers/$GROUP_NAME/start" > /dev/null 2>&1 || true
done

echo ""
echo "Waiting for workers to become ready (this may take 2-5 minutes)..."
echo ""

MAX_WAIT=300  # 5 minutes
POLL_INTERVAL=15
ELAPSED=0
READY_COUNT=0

while [ $ELAPSED -lt $MAX_WAIT ] && [ $READY_COUNT -lt ${#CREATED_GROUPS[@]} ]; do
    READY_COUNT=0
    for GROUP_NAME in "${CREATED_GROUPS[@]}"; do
        STATUS_RESP=$(api GET "/organizations/$SALAD_ORG/projects/$SALAD_PROJECT/containers/$GROUP_NAME")
        CURRENT_STATE=$(echo "$STATUS_RESP" | grep -o '"current_state"[[:space:]]*:[[:space:]]*{[^}]*}' | head -1)
        STATUS=$(echo "$CURRENT_STATE" | grep -o '"status"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"status"[[:space:]]*:[[:space:]]*"//' | sed 's/"//')

        if [ "$STATUS" = "running" ]; then
            READY_COUNT=$((READY_COUNT + 1))
        fi
    done
    echo "  [$ELAPSED/${MAX_WAIT}s] $READY_COUNT/${#CREATED_GROUPS[@]} workers running..."

    if [ $READY_COUNT -lt ${#CREATED_GROUPS[@]} ]; then
        sleep $POLL_INTERVAL
        ELAPSED=$((ELAPSED + POLL_INTERVAL))
    fi
done

echo ""
echo "=== Deployment Summary ==="

GATEWAY_URLS=()
for GROUP_NAME in "${CREATED_GROUPS[@]}"; do
    STATUS_RESP=$(api GET "/organizations/$SALAD_ORG/projects/$SALAD_PROJECT/containers/$GROUP_NAME")

    # Extract gateway URL from networking section
    GATEWAY_URL=$(echo "$STATUS_RESP" | grep -o '"access_domain_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"access_domain_name"[[:space:]]*:[[:space:]]*"//' | sed 's/"//')
    STATUS=$(echo "$STATUS_RESP" | grep -o '"status"[[:space:]]*:[[:space:]]*"[^"]*"' | tail -1 | sed 's/.*"status"[[:space:]]*:[[:space:]]*"//' | sed 's/"//')

    if [ -n "$GATEWAY_URL" ]; then
        FULL_URL="https://$GATEWAY_URL"
        GATEWAY_URLS+=("$FULL_URL")
        echo "  $GROUP_NAME: $STATUS -> $FULL_URL"
    else
        echo "  $GROUP_NAME: $STATUS (no gateway URL yet)"
    fi
done

echo ""
if [ ${#GATEWAY_URLS[@]} -gt 0 ]; then
    echo "=== WORKER_POOL URLs (add to existing pool) ==="
    POOL_ADDITION=$(IFS=,; echo "${GATEWAY_URLS[*]}")
    echo "  $POOL_ADDITION"
    echo ""
    echo "Example full WORKER_POOL with existing local workers:"
    echo "  http://192.168.5.185:8766,http://192.168.4.127:8765,http://192.168.5.122:8766,$POOL_ADDITION"
fi

echo ""
echo "TIP: Set PLEXBEAM_CHUNK_DURATION=120 on the Plex host for faster cloud beam uploads"
echo "     (default 300s chunks are large; 120s chunks improve parallelism over internet)"
echo ""
echo "Use 'bash deploy/salad-status.sh' to check status"
echo "Use 'bash deploy/salad-teardown.sh' to clean up"
