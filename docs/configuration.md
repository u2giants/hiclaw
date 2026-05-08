# Configuration

## Configuration Surfaces

### `workspace/openclaw.json`

Path:

- host: [workspace/openclaw.json](/worksp/hiclaw/workspace/openclaw.json)
- manager container: `/root/manager-workspace/openclaw.json`

Purpose:

- live OpenClaw gateway config for `hiclaw-manager`
- shared between the manager and controller

Important behavior:

- this file is not single-writer
- controller reconciliation, manager startup, and repair scripts all mutate it
- OpenClaw health/backup state under `workspace/.openclaw/` can revert changes if the health metadata no longer matches the file

### Host-managed startup patch

Path:

- [start-manager-agent.sh](/worksp/hiclaw/start-manager-agent.sh)

Purpose:

- authoritative patched copy of the manager startup script
- copied into `hiclaw-manager` by `manager-bootstrap-keeper.sh`

### Host-managed controller startup patch

Path:

- [start-element-web.sh](/worksp/hiclaw/start-element-web.sh)

Purpose:

- authoritative patched copy of the controller Element Web startup script
- copied into `hiclaw-controller` by `controller-bootstrap-keeper.sh`
- injects the `New Chat` and `Control Panel` browser affordances
- starts the controller-local new-chat helper API

### Keeper state

Path:

- `.state/manager-bootstrap-keeper.last-container`

Purpose:

- remembers which running container ID already received the patched startup script

## Current Managed OpenClaw Behavior

### `commands.restart`

Effective policy:

- always forced to `true`

Why:

- in this deployment, `false` causes a controller-triggered restart loop

Owners:

- startup patch in [start-manager-agent.sh](/worksp/hiclaw/start-manager-agent.sh:710)
- fallback repair in [manager-config-keeper.sh](/worksp/hiclaw/manager-config-keeper.sh:1)

### `session.dmScope`

Effective policy:

- always forced to `main`

Why:

- this makes HiClaw Matrix direct messages reuse the same OpenClaw session as the web chat
- without it, Matrix DMs land in per-channel sessions and the two UIs look disconnected even when the manager is healthy

Owners:

- startup patch in [start-manager-agent.sh](/worksp/hiclaw/start-manager-agent.sh:707)
- fallback repair in [manager-config-keeper.sh](/worksp/hiclaw/manager-config-keeper.sh:1)

Important behavior:

- this only affects direct messages
- Matrix private/group rooms still use separate group/channel session keys
- if the admin wants another simultaneous conversation in HiClaw, the correct path is a new room, not another DM

### HiClaw separate-chat helper

Path:

- host / workspace: [workspace/skills/matrix-server-management/scripts/create-admin-chat-room.sh](/worksp/hiclaw/workspace/skills/matrix-server-management/scripts/create-admin-chat-room.sh)

Purpose:

- creates a new private HiClaw room for a separate admin conversation
- invites `@manager` and sends the first `@mention` automatically

Important behavior:

- this helper lives in `workspace/`, so it survives `hiclaw-manager` container recreation
- it depends on `HICLAW_ADMIN_PASSWORD` being present in the manager runtime environment
- it intentionally does not create a direct-message room, because DMs are pinned to the main session by `session.dmScope = "main"`

### Controller new-chat API

Path:

- generated inside `hiclaw-controller` at `/opt/element-web/hiclaw-chat-api.py`
- exposed through Element Web nginx at `/hiclaw-api/new-chat`

Purpose:

- powers the HiClaw `New Chat` button in the browser UI
- creates a new private admin room and sends the initial `@manager` message

Important behavior:

- this API is recreated on every controller boot by [start-element-web.sh](/worksp/hiclaw/start-element-web.sh)
- it assumes a single human admin account for the deployment
- it is intentionally same-origin behind the existing HiClaw UI host rather than a separate public service

### ClawTalk plugin config

Managed entry:

```json
"plugins": {
  "entries": {
    "clawtalk": {
      "enabled": true,
      "config": {
        "apiKey": "...",
        "autoConnect": true
      }
    }
  }
}
```

Important behavior:

- `plugins.load.paths` must not be used for ClawTalk in this deployment
- stale `installRecords.clawtalk` must not be present
- the startup patch rebuilds a bundled shim under `/usr/lib/node_modules/openclaw/dist/extensions/clawtalk`

### WhatsApp channel baseline

Managed behavior:

