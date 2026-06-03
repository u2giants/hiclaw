# Architecture

## 1. System Overview

HiClaw is a personal AI agent orchestration platform running on a single dedicated Linux server (`178.156.180.212`). The owner (Albert) interacts with an AI agent exclusively through a Matrix/Element chat interface. The agent receives natural-language tasks, executes them using a cloud LLM (DeepSeek via OpenRouter), and automates a live Chrome browser for web tasks using Chrome DevTools Protocol (CDP).

This repository does not contain the HiClaw application itself. It owns:
- One Docker image (`novnc-desktop`) that provides a browser-in-a-box via noVNC
- Host-side keeper scripts that maintain container state across restarts
- OAuth2 proxy configuration that gates all web-facing services with Google login
- Traefik dynamic routing configuration

The HiClaw controller and manager images are maintained by Alibaba/Higress and are not built from this repository.

---

## 2. Component Diagram

```
Browser (Albert's laptop)
        |
        v  HTTPS (443)
  coolify-proxy (Traefik v3.6)
        |
        |-- /oauth2/*  ---> oauth2-proxy:4180 (Google OAuth callbacks, no auth)
        |
        +-- claw.designflow.app  ---[google-auth]---> hiclaw-controller:8088
        |   (Element Web, excl /_matrix)                    |
        |                                                   | nginx sub_filter
        |                                                   | injects JS bundles
        |                                                   v
        |                                          Element Web SPA
        |                                          auto-login.js --> POST /hiclaw-api/session
        |                                                              |
        |                                                              v
        |                                                   hiclaw-chat-api.py :8091
        |                                                   (Matrix password login)
        |
        +-- claw.designflow.app/_matrix  ---> hiclaw-controller:8080
        |   (Matrix homeserver API, no auth)        |
        |                                           v
        |                                      Tuwunel :6167 (Matrix homeserver)
        |
        +-- control.claw.designflow.app  --[google-auth]--> hiclaw-controller:18888
        |   (OpenClaw manager console)                          |
        |                                                       | nginx proxy (Docker DNS resolver)
        |                                                       v
        |                                              hiclaw-manager:18799
        |                                              (OpenClaw gateway)
        |
        +-- gateway.claw.designflow.app  --[google-auth]--> hiclaw-manager:18799
        |   (OpenClaw direct gateway access)
        |
        +-- vnc.designflow.app  ---> novnc-desktop:3000
            (noVNC browser view, no auth)

Internal (hiclaw-net) service mesh:
  hiclaw-manager  <-->  hiclaw-controller:8080  (Higress AI gateway, LLM routing)
  hiclaw-manager  <-->  hiclaw-controller:6167  (Tuwunel Matrix homeserver)
  hiclaw-manager  <-->  hiclaw-controller:9000  (MinIO S3 storage)
  hiclaw-manager  <-->  hiclaw-controller:8001  (Higress admin API)

CDP (browser automation):
  hiclaw-manager (10.0.2.3)  ---> novnc-desktop (10.0.5.4):9223
  (Playwright MCP → cdp_proxy.py → Chrome :9222)
```

---

## 3. Container Descriptions

### hiclaw-controller

- **Image:** `higress-registry.cn-hangzhou.cr.aliyuncs.com/higress/hiclaw-embedded:v1.1.2` (Alibaba/Higress)
- **Supervisor:** `supervisord` — not a keeper script
- **Process inventory (inside container):**
  - `kube-apiserver` + `etcd` — embedded Kubernetes control plane used by the reconciler for state storage
  - `hiclaw-controller` binary — ManagerReconciler, config template reconciliation, MinIO push
  - MinIO (`:9000` S3 API, `:9001` console) — primary workspace sync storage
  - Higress (Envoy-based AI gateway, `:8080`) — routes LLM requests from manager to OpenRouter
  - `higress-console` (Java, `:8001`) — Higress admin API
  - Tuwunel (`:6167`) — Matrix homeserver (conduwuit fork) for agent messaging
  - nginx (`:8088` Element Web, `:18888` manager console proxy, `:8002` WASM plugin server)
  - `start-element-web.sh` — generates Element Web config and nginx configs on every start
  - `start-tuwunel.sh` — configures and starts Tuwunel on every start
  - `hiclaw-chat-api.py` — Python HTTP helper (`:8091`) for auto-login and new-chat
