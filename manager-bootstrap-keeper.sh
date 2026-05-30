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
else
    echo "applying manager startup patch to ${CONTAINER_NAME} (${container_id})"
    docker cp "${HOST_SCRIPT}" "${CONTAINER_NAME}:${CONTAINER_SCRIPT}"
    docker exec "${CONTAINER_NAME}" chmod 755 "${CONTAINER_SCRIPT}"
    echo "${container_id}" > "${STATE_FILE}"

    # Re-apply resource limits after container recreation (docker update is
    # not persistent across docker rm + docker run — new containers start uncapped).
    docker update --memory 768m --memory-swap 768m --cpus 1 "${CONTAINER_NAME}" >/dev/null \
        && echo "resource limits re-applied (768m RAM, 1 CPU)" \
        || echo "warning: docker update failed; container may be uncapped"

    if [ "${container_hash}" != "${host_hash}" ]; then
        echo "startup script patched in-place; will take effect on next natural restart (no restart triggered)"
    else
        echo "container was recreated; patched script restored without additional changes"
    fi
fi

# Detect openclaw in-container package updates and restart the container so
# new hash-stamped module files are loaded fresh (in-process restarts don't
# reload them — see Idiosyncratic Decision #5 in AGENTS.md).
STARTUP_HASH_FILE="/worksp/hiclaw/workspace/.openclaw-startup-pkg-hash"
# Find the active openclaw package.json — npm global install takes priority over image built-in.
OPENCLAW_PKG="$(docker exec "${CONTAINER_NAME}" bash -c '
    for p in /usr/lib/node_modules/openclaw/package.json /opt/openclaw/package.json; do
        [ -f "$p" ] && echo "$p" && break
    done' 2>/dev/null || true)"
if [ -f "${STARTUP_HASH_FILE}" ]; then
    startup_pkg_hash="$(cat "${STARTUP_HASH_FILE}" 2>/dev/null || true)"
    current_pkg_hash="$(
        [ -n "${OPENCLAW_PKG}" ] && docker exec "${CONTAINER_NAME}" sha256sum "${OPENCLAW_PKG}" 2>/dev/null \
            | cut -d' ' -f1 || true
    )"
    if [ -n "${startup_pkg_hash}" ] && [ -n "${current_pkg_hash}" ] \
       && [ "${startup_pkg_hash}" != "${current_pkg_hash}" ]; then
        echo "openclaw package changed since startup (${startup_pkg_hash:0:8} -> ${current_pkg_hash:0:8}); restarting to apply update"
        docker restart "${CONTAINER_NAME}" >/dev/null
    fi
fi
