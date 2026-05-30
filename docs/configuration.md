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
| `start-manager-agent.sh` | Manager startup; ClawTalk bootstrap; k8s MinIO sync; OpenRouter model sync | Copied into container by `manager-bootstrap-keeper.sh` |
| `start-element-web.sh` | Controller Element Web startup; nginx config; New Chat API | Copied into controller by `controller-bootstrap-keeper.sh` |
| `manager-config-keeper.sh` | Stabilizes `openclaw.json`; runs from host directly | Host cron, every minute |
| `manager-bootstrap-keeper.sh` | Re-applies startup script after container recreation; restarts container on openclaw package update | Host cron, every minute |
| `controller-bootstrap-keeper.sh` | Re-applies controller startup script after recreation | Host cron, every minute |
| `mcp-keeper.sh` | Re-adds browser MCP block to `openclaw.json` | **Not in cron** — run manually when needed |

### Keeper state

`.state/manager-bootstrap-keeper.last-container` and `.state/controller-bootstrap-keeper.last-container` record the last container ID that received the patched script, so keepers skip containers they have already patched.

The bootstrap keeper also tracks the openclaw package hash at `workspace/.openclaw-startup-pkg-hash` (bind-mounted from `/root/manager-workspace/.openclaw-startup-pkg-hash` inside the container). When the hash changes — which happens after a successful `openclaw update` — the keeper restarts the container so new module files load correctly. The keeper does **not** restart the container when only the startup script changes (script changes take effect at next natural container start).

---

## openclaw Install Paths

openclaw may be installed at two locations depending on whether it has been updated since the base image:

| Path | When present |
|---|---|
| `/opt/openclaw/` | Always present — bundled in the base image (`higress/hiclaw-manager:v1.1.0`) |
| `/usr/lib/node_modules/openclaw/` | Present after `openclaw update` runs (npm global install) |

The startup script checks the npm path first. If `/usr/lib/node_modules/openclaw/package.json` exists, it symlinks `/usr/local/bin/openclaw` to `/usr/lib/node_modules/openclaw/openclaw.mjs` so the newer version is used. Otherwise the base-image binary at `/opt/openclaw/` is used.

The package hash for update detection is read from the npm path if present, otherwise from `/opt/openclaw/package.json`.

Updates are triggered via the "Update now" button in the Control UI, which runs `openclaw update` in-process. Do not run `npm install -g openclaw@latest` directly — it runs without adequate swap margin and can OOM-kill the container, leaving a broken partial install.

---

## Managed openclaw.json Settings

### `commands.restart`

#### How the gateway's reload diff works

This is the most non-obvious part of the system. Read it carefully before touching anything related to `commands`.

**The gateway uses a startup baseline, not its in-memory running state, for reload diffs.**

When the container starts, `start-manager-agent.sh` writes `commands.restart = true` to `openclaw.json` before launching the gateway. The gateway loads this file and records it as the "last known good" in `workspace/.openclaw/logs/config-health.json`. This initial config — including `commands.restart: true` and the runtime fields the gateway adds on startup (Matrix accessToken, tools, meta, agents.defaults.elevatedDefault) — becomes the **permanent baseline** for all future reload evaluations. The gateway does NOT update this baseline after in-process restarts.

Every time `openclaw.json` changes on disk, the gateway computes a field-by-field diff between the current file and this startup baseline. If `commands` or any of its sub-keys appears as changed, the gateway triggers a full in-process restart (SIGUSR1) instead of a hot reload.

#### The restart trigger

The gateway only restarts when `commands` **changes in the diff** — it is diff-based, not value-based. A stable `commands.restart: true` does not cause restarts because it matches the startup baseline and produces a zero diff.

#### What the controller writes

The controller's ManagerReconciler writes its template to `openclaw.json` every ~5 minutes. That template sets `commands: null`. This is a deliberate reset — the controller does not own the commands signal. After this write, `commands` in the file is `null`.

#### Steady-state value: `commands: {"restart": true}`

`manager-config-keeper.sh` writes `commands: {"restart": true}` on every run. This is the only value that produces a zero diff against the startup baseline:

| Value keeper writes | Diff vs startup baseline | Result |
|---|---|---|
| `{"restart": true}` | No change in `commands` | Hot reload only |
| `{}` | `commands.restart` removed (true → absent) | Full restart |
| `null` | `commands` changed (object → null) | Full restart |
| `{"restart": false}` | `commands.restart` changed (true → false) | Full restart |

#### Inspect the baseline yourself

```bash
sudo python3 -c "
import json
h = json.load(open('/worksp/hiclaw/workspace/.openclaw/logs/config-health.json'))
for path, info in h['entries'].items():
    lg = info['lastKnownGood']
    print(path)
    print('  hash:', lg['hash'][:16], ' bytes:', lg['bytes'])
    print('  observed:', lg['observedAt'])
"
```

The `/root/manager-workspace/openclaw.json` entry is the active baseline. Its byte count is larger than the keeper's output (typically 10000+ vs 9500+ bytes) because the gateway adds runtime fields the keeper does not preserve.

#### Verify the keeper is writing the right value

