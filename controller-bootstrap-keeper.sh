#!/bin/bash
set -euo pipefail

CONTAINER_NAME="hiclaw-controller"
HOST_ELEMENT_SCRIPT="/worksp/hiclaw/start-element-web.sh"
CONTAINER_ELEMENT_SCRIPT="/opt/hiclaw/scripts/init/start-element-web.sh"
HOST_TUWUNEL_SCRIPT="/worksp/hiclaw/start-tuwunel.sh"
CONTAINER_TUWUNEL_SCRIPT="/opt/hiclaw/scripts/init/start-tuwunel.sh"
STATE_DIR="/worksp/hiclaw/.state"
STATE_FILE="${STATE_DIR}/controller-bootstrap-keeper.last-container"

mkdir -p "${STATE_DIR}"

if [ ! -f "${HOST_ELEMENT_SCRIPT}" ]; then
    echo "host controller startup script not found: ${HOST_ELEMENT_SCRIPT}" >&2
    exit 1
fi

if [ ! -f "${HOST_TUWUNEL_SCRIPT}" ]; then
    echo "host controller startup script not found: ${HOST_TUWUNEL_SCRIPT}" >&2
    exit 1
fi

container_id="$(docker ps --filter "name=^/${CONTAINER_NAME}$" --format '{{.ID}}' | head -n1)"
if [ -z "${container_id}" ]; then
    echo "container not running: ${CONTAINER_NAME}"
    exit 0
fi

host_element_hash="$(sha256sum "${HOST_ELEMENT_SCRIPT}" | awk '{print $1}')"
host_tuwunel_hash="$(sha256sum "${HOST_TUWUNEL_SCRIPT}" | awk '{print $1}')"
container_element_hash=""
container_tuwunel_hash=""
for _ in 1 2 3 4 5; do
    container_element_hash="$(
        docker exec "${CONTAINER_NAME}" sh -lc "sha256sum '${CONTAINER_ELEMENT_SCRIPT}' 2>/dev/null | cut -d' ' -f1" 2>/dev/null || true
    )"
    container_tuwunel_hash="$(
        docker exec "${CONTAINER_NAME}" sh -lc "sha256sum '${CONTAINER_TUWUNEL_SCRIPT}' 2>/dev/null | cut -d' ' -f1" 2>/dev/null || true
    )"
    if [ -n "${container_element_hash}" ] && [ -n "${container_tuwunel_hash}" ]; then
        break
    fi
    sleep 2
done

if [ -z "${container_element_hash}" ] || [ -z "${container_tuwunel_hash}" ]; then
    echo "controller startup script not readable yet; skipping this run"
    exit 0
fi

last_container_id=""
if [ -f "${STATE_FILE}" ]; then
    last_container_id="$(cat "${STATE_FILE}" 2>/dev/null || true)"
fi

if [ "${container_element_hash}" = "${host_element_hash}" ] && \
   [ "${container_tuwunel_hash}" = "${host_tuwunel_hash}" ] && \
   [ "${last_container_id}" = "${container_id}" ]; then
    echo "controller startup patch already current for ${container_id}"
    exit 0
fi

echo "applying controller startup patch to ${CONTAINER_NAME} (${container_id})"
docker cp "${HOST_ELEMENT_SCRIPT}" "${CONTAINER_NAME}:${CONTAINER_ELEMENT_SCRIPT}"
docker cp "${HOST_TUWUNEL_SCRIPT}" "${CONTAINER_NAME}:${CONTAINER_TUWUNEL_SCRIPT}"
docker exec "${CONTAINER_NAME}" chmod 755 "${CONTAINER_ELEMENT_SCRIPT}" "${CONTAINER_TUWUNEL_SCRIPT}"
echo "${container_id}" > "${STATE_FILE}"

if [ "${container_element_hash}" != "${host_element_hash}" ] || [ "${container_tuwunel_hash}" != "${host_tuwunel_hash}" ]; then
    echo "restarting ${CONTAINER_NAME} to activate patched controller startup"
    docker restart "${CONTAINER_NAME}" >/dev/null
else
    echo "controller container was recreated; patched scripts restored without additional changes"
fi
