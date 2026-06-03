#!/bin/bash
set -euo pipefail

CONTAINER_NAME="novnc-desktop"
STATE_DIR="/worksp/hiclaw/.state"
STATE_FILE="${STATE_DIR}/novnc-resource-keeper.last-container"

MEMORY_LIMIT="3g"
MEMORY_SWAP_LIMIT="4g"
CPU_LIMIT="2"
PIDS_LIMIT="250"

MEMORY_RESTART_BYTES=$((2900 * 1024 * 1024))
PIDS_RESTART_THRESHOLD=225

mkdir -p "${STATE_DIR}"

container_id="$(docker ps -a --filter "name=^/${CONTAINER_NAME}$" --format '{{.ID}}' | head -n1)"
if [ -z "${container_id}" ]; then
    echo "container not found: ${CONTAINER_NAME}"
    exit 0
fi

last_container_id=""
if [ -f "${STATE_FILE}" ]; then
    last_container_id="$(cat "${STATE_FILE}" 2>/dev/null || true)"
fi

inspect_limits="$(
    docker inspect "${CONTAINER_NAME}" \
        --format '{{.HostConfig.Memory}} {{.HostConfig.MemorySwap}} {{.HostConfig.NanoCpus}} {{.HostConfig.PidsLimit}}' 2>/dev/null \
        || true
)"

expected_limits="3221225472 4294967296 2000000000 250"
if [ "${container_id}" != "${last_container_id}" ] || [ "${inspect_limits}" != "${expected_limits}" ]; then
    docker update \
        --memory "${MEMORY_LIMIT}" \
        --memory-swap "${MEMORY_SWAP_LIMIT}" \
        --cpus "${CPU_LIMIT}" \
        --pids-limit "${PIDS_LIMIT}" \
        "${CONTAINER_NAME}" >/dev/null \
        && echo "resource limits enforced (${MEMORY_LIMIT} RAM, ${MEMORY_SWAP_LIMIT} total swap, ${CPU_LIMIT} CPUs, ${PIDS_LIMIT} PIDs)" \
        || echo "warning: docker update failed for ${CONTAINER_NAME}"
    echo "${container_id}" > "${STATE_FILE}"
fi

running="$(docker inspect "${CONTAINER_NAME}" --format '{{.State.Running}}' 2>/dev/null || echo false)"
if [ "${running}" != "true" ]; then
    echo "container is stopped; limits are set and no restart was requested"
    exit 0
fi

cgroup_path="$(docker inspect "${CONTAINER_NAME}" --format '{{.State.CgroupPath}}' 2>/dev/null || true)"
cgroup_root="/sys/fs/cgroup${cgroup_path}"
memory_current=""
pids_current=""

if [ -n "${cgroup_path}" ] && [ -r "${cgroup_root}/memory.current" ]; then
    memory_current="$(cat "${cgroup_root}/memory.current" 2>/dev/null || true)"
fi

if [ -n "${cgroup_path}" ] && [ -r "${cgroup_root}/pids.current" ]; then
    pids_current="$(cat "${cgroup_root}/pids.current" 2>/dev/null || true)"
fi

if [ -z "${pids_current}" ]; then
    pids_current="$(docker stats --no-stream --format '{{.PIDs}}' "${CONTAINER_NAME}" 2>/dev/null || true)"
fi

if [ -n "${memory_current}" ] && [ "${memory_current}" -gt "${MEMORY_RESTART_BYTES}" ]; then
    echo "memory ${memory_current} exceeds restart threshold ${MEMORY_RESTART_BYTES}; restarting ${CONTAINER_NAME}"
    docker restart "${CONTAINER_NAME}" >/dev/null
    exit 0
fi

if [ -n "${pids_current}" ] && [ "${pids_current}" -gt "${PIDS_RESTART_THRESHOLD}" ]; then
    echo "PID count ${pids_current} exceeds restart threshold ${PIDS_RESTART_THRESHOLD}; restarting ${CONTAINER_NAME}"
    docker restart "${CONTAINER_NAME}" >/dev/null
    exit 0
fi

echo "resource usage OK (memory=${memory_current:-unknown} bytes, pids=${pids_current:-unknown})"
