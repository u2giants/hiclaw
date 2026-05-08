# Development

## What "development" means here

This repo is mostly shell scripts and deployment state. There is no local app build, test suite, or lint pipeline for a standalone product in this directory. The normal workflow is:

1. edit a host script or host-managed config
2. syntax-check it
3. apply it to the running containers if needed
4. verify behavior with container logs and OpenClaw commands

## Prerequisites

- shell access on the host that owns `/worksp/hiclaw`
- Docker CLI access
- permission to edit the host crontab
- a running `hiclaw-manager` container for most validations

## Important Working Files

- [start-manager-agent.sh](/worksp/hiclaw/start-manager-agent.sh)
  - Host-owned source of truth for the manager startup patch.
- [manager-bootstrap-keeper.sh](/worksp/hiclaw/manager-bootstrap-keeper.sh)
  - Applies the startup patch to new containers.
- [manager-config-keeper.sh](/worksp/hiclaw/manager-config-keeper.sh)
  - Repairs `workspace/openclaw.json`.
- [start-element-web.sh](/worksp/hiclaw/start-element-web.sh)
  - Host-owned source of truth for the controller chat UI startup patch.
- [controller-bootstrap-keeper.sh](/worksp/hiclaw/controller-bootstrap-keeper.sh)
  - Applies the controller startup patch to new `hiclaw-controller` containers.
- [workspace/openclaw.json](/worksp/hiclaw/workspace/openclaw.json)
  - Live shared manager/controller config.
- [workspace/skills/matrix-server-management/scripts/create-admin-chat-room.sh](/worksp/hiclaw/workspace/skills/matrix-server-management/scripts/create-admin-chat-room.sh)
  - Persistent helper for creating new HiClaw-only conversation rooms.

## Safe Edit Workflow

### Startup path changes

Use this when changing ClawTalk bootstrap or anything else in the manager startup script.

```bash
bash -n /worksp/hiclaw/start-manager-agent.sh
bash /worksp/hiclaw/manager-bootstrap-keeper.sh
docker logs hiclaw-manager --since 5m | grep -E 'Bootstrapping ClawTalk|ClawTalk|http server listening'
docker exec hiclaw-manager openclaw clawtalk doctor
```

### Config keeper changes

```bash
bash -n /worksp/hiclaw/manager-config-keeper.sh
bash /worksp/hiclaw/manager-config-keeper.sh
python3 -m json.tool /worksp/hiclaw/workspace/openclaw.json >/dev/null
```

### HiClaw separate-chat helper changes

```bash
bash -n /worksp/hiclaw/workspace/skills/matrix-server-management/scripts/create-admin-chat-room.sh
/worksp/hiclaw/workspace/skills/matrix-server-management/scripts/create-admin-chat-room.sh --help
```

### MCP repair changes

```bash
bash -n /worksp/hiclaw/mcp-keeper.sh
bash /worksp/hiclaw/mcp-keeper.sh
docker exec hiclaw-manager openclaw mcp list
```

### Controller chat UI startup changes

```bash
bash -n /worksp/hiclaw/start-element-web.sh
bash /worksp/hiclaw/controller-bootstrap-keeper.sh
docker logs hiclaw-controller --since 5m | tail -n 100
docker exec hiclaw-controller ps -ef | grep nginx | grep -v grep
docker exec hiclaw-controller curl -s http://127.0.0.1:8088/hiclaw-api/healthz
```

## Debugging

### ClawTalk not connected

Use these in order:

```bash
docker exec hiclaw-manager openclaw clawtalk doctor
docker logs hiclaw-manager --since 10m | grep -E 'clawtalk|ClawTalk'
docker exec hiclaw-manager openclaw clawtalk logs --since 100
```

What to look for:

- `loading clawtalk from /usr/lib/node_modules/openclaw/dist/extensions/clawtalk/index.js`
- `ClawTalk authenticated`
- `ClawTalk service started`

If the doctor loads the plugin but `bot_connected` is false, check the live gateway logs before assuming config is wrong. During startup there is a short period where the doctor can run before the gateway-side WebSocket has fully authenticated.

### Manager restart loop

```bash
docker logs hiclaw-manager --since 15m | grep -E 'commands.restart|SIGUSR1|restarting'
python3 - <<'PY'
import json
print(json.load(open('/worksp/hiclaw/workspace/openclaw.json'))['commands']['restart'])
PY
```

If `commands.restart` is not `true`, the config keeper or startup patch has drifted.

### Browser MCP disappeared

```bash
bash /worksp/hiclaw/mcp-keeper.sh
docker exec hiclaw-manager openclaw mcp list
```

### HiClaw chat UI looks disconnected or stale

Check the controller-side Element Web loop first:

```bash
docker logs hiclaw-controller --since 10m | tail -n 200
docker exec hiclaw-controller sh -lc 'ss -ltnp | grep -E ":(8088|18888|8002)\\b" || true'
```

If you see repeated `element-web exited` lines or `bind()` failures for `8088`, `18888`, or `8002`, the controller has stale nginx ownership and the UI layer is broken even if `hiclaw-manager` is still processing chat.

If the `New Chat` button is visible but does nothing, check the controller-local helper:

```bash
docker exec hiclaw-controller curl -s http://127.0.0.1:8088/hiclaw-api/healthz
docker exec hiclaw-controller ps -ef | grep hiclaw-chat-api | grep -v grep
docker exec hiclaw-controller tail -n 100 /var/log/hiclaw-chat-api.log
```

### Is the startup patch current?

```bash
bash /worksp/hiclaw/manager-bootstrap-keeper.sh
```

Expected steady-state output:

```text
startup patch already current for <container-id>
```

Possible transient output during container startup:

```text
container startup script not readable yet; skipping this run
```

That is not a failure by itself. It means the container is still early in boot and the keeper should be retried after the process settles.

## There Is No Separate Build/Test System Here

- Build: none in this repo
- Unit tests: none in this repo
- Lint: no configured lint runner
- Best available validation:
  - `bash -n` for shell scripts
  - `python3 -m json.tool` for JSON touched by scripts
  - manual keeper execution
  - `docker logs`
  - `openclaw ... doctor` or other runtime inspection commands

## Extending the System

Prefer these patterns:

- host-owned script plus cron if the problem is caused by container recreation or an image reset
- direct edits to `workspace/openclaw.json` only when the setting is truly persistent and not rewritten by another actor
- startup-script patching only for behavior that must exist before the gateway starts
- persistent `workspace/skills/...` helpers when the behavior belongs to the manager's ongoing operating model rather than container boot

Avoid these patterns:

- one-off `docker exec` fixes without a host-side keeper if the fix needs to survive recreation
- editing mirrored files under `workspace/hiclaw/hiclaw-storage/...`
- adding duplicate repair logic to multiple scripts when one existing keeper already owns that concern
