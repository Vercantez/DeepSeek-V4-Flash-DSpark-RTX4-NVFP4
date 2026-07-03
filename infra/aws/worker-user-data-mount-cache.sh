#!/usr/bin/env bash
set -euo pipefail

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
  lsblk >&2 || true
  exit 1
fi

if ! grep -q 'LABEL=deepseek-cache /opt/deepseek-cache' /etc/fstab; then
  echo 'LABEL=deepseek-cache /opt/deepseek-cache ext4 defaults,nofail,x-systemd.device-timeout=300 0 2' >>/etc/fstab
fi

mountpoint -q /opt/deepseek-cache || mount /opt/deepseek-cache
chown -R ubuntu:ubuntu /opt/deepseek-cache

systemctl daemon-reload
systemctl start deepseek-rtx4.service