- **Volumes:**
  - `/var/lib/docker/volumes/hiclaw-data/_data` → `/data` (MinIO data, Tuwunel RocksDB)
  - `/worksp/hiclaw/workspace` → `/root/hiclaw-fs/agents/manager` (shared workspace, read by reconciler)
  - `/var/run/docker.sock` → `/var/run/docker.sock` (used to recreate worker containers)
- **Networks:** `hiclaw-net` (10.0.2.0/24), `coolify` (Traefik access)
- **Host port bindings:** `:18001` → 8001, `:18080` → 8080, `:18088` → 8088
- **Managed by:** `controller-bootstrap-keeper.sh` (host cron)
- **Resource limits:** 3g RAM, 4g swap (total RAM+swap), 2 CPUs, 1024 PIDs (applied by keeper on each patch cycle)

### hiclaw-manager

- **Image:** `higress-registry.cn-hangzhou.cr.aliyuncs.com/higress/hiclaw-manager:v1.1.2` (Alibaba/Higress)
- **Process:** OpenClaw gateway (`exec openclaw gateway run --verbose --force`) — Node.js, single process
- **Runtime modes:**
  - `HICLAW_RUNTIME=k8s` — enables MinIO sync on startup, affects init paths
  - `HICLAW_MANAGER_RUNTIME=openclaw` — uses OpenClaw as the agent runtime
- **OpenClaw binary locations:**
  - Base image: `/opt/openclaw/` (version 2026.4.14)
  - After update: `/usr/lib/node_modules/openclaw/` (npm global install, version 2026.5.28 currently)
  - Active symlink: `/usr/local/bin/openclaw` — set by startup script; prefers npm-installed version if valid (json5 + openai/index.mjs checks), otherwise falls back to base image
- **Volumes:**
  - `/worksp/hiclaw/workspace` → `/root/manager-workspace` (shared workspace, OpenClaw config lives here)
  - `/home/ai` → `/host-share`
- **Networks:** `hiclaw-net` (10.0.2.3)
- **Host port binding:** `127.0.0.1:18888` → 18799 (OpenClaw gateway, loopback only)
- **Managed by:** `manager-bootstrap-keeper.sh` (host cron)
- **Resource limits:** 1536m RAM, 3g swap (total RAM+swap), 1 CPU
  - Swap headroom is required for `npm install` during openclaw updates, which peaks well above 768m

### novnc-desktop

- **Image:** `ghcr.io/u2giants/novnc-desktop:latest` (built from this repo)
- **Contents:** Chrome browser, noVNC server, `cdp_proxy.py` (WebSocket bridge Chrome :9222 → :9223)
- **Static IP:** `10.0.5.4` on network `e10kwzww46ljhrgz1qj08j6a` — hardcoded because hiclaw-manager config references this IP as the CDP endpoint
- **Managed by:** `novnc-desktop/recreate.sh` with `--restart unless-stopped`; resource limits re-applied by `novnc-resource-keeper.sh`; not in Coolify
- **Resource limits:** 3g RAM, 4g swap (total RAM+swap), 2 CPUs, 250 PIDs
- **Purpose:** provides a live Chrome browser for CDP/Playwright-based browser automation tasks

### coolify-proxy (Traefik)

- **Image:** `traefik:v3.6`
- **Role:** TLS termination, HTTP→HTTPS redirect, OAuth2 middleware forwarding, routing to all internal services
- **Dynamic config:** `/data/coolify/proxy/dynamic/claw.yml` (copy at `traefik/claw.yml` in repo)
- **Auth middleware:** `forwardAuth` to `oauth2-proxy:4180`; passes `X-Auth-Request-User` and `X-Auth-Request-Email` headers to backends

### oauth2-proxy

- **Image:** `quay.io/oauth2-proxy/oauth2-proxy:latest`
- **Provider:** Google OAuth2 direct
- **Protected services:** `claw.designflow.app` (Element Web), `control.claw.designflow.app` (OpenClaw console), `gateway.claw.designflow.app`
- **Unprotected:** `/_matrix` and `/_synapse` paths (Matrix protocol), `/oauth2/*` callbacks, `vnc.designflow.app`
- **Allowlist:** `oauth2-proxy/allowed-emails.txt`
- **Managed by:** `oauth2-proxy/docker-compose.yml`