```bash
sudo python3 -c "import json; d=json.load(open('/worksp/hiclaw/workspace/openclaw.json')); print('commands:', d.get('commands'))"
# Expected: {'restart': True}
```

#### What a broken state looks like

If `commands` gets set to anything other than `{"restart": true}`, you will see this pattern in `docker logs hiclaw-manager` repeating every ~5 minutes:

```
[reload] config reload skipped (invalid config): channels.matrix.groups.*: ...
[reload] config change detected; evaluating reload (..., commands.restart, ...)
[reload] config change requires gateway restart (commands.restart)
[gateway] signal SIGUSR1 received
[gateway] received SIGUSR1; restarting
```

To fix: run `bash /worksp/hiclaw/manager-config-keeper.sh` — the keeper will set `commands: {restart: true}` and the loop will stop within one cycle.

**Do not set `commands.restart = false`:** Writing false would produce `false → true` diffs on subsequent controller writes, re-triggering the loop. See Critical Incidents 1 and 2 in AGENTS.md for the full history.

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

### Model metadata (`models` / `known-models.json`)

On startup, `start-manager-agent.sh` fetches live model metadata from the OpenRouter API and merges it into `openclaw.json`. For any model whose ID matches an OpenRouter model ID, the startup script overwrites `contextWindow` and `maxTokens` with the live values from OpenRouter.

Currently only `deepseek/deepseek-v4-pro` matches an OpenRouter model ID — it is updated to 1048576 context. Other models used in this deployment (`gpt-5.4`, `claude-opus-4-6`, `deepseek-chat`, etc.) are accessed through Higress gateway alias IDs that have no OpenRouter equivalent, so their context windows remain at the static values in `known-models.json`.

The OpenRouter response is written to a temp file (not a shell variable) to avoid "Argument list too long" errors with large JSON payloads.

After the OpenRouter sync, the startup script immediately pushes the updated config back to MinIO so the background `MinIO→Local` sync (which starts seconds later) does not overwrite the freshly-synced values with stale MinIO data.

The OpenClaw schema rejects unknown model fields. The startup script strips the `pricing` field (returned by OpenRouter) before writing to `openclaw.json`.

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
| `HICLAW_LLM_API_KEY` | startup | OpenRouter API key (also used for OpenRouter model metadata sync) |
| `HICLAW_LLM_PROVIDER` | startup | LLM provider (`openai-compat`) |
| `HICLAW_DEFAULT_MODEL` | startup | Default model (`deepseek/deepseek-v4-pro`) |

### Google OAuth credentials (in `oauth2-proxy/.env`, not committed)

The same Google OAuth app credentials are used by both the auth proxy and the Matrix homeserver's SSO config.

| Variable | Used by | Description |
|---|---|---|
| `GOOGLE_CLIENT_ID` | `oauth2-proxy`, `start-tuwunel.sh` | Google OAuth client ID (`*.apps.googleusercontent.com`) |
| `GOOGLE_CLIENT_SECRET` | `oauth2-proxy`, `start-tuwunel.sh` | Google OAuth client secret (`GOCSPX-...`) |
| `OAUTH2_PROXY_COOKIE_SECRET` | `oauth2-proxy` | 32-byte base64 cookie signing secret |

The Google Cloud Console OAuth app must have `https://control.claw.designflow.app/oauth2/callback` registered as an authorized redirect URI.

To rotate credentials: update `oauth2-proxy/.env`, then `cd oauth2-proxy && docker compose up -d`.

To extract the current cookie secret: `docker inspect oauth2-proxy | grep cookie-secret`.

---

## nginx Upstream Resolution

nginx inside `hiclaw-controller` proxies the Control UI to `hiclaw-manager`. It uses Docker's internal DNS resolver (`127.0.0.11`) with a short TTL rather than a hardcoded IP:

```nginx
resolver 127.0.0.11 valid=10s;
set $upstream hiclaw-manager;
proxy_pass http://$upstream:3000;
```

This is generated by `start-element-web.sh` into `manager-console.conf`. The dynamic `$upstream` variable forces nginx to re-resolve on each request, which prevents 502 errors after `hiclaw-manager` is recreated (Docker assigns a new IP on recreation). **Do not replace this with a hardcoded IP.**

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
| `workspace/.openclaw-startup-pkg-hash` | openclaw package hash written by startup script; read by bootstrap keeper to detect updates |

---

## Known Configuration Smells

- **ClawTalk API key is hardcoded in `manager-config-keeper.sh`.** It belongs in an env var or secret store. Current design accepts this for a single-deployment host-ops layer.
- **`fix-element-config.sh` hardcodes the manager gateway key** in the nginx `manager-console.conf` sub_filter template for auto-login token injection. This key is already in the manager container's environment — the hardcoded value is a convenience for the one-off repair script.
- **`workspace/.openclaw/npm/node_modules/@openclaw/whatsapp` path** is hardcoded in `manager-config-keeper.sh`. It is the npm install path inside the manager container and does not vary across instances.
- **OpenRouter model sync is partial.** Only models with IDs that match OpenRouter's catalog get live context window values. Gateway alias IDs (e.g. `gpt-5.4`, `claude-opus-4-6`) have no OpenRouter equivalent and keep static values from `known-models.json`. A mapping table would be needed to fix this.
