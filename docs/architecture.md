# Architecture

## Scope

This repo is a host-ops wrapper around a running HiClaw deployment. It does not build or publish the main HiClaw application. It owns one Docker image (`novnc-desktop`), the host scripts and cron jobs that make a specific deployment behave correctly across restarts and container recreations, and the OAuth2 proxy sidecar.

## Component Map

### hiclaw-controller

- Image: `higress-registry.cn-hangzhou.cr.aliyuncs.com/higress/hiclaw-embedded:v1.1.0` (Alibaba/Higress, not owned by this repo)
- Runs (via supervisord):
  - `kube-apiserver` and `etcd` — embedded Kubernetes control plane
  - `hiclaw-controller` binary — ManagerReconciler, MinIO sync push, config template reconciliation
  - MinIO (ports 9000/9001) — object storage for workspace sync
  - Higress (Envoy-based AI gateway) and `higress-console` (Java)
  - Tuwunel — Matrix homeserver (port 6167)
  - nginx — serves Element Web (port 8088), manager-console proxy (port 18888), WASM plugin server (port 8002)
- Volume: `/var/lib/docker/volumes/hiclaw-data/_data` → `/data` (MinIO lives at `/data/minio/`)
- Bind mounts:
  - `/worksp/hiclaw/workspace` → `/root/hiclaw-fs/agents/manager`
  - `/var/run/docker.sock` → `/var/run/docker.sock`
- Networks: `hiclaw-net`, `coolify` (Traefik access)
- Traefik routes:
  - `control.claw.designflow.app` → hiclaw-controller:18888 (manager console, via oauth2-proxy)
  - `claw.designflow.app` → hiclaw-controller:8088 (Element Web, via oauth2-proxy)

### hiclaw-manager

- Image: `higress-registry.cn-hangzhou.cr.aliyuncs.com/higress/hiclaw-manager:v1.1.0` (Alibaba/Higress, not owned by this repo)
- Runs: OpenClaw gateway (Node.js), agent process
- `HICLAW_RUNTIME=k8s` — confirmed active; this affects startup sync behavior (see below)
- `HICLAW_MANAGER_RUNTIME=openclaw`
- OpenClaw binary locations:
  - Base image: `/opt/openclaw/` (version 2026.4.14, built into image)
  - After "Update now": `/usr/lib/node_modules/openclaw/` (npm global install)
  - Active symlink: `/usr/local/bin/openclaw` — patched by startup script to prefer the npm-installed version if present, otherwise falls back to `/opt/openclaw/`
- Bind mounts:
  - `/worksp/hiclaw/workspace` → `/root/manager-workspace`
  - `/home/ai` → `/host-share`
- Networks: `hiclaw-net`, `coolify`
- Traefik route: `gateway.claw.designflow.app` → hiclaw-manager:18799 (OpenClaw gateway, via oauth2-proxy)

### novnc-desktop

- Image: `ghcr.io/u2giants/novnc-desktop:latest` (only image built in this repo)
- Runs: Chrome, noVNC, CDP proxy (`cdp_proxy.py` bridges Chrome 9222 → 9223)
- Static IP `10.0.5.4` on network `e10kwzww46ljhrgz1qj08j6a`
- Managed manually — not in Coolify

### oauth2-proxy

- Provider: Google OAuth direct (`--provider=google`)
- Protects `control.claw.designflow.app`, `gateway.claw.designflow.app`, and `claw.designflow.app` (Element Web)
- Redirect URI: `https://control.claw.designflow.app/oauth2/callback` (registered in Google Cloud Console)
- Cookie domain: `claw.designflow.app` and `*.claw.designflow.app`
- Permit list: `oauth2-proxy/allowed-emails.txt`
- Credentials: `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` in `oauth2-proxy/.env` (not committed)

## Critical Mount Relationship

Both containers share the same host directory via different bind-mount paths:

```
Host: /worksp/hiclaw/workspace/
  └── mounted as /root/manager-workspace/           in hiclaw-manager
  └── mounted as /root/hiclaw-fs/agents/manager/   in hiclaw-controller
```

This means edits to the workspace by either container are immediately visible to the other. `workspace/openclaw.json` has three concurrent writers: the controller reconciler, the gateway, and `manager-config-keeper.sh`.

