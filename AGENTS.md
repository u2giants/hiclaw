# AGENTS.md — HiClaw Host Ops

Start here. This is the canonical operating guide for future developers and AI coding sessions.

---

## 1. Project Summary

HiClaw is Albert's personal AI operations platform on one Linux server (`178.156.180.212`). It runs Alibaba/Higress HiClaw controller+manager containers, an OpenClaw agent gateway, Matrix/Element chat, Higress LLM routing to OpenRouter/DeepSeek, MinIO storage, Google OAuth, and a noVNC Chrome desktop for CDP browser automation. This repo is the host-ops layer: keeper scripts, startup script overrides, routing/auth config, documentation, and the only locally built image (`novnc-desktop`). The outcome that matters is stable autonomous operation without host-wide crashes, config drift, or fragile in-container hand edits.

---

## 2. Multi-Model AI Note

There is no universal ignore-file standard across AI coding tools.

`.claudeignore` works for Claude Code.

When using any other AI tool, paste this file as your first message and follow the instructions in the "What to ignore" section.

`.cursorignore` is present for Cursor. `.copilotignore` is present for GitHub Copilot context control.

---

## 3. Repository Structure

| Path | Type | Purpose |
|---|---|---|
| `AGENTS.md` | docs | Primary AI/developer operating guide. |
| `README.md` | docs | Quick orientation and service links. |
| `CLAUDE.md` | docs | Claude Code-specific notes only; defer to this file for facts. |
| `docs/architecture.md` | docs | System design, component/data-flow details, constraints. |
| `docs/configuration.md` | docs | Env vars, config surfaces, OpenClaw config fields, state files. |
| `docs/deployment.md` | docs | Deploy, update, recovery, and runtime operations. |
| `docs/development.md` | docs | Debugging, local validation, safe edit workflows. |
| `.github/workflows/build-and-push.yml` | deployment | Builds and pushes only `novnc-desktop`. |
| `novnc-desktop/` | code we own | Dockerfile, Chrome startup/watchdog, CDP proxy, recreate helper. |
| `oauth2-proxy/` | deployment/config | Google OAuth proxy compose file, allowlist, live env file. |
| `traefik/claw.yml` | deployment/config | Traefik dynamic routes; mirror of live proxy config. |
| `*.sh` at repo root | scripts we own | Host keepers and upstream-container startup overrides. |
| `workspace/` | generated/runtime | Runtime state and OpenClaw config; not in git. |
| `.state/` | generated/runtime | Keeper state; not in git. |
| `*.log` | generated/runtime | Keeper/container logs; not in git. |

There are no app migrations in this repo. No third-party source is vendored here; upstream HiClaw/OpenClaw code lives inside Docker images and npm installs.

---

## 4. Prime Directive: Custom-Code Boundary

Our custom code lives here:

- `novnc-desktop/`
- root-level keeper/startup scripts: `controller-bootstrap-keeper.sh`, `manager-bootstrap-keeper.sh`, `manager-config-keeper.sh`, `novnc-resource-keeper.sh`, `mcp-keeper.sh`, `start-element-web.sh`, `start-manager-agent.sh`, `start-tuwunel.sh`, `fix-element-config.sh`
- `oauth2-proxy/`
- `traefik/claw.yml`
- `.github/workflows/`
- `docs/`, `README.md`, `AGENTS.md`, `CLAUDE.md`
- `.env.example` and AI ignore files

Everything else requires justification before touching.

Do not hand-edit files inside running `hiclaw-manager` or `hiclaw-controller` as a permanent fix. If a fix uses `docker exec hiclaw-manager some-edit`, it is temporary; the durable fix belongs in `start-manager-agent.sh`, a keeper script, or a mounted file.

Treat `/worksp/hiclaw/workspace/` as runtime data. The only normal direct edit there is a targeted `openclaw.json` recovery/config fix, and you must account for `manager-config-keeper.sh` and `config-health.json`.

---

## 5. Core Modification Inventory

These are repo-owned files or scripted modifications that compensate for upstream-container behavior.

