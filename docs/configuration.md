# Configuration

## Configuration Surfaces

### `workspace/openclaw.json`

- Host path: `/worksp/hiclaw/workspace/openclaw.json`
- Manager container path: `/root/manager-workspace/openclaw.json`
- Controller container path: `/root/hiclaw-fs/agents/manager/openclaw.json`

This file has three concurrent writers: the controller reconciler, the OpenClaw gateway, and `manager-config-keeper.sh`. OpenClaw also tracks a backup at `workspace/.openclaw/openclaw.json.bak` and a health baseline at `workspace/.openclaw/logs/config-health.json` — both are used by observe-recovery to revert "unexpected" changes. `manager-config-keeper.sh` keeps `config-health.json` in sync whenever it edits `openclaw.json` so observe-recovery does not overwrite the keeper's fixes.

### Host-managed scripts

| Script | Purpose | Persistent how |
|---|---|---|
| `start-manager-agent.sh` | Manager startup; ClawTalk bootstrap; k8s MinIO sync | Copied into container by `manager-bootstrap-keeper.sh` |
| `start-element-web.sh` | Controller Element Web startup; nginx config; New Chat API | Copied into controller by `controller-bootstrap-keeper.sh` |
| `manager-config-keeper.sh` | Stabilizes `openclaw.json`; runs from host directly | Host cron, every minute |
| `manager-bootstrap-keeper.sh` | Re-applies startup script after container recreation | Host cron, every minute |
| `controller-bootstrap-keeper.sh` | Re-applies controller startup script after recreation | Host cron, every minute |
| `mcp-keeper.sh` | Re-adds browser MCP block to `openclaw.json` | **Not in cron** — run manually when needed |

### Keeper state

`.state/manager-bootstrap-keeper.last-container` and `.state/controller-bootstrap-keeper.last-container` record the last container ID that received the patched script, so keepers skip containers they have already patched.

---

## Managed openclaw.json Settings

### `commands.restart`

**Effective behavior:** The startup script (`start-manager-agent.sh`) sets `commands.restart = true` at startup. The gateway processes this as a "reload now" signal within seconds, then clears `commands` to `{}`. The keeper (`manager-config-keeper.sh`) then normalizes `commands: {}` in the file to match the gateway's cleared running state.

**Why not just leave it `true`:** The controller writes its reconciliation template every ~5 minutes with `commands: {restart: true, native: "auto", ...}`. If the file contains a non-empty `commands` object when the keeper fixes the schema, the gateway sees a state change in `commands` (running `{}` vs file non-empty) and triggers another restart. Setting `commands: {}` in the file means this diff never occurs.

**What the keeper actually writes:** `commands: {}` — not `commands.restart: true`. The startup `true` is consumed immediately and is not the steady-state value.

**Do not change:** If you set `commands.restart = false` anywhere in this path, the controller will later write `true`, the gateway will see a `false → true` transition, and trigger a restart loop. If you leave `commands` non-empty after the initial startup, the 5-minute controller reconciliation will restart the gateway on every cycle. See Critical Incidents 1 and 2 in AGENTS.md.

### `session.dmScope`

Effective policy: always `"main"`.

The manager's main OpenClaw session key is `agent:main:main`. Forcing all Matrix DMs onto this session means the HiClaw chat UI and OpenClaw web chat share one transcript. Without this, each DM thread gets its own isolated session and the two UIs diverge.

This only affects direct messages. Matrix private/group rooms still use separate group-session keys. If the admin wants a parallel conversation, create a new Matrix room (use the "+ New Chat" button in Element Web or the skill at `workspace/skills/matrix-server-management/scripts/create-admin-chat-room.sh`).

### `channels.matrix.groups.*`

The controller writes `allow: true` in matrix group configs; the OpenClaw schema requires `enabled: true`. The keeper migrates `allow → enabled` on every run. This migration is why the keeper exists at all — without it, the gateway would permanently skip config reloads due to schema errors.

### `plugins.entries.clawtalk`

```json
"plugins": {
  "entries": {
    "clawtalk": {
      "enabled": true,
      "config": {
        "apiKey": "cc_live_...",
        "autoConnect": true
      }
    }
  }
}
```

The startup script adds this entry if absent. `plugins.load.paths` must not include the ClawTalk npm path — the keeper removes it if present because ClawTalk loads from the bundled shim at `/usr/lib/node_modules/openclaw/dist/extensions/clawtalk/`, not from the npm location.

