#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env.dspark}"
COMPOSE_FILE="${COMPOSE_FILE:-$SCRIPT_DIR/docker-compose.dspark.yml}"
PROJECT_NAME="${PROJECT_NAME:-deepseek-v4-flash}"
API_URL="${API_URL:-http://127.0.0.1:8888/v1/models}"
CHAT_URL="${CHAT_URL:-http://127.0.0.1:8888/v1/chat/completions}"
WAIT_ATTEMPTS="${WAIT_ATTEMPTS:-100}"
WAIT_SECONDS="${WAIT_SECONDS:-15}"
PORT="${PORT:-8888}"

if [ ! -f "$ENV_FILE" ]; then
  echo "Missing $ENV_FILE. Copy .env.dspark.example to .env.dspark and edit node-specific values." >&2
  exit 1
fi

if [ ! -f "$COMPOSE_FILE" ]; then
  echo "Missing $COMPOSE_FILE." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

: "${WORKER_HOST:?WORKER_HOST must be set in $ENV_FILE}"
: "${MASTER_ADDR:?MASTER_ADDR must be set in $ENV_FILE}"
: "${MASTER_PORT:?MASTER_PORT must be set in $ENV_FILE}"
: "${NCCL_IB_HCA:?NCCL_IB_HCA must be set in $ENV_FILE}"
: "${NCCL_SOCKET_IFNAME:?NCCL_SOCKET_IFNAME must be set in $ENV_FILE}"
: "${DSPARK_VLLM_IMAGE:?DSPARK_VLLM_IMAGE must be set in $ENV_FILE}"

VLLM_HOST_IP="${VLLM_HOST_IP:-$MASTER_ADDR}"
WORKER_VLLM_HOST_IP="${WORKER_VLLM_HOST_IP:-$WORKER_HOST}"
WORKER_DIR="${WORKER_SCRIPT_DIR:-${WORKER_DIR:-$SCRIPT_DIR}}"
WORKER_HF_CACHE="${WORKER_HF_CACHE:-${HF_CACHE:-}}"
REMOTE_WORKER_DIR="$(printf '%q' "$WORKER_DIR")"
REMOTE_COMPOSE="cd $REMOTE_WORKER_DIR && env -u MASTER_ADDR -u MASTER_PORT -u NODE_RANK -u HEADLESS COMPOSE_DISABLE_ENV_FILE=1"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

compose_base() {
  env -u NODE_RANK -u HEADLESS COMPOSE_DISABLE_ENV_FILE=1 \
    WORKER_HOST="$WORKER_HOST" \
    MASTER_ADDR="$MASTER_ADDR" \
    MASTER_PORT="$MASTER_PORT" \
    NCCL_IB_HCA="$NCCL_IB_HCA" \
    NCCL_SOCKET_IFNAME="$NCCL_SOCKET_IFNAME" \
    NCCL_IB_GID_INDEX="${NCCL_IB_GID_INDEX:-}" \
    VLLM_HOST_IP="$VLLM_HOST_IP" \
    NODE_RANK="$1" \
    HEADLESS="$2" \
    docker compose -p "$PROJECT_NAME" --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "${@:3}"
}

log_since() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

print_startup_logs() {
  local since="$1"

  compose_base 0 "" logs --since "$since" vllm-dspark || true
  ssh "$WORKER_HOST" "$REMOTE_COMPOSE docker compose -p '$PROJECT_NAME' --env-file .env.dspark -f docker-compose.dspark.yml logs --since '$since' vllm-dspark" || true
}

wait_with_startup_logs() {
  local since
  since="$(log_since)"

  sleep "$WAIT_SECONDS"
  print_startup_logs "$since"
}

print_initial_startup_logs() {
  compose_base 0 "" logs --tail=100 vllm-dspark || true
  ssh "$WORKER_HOST" "$REMOTE_COMPOSE docker compose -p '$PROJECT_NAME' --env-file .env.dspark -f docker-compose.dspark.yml logs --tail=100 vllm-dspark" || true
}

need_cmd docker
need_cmd ssh
need_cmd scp
need_cmd curl