## Data Flows

### Manager startup (HICLAW_RUNTIME=k8s)

`HICLAW_RUNTIME=k8s` is the active mode. The k8s startup block in `start-manager-agent.sh` runs on **every container start**:

1. Configures `mc` alias pointing to the controller's MinIO (`http://hiclaw-controller:9000`)
2. Pulls MinIO `hiclaw/hiclaw-storage/manager/` → `/root/manager-workspace/` (the workspace)
3. Pulls MinIO `hiclaw/hiclaw-storage/` → `/root/hiclaw-fs/` (container-internal)
4. Creates symlink `/root/manager-workspace/hiclaw-fs` → `/root/hiclaw-fs`

Step 2 is the most dangerous step — see [MinIO sync safety](#minio-sync-safety).

After the pull, the manager:
- Fetches OpenRouter `/v1/models` and updates `openclaw.json` `contextWindow`/`maxTokens` for any model whose ID exactly matches an OpenRouter model ID. Pushes the updated config back to MinIO immediately so the background MinIO→local sync does not overwrite it.
- Patches `/usr/local/bin/openclaw` symlink to prefer `/usr/lib/node_modules/openclaw/` (npm-installed) if present, otherwise `/opt/openclaw/`
- Writes the current openclaw package hash to `/root/manager-workspace/.openclaw-startup-pkg-hash` (host-visible via bind mount at `/worksp/hiclaw/workspace/.openclaw-startup-pkg-hash`)
- Bootstraps ClawTalk (creates bundled shim, clears `installs.json`)
- Patches `openclaw.json` (sets `commands.restart = true` for initial gateway reload)
- Starts the OpenClaw gateway

### Controller's role in MinIO sync

The controller's internal ManagerReconciler (proprietary code) pushes workspace content to MinIO `hiclaw/hiclaw-storage/manager/` periodically. Since it sees the workspace as `/root/hiclaw-fs/agents/manager/`, whatever is in the workspace at that path gets uploaded.

**This is the push side of a bidirectional sync.** The manager pulls on startup; the controller pushes periodically. If the workspace contains a `hiclaw/hiclaw-storage/` subdirectory (from a previous pull), the push creates a recursive path in MinIO.

### Config stabilization

1. Controller reconciliation writes its template to `workspace/openclaw.json` every ~5 minutes, including `channels.matrix.groups.*: {allow: true}` (invalid schema) and a non-empty `commands` object.
2. The gateway skips the reload due to the invalid `allow` field.
3. `manager-config-keeper.sh` (runs every minute via cron) detects the drift, migrates `allow → enabled`, normalizes `commands: {}`, and syncs `config-health.json` so observe-recovery does not revert the fix.
4. The gateway applies a hot reload (no restart, no dropped connections).

### OpenClaw update mechanism

1. Admin clicks "Update now" in the Control UI.
2. OpenClaw runs `openclaw update` in-process, which executes `npm install -g openclaw@latest` and installs the new version to `/usr/lib/node_modules/openclaw/`.
3. `manager-bootstrap-keeper.sh` (runs on the host) detects a hash mismatch between `/usr/lib/node_modules/openclaw/package.json` (or `/opt/openclaw/package.json` if npm path absent) and `/worksp/hiclaw/workspace/.openclaw-startup-pkg-hash`.
4. The keeper recreates the hiclaw-manager container.
5. On restart, `start-manager-agent.sh` patches the `/usr/local/bin/openclaw` symlink to the npm-installed version and records the new hash.

### Controller Element Web startup

1. `hiclaw-controller` runs `start-element-web.sh` (host-owned, injected by `controller-bootstrap-keeper.sh`) as the supervisord Element Web component.
2. The script generates into `/opt/element-web/`:
   - `config.json` — Element Web homeserver config
   - `browser-bypass.js` — suppresses the "unsupported browser" banner
   - `auto-login.js` — Google SSO auto-login bridge (see [Google SSO Auto-Login](#google-sso-auto-login))
   - `auth-ui-tweaks.js` — styles SSO button; auto-skips E2E verification prompts
   - `control-panel-btn.js` — injects the Control Panel link button
   - `new-chat-btn.js` — injects the + New Chat button
   - `hiclaw-chat-api.py` — Python HTTP helper on `127.0.0.1:8091`
3. It clears any stale nginx master (prevents crash-loop on ports `8088`/`18888`/`8002`), starts `hiclaw-chat-api.py`, then starts nginx in the foreground.
4. nginx injects all `.js` files above via `sub_filter` into every HTML response. The manager-console proxy uses `resolver 127.0.0.11 valid=10s; set $upstream hiclaw-manager;` (Docker DNS) rather than a hardcoded IP, so it survives container recreation without stale IP errors. nginx proxies:
   - `/hiclaw-api/session` → Python helper `/session` (Matrix session credentials for auto-login)
   - `/hiclaw-api/new-chat` → Python helper `/new-chat`
   - `/hiclaw-api/matrix-auth` → Python helper `/matrix-auth` (legacy login-token flow, unused by auto-login)
   - `/hiclaw-api/healthz` → Python helper `/healthz`
   - Element Web itself on port 8088
   - Manager console (hiclaw-manager:18799, auto-token-injected) on port 18888
   - WASM plugins on port 8002

### New Chat workflow

1. Admin clicks "+ New Chat" in Element Web.
2. Browser POSTs `{ name }` to `/hiclaw-api/new-chat` (proxied to `hiclaw-chat-api.py`).
3. Python helper logs in as admin, creates a `trusted_private_chat` room with `@manager` invited, sends the initial `@mention` message.
4. Browser polls the room list until it finds the new room and focuses it.

### Google SSO Auto-Login

**Context:** This is a solved problem that took significant effort to get right. The design is non-obvious. Do not change it without reading this section.

#### The double-login problem

oauth2-proxy gates every web-facing service with Google OAuth. After passing that gate, the user lands on Element Web — which is a Matrix client and requires a separate Matrix account login. Without auto-login, the user must authenticate twice: once with Google, and once with a Matrix username/password.

Previously this was solved by routing both auth layers through Authentik (an OIDC identity provider). Authentik maintained a session after the first Google login, so when Element Web's SSO flow redirected to Authentik a second time, Authentik recognized the session and returned the user to Element already authenticated. Switching to direct Google OAuth (bypassing Authentik) broke this — there is no shared session for Element's SSO to tap.

#### The solution: localStorage session injection

`auto-login.js` is injected into every Element Web HTML response (via nginx `sub_filter`). On page load it:

1. Checks `localStorage` for an existing Matrix session (`mx_access_token` + `mx_user_id`). If both exist, exits immediately — the user is already logged in.
2. POSTs to `/hiclaw-api/session` — the Python helper does a Matrix password login with a **fixed `device_id` of `hiclaw_web_auto`** and returns `{access_token, user_id, device_id}`.
3. Writes 7 keys into `localStorage`:

   | Key | Value |
   |-----|-------|
   | `mx_hs_url` | `window.location.origin` |
   | `mx_access_token` | access token from step 2 |
   | `mx_user_id` | Matrix user ID |
   | `mx_device_id` | `hiclaw_web_auto` |
   | `mx_is_guest` | `false` |
   | `mx_has_access_token` | `true` |
   | `mx_has_pickle_key` | `false` |

4. Calls `window.location.replace('/')` — navigates to `/` with no query params.

Element Web starts, finds the pre-populated `localStorage`, and enters its **restore-session code path** (`loadSession()`) rather than its **fresh-login code path** (`onLoggedIn()` → `postLoginSetup()`). The restore path does not trigger the cross-signing verification screen.

#### Why not `/?loginToken=<token>`

This was tried first (and failed three separate ways):

1. **Wrong location for token:** Element 1.12.10 reads `loginToken` from `window.location.search` (real query string), not the hash fragment. Putting it in `/#/login?loginToken=...` was silently ignored.
2. **Missing homeserver in storage:** When `loginToken` is in the query string, Element calls `trySsoLogin()` which reads the homeserver URL from `localStorage.getItem('mx_sso_hs_url')`. Without that key, it shows "browser has forgotten which homeserver you use."
3. **Cross-signing verification screen:** Even after both fixes above, Element exchanged the token and called `postLoginSetup()`. The admin account has cross-signing keys set up, so `userHasCrossSigningKeys()` returned true and Element showed "Confirm your identity / Verify this device."

The verification screen has no "skip" button — only "Use another device", "Can't confirm?", and "Sign out". "Can't confirm?" opens a **reset identity** dialog, not a skip. Attempting to auto-click through it caused a MutationObserver feedback loop that froze the browser. The root cause: every `loginToken` exchange creates a new Matrix device (no `device_id` is specified), and Element asks to verify every new device against the cross-signing trust chain.

#### Why the fixed device_id matters

Password login with a fixed `device_id` (`hiclaw_web_auto`) either creates that device (first time) or reissues an access token for the existing device (every subsequent time). The homeserver keeps the device record; Element treats it as a known session. Since the device is never "new", the cross-signing verification screen never appears after the first login.

On the first-ever login (e.g., on a fresh server), the device is created and Element will show the verification screen once. After that, every login reuses the existing device and goes straight to the chat.

#### Session lifecycle

- **Incognito / cleared localStorage:** `auto-login.js` fires, fetches a fresh access token for `hiclaw_web_auto`, writes localStorage, navigates to `/`. The previous access token for that device is invalidated on the homeserver.
- **Existing session:** `auto-login.js` exits at step 1 without any network request.
- **Invalidated token (soft logout):** Element detects the 401, clears its own session, and redirects to the login screen. `auto-login.js` fires on the next page load and re-authenticates.

#### What this is NOT

This auto-login is for a single-admin personal deployment. Everyone in `oauth2-proxy/allowed-emails.txt` gets logged into the same Matrix admin account. This design is correct for the current deployment and must not be extended to multi-user without rethinking the entire auth model.

### Matrix DM routing

`session.dmScope = "main"` in `openclaw.json` (enforced by `manager-config-keeper.sh`) collapses all Matrix direct messages into the same `agent:main:main` session used by OpenClaw web chat. This is intentional for the single-admin deployment model — both UIs stay in sync. Separate HiClaw conversations should be new Matrix rooms, not new DMs.

## MinIO Sync Safety

**The most dangerous failure mode in this codebase.** Read this before touching any `mc mirror` call.

### What the recursion looks like

```
MinIO bucket: hiclaw-storage
Object key prefix: manager/
Physical path: /var/lib/docker/volumes/hiclaw-data/_data/minio/hiclaw-storage/manager/

Healthy state:
  manager/openclaw.json
  manager/AGENTS.md
  manager/skills/...
  manager/memory/...

Recursive (broken) state:
  manager/hiclaw/hiclaw-storage/manager/openclaw.json
  manager/hiclaw/hiclaw-storage/manager/hiclaw/hiclaw-storage/manager/openclaw.json
  ...  (grows one level per startup cycle)
```

### How the loop forms

1. Manager startup pulls `hiclaw/hiclaw-storage/manager/` → workspace. If MinIO already has `manager/hiclaw/hiclaw-storage/` from a previous cycle, the workspace now contains `hiclaw/hiclaw-storage/` as a subdirectory.
2. Controller's ManagerReconciler pushes workspace → `hiclaw/hiclaw-storage/manager/`, uploading the nested copy.
3. Repeat: each startup adds one more nesting level.

### The guard

`start-manager-agent.sh` adds `--exclude` flags to the k8s startup pull:

```bash
mc mirror "${HICLAW_STORAGE_PREFIX}/manager/" /root/manager-workspace/ --overwrite \
    --exclude "hiclaw/*" \
    --exclude "hiclaw-fs" \
    --exclude "*.clobbered.*" \
    --exclude ".npm/*" \
    --exclude ".codex/*" \
    --exclude ".cache/*"
```

**Do not remove these exclusions.** They are the fix for the incident that caused a server crash on 2026-05-20.

### Detection

Run after every container startup:

```bash
sudo find /var/lib/docker/volumes/hiclaw-data/_data/minio/hiclaw-storage \
  -maxdepth 8 -type d -name "hiclaw-storage" -print
# Healthy: prints only the root path
# Broken:  prints multiple lines (stop containers immediately)

ls /worksp/hiclaw/workspace/hiclaw/ 2>/dev/null \
  && echo "WARNING: recursion seed in workspace" \
  || echo "OK"
```

### Recovery

```bash
docker stop hiclaw-manager hiclaw-controller

# Remove recursion seed from workspace
sudo rm -rf /worksp/hiclaw/workspace/hiclaw/
sudo rm -f /worksp/hiclaw/workspace/hiclaw-fs

# Remove recursive objects from MinIO (everything under manager/hiclaw/)
# Use mc from inside a temporary container with MinIO access:
#   mc rm --recursive hiclaw/hiclaw-storage/manager/hiclaw/

# Restart in staged order
docker start hiclaw-controller
sleep 20
sudo find /var/lib/docker/volumes/hiclaw-data/_data/minio/hiclaw-storage \
  -maxdepth 4 -type d -name "hiclaw-storage" -print   # must show root only
docker start hiclaw-manager
sleep 30
# Repeat the find check above
```

## openclaw.json.clobbered.* Files

Files named `workspace/openclaw.json.clobbered.<timestamp>` are created by OpenClaw's observe-recovery mechanism when it detects a config hash mismatch. They are runtime noise from when the controller wrote an invalid config template and the keeper fixed it back — OpenClaw interpreted the keeper's write as an external "clobber". Accumulation of hundreds of these files was a symptom of the resolved 5-minute restart loop (Incident 2 in AGENTS.md).

These files are pushed to MinIO as `manager/openclaw.json.clobbered.*` and accumulate there too. The startup pull `--exclude "*.clobbered.*"` prevents them from being restored to the workspace. Stale ones can be deleted from both locations safely.

## What We Do Not Own

- `hiclaw-controller` and `hiclaw-manager` image contents — managed by Alibaba/Higress
- MinIO data model and reconciliation logic inside the controller
- The OpenClaw gateway (`/usr/lib/node_modules/openclaw/`) — updated in-container by OpenClaw's own "Update now" flow
- Tuwunel Matrix homeserver internal state at `/data/tuwunel/`

## Intentional Behaviors That Look Wrong

- **`start-manager-agent.sh` patches files inside a running container.** The keeper copies it into new containers on each recreation — this is the intended persistence boundary.
- **`commands.restart = true` on startup, then `{}` during operation.** Setting `true` triggers the gateway's initial reload. The keeper then normalizes to `{}` so the controller's periodic template writes (which include `commands: {restart:true, ...}`) never appear as a state change and never trigger another restart. See [configuration.md § commands.restart](configuration.md#commandsrestart).
- **`workspace/hiclaw/hiclaw-storage/` must not exist.** If it appears, it is a recursion indicator. Old docs called it a "mirrored artifact" — that framing was wrong; it is a bug artifact.
- **`fix-element-config.sh` installs ephemeral patches inside containers.** The npm wrapper, mc wrapper, and some nginx config written by this script live only until the next container recreation. The persistent versions are delivered by `start-element-web.sh` (controller) and `start-manager-agent.sh` (manager) via the bootstrap keepers.
- **`session.dmScope = "main"` is forced.** Multiple DMs with the same manager bot would create isolated per-channel sessions that never share context. The single-admin model intentionally avoids that by routing everything through `agent:main:main`.
- **nginx stale master cleanup in `start-element-web.sh`.** The controller can retain an old daemonized nginx master across patching cycles. A second nginx instance causes Element Web to crash-loop on port conflicts. The cleanup runs on every controller startup to prevent this.
- **nginx manager-console proxy uses Docker DNS resolver, not a hardcoded IP.** Docker reassigns container IPs on recreation. Using `resolver 127.0.0.11 valid=10s; set $upstream hiclaw-manager;` ensures nginx re-resolves on each request rather than caching a stale IP.
- **OpenRouter model sync writes to a file, not a shell variable.** The API response for all models is large enough to exceed shell argument length limits ("Argument list too long"). The startup script writes the response to a temp file and reads from it with `jq`.
- **OpenRouter sync pushes config back to MinIO immediately.** The background MinIO→local sync starts seconds after startup. Without the push, the background sync would pull the old config from MinIO and overwrite the freshly-updated `openclaw.json`.
