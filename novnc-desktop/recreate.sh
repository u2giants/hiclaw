#!/bin/bash
# Recreates the novnc-desktop container with the correct flags.
#
# Run this whenever the container needs to be rebuilt from scratch.
# DO NOT omit --dns — the host resolver uses Tailscale DNS (100.100.100.100)
# which is unreachable from inside Docker, breaking browser internet access.
# --ip 10.0.5.4 must stay fixed: it is hardcoded as the CDP endpoint for
# browser MCP in workspace/openclaw.json and docs/configuration.md.
set -euo pipefail

NETWORK="e10kwzww46ljhrgz1qj08j6a"
IMAGE="ghcr.io/u2giants/novnc-desktop:latest"

docker stop novnc-desktop 2>/dev/null || true
docker rm novnc-desktop 2>/dev/null || true

docker run -d \
  --name novnc-desktop \
  --restart unless-stopped \
  --network "${NETWORK}" \
  --ip 10.0.5.4 \
  --dns 1.1.1.1 \
  --dns 8.8.8.8 \
  --memory 3g \
  --memory-swap 4g \
  --cpus 2 \
  --pids-limit 250 \
  --shm-size 2g \
  -v "novnc-${NETWORK}-config:/config" \
  -e PUID=1000 \
  -e PGID=1000 \
  -e TZ=UTC \
  -e "TITLE=HiClaw Desktop" \
  "${IMAGE}"

docker network connect coolify novnc-desktop

echo "novnc-desktop recreated. Verifying internet..."
sleep 8
docker exec novnc-desktop curl -s --max-time 8 https://ifconfig.me && echo ""
echo "Done."