| File | Change made | Why it was necessary | Risk during upgrades |
|---|---|---|---|
| `start-manager-agent.sh` | Patches `openclaw.json`, installs fake `systemd-run`, validates npm OpenClaw install with `json5/package.json` and `openai/index.mjs`, bootstraps ClawTalk/WhatsApp, records package hash. | Makes OpenClaw usable in Docker, prevents update and partial-install crash loops, keeps config compatible with the reconciler. | Upstream OpenClaw/HiClaw changes can invalidate jq patches, plugin paths, or update assumptions. |
| `manager-bootstrap-keeper.sh` | Copies host startup script into `hiclaw-manager`, enforces `1536m/3g/1CPU`, consumes `.openclaw-update-requested`, waits 30s before restart, restarts on package hash change. | Makes startup overrides durable and prevents openclaw update truncation/OOM failures. | Any OpenClaw update-flow change must preserve the marker, sleep, and validation sequence. |
| `manager-config-keeper.sh` | Normalizes `openclaw.json`, strips invalid wildcard groups, clears `commands.restart` if present, updates `config-health.json` atomically. | Controller reconciler/startup paths can write values OpenClaw rejects or values that trigger restart loops. | Reconciler/schema changes require rechecking all enforced fields. |
| `controller-bootstrap-keeper.sh` | Copies `start-element-web.sh` and `start-tuwunel.sh` into `hiclaw-controller`, enforces `3g/4g/2CPU/1024PIDs`, restarts when scripts change. | Keeps controller nginx/Element/Tuwunel customizations durable and gives controller enough memory headroom. | Upstream controller startup paths may change. |
| `novnc-resource-keeper.sh` | Enforces `novnc-desktop` limits (`3g` RAM, `4g` total memory+swap, 2 CPUs, 250 PIDs) and restarts it before memory/PID danger thresholds. | Prevents Chrome/QtWebEngine from causing host-wide OOM. | Thresholds may need tuning if browser automation workload grows. |
| `novnc-desktop/Dockerfile` | Installs Google Chrome, Dropbox, Insync; wraps Chrome with Docker-safe flags and Singleton guard. | Provides browser automation target and prevents double-Chrome OOM. | Rebuild required after edits; upstream webtop/Chrome behavior can change. |
| `novnc-desktop/cdp_proxy.py` | Proxies Chrome CDP from `:9222` to `:9223`. | OpenClaw Playwright MCP uses a stable CDP endpoint at `10.0.5.4:9223`. | If bind-mounted live, edit in place to preserve inode. |
| `start-element-web.sh` | Generates Element Web config, nginx routes, JS injection, control-panel proxy, chat API helper. | Enables Google OAuth gated Element and Control UI auto-login. | Element Web or OpenClaw UI changes can break injected JS/sub_filter assumptions. |
| `fix-element-config.sh` | Idempotent repair for post-upgrade controller config. | Restores generated config after upstream image changes. | Hardcoded repair assumptions must be checked after upgrades. |
| `oauth2-proxy/.env.example` | Documents the Google OAuth variables used by `oauth2-proxy/docker-compose.yml`. | Keeps the ignored live `.env` reproducible without committing secrets. | Must stay aligned with compose variable names. |

---

## 6. Task-to-File Navigation

| Task | Files to touch | Files not to touch |
|---|---|---|
| Change Chrome flags/watchdog | `novnc-desktop/Dockerfile`, `novnc-desktop/novnc-startup.sh`, `docs/` | Running browser profile in `workspace/`; upstream image internals as permanent fix |
| Change CDP proxy behavior | `novnc-desktop/cdp_proxy.py` in place, docs | Replacing `cdp_proxy.py` via `cp`/atomic write when live-bind-mounted |
| Recreate noVNC desktop | `novnc-desktop/recreate.sh`, `novnc-resource-keeper.sh` | Coolify UI; uncapped `docker run` commands |
| Change noVNC resource limits | `novnc-desktop/recreate.sh`, `novnc-resource-keeper.sh`, `docs/deployment.md` | One-off `docker update` only |
| Change OAuth users | `oauth2-proxy/allowed-emails.txt`, `docs/configuration.md` if behavior changes | Google OAuth secrets unless rotating |
| Change OAuth proxy config | `oauth2-proxy/docker-compose.yml`, `oauth2-proxy/.env.example`, `docs/` | Traefik auth middleware unless routing also changes |
| Change Traefik route | `traefik/claw.yml`, `docs/deployment.md` | Coolify-managed generated proxy files except applying with `docker cp` |
| Change manager startup/OpenClaw behavior | `start-manager-agent.sh`, maybe `manager-bootstrap-keeper.sh`, docs | Files edited manually inside `hiclaw-manager` |
| Change controller Element/nginx/Tuwunel behavior | `start-element-web.sh`, `start-tuwunel.sh`, `controller-bootstrap-keeper.sh`, docs | Files edited manually inside `hiclaw-controller` |
| Change OpenClaw runtime config | `workspace/openclaw.json` for targeted live fix, `manager-config-keeper.sh` for durable invariant, `docs/configuration.md` | `config-health.json` ignored; changes will be reverted |
| Change env var contract | `.env.example`, `docs/configuration.md`, relevant script | Production env by hand without documenting |
| Update OpenClaw | Control UI "Update now" or marker consumed by `manager-bootstrap-keeper.sh` | Direct `docker exec hiclaw-manager openclaw update --yes` during normal operation |
| Update docs | `AGENTS.md` first, then focused docs | Duplicating the same procedure everywhere |