---

## 4. Network Topology

```
Network: hiclaw-net (57389449a3a0, bridge, 10.0.2.0/24)
  hiclaw-controller  10.0.2.x  (assigned dynamically)
  hiclaw-manager     10.0.2.3

Network: coolify (d4b3e6b3b0cf, bridge)
  coolify-proxy (Traefik)
  hiclaw-controller  (for Traefik to reach :18888, :18080, :18088)
  oauth2-proxy

Network: e10kwzww46ljhrgz1qj08j6a (bridge, 10.0.5.0/24)
  novnc-desktop  10.0.5.4  (static, CDP endpoint)
  (hiclaw-manager was previously on this network for Playwright MCP access;
   re-add with: docker network connect e10kwzww46ljhrgz1qj08j6a hiclaw-manager)
```

**Key addressing notes:**
- `hiclaw-manager` references the CDP endpoint at `10.0.5.4:9223` in `openclaw.json` `mcp.servers.browser`. This IP is static by `--ip 10.0.5.4` in the `docker run` command.
- `hiclaw-controller` is referenced by name (`hiclaw-controller`) from manager, resolved via Docker DNS on `hiclaw-net`.
- The nginx manager-console proxy in hiclaw-controller uses `resolver 127.0.0.11` (Docker DNS) and stores the upstream as `set $upstream hiclaw-manager`, forcing re-resolution on every request. This is required because hiclaw-manager's IP on hiclaw-net changes each time the container is recreated.
- Traefik routes `control.claw.designflow.app` to `hiclaw-controller:18888`. Port 18888 on the controller is nginx, which proxies to `hiclaw-manager:18799` via Docker DNS.
- `hiclaw-manager` internal port 18799 is bound to `127.0.0.1:18888` on the host — not the container named `hiclaw-controller`. These are different entities sharing the port number for historical reasons.

---

## 5. Data Flows

### 5.1 Matrix message becomes an AI response

```
Albert types in Element Web (claw.designflow.app)
  → POST to Tuwunel /_matrix/client/v3/rooms/.../send (via claw.designflow.app/_matrix route)
  → Tuwunel stores message in RocksDB, pushes sync event
  → hiclaw-manager Matrix channel plugin receives sync event via long-poll
  → OpenClaw gateway routes to active agent session (agent:main:main)
  → Agent calls LLM: POST http://aigw-local.hiclaw.io:8080/v1/chat/completions
       (aigw-local.hiclaw.io resolves to hiclaw-controller inside hiclaw-net)
  → Higress (Envoy) applies AI plugin (auth, retry, model routing)
  → Higress forwards to OpenRouter https://openrouter.ai/api/v1
  → OpenRouter calls DeepSeek/deepseek-v4-pro
  → Response streams back through Higress → OpenClaw → Matrix channel plugin
  → POST to Tuwunel to send reply message
  → Element Web receives reply via sync
```

For browser automation tasks, the agent additionally:
```
  Agent calls Playwright MCP tool
  → OpenClaw MCP client connects to http://10.0.5.4:9223 (CDP endpoint)
  → cdp_proxy.py on novnc-desktop bridges to Chrome :9222
  → Chrome executes the automation
```

### 5.2 openclaw.json config change flow

`openclaw.json` is a live config file with three concurrent writers:

```
Writer 1: hiclaw-controller ManagerReconciler
  - Runs every ~47 seconds
  - Writes its template values (model list, commands.restart=true, channels config)
  - Can write invalid schema (channels.matrix.groups.*.allow instead of .enabled)
  - Can write null for fields the manager added (YOLO settings, tool config)

Writer 2: OpenClaw gateway (hiclaw-manager)
  - Writes on config-change events (plugin state, runtime settings)
  - Writes config-health.json to track "last known good" hash

Writer 3: manager-config-keeper.sh (host cron, every ~60s)
  - Normalizes schema issues from Writer 1
  - Enforces invariants (bootstrapMaxChars, contextWindow, clawtalk entry)
  - Defeats observe-recovery by updating config-health.json with new hash
  - Atomic write to prevent partial-read by the gateway file watcher

Flow on a typical reconciler cycle:
  1. Reconciler writes openclaw.json with commands.restart=true, allow keys, possibly bad model data
  2. Gateway file watcher fires → SIGUSR1 → in-process restart (due to commands change)
  3. keeper runs: normalizes allow→enabled, restores commands to {"restart": true}, updates config-health.json
  4. Gateway file watcher fires again → hot reload only (no restart, no SIGUSR1)
```