```json
"plugins": {
  "allow": ["whatsapp"],
  "entries": {
    "whatsapp": {
      "enabled": true
    }
  },
  "load": {
    "paths": [
      "/root/manager-workspace/.openclaw/npm/node_modules/@openclaw/whatsapp"
    ]
  }
},
"channels": {
  "whatsapp": {
    "enabled": true,
    "dmPolicy": "pairing",
    "groupPolicy": "allowlist"
  }
}
```

Important behavior:

- the host startup patch auto-installs `@openclaw/whatsapp` at the manager's OpenClaw version when the package is missing
- WhatsApp auth state lives under `workspace/.openclaw/credentials/whatsapp/`
- this deployment enables the channel but does not pre-authorize any phone numbers; first-contact DMs use OpenClaw pairing flow
- linking still requires running `openclaw channels login --channel whatsapp` inside `hiclaw-manager` and scanning the QR code

### Browser MCP config

Managed by [mcp-keeper.sh](/worksp/hiclaw/mcp-keeper.sh:1):

```json
"mcp": {
  "servers": {
    "browser": {
      "command": "npx",
      "args": ["@playwright/mcp", "--cdp-endpoint", "http://10.0.5.4:9223"]
    }
  }
}
```

Important behavior:

- the gateway can strip unknown keys during MinIO sync
- this block is not currently defended by a cron job

## Environment Variables

This repo does not define the full HiClaw environment model. It only relies on a few variables directly.

### Used directly by host-managed startup patch

- `CLAWTALK_API_KEY`
  - optional override for the default ClawTalk API key embedded in the startup patch
  - consumed inside the patched manager startup flow

### Used by the upstream manager startup behavior we intentionally preserve

- `HICLAW_MANAGER_RUNTIME`
  - expected to remain `openclaw` for the current ClawTalk integration path
- `HICLAW_MATRIX_DEBUG`
  - if set to `1`, enables additional matrix plugin tracing in the manager startup path
- `HICLAW_GITHUB_TOKEN`
  - used by upstream manager startup logic to auto-configure GitHub MCP

### Used directly by the controller chat UI patch

- `HICLAW_ADMIN_USER`
  - used by the controller-local new-chat API to authenticate as the human admin
- `HICLAW_ADMIN_PASSWORD`
  - required by the controller-local new-chat API
- `HICLAW_MATRIX_URL`
  - target Matrix API base URL used by the controller-local new-chat API
- `HICLAW_MATRIX_DOMAIN`
  - used to build the `@manager:<domain>` invite and mention target

### Values hardcoded in this host-ops layer

- ClawTalk server URL defaults to `https://clawdtalk.com`
- browser MCP CDP endpoint defaults to `http://10.0.5.4:9223`
- `oauth2-proxy` config is hardcoded in `oauth2-proxy/docker-compose.yml`

## Cron Configuration

Current expected host crontab:

```cron
* * * * * /worksp/hiclaw/manager-config-keeper.sh >> /worksp/hiclaw/manager-config-keeper.log 2>&1
* * * * * /worksp/hiclaw/manager-bootstrap-keeper.sh >> /worksp/hiclaw/manager-bootstrap-keeper.log 2>&1
* * * * * /worksp/hiclaw/controller-bootstrap-keeper.sh >> /worksp/hiclaw/controller-bootstrap-keeper.log 2>&1
```

Behavior:

- `manager-config-keeper.sh` edits host files directly
- `manager-bootstrap-keeper.sh` patches the running container and may restart it once when drift is detected
- `controller-bootstrap-keeper.sh` patches the controller-side Element Web startup script and may restart `hiclaw-controller` once when drift is detected
- `manager-bootstrap-keeper.sh` may briefly print `container startup script not readable yet; skipping this run` while `hiclaw-manager` is still booting

## Logs and State Files

- `manager-config-keeper.log`
  - cron output for config repairs
- `manager-bootstrap-keeper.log`
  - cron output for startup patch repair
- `controller-bootstrap-keeper.log`
  - cron output for controller startup patch repair
- `workspace/.openclaw/logs/config-health.json`
  - OpenClaw config health baseline; can cause surprise restores
- `workspace/.openclaw/clawtalk/ws.log`
  - ClawTalk WebSocket log created by the startup shim path

## Intentional Smells

- The ClawTalk API key is present in host-managed scripts.
  - That is not ideal.
  - It is the current design because this host-ops layer is directly repairing runtime behavior for a single deployment.
- `workspace/undefined/ws.log` may exist from earlier broken ClawTalk boots.
  - That path came from the older unwrapped `resolvePath()` behavior.
  - The current shim writes to `.openclaw/clawtalk/ws.log` instead.