### `plugins.entries.whatsapp` / `channels.whatsapp`

```json
"plugins": {
  "allow": ["whatsapp", "clawtalk"],
  "entries": { "whatsapp": { "enabled": true } },
  "load": { "paths": ["/root/manager-workspace/.openclaw/npm/node_modules/@openclaw/whatsapp"] }
},
"channels": {
  "whatsapp": { "enabled": true, "dmPolicy": "pairing", "groupPolicy": "allowlist" }
}
```

Added by the startup script. WhatsApp auth state lives under `workspace/.openclaw/credentials/whatsapp/`. The channel is enabled but requires a separate `openclaw channels login --channel whatsapp` pairing step before it can receive messages.

### Browser MCP

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

CDP endpoint `10.0.5.4:9223` is the static IP of the `novnc-desktop` container on the `e10kwzww46ljhrgz1qj08j6a` network. `mcp-keeper.sh` re-adds this block if the gateway strips it. `mcp-keeper.sh` is not in cron — run it manually if the browser tool disappears.

### `agents.defaults.bootstrapMaxChars`

Set to `20000` by the keeper so AGENTS.md (15k+ chars) is not truncated when the manager loads its bootstrap context.

---

## MinIO Storage Configuration

The MinIO server runs inside `hiclaw-controller` on port 9000.

| Setting | Value |
|---|---|
| `HICLAW_FS_ENDPOINT` | `http://hiclaw-controller:9000` |
| `HICLAW_FS_ACCESS_KEY` | `default` |
| `HICLAW_FS_SECRET_KEY` | set at deployment time, stored in container env |
| `HICLAW_FS_BUCKET` | `hiclaw-storage` |
| `HICLAW_STORAGE_PREFIX` | `hiclaw/hiclaw-storage` (mc alias + bucket combined) |

In `mc` syntax: `hiclaw/hiclaw-storage/manager/` means mc alias `hiclaw`, bucket `hiclaw-storage`, object prefix `manager/`.

### MinIO sync exclusions (CRITICAL)

The k8s startup pull in `start-manager-agent.sh` includes these `--exclude` flags. **Do not remove them.** Each exclusion blocks a category of content that must not enter the workspace from MinIO:

| Exclusion | Why |
|---|---|
| `hiclaw/*` | Local MinIO mirror (`hiclaw/hiclaw-storage/...`). If pulled into workspace, the controller's push creates a recursive path — the crash-causing bug of 2026-05-20 |
| `hiclaw-fs` | Symlink to container-internal `/root/hiclaw-fs`, recreated fresh on each startup |
| `*.clobbered.*` | Observe-recovery backup files — runtime noise, never needed in workspace |
| `.npm/*` | npm cache — large, runtime, no value in MinIO |
| `.codex/*` | Codex session state — runtime, no value in MinIO |
| `.cache/*` | Generic cache directories |

---

## Environment Variables

Variables used by this host-ops layer. The complete upstream HiClaw variable set is in `.env.example`.

### MinIO and storage

| Variable | Used by | Description |
|---|---|---|
| `HICLAW_FS_ENDPOINT` | `start-manager-agent.sh` | MinIO server URL, e.g. `http://hiclaw-controller:9000` |
| `HICLAW_FS_ACCESS_KEY` | `start-manager-agent.sh` | MinIO access key |
| `HICLAW_FS_SECRET_KEY` | `start-manager-agent.sh` | MinIO secret key |
| `HICLAW_FS_BUCKET` | `start-manager-agent.sh` | MinIO bucket name (`hiclaw-storage`) |
| `HICLAW_STORAGE_PREFIX` | `start-manager-agent.sh` | Full object prefix including alias (`hiclaw/hiclaw-storage`) |

### Runtime mode

| Variable | Value | Effect |
|---|---|---|
| `HICLAW_RUNTIME` | `k8s` | Activates k8s startup block: `mc mirror` pulls from MinIO, creates `hiclaw-fs` symlink |
| `HICLAW_MANAGER_RUNTIME` | `openclaw` | Selects OpenClaw gateway (vs CoPaw) |

### Manager identity