---

## 7. Data Model and External Identifiers

Do not casually rename or regenerate these.

| Entity/System | Identifier | Where defined | Notes |
|---|---|---|---|
| Host server | `178.156.180.212` | Deployment environment/docs | Single production server. |
| Matrix domain | `matrix-local.hiclaw.io:18080` | env, `openclaw.json`, scripts | Part of MXIDs; changing breaks identity. |
| Admin Matrix user | `@admin:matrix-local.hiclaw.io:18080` | startup scripts/runtime | Primary user. |
| Manager Matrix user | `@manager:matrix-local.hiclaw.io:18080` | startup scripts/runtime | Agent user. |
| Permanent Matrix DM room | `!Yzg8FAvvzjKsYTBJb3:matrix-local.hiclaw.io:18080` | runtime/docs | Main DM room; do not replace casually. |
| AI gateway URL | `http://aigw-local.hiclaw.io:8080/v1` | `openclaw.json`, startup | Internal LLM proxy via Higress. |
| OpenClaw gateway token | `5de86910dec50bf9d9162682d9a7f468143b85ee68c5deb316ad081b5a97ab0c` | runtime config/auth token | Used by Control UI injection and gateway auth. |
| MinIO bucket | `hiclaw-storage` | env/scripts | Object storage bucket. |
| MinIO manager config key | `hiclaw/hiclaw-storage/manager/openclaw.json` | `start-manager-agent.sh` | Synced copy of live config. |
| Live OpenClaw config | `/worksp/hiclaw/workspace/openclaw.json` | host bind mount | Also visible at `/root/manager-workspace/openclaw.json`. |
| CDP endpoint | `http://10.0.5.4:9223` | `openclaw.json`, `novnc-desktop/recreate.sh` | Static noVNC IP; Playwright MCP target. |
| noVNC network | `e10kwzww46ljhrgz1qj08j6a` | `recreate.sh`, Docker | noVNC gets static `10.0.5.4`. |
| `hiclaw-net` | Docker network | Docker/scripts | Controller, manager, oauth2-proxy internal network. |
| `coolify` | Docker network | Docker/Coolify | Traefik-facing network. |
| Element URL | `https://claw.designflow.app` | Traefik | Google OAuth gated except Matrix API paths. |
| Control URL | `https://control.claw.designflow.app` | Traefik/controller nginx | Routes through controller nginx to manager. |
| Gateway URL | `https://gateway.claw.designflow.app` | Traefik | Direct OpenClaw gateway access. |
| noVNC URL | `https://vnc.designflow.app` | Traefik | No auth in current config. |
| GHCR image | `ghcr.io/u2giants/novnc-desktop` | GitHub Actions | Tags `latest` and `sha-<commit>`. |
| Deleted Coolify service UUID | `e10kwzww46ljhrgz1qj08j6a` | GitHub secret/docs | Workflow restart step references deleted service; image build still succeeds. |

No application database or migrations are managed by this repo. Tuwunel uses embedded RocksDB and MinIO stores workspace objects.

---

## 8. Container and Service Inventory

| Container/service | Purpose | Managed by | App/project ID | Image/source |
|---|---|---|---|---|
| `hiclaw-controller` | Tuwunel Matrix, Higress AI gateway, MinIO, Element Web, controller reconciler | `controller-bootstrap-keeper.sh` cron; upstream container | N/A, not in Coolify | `higress/hiclaw-embedded:v1.1.2` |
| `hiclaw-manager` | OpenClaw gateway and agent runtime | `manager-bootstrap-keeper.sh` + `manager-config-keeper.sh` cron; upstream container | N/A, not in Coolify | `higress/hiclaw-manager:v1.1.2` |
| `novnc-desktop` | Chrome/noVNC/CDP automation target | `novnc-desktop/recreate.sh` manually; `novnc-resource-keeper.sh` cron | N/A, not in Coolify | `ghcr.io/u2giants/novnc-desktop:latest` |
| `oauth2-proxy` | Google OAuth forward-auth | `oauth2-proxy/docker-compose.yml` | N/A, not in Coolify | `quay.io/oauth2-proxy/oauth2-proxy:latest` |
| `coolify-proxy` | Traefik TLS/routing | Coolify/systemd | Coolify proxy | `traefik:v3.6` |
| `coolify` | Coolify management UI, not owner of HiClaw core containers | systemd | Coolify app | `ghcr.io/coollabsio/coolify:4.1.1` |