**Why `commands.restart` must stay true:**
The gateway diffs live config changes against the startup baseline recorded in `config-health.json`. In the current stable state, that baseline expects `commands.restart=true`. The controller reconciler periodically writes `commands:null`; the keeper writes `{"restart": true}` back so the next diff matches the baseline and does not trigger a restart loop.

### 5.3 Manager startup sequence

On every container start, `start-manager-agent.sh` runs as the container entrypoint:

1. **Wait for dependencies** — polls Higress (:8080, :8001), Tuwunel (:6167), MinIO (:9000)
2. **Load secrets** — reads `/data/hiclaw-secrets.env`; auto-generates and persists `MANAGER_GATEWAY_KEY` and `MANAGER_PASSWORD` if absent
3. **MinIO pull (k8s mode)** — `mc mirror hiclaw/hiclaw-storage/manager/ /root/manager-workspace/` with exclusions to prevent recursion
4. **Workspace versioning** — checks `.builtin-version`; runs `upgrade-builtins.sh` on version change
5. **Matrix account setup** — registers admin + manager accounts (idempotent), obtains access token
6. **Higress initialization** — registers Matrix and Element Web service sources, creates LLM provider and AI route
7. **DM room creation** — finds or creates the admin DM room; on first boot schedules a welcome message
8. **openclaw.json update** — jq merge of known models, model metadata sync from OpenRouter, Matrix token update, schema migrations, `del(.pricing)` cleanup, push back to MinIO
9. **OpenRouter model sync** — writes API response to `/tmp/openrouter-models.json` (file, not variable, to avoid arg-length limits), updates contextWindow/maxTokens for matching models
10. **MinIO push** — immediately pushes updated `openclaw.json` to MinIO to prevent background sync from overwriting fresh values
11. **ClawTalk bootstrap** — patches plugin manifest, creates bundled shim at `/usr/lib/node_modules/openclaw/dist/extensions/clawtalk/`, clears `installs.json`
12. **WhatsApp bootstrap** — installs `@openclaw/whatsapp` if absent, ensures config entries
13. **Fake systemd-run install** — writes `/usr/local/bin/systemd-run` wrapper
14. **openclaw validation** — checks npm-installed openclaw for `json5/package.json` AND `openai/index.mjs`; removes broken install and falls back to `/opt/openclaw/` if either is missing
15. **Hash recording** — writes openclaw package.json hash to `.openclaw-startup-pkg-hash`
16. **`exec openclaw gateway run`** — replaces the shell process

### 5.4 Google SSO auto-login flow

After passing Google OAuth via oauth2-proxy, the user's browser loads Element Web. `auto-login.js` (injected by nginx `sub_filter`) intercepts the page load:

1. Checks `localStorage` for `mx_access_token` + `mx_user_id`. If present, exits — already logged in.
2. POSTs to `/hiclaw-api/session` → `hiclaw-chat-api.py` → Matrix password login with `device_id=hiclaw_web_auto` (fixed, not random)
3. Writes 7 `mx_*` keys into `localStorage` directly
4. Calls `window.location.replace('/')` — triggers Element's restore-session path, which skips cross-signing verification

Using `loginToken` URL parameter was tried and abandoned: it creates a new Matrix device each time, which triggers Element's "verify this device" cross-signing screen with no usable skip path. The fixed `device_id` approach reuses the same device record, making every login appear as a session restore rather than a new login.

---

## 6. Storage

### Shared workspace volume

```
Host path:  /worksp/hiclaw/workspace/
Manager:    /root/manager-workspace/          (read/write — OpenClaw config, state, skills)
Controller: /root/hiclaw-fs/agents/manager/  (read/write — reconciler pushes this to MinIO)
```

Both containers see the same files simultaneously. Key files:

| File | Written by | Read by |
|------|-----------|---------|
| `openclaw.json` | manager startup, reconciler, keeper, gateway | gateway (live watch), keeper |
| `openclaw.json.bak` | observe-recovery | observe-recovery (restore trigger) |
| `openclaw.json.bak.[1-4]` | keeper (rotating backup) | keeper |
| `.openclaw-startup-pkg-hash` | manager startup | manager-bootstrap-keeper.sh |
| `.openclaw-update-requested` | fake systemd-run (in container) | manager-bootstrap-keeper.sh (host) |
| `.openclaw/logs/config-health.json` | gateway, keeper | gateway (observe-recovery), keeper |
| `state.json` | manager startup (DM room ID) | manager |
| `memory/` | agent memory writes | agent reads |
| `skills/` | upgrade-builtins.sh | agent |

### MinIO object storage

- **Endpoint:** `http://hiclaw-controller:9000` (from manager), `http://127.0.0.1:9000` (from controller)
- **Bucket:** `hiclaw-storage`
- **Key prefix:** `hiclaw/hiclaw-storage/`
- **Relevant paths:**
  - `manager/openclaw.json` — synced copy of workspace openclaw.json
  - `manager/skills/` — agent skill definitions
  - `manager/memory/` — agent memory files
  - `manager/openclaw.json.clobbered.*` — forensic copies from truncation events
  - `credentials/matrix/password` — worker Matrix passwords (uploaded by startup script)
- **Data directory on host:** `/var/lib/docker/volumes/hiclaw-data/_data/minio/`

### Persistent host paths

| Path | Contents | Survives |
|------|----------|---------|
| `/worksp/hiclaw/workspace/` | Runtime state, openclaw config | Container recreation (bind mount) |
| `/var/lib/docker/volumes/hiclaw-data/` | MinIO data, Tuwunel RocksDB | Container recreation (named volume) |
| `/data/hiclaw-secrets.env` | Auto-generated manager credentials | Reboots (host file) |
| `/data/worker-creds/<name>.env` | Worker Matrix passwords | Reboots (host file) |
| `/worksp/hiclaw/.state/` | Keeper last-container-ID tracking | Reboots (git-ignored) |

---

## 7. Update Mechanism

### Normal flow (via Control UI "Update now")

```
1. Admin clicks "Update now" in control.claw.designflow.app
2. OpenClaw calls update.run in-process
3. Because OPENCLAW_SYSTEMD_UNIT=openclaw-gateway is set, openclaw follows
   managed-service-handoff path → calls /usr/local/bin/systemd-run
4. Fake systemd-run writes /root/manager-workspace/.openclaw-update-requested
   (host-visible as /worksp/hiclaw/workspace/.openclaw-update-requested)
   and exits 0
5. Gateway thinks handoff started; sends itself SIGUSR1 → in-process restart begins
6. manager-bootstrap-keeper.sh (host cron, ~60s interval) detects marker file:
   a. Removes marker
   b. Runs: docker exec hiclaw-manager openclaw update --yes --json
      (--memory-swap 3g is set via docker update before this step)
   c. Sleeps 30s (allows in-process SIGUSR1 write to complete — prevents truncation)
7. Keeper computes hash of new /usr/lib/node_modules/openclaw/package.json
8. Hash differs from .openclaw-startup-pkg-hash → docker restart hiclaw-manager
9. start-manager-agent.sh validates new install (json5 + openai/index.mjs checks)
10. If valid: symlinks /usr/local/bin/openclaw → /usr/lib/node_modules/openclaw/
    If invalid: removes broken install, symlinks to /opt/openclaw/ (base image)
11. New hash written to .openclaw-startup-pkg-hash
```

**Why the 30s sleep is critical:** The `docker restart` immediately after `openclaw update` killed the container while openclaw was mid-write to `openclaw.json` during its SIGUSR1 in-process restart. This produced consistently truncated config files (8788 bytes vs 9283 bytes complete). The truncation corrupted config on every update cycle. The 30s sleep gives the write time to complete before the container is killed.

### SIGUSR1 in-process restart vs docker restart