| Variable | Used by | Description |
|---|---|---|
| `HICLAW_MANAGER_GATEWAY_KEY` | startup, nginx token injection | OpenClaw gateway authentication key |
| `HICLAW_MANAGER_PASSWORD` | startup, Matrix registration | Manager Matrix account password |
| `HICLAW_MANAGER_NAME` | startup | Manager name (`default`) |

### Controller / cluster

| Variable | Used by | Description |
|---|---|---|
| `HICLAW_CONTROLLER_URL` | startup | Controller API endpoint |
| `HICLAW_ADMIN_USER` | startup, new-chat API | HiClaw admin username |
| `HICLAW_ADMIN_PASSWORD` | startup, new-chat API | HiClaw admin password |
| `HICLAW_REGISTRATION_TOKEN` | startup, tuwunel | Matrix homeserver registration token |
| `HICLAW_AUTH_TOKEN` | startup | Long-lived JWT for controller auth |

### Matrix

| Variable | Used by | Description |
|---|---|---|
| `HICLAW_MATRIX_URL` | startup, new-chat API | Matrix homeserver internal URL (`http://hiclaw-controller:6167`) |
| `HICLAW_MATRIX_DOMAIN` | startup, tuwunel | Matrix server domain (`matrix-local.hiclaw.io:18080`) |

### LLM

| Variable | Used by | Description |
|---|---|---|
| `HICLAW_LLM_API_KEY` | startup | OpenRouter API key |
| `HICLAW_LLM_PROVIDER` | startup | LLM provider (`openai-compat`) |
| `HICLAW_DEFAULT_MODEL` | startup | Default model (`deepseek/deepseek-v4-pro`) |

### OAuth2 proxy (in `oauth2-proxy/.env`, not committed)

| Variable | Description |
|---|---|
| `OAUTH2_CLIENT_ID` | Authentik OIDC client ID |
| `OAUTH2_CLIENT_SECRET` | Authentik OIDC client secret |
| `OAUTH2_PROXY_COOKIE_SECRET` | 32-byte base64 cookie signing secret |

### Google SSO for Matrix (in `.env`, not committed)

| Variable | Used by | Description |
|---|---|---|
| `GOOGLE_CLIENT_ID` | `start-tuwunel.sh` | Google OAuth client ID for native Matrix SSO |
| `GOOGLE_CLIENT_SECRET` | `start-tuwunel.sh` | Google OAuth client secret |

---

## Cron Configuration

Current host crontab (verify with `crontab -l`):

```cron
* * * * * /worksp/hiclaw/manager-config-keeper.sh >> /worksp/hiclaw/manager-config-keeper.log 2>&1
* * * * * /worksp/hiclaw/manager-bootstrap-keeper.sh >> /worksp/hiclaw/manager-bootstrap-keeper.log 2>&1
* * * * * /worksp/hiclaw/controller-bootstrap-keeper.sh >> /worksp/hiclaw/controller-bootstrap-keeper.log 2>&1
```

`mcp-keeper.sh` is **not in cron** — it modifies files inside the running manager container and is run manually when the browser MCP tool disappears.

---

## Logs and State Files

| File | Contents |
|---|---|
| `manager-config-keeper.log` | Keeper output — what it changed each minute |
| `manager-bootstrap-keeper.log` | Bootstrap keeper output — patch applied / container restarted |
| `controller-bootstrap-keeper.log` | Controller bootstrap keeper output |
| `workspace/.openclaw/logs/config-health.json` | OpenClaw config health baseline — kept in sync by the config keeper |
| `workspace/.openclaw/openclaw.json.bak` | OpenClaw backup — kept in sync by the config keeper to prevent observe-recovery rollbacks |
| `workspace/.openclaw/clawtalk/ws.log` | ClawTalk WebSocket service log |

---

## Known Configuration Smells

- **ClawTalk API key is hardcoded in `manager-config-keeper.sh`.** It belongs in an env var or secret store. Current design accepts this for a single-deployment host-ops layer.
- **`fix-element-config.sh` hardcodes the manager gateway key** in the nginx `manager-console.conf` sub_filter template for auto-login token injection. This key is already in the manager container's environment — the hardcoded value is a convenience for the one-off repair script.
- **`workspace/.openclaw/npm/node_modules/@openclaw/whatsapp` path** is hardcoded in `manager-config-keeper.sh`. It is the npm install path inside the manager container and does not vary across instances.