Resource limits:

| Container | RAM | Total memory+swap (`--memory-swap`) | CPUs | PID limit |
|---|---:|---:|---:|---:|
| `hiclaw-manager` | 1536 MiB | 3072 MiB | 1 | Docker default |
| `hiclaw-controller` | 3072 MiB | 4096 MiB | 2 | 1024 |
| `novnc-desktop` | 3072 MiB | 4096 MiB | 2 | 250 |

Host memory policy: `/swapfile` is 12 GiB, mounted from `/etc/fstab`; `vm.swappiness=20` is persisted in `/etc/sysctl.d/99-hiclaw-memory.conf`.

---

## 9. What to Ignore

These are runtime/generated/cache artifacts and should not consume AI context or be committed:

- `workspace/`
- `.state/`
- `*.log`
- `dist/`
- `node_modules/`
- `.cache/`
- `coverage/`
- `.ruff_cache/`
- `.DS_Store`
- `*.swp`, `*.swo`
- `workspace/openclaw.json.clobbered.*`
- `workspace/.openclaw/`
- `workspace/.playwright-mcp/`
- `workspace/hiclaw/` if present; this is a MinIO recursion artifact and should be deleted after investigation.

---

## 10. Intentional Quirks and Non-Obvious Decisions

### Core containers are not in Coolify

Looks like:
Core services should be managed by Coolify because Coolify is present.

Actually:
`hiclaw-manager`, `hiclaw-controller`, `novnc-desktop`, and `oauth2-proxy` are host-managed. Coolify mainly provides Traefik/proxy infrastructure.

Why:
The manager/controller need shared bind mounts, custom PID-1 startup scripts, script patching, and cron keepers that do not fit the current Coolify app model.

Do not change because:
Moving them to Coolify is a migration project, not a cleanup. Duplicating them from Coolify will create conflicting containers.

### Fake `systemd-run` enables OpenClaw updates

Looks like:
`/usr/local/bin/systemd-run` and `OPENCLAW_SYSTEMD_UNIT=openclaw-gateway` are fake or leftover systemd hacks.

Actually:
OpenClaw only enables managed update handoff on Linux when it detects systemd. The fake wrapper writes `/worksp/hiclaw/workspace/.openclaw-update-requested`; `manager-bootstrap-keeper.sh` consumes it and runs the update safely.

Why:
Docker has no systemd, but the Control UI "Update now" path needs a supervisor handoff.

Do not change because:
Removing it returns `managed-service-handoff-unavailable` and the UI update button stops working.

### OpenClaw update must go through the keeper

Looks like:
`docker exec hiclaw-manager openclaw update --yes` is simpler.

Actually:
The keeper ensures swap headroom, consumes the marker, waits 30 seconds for the in-process SIGUSR1 write to finish, and then restarts only after package hash changes.

Why:
Direct updates previously caused npm partial installs and truncated `openclaw.json`.

Do not change because:
Bypassing the keeper can crash the gateway or corrupt the live config.

### `commands.restart` must not persist

Looks like:
Keeping `commands.restart=true` in `openclaw.json` should be harmless or even required for restarts.

Actually:
The current stable live config has no `commands` key. `start-manager-agent.sh` deletes `commands.restart` before launch, and `manager-config-keeper.sh` clears it if an upstream write reintroduces it.

Why:
OpenClaw diffs live config changes against its startup baseline. A persistent `commands.restart` can turn routine reconciler/config writes into recurring SIGUSR1 restarts.

Do not change because:
The stable state is `commands` absent. If this changes, verify the live baseline and gateway logs before updating keeper behavior.

### `channels.matrix.groups["*"]` must be stripped

Looks like:
A wildcard Matrix group is a useful default policy.

Actually:
OpenClaw's schema rejects extra group keys, including `"*"`.

Why:
The upstream reconciler writes the wildcard, but OpenClaw validation rejects it and then skips config reloads/update handoff.

Do not change because:
Leaving it breaks config reload and can make `update.run` report unavailable.

### `config-health.json` must match keeper-written config

Looks like:
Editing `openclaw.json` should be enough.

Actually:
OpenClaw observe-recovery compares the config to `workspace/.openclaw/logs/config-health.json` and may restore from backup if the hash differs.

Why:
This mechanism protects against truncation, but it also reverts uncoordinated edits.

