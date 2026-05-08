#!/bin/bash
set -euo pipefail

CONTAINER_NAME="hiclaw-manager"
HOST_SCRIPT="/worksp/hiclaw/start-manager-agent.sh"
CONTAINER_SCRIPT="/opt/hiclaw/scripts/init/start-manager-agent.sh"
STATE_DIR="/worksp/hiclaw/.state"
STATE_FILE="${STATE_DIR}/manager-bootstrap-keeper.last-container"

mkdir -p "${STATE_DIR}"

if [ ! -f "${HOST_SCRIPT}" ]; then
    echo "host startup script not found: ${HOST_SCRIPT}" >&2
    exit 1
fi

container_id="$(docker ps --filter "name=^/${CONTAINER_NAME}$" --format '{{.ID}}' | head -n1)"
if [ -z "${container_id}" ]; then
    echo "container not running: ${CONTAINER_NAME}"
    exit 0
fi

host_hash="$(sha256sum "${HOST_SCRIPT}" | awk '{print $1}')"
container_hash=""
for _ in 1 2 3 4 5; do
    container_hash="$(
        docker exec "${CONTAINER_NAME}" sh -lc "sha256sum '${CONTAINER_SCRIPT}' 2>/dev/null | cut -d' ' -f1" 2>/dev/null || true
    )"
    if [ -n "${container_hash}" ]; then
        break
    fi
    sleep 2
done

if [ -z "${container_hash}" ]; then
    echo "container startup script not readable yet; skipping this run"
    exit 0
fi

last_container_id=""
if [ -f "${STATE_FILE}" ]; then
    last_container_id="$(cat "${STATE_FILE}" 2>/dev/null || true)"
fi

if [ "${container_hash}" = "${host_hash}" ] && [ "${last_container_id}" = "${container_id}" ]; then
    echo "startup patch already current for ${container_id}"
    exit 0
fi

echo "applying manager startup patch to ${CONTAINER_NAME} (${container_id})"
docker cp "${HOST_SCRIPT}" "${CONTAINER_NAME}:${CONTAINER_SCRIPT}"
docker exec "${CONTAINER_NAME}" chmod 755 "${CONTAINER_SCRIPT}"
echo "${container_id}" > "${STATE_FILE}"

if [ "${container_hash}" != "${host_hash}" ]; then
    echo "restarting ${CONTAINER_NAME} to activate patched startup script"
    docker restart "${CONTAINER_NAME}" >/dev/null
else
    echo "container was recreated; patched script restored without additional changes"
fi
