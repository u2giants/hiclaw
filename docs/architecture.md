# Architecture

## Scope

This repo is a host-ops wrapper around a running HiClaw deployment. It does not build or publish the main HiClaw application. It owns one Docker image (`novnc-desktop`), the host scripts and cron jobs that make a specific deployment behave correctly across restarts and container recreations, and the OAuth2 proxy sidecar.

## Component Map

### hiclaw-controller

- Image: `higress-registry.cn-hangzhou.cr.aliyuncs.com/higress/hiclaw-embedded:v1.1.0`
- Runs: MinIO (port 9000/9001), Higress console, Envoy, kube-apiserver, Tuwunel Matrix homeserver (port 6167), Element Web (nginx port 8088), manager-console proxy (port 18888)
- Volume: `/var/lib/docker/volumes/hiclaw-data/_data` → `/data` (MinIO lives at `/data/minio/`)
- Bind mounts:
  - `/worksp/hiclaw/workspace` → `/root/hiclaw-fs/agents/manager`
  - `/var/run/docker.sock` → `/var/run/docker.sock`

### hiclaw-manager

- Image: `higress-registry.cn-hangzhou.cr.aliyuncs.com/higress/hiclaw-manager:v1.1.0`
- Runs: OpenClaw gateway (Node.js), agent process
- `HICLAW_RUNTIME=k8s` — confirmed active; this affects startup sync behavior (see below)
- `HICLAW_MANAGER_RUNTIME=openclaw`
- Bind mounts:
  - `/worksp/hiclaw/workspace` → `/root/manager-workspace`
  - `/home/ai` → `/host-share`

### novnc-desktop

- Image: `ghcr.io/u2giants/novnc-desktop:latest` (only image built in this repo)
- Runs: Chrome, noVNC, CDP proxy (`cdp_proxy.py` bridges Chrome 9222 → 9223)
- Static IP `10.0.5.4` on network `e10kwzww46ljhrgz1qj08j6a`
- Managed manually — not in Coolify

### oauth2-proxy

- OIDC provider: Authentik at `https://auth.designflow.app/application/o/hiclaw/`
- Protects `control.claw.designflow.app` and `gateway.claw.designflow.app`
- Cookie domain: `claw.designflow.app`
- Permit list: `oauth2-proxy/allowed-emails.txt`

## Critical Mount Relationship

Both containers share the same host directory via different bind-mount paths:

```
Host: /worksp/hiclaw/workspace/
  └── mounted as /root/manager-workspace/    in hiclaw-manager
  └── mounted as /root/hiclaw-fs/agents/manager/   in hiclaw-controller
```

This means edits to the workspace by either container are immediately visible to the other. `workspace/openclaw.json` has three concurrent writers: the controller reconciler, the gateway, and `manager-config-keeper.sh`.

## Data Flows

### Manager startup (HICLAW_RUNTIME=k8s)

`HICLAW_RUNTIME=k8s` is the active mode. The k8s startup block in `start-manager-agent.sh` (lines 171-196) runs on **every container start**:

1. Configures `mc` alias pointing to the controller's MinIO (`http://hiclaw-controller:9000`)
2. Pulls MinIO `hiclaw/hiclaw-storage/manager/` → `/root/manager-workspace/` (the workspace)
3. Pulls MinIO `hiclaw/hiclaw-storage/` → `/root/hiclaw-fs/` (container-internal)
4. Creates symlink `/root/manager-workspace/hiclaw-fs` → `/root/hiclaw-fs`

Step 2 is the most dangerous step — see [MinIO sync safety](#minio-sync-safety).

After the pull, the manager:
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

### Controller Element Web startup

1. `hiclaw-controller` runs `start-element-web.sh` (host-owned, injected by `controller-bootstrap-keeper.sh`) as the supervisord Element Web component.
2. The script generates `config.json`, `control-panel-btn.js`, `new-chat-btn.js`, `auth-ui-tweaks.js`, and `hiclaw-chat-api.py` into `/opt/element-web/`.
3. It clears any stale nginx master (prevents crash-loop on port `8088`/`18888`/`8002`), starts `hiclaw-chat-api.py` on `127.0.0.1:8091`, then starts nginx in the foreground.
4. nginx proxies `/hiclaw-api/new-chat` and `/hiclaw-api/matrix-auth` to the Python helper; serves Element Web on port 8088; serves the manager console (auto-token-injected) on port 18888; serves WASM plugins on port 8002.

### New Chat workflow

1. Admin clicks "+ New Chat" in Element Web.
2. Browser POSTs `{ name }` to `/hiclaw-api/new-chat` (proxied to `hiclaw-chat-api.py`).
3. Python helper logs in as admin, creates a `trusted_private_chat` room with `@manager` invited, sends the initial `@mention` message.
4. Browser polls the room list until it finds the new room and focuses it.

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

`start-manager-agent.sh` (lines 186-193) adds `--exclude` flags to the k8s startup pull:

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