| Event | Mechanism | openclaw.json written? | Container killed? |
|-------|-----------|----------------------|------------------|
| Config file change detected by file watcher | SIGUSR1 in-process | Yes (rewrites with current config) | No |
| `openclaw update --yes` | SIGUSR1 in-process | Yes (rewrites with new config) | No |
| Hash mismatch detected by keeper | `docker restart` | No (container is killed) | Yes |
| Manual `docker restart hiclaw-manager` | — | No | Yes |

`OPENCLAW_NO_RESPAWN=1` is set in the environment, which changes openclaw's restart behavior: on SIGUSR1, it restarts in-process (re-requiring all modules) rather than calling `exec` to replace the process. This is required for the fake systemd-run handoff to work correctly, but it means config writes happen mid-restart and are vulnerable to interruption by `docker restart`.

### Keeper orchestration

Host-side keeper scripts maintain container/runtime state:

| Script | Interval | Responsibility |
|--------|----------|---------------|
| `manager-bootstrap-keeper.sh` | ~60s | Sync start-manager-agent.sh into container; apply resource limits; consume update marker; detect version hash change |
| `manager-config-keeper.sh` | ~60s | Normalize openclaw.json; enforce invariants; defeat observe-recovery |
| `controller-bootstrap-keeper.sh` | ~60s | Sync start-element-web.sh and start-tuwunel.sh into controller; apply resource limits; restart if scripts changed |
| `novnc-resource-keeper.sh` | ~60s | Enforce noVNC Docker limits; restart before Chrome memory or PID growth can cause global OOM |
| `mcp-keeper.sh` | ~few min | Ensure mcp.servers.browser (Playwright CDP) is in openclaw.json |

---

## 8. OpenClaw Plugin Architecture

OpenClaw loads plugins from two locations:

1. **Bundled extensions:** `/usr/lib/node_modules/openclaw/dist/extensions/<plugin>/`
2. **Load paths:** `plugins.load.paths` in `openclaw.json` — additional directories scanned for plugin manifests

Plugins are declared in `plugins.entries` (with `enabled`, `apiKey`, `autoConnect` fields) and must appear in `plugins.allow` to be activated.

### Matrix channel plugin

Built into OpenClaw. Configured via `channels.matrix` in `openclaw.json`:
- Connects to Tuwunel at `http://hiclaw-controller:6167`
- Authenticates as `@manager:matrix-local.hiclaw.io:18080`
- Handles DMs from `allowFrom` list (`@admin`, `@manager`)
- `session.dmScope=main` collapses all DMs into `agent:main:main` session

### clawtalk plugin

- **npm package:** `/root/manager-workspace/.openclaw/npm/node_modules/clawtalk/`
- **Problem:** `build/index.js` is an ES module; OpenClaw uses CJS `require()`
- **Fix:** `start-manager-agent.sh` creates a CJS wrapper `index.cjs` that does `const m = require('./build/index.js'); module.exports = m.default || m;` and updates `package.json` to point at `index.cjs`
- **Bundled shim:** also created at `/usr/lib/node_modules/openclaw/dist/extensions/clawtalk/` on every startup
- **installs.json:** deleted on every startup so OpenClaw rescans and finds the shim; without deletion the cached registry predates the shim and reports "plugin not found"
- **This fix is ephemeral** — lives inside the container overlay and is lost on restart; `start-manager-agent.sh` recreates it on every start

### whatsapp plugin

- **npm package:** `@openclaw/whatsapp` — installed at openclaw version if absent
- Configured in `plugins.allow`, `plugins.load.paths`, and `channels.whatsapp`
- `dmPolicy=pairing`, `groupPolicy=allowlist`

### memory-core

Built into OpenClaw. Activated when `memorySearch` is configured in `openclaw.json` with an embedding model (set from `HICLAW_EMBEDDING_MODEL`).

### MCP browser plugin (Playwright)

Not a traditional OpenClaw plugin — configured as `mcp.servers.browser` in `openclaw.json`:
```json
{
  "mcp": {
    "servers": {
      "browser": {
        "command": "npx",
        "args": ["@playwright/mcp", "--cdp-endpoint", "http://10.0.5.4:9223"]
      }
    }
  }
}
```
The OpenClaw gateway strips unknown top-level keys during MinIO sync. `mcp-keeper.sh` re-injects this config when it disappears. `fix-element-config.sh` installs an `mc` wrapper that injects it on every `mc cp` touching `openclaw.json`.

