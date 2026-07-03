#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env.rtx4}"

if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

: "${CONTAINER_NAME:=deepseek-v4-flash-dspark-rtx4}"
: "${PORT:=8000}"

docker ps -a --filter "name=$CONTAINER_NAME"
curl -fsS --max-time 5 "http://127.0.0.1:$PORT/v1/models" || true
echo
