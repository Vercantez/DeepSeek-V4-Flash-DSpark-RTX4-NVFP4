#!/usr/bin/env bash
set -euo pipefail

: "${AWS_REGION:=us-east-2}"
: "${AWS_ASG_NAME:=deepseek-rtx4-spot-asg}"
: "${ROUTER_PORT:=8080}"
: "${BACKEND_PORT:=8000}"
: "${ROUTER_API_KEY:?Set ROUTER_API_KEY before installing the router}"

install -d -m 0755 /opt/deepseek-router
install -m 0755 "$(dirname "$0")/../router/sticky_openai_router.py" /opt/deepseek-router/sticky_openai_router.py

cat >/etc/deepseek-router.env <<EOF
AWS_REGION=$AWS_REGION
AWS_ASG_NAME=$AWS_ASG_NAME
ROUTER_HOST=0.0.0.0
ROUTER_PORT=$ROUTER_PORT
BACKEND_PORT=$BACKEND_PORT
DISCOVERY_INTERVAL=15
HEALTH_TIMEOUT=3
REQUEST_TIMEOUT=900
ROUTER_API_KEY=$ROUTER_API_KEY
EOF
chmod 0600 /etc/deepseek-router.env

cat >/etc/systemd/system/deepseek-sticky-router.service <<'EOF'
[Unit]
Description=Sticky OpenAI-compatible router for DeepSeek RTX4 GPU backends
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/deepseek-router.env
ExecStart=/usr/bin/python3 /opt/deepseek-router/sticky_openai_router.py
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now deepseek-sticky-router.service