Do not change because:
Durable config fixes must update `openclaw.json` and `config-health.json` together or the fix will be undone.

### `OPENCLAW_NO_RESPAWN=1` is required

Looks like:
Disabling respawn should make restarts less reliable.

Actually:
It keeps SIGUSR1 reloads in-process instead of `exec`ing a detached child that Docker PID 1 cannot supervise correctly.

Why:
Config reloads happen often due to reconciler/keeper writes.

Do not change because:
Without it, config reloads can kill the container.

### `workspace/` survives restart, not every container overlay

Looks like:
Restarting or recreating containers should be equivalent because the workspace is persistent.

Actually:
The bind-mounted workspace survives, but npm overlays, fake binaries, symlinks, and plugin shims inside the container overlay are lost on `docker rm`.

Why:
Docker recreation destroys the writable layer.

Do not change because:
Prefer `docker stop`/`docker start` for manager debugging. If recreation is unavoidable, expect startup scripts/keepers to rebuild overlay state.

### MinIO sync exclusions prevent recursive storage explosion

Looks like:
`mc mirror` exclusions such as `hiclaw/*` are defensive clutter.

Actually:
Without them, MinIO content can be pulled into `workspace/` and then pushed back into MinIO recursively.

Why:
The controller also sees and syncs the same workspace.

Do not change because:
Removing exclusions previously caused disk-growth crashes.

### `cdp_proxy.py` must be edited in place when live-mounted

Looks like:
Replacing a Python file via `cp` or atomic write is fine.

Actually:
Docker bind mounts track the inode, so replacing the host path can leave the container reading the old file.

Why:
The live noVNC container may have the file bind-mounted.

Do not change because:
Use in-place edits (`apply_patch`, Edit tool, or `sed -i`) for live changes.

### Chrome Singleton and process limits are intentional

Looks like:
The Chrome wrapper and noVNC PID/memory limits are overcautious.

Actually:
Chrome/QtWebEngine has caused both double-instance OOMs and host-wide global OOMs.

Why:
The wrapper avoids duplicate Chrome instances; `novnc-resource-keeper.sh` and `recreate.sh` prevent host-wide memory/swap exhaustion.

Do not change because:
Uncapped noVNC can make SSH unreachable and crash the server.

### Control UI routes through controller nginx

Looks like:
Traefik should route `control.claw.designflow.app` straight to `hiclaw-manager:18799`.

Actually:
Traefik routes to `hiclaw-controller:18888`; controller nginx proxies to `hiclaw-manager:18799` and injects the gateway token.

Why:
Token injection and Docker DNS re-resolution happen in generated nginx config.

Do not change because:
Direct routing loses auto-auth; hardcoded IPs cause 502 after manager recreation.

### Element auto-login writes Matrix session to localStorage

Looks like:
Element should use Matrix `loginToken`.

Actually:
`auto-login.js` calls the controller helper API and writes `mx_*` localStorage keys for a fixed Matrix device.

Why:
`loginToken` creates a new device and triggers Element cross-signing verification every time.

Do not change because:
The current flow skips repeated device verification for this single-admin deployment.

---

## 11. Credentials and Environment

List variables only; do not paste secret values into docs.