docker compose version >/dev/null
docker image inspect "$DSPARK_VLLM_IMAGE" >/dev/null || {
  echo "Missing local Docker image $DSPARK_VLLM_IMAGE. Run ./build-dspark-vllm-runtime.sh first." >&2
  exit 1
}

ssh -o BatchMode=yes -o ConnectTimeout=10 "$WORKER_HOST" "true" >/dev/null || {
  echo "Cannot reach worker with passwordless SSH: $WORKER_HOST" >&2
  exit 1
}

ssh "$WORKER_HOST" "docker image inspect '$DSPARK_VLLM_IMAGE' >/dev/null" || {
  echo "Missing worker Docker image $DSPARK_VLLM_IMAGE. Run ./build-dspark-vllm-runtime.sh first." >&2
  exit 1
}

if docker ps --format '{{.Names}}' | grep -qx "${PROJECT_NAME}-vllm-dspark-1"; then
  echo "DSpark head container already exists for project $PROJECT_NAME. Stop it first or use PROJECT_NAME=..." >&2
  exit 1
fi

if command -v ss >/dev/null 2>&1 && ss -ltn "( sport = :$PORT )" | tail -n +2 | grep -q .; then
  echo "Port $PORT is already listening on the head node. Stop the conflicting service first." >&2
  exit 1
fi

ssh "$WORKER_HOST" "if docker ps --format '{{.Names}}' | grep -qx '${PROJECT_NAME}-vllm-dspark-1'; then echo 'DSpark worker container already exists for project $PROJECT_NAME.' >&2; exit 1; fi"

cd "$SCRIPT_DIR"

echo "Syncing DSpark deployment files to ${WORKER_HOST}:${WORKER_DIR}"
ssh "$WORKER_HOST" "mkdir -p $REMOTE_WORKER_DIR"
scp "$COMPOSE_FILE" "${WORKER_HOST}:${WORKER_DIR}/docker-compose.dspark.yml"
scp "$ENV_FILE" "${WORKER_HOST}:${WORKER_DIR}/.env.dspark"

echo "Starting DSpark worker on ${WORKER_HOST}..."
ssh "$WORKER_HOST" "$REMOTE_COMPOSE NODE_RANK=1 HEADLESS=1 HF_CACHE='$WORKER_HF_CACHE' VLLM_HOST_IP='$WORKER_VLLM_HOST_IP' docker compose -p '$PROJECT_NAME' --env-file .env.dspark -f docker-compose.dspark.yml up -d"

echo "Starting DSpark head..."
compose_base 0 "" up -d

echo "Waiting for DSpark vLLM API..."
print_initial_startup_logs
for _ in $(seq 1 "$WAIT_ATTEMPTS"); do
  if curl -fsS --max-time 5 "$API_URL" >/dev/null 2>&1; then
    echo "DeepSeek V4 Flash DSpark is running: $API_URL"
    compose_base 0 "" ps
    ssh "$WORKER_HOST" "$REMOTE_COMPOSE docker compose -p '$PROJECT_NAME' --env-file .env.dspark -f docker-compose.dspark.yml ps"
    echo "Running minimal OpenAI-compatible chat request..."
    curl -fsS --max-time 60 "$CHAT_URL" \
      -H "Content-Type: application/json" \
      -d '{"model":"'"${SERVED_MODEL_NAME:-deepseek-v4-flash-dspark}"'","messages":[{"role":"user","content":"Reply with OK."}],"max_tokens":8,"temperature":0.0}' >/dev/null
    echo "Minimal chat request succeeded."
    exit 0
  fi
  wait_with_startup_logs
done

echo "Timed out waiting for DSpark API. Recent head logs:" >&2
compose_base 0 "" logs --tail=120 vllm-dspark >&2 || true
echo "Recent worker logs:" >&2
ssh "$WORKER_HOST" "$REMOTE_COMPOSE docker compose -p '$PROJECT_NAME' --env-file .env.dspark -f docker-compose.dspark.yml logs --tail=120 vllm-dspark" >&2 || true
exit 1
