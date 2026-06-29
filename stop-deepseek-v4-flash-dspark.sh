#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env.dspark}"
COMPOSE_FILE="${COMPOSE_FILE:-$SCRIPT_DIR/docker-compose.dspark.yml}"
PROJECT_NAME="${PROJECT_NAME:-deepseek-v4-flash}"
LEGACY_PROJECT_NAME="${LEGACY_PROJECT_NAME:-$(basename "$SCRIPT_DIR" | tr '[:upper:]' '[:lower:]')}"

if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

: "${WORKER_HOST:?WORKER_HOST must be set in $ENV_FILE or environment}"

cd "$SCRIPT_DIR"

stop_dspark_local() {
  local project
  if [ -f "$COMPOSE_FILE" ]; then
    for project in "$PROJECT_NAME" "$LEGACY_PROJECT_NAME"; do
      COMPOSE_DISABLE_ENV_FILE=1 docker compose -p "$project" --env-file "$ENV_FILE" -f "$COMPOSE_FILE" down --remove-orphans || true
    done
  fi
  for project in "$PROJECT_NAME" "$LEGACY_PROJECT_NAME"; do
    docker ps -aq \
      --filter "label=com.docker.compose.project=$project" \
      --filter "label=com.docker.compose.service=vllm-dspark" | xargs -r docker rm -f
  done
  docker ps -aq \
    --filter "label=com.docker.compose.service=vllm-dspark" \
    --filter "name=deepseek-v4-flash" | xargs -r docker rm -f
}

echo "Stopping DSpark head..."
stop_dspark_local

echo "Stopping DSpark worker on ${WORKER_HOST}..."
ssh "$WORKER_HOST" "cd '$SCRIPT_DIR' && PROJECT_NAME='$PROJECT_NAME' LEGACY_PROJECT_NAME='$LEGACY_PROJECT_NAME' bash -s" <<'REMOTE_STOP' || true
set -euo pipefail
if [ -f docker-compose.dspark.yml ]; then
  for project in "$PROJECT_NAME" "$LEGACY_PROJECT_NAME"; do
    env -u MASTER_ADDR -u MASTER_PORT -u NODE_RANK -u HEADLESS COMPOSE_DISABLE_ENV_FILE=1 \
      docker compose -p "$project" --env-file .env.dspark -f docker-compose.dspark.yml down --remove-orphans || true
  done
fi
for project in "$PROJECT_NAME" "$LEGACY_PROJECT_NAME"; do
  docker ps -aq \
    --filter "label=com.docker.compose.project=$project" \
    --filter "label=com.docker.compose.service=vllm-dspark" | xargs -r docker rm -f
done
docker ps -aq \
  --filter "label=com.docker.compose.service=vllm-dspark" \
  --filter "name=deepseek-v4-flash" | xargs -r docker rm -f
REMOTE_STOP

echo "DeepSeek V4 Flash DSpark stopped."