---

## 9. Key Constraints and Design Decisions

### Workspace is a shared mutable file system

The bind mount makes `/worksp/hiclaw/workspace/` visible to both containers and the host simultaneously. Three concurrent writers (`manager-config-keeper.sh`, the controller reconciler, and the OpenClaw gateway) write `openclaw.json` without coordination. The keeper's atomic write + `config-health.json` update is the only synchronization mechanism. This is a known constraint, not a bug to fix.

### hiclaw-manager and hiclaw-controller are not in Coolify

The containers require a shared volume mount (`/worksp/hiclaw/workspace`) that Coolify's compose model does not accommodate for this image version, plus startup-time environment injection and config patching baked into the keeper scripts. Migrating to Coolify would require rewriting the startup logic as compose-compatible entrypoints. This is deferred work.

### openclaw.json reconciler conflicts are structural

The hiclaw-controller ManagerReconciler writes its own template values to `openclaw.json` every ~47 seconds. This behavior is inside the upstream image and cannot be changed. The keeper scripts are the permanent mitigation: they run after the reconciler, normalize the schema, and update `config-health.json` to prevent observe-recovery from reverting the fixes.

### MinIO recursion is a standing hazard

The controller's reconciler pushes the workspace to MinIO. Because the manager's startup pull writes into the same workspace, if the exclusions are removed or circumvented, the workspace will contain a MinIO path that gets pushed back, creating recursive nesting. The `--exclude "hiclaw/*"` guard in `start-manager-agent.sh` is the only thing preventing this. Do not remove it.

### cdp_proxy.py must be edited in-place

`cdp_proxy.py` is bind-mounted into `novnc-desktop`. Docker bind mounts track the inode, not the path. Replacing the file (using Write tool, `cp`, or `mv`) creates a new inode; the container continues reading from the original inode and never sees the update. Always edit using the Edit tool (in-place modification) or `sed -i`.

### commands.restart baseline must stay true

The gateway records its startup config as the baseline in `config-health.json` and triggers SIGUSR1 on any diff against that baseline. The current stable baseline expects `commands.restart=true`. The controller reconciler can write `commands:null`; if that value persists, the next diff triggers a restart loop. `manager-config-keeper.sh` restores `commands` to `{"restart": true}` so live config matches the baseline.

### YOLO settings removed from startup config

Earlier versions of `start-manager-agent.sh` wrote `tools.exec`, `tools.elevated`, and `agents.defaults.elevatedDefault` to `openclaw.json` at startup. The v1.1.2 ManagerReconciler writes `null` for these fields approximately every 47 seconds. This produced a continuous diff → SIGUSR1 → restart loop making control.claw unavailable ~40% of the time. These settings were removed from the startup write; the reconciler baseline now matches the reconciler output.

### Auto-login uses localStorage injection, not loginToken

The `loginToken` URL parameter creates a new Matrix device on every use, triggering Element's cross-signing verification screen. There is no programmatic skip path. The fixed `device_id=hiclaw_web_auto` approach reuses the same device record, bypassing verification entirely after the first login. This is specific to single-admin deployments.

---

## 10. Scope Boundary

**Owned by this repo:**
- `novnc-desktop/` — Docker image (Chrome, noVNC, CDP proxy)
- All `.sh` scripts at repo root — keeper and startup scripts
- `oauth2-proxy/` — auth proxy config
- `traefik/claw.yml` — routing rules

**Not owned (upstream, read-only):**
- `hiclaw-controller` and `hiclaw-manager` images — Alibaba/Higress
- OpenClaw gateway inside hiclaw-manager
- Tuwunel internal state at `/data/tuwunel/`
- MinIO data model and reconciliation logic

**Ephemeral (in-container, lost on restart, recreated by startup scripts):**
- clawtalk `index.cjs` wrapper
- Fake `/usr/local/bin/systemd-run`
- `/usr/local/bin/openclaw` symlink
- ClawTalk bundled shim at `/usr/lib/node_modules/openclaw/dist/extensions/clawtalk/`
- Element Web `config.json`, all injected JS files, nginx configs (regenerated by `start-element-web.sh`)
