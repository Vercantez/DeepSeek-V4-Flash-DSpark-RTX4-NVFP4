#!/usr/bin/env bash
set -euo pipefail

# Isolated benchmark bootstrap. This must not be used by a serving ASG.
systemctl stop deepseek-rtx4.service 2>/dev/null || true

mkdir -p /opt/deepseek-cache
for _ in $(seq 1 120); do
  if dev="$(blkid -L deepseek-cache 2>/dev/null)" && [ -n "$dev" ]; then
    break
  fi
  sleep 2
done

dev="$(blkid -L deepseek-cache 2>/dev/null || true)"
if [ -z "$dev" ]; then
  echo "deepseek-cache volume label not found" >&2
  exit 1
fi

if ! grep -q 'LABEL=deepseek-cache /opt/deepseek-cache' /etc/fstab; then
  echo 'LABEL=deepseek-cache /opt/deepseek-cache ext4 defaults,nofail,x-systemd.device-timeout=300 0 2' >>/etc/fstab
fi
mountpoint -q /opt/deepseek-cache || mount /opt/deepseek-cache
chown ubuntu:ubuntu /opt/deepseek-cache

repo=/opt/deepseek/mia-dspark-rtx4
env_file="$repo/.env.rtx4"
test -f "$env_file"
sed -i '/^KV_OFFLOAD_GB=/d; /^KV_OFFLOAD_DISK_DIR=/d' "$env_file"
printf '%s\n' \
  'KV_OFFLOAD_GB=256' \
  'KV_OFFLOAD_DISK_DIR=/opt/dlami/nvme/kv-offload' >>"$env_file"
install -d -o ubuntu -g ubuntu /opt/dlami/nvme/kv-offload

systemctl daemon-reload
systemctl start deepseek-rtx4.service