| Variable | Purpose | Stored where | Required in dev | Required in prod |
|---|---|---|---|---|
| `HICLAW_ADMIN_USER` | Admin username | container env / `.env.example` | no | yes |
| `HICLAW_ADMIN_PASSWORD` | Admin, MinIO, Matrix setup password | container env or `/data/hiclaw-secrets.env` | no | yes |
| `HICLAW_MINIO_PASSWORD` | MinIO root password | container env | no | yes |
| `HICLAW_LLM_PROVIDER` | LLM provider type | container env | no | yes |
| `HICLAW_LLM_API_KEY` | OpenRouter API key | container env or `/data/hiclaw-secrets.env` | no | yes |
| `HICLAW_OPENAI_BASE_URL` | OpenRouter-compatible base URL | controller env | no | yes |
| `HICLAW_DEFAULT_MODEL` | Default agent model | manager env | no | yes |
| `HICLAW_EMBEDDING_MODEL` | Memory search embedding model | manager env | no | no |
| `HICLAW_AI_GATEWAY_URL` | Internal Higress AI gateway URL | manager env | no | yes |
| `HICLAW_AI_GATEWAY_ADMIN_URL` | Higress admin API URL | manager env | no | yes |
| `HICLAW_MANAGER_GATEWAY_KEY` | OpenClaw gateway token | auto-generated or env; `/data/hiclaw-secrets.env`; `openclaw.json` | no | yes |
| `HICLAW_MANAGER_PASSWORD` | Matrix manager password | auto-generated or env; `/data/hiclaw-secrets.env` | no | yes |
| `HICLAW_AUTH_TOKEN` | Controller auth JWT | container env | no | yes |
| `HICLAW_REGISTRATION_TOKEN` | Matrix registration token | container env | no | yes |
| `HICLAW_FS_ENDPOINT` | MinIO endpoint | container env | no | yes |
| `HICLAW_FS_ACCESS_KEY` | MinIO access key | container env | no | yes |
| `HICLAW_FS_SECRET_KEY` | MinIO secret | container env | no | yes |
| `HICLAW_FS_BUCKET` | MinIO bucket | container env | no | yes |
| `HICLAW_STORAGE_PREFIX` | MinIO object prefix | container env | no | yes |
| `HICLAW_MATRIX_DOMAIN` | Matrix server name | container env | no | yes |
| `HICLAW_MATRIX_URL` | Matrix API URL | container env | no | yes |
| `HICLAW_ELEMENT_HOMESERVER_URL` | Element homeserver URL | controller env | no | yes |
| `GOOGLE_CLIENT_ID` | Google OAuth client ID | `oauth2-proxy/.env`, controller env | no | yes |
| `GOOGLE_CLIENT_SECRET` | Google OAuth client secret | `oauth2-proxy/.env`, controller env | no | yes |
| `OAUTH2_PROXY_COOKIE_SECRET` | OAuth cookie signing secret | `oauth2-proxy/.env` | no | yes |
| `GOOGLE_ADMIN_EMAIL` | Tuwunel OAuth admin association | controller env/script | no | yes |
| `CLAWTALK_API_KEY` | Optional override for ClawTalk relay key | manager env; otherwise hardcoded default | no | no |
| `COOLIFY_BASE_URL` | GitHub Actions Coolify restart endpoint | GitHub secret | no | workflow only |
| `COOLIFY_API_TOKEN` | Coolify API token | GitHub secret / Coolify | no | workflow only |
| `COOLIFY_SERVICE_UUID` | Deleted noVNC Coolify service UUID | GitHub secret | no | workflow only, currently stale |

`oauth2-proxy/.env` contains live Google OAuth credentials on the server and is ignored by git. Root `.env` is also ignored; `.env.example` files are templates only.

---

## 12. Deployment

| Track | Trigger | Build/package | Deploy/apply | Rollback |
|---|---|---|---|---|
| `novnc-desktop` image | Push to `main` touching `novnc-desktop/**`, or `workflow_dispatch` | GitHub Actions `Build and Push`; pushes `ghcr.io/u2giants/novnc-desktop:latest` and `:sha-<commit>` | On server: `docker pull ghcr.io/u2giants/novnc-desktop:latest && bash /worksp/hiclaw/novnc-desktop/recreate.sh` | Run `recreate.sh` with a previous `:sha-<commit>` image tag. |
| Host scripts/docs/config | Git push/pull | No image build | On server: `cd /worksp/hiclaw && git pull`; cron uses new keeper scripts; run relevant keeper/apply command if immediate convergence is needed | `git revert` or checkout prior commit and re-apply. |
| Traefik dynamic config | Edit `traefik/claw.yml` | No build | `docker cp traefik/claw.yml coolify-proxy:/traefik/dynamic/claw.yml`; Traefik hot-reloads | Copy previous file back. |
| OAuth proxy config | Edit `oauth2-proxy/` | Compose pull/run | `cd /worksp/hiclaw/oauth2-proxy && docker compose up -d` | Revert file and `docker compose up -d`. |
| Runtime OpenClaw config | Targeted edit or keeper convergence | No build | Edit `/worksp/hiclaw/workspace/openclaw.json` carefully; durable invariants go in `manager-config-keeper.sh` | Restore `openclaw.json.bak` or MinIO copy. |

GitHub Actions workflow: `.github/workflows/build-and-push.yml` (`Build and Push`). The workflow also tries to call a Coolify restart endpoint for a deleted noVNC service; that step can fail even when GHCR image build/push succeeded. Do not treat Coolify as the deployment platform for `hiclaw-manager`, `hiclaw-controller`, `oauth2-proxy`, or `novnc-desktop`.

Runtime environment variables live in Docker container env, `/data/hiclaw-secrets.env`, `oauth2-proxy/.env`, and GitHub Secrets for the workflow. SSH/server shell access is routine for this host-ops repo because scripts and containers run directly on the production server, but durable changes still go through git.

Required keeper cron entries live under the `ai` user's crontab:

```cron
* * * * * /worksp/hiclaw/manager-config-keeper.sh >> /worksp/hiclaw/manager-config-keeper.log 2>&1
* * * * * /worksp/hiclaw/controller-bootstrap-keeper.sh >> /worksp/hiclaw/controller-bootstrap-keeper.log 2>&1
* * * * * /worksp/hiclaw/manager-bootstrap-keeper.sh >> /worksp/hiclaw/manager-bootstrap-keeper.log 2>&1
* * * * * /worksp/hiclaw/novnc-resource-keeper.sh >> /worksp/hiclaw/novnc-resource-keeper.log 2>&1
```

Verify with `sudo crontab -u ai -l`.

---

## 13. Critical Incidents

### 2026-05-05 OpenClaw restart loop

What happened:
OpenClaw restarted repeatedly after startup.

Impact:
Gateway instability and unavailable agent sessions.

Root cause:
Startup wrote a `commands.restart` value that differed from the reconciler/baseline flow.

Recovery:
Changed startup/config keeper behavior so `commands.restart` is removed before/after startup.

Rule added to prevent recurrence:
Do not persist `commands.restart`; keeper owns this field.

### 2026-05-08 Chrome double-instance OOM

What happened:
Two Chrome instances ran in noVNC.

Impact:
Browser memory exceeded safe levels.

Root cause:
Chrome Singleton files were deleted while Chrome was already running; `pkill` regex used a literal pipe.

Recovery:
Added pgrep guard and fixed `pkill` ERE alternation.

Rule added to prevent recurrence:
Keep the Chrome wrapper Singleton guard and watchdog regex.

### 2026-05-20 MinIO recursive storage explosion

What happened:
MinIO/workspace paths nested recursively.

Impact:
Disk growth and server instability.

Root cause:
Manager pulled MinIO content into the workspace that controller then pushed back into MinIO.

Recovery:
Added `mc mirror` exclusions (`hiclaw/*`, `hiclaw-fs`, `*.clobbered.*`, `.npm/*`, `.codex/*`, `.cache/*`).

Rule added to prevent recurrence:
Never remove MinIO sync exclusions; investigate any `workspace/hiclaw/` directory.

### 2026-05-30 Swap exhaustion and npm partial install

What happened:
Old shell/session swap use combined with OpenClaw npm install memory demand.

Impact:
OOM killed npm install and left broken OpenClaw dependencies.

Root cause:
Insufficient swap headroom and direct/unsafe update path.

Recovery:
Killed stale process, recreated manager, updated via keeper path.

Rule added to prevent recurrence:
OpenClaw updates must go through `manager-bootstrap-keeper.sh`; manager `--memory-swap` must exceed `--memory`.

### 2026-05-30 control.claw 502 after manager recreation

What happened:
Control UI returned 502 after container recreation.

Impact:
OpenClaw Control UI inaccessible.

Root cause:
nginx used hardcoded manager container IP.

Recovery:
`start-element-web.sh` now generates nginx with Docker DNS resolver and `$upstream hiclaw-manager`.

Rule added to prevent recurrence:
Never hardcode manager IPs in controller nginx.

### 2026-05-31 update.run unavailable

What happened:
OpenClaw update UI returned `managed-service-handoff-unavailable`.

Impact:
UI update path failed.

Root cause:
Invalid wildcard Matrix group, stale observe-recovery backup, and no systemd supervisor in Docker.

Recovery:
Keeper strips wildcard, fixes backup path/health baseline, fake `systemd-run` enables marker handoff.

Rule added to prevent recurrence:
Keep fake systemd-run and schema normalization.

### 2026-05-31 OpenClaw downgrade and npm OOM loop

What happened:
Container recreation fell back to base OpenClaw, update npm install OOMed, broken install was accepted.

Impact:
Gateway crash loop.

Root cause:
Docker overlay loss plus `--memory-swap` equal to memory and insufficient install validation.

Recovery:
Set manager `1536m/3g`, validate both `json5` and `openai/index.mjs`, fall back to base image on failure.

Rule added to prevent recurrence:
Do not recreate manager casually; keep dual dependency validation.

### 2026-05-31 openclaw.json truncation loop

What happened:
`openclaw.json` repeatedly truncated during update/restart.

Impact:
Gateway crashed on startup; 211 clobbered forensic files were created.

Root cause:
Docker restart killed OpenClaw during its in-process SIGUSR1 config write.

Recovery:
Added 30-second sleep after `openclaw update --yes --json` before restart/hash handling.

Rule added to prevent recurrence:
Never restart manager immediately after OpenClaw update.

### 2026-06-01 missing `openai/index.mjs`

What happened:
Partial npm install left `.map` files but no `.mjs` OpenAI package files.

Impact:
Gateway crashed on first request.

Root cause:
Validation checked `json5` only.

Recovery:
Added `openai/index.mjs` validation and fallback to `/opt/openclaw/`.

Rule added to prevent recurrence:
Do not reduce OpenClaw install validation.

### 2026-05-31 jq parse errors and YOLO reconciler diff loop

What happened:
jq parse failures and reconciler overwrites caused frequent restarts.

Impact:
`control.claw` unavailable a large fraction of the time.

Root cause:
Inline comments inside jq expressions and startup-written YOLO fields that reconciler nulled every cycle.

Recovery:
Removed inline jq comments and removed YOLO defaults from startup config.

Rule added to prevent recurrence:
Keep jq expressions simple and do not write fields the upstream reconciler nulls every 47 seconds.

### 2026-06-03 host-wide OOM from uncapped noVNC Chrome/QtWebEngine

What happened:
The whole server became slow/unreachable; global OOM killed Chrome/QtWebEngine in the noVNC cgroup.

Impact:
SSH appeared broken and the host thrashed on full swap.

Root cause:
`novnc-desktop` had no Docker memory/PID limits; host swap was only 4 GiB.

Recovery:
Added `novnc-resource-keeper.sh`, noVNC `3g/4g/2CPU/250PIDs` limits, controller headroom, 12 GiB host swap, `vm.swappiness=20`.

Rule added to prevent recurrence:
Never run `novnc-desktop` uncapped; leave it stopped when unused.

---

## 14. Pending Work

| Status | Item | Owner/next action |
|---|---|---|
| done | Static context windows for non-OpenRouter alias model IDs (`gpt-5.4`, `claude-opus-4-6`, `kimi-k2.5`, etc.). | Completed 2026-06-03: `manager-config-keeper.sh` enforces a static context-window table for all current gateway alias IDs, while startup OpenRouter metadata sync remains best-effort for canonical IDs. |
| blocked | Rebuild and push `ghcr.io/u2giants/novnc-desktop` so the latest Chrome wrapper/resource-related source is in GHCR. | GitHub Actions build succeeded locally through image export but GHCR push failed with `permission_denied: write_package` on run `26891511685`. Grant package write permission to `GITHUB_TOKEN`/package settings or add a PAT secret with `write:packages`, then rerun `Build and Push` and run `novnc-desktop/recreate.sh`. |
| done | Move ClawTalk modifications from ephemeral container overlay to a host-mounted durable path. | Completed 2026-06-03: `start-manager-agent.sh` writes the ClawTalk bundled shim to `/root/manager-workspace/.openclaw/bundled-extensions/clawtalk` and symlinks `/usr/lib/node_modules/openclaw/dist/extensions/clawtalk` to it on startup. Takes effect on next manager restart. |
| done | Verify Tuwunel health after current docs/ops changes. | Completed 2026-06-03: `docker exec hiclaw-controller curl http://127.0.0.1:6167/_matrix/client/versions` and `https://claw.designflow.app/_matrix/client/versions` both returned 200. |
| deferred | Set up git pull automation on the server. | Decision 2026-06-03: do not auto-pull production scripts without an explicit deployment gate. Keep manual `git pull` unless a safer signed/tagged deployment mechanism is designed. |
| done | Clean up historical `workspace/openclaw.json.clobbered.*` files if disk space is needed. | Completed 2026-06-03: confirmed files were historical May 31/June 1 artifacts and removed 211 files; current count is 0. |
| deferred | Move manager/controller/oauth2-proxy to Coolify. | Only revisit as a planned migration; current keeper model works and is documented. |
<!-- ansible-host-policy: managed rollout from u2giants/ansible -->
## Host / server changes — do NOT make them here

The `hetz` server's host/OS layer is managed by **Ansible** in **[`u2giants/ansible`](https://github.com/u2giants/ansible)**.
To change the server (packages, users, firewall, DNS, Docker *engine* config, system cron,
systemd units, Cloudflare Tunnel 1, the backup watchdog), **open a PR there** and let CI apply
it — **never** SSH into the box and hand-edit it. Manual changes are drift and get reverted by
the next apply. See [`u2giants/ansible/AGENTS.md`](https://github.com/u2giants/ansible/blob/main/AGENTS.md).

This repo is **not** the host layer. Its own changes belong here and deploy through their normal
pipeline (e.g. Coolify). Don't put host-level changes here, and don't manage this service's
container with Ansible. Scope boundary: **Ansible owns the host; Coolify owns the apps.**