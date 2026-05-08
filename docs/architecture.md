# Architecture

## Scope

This repo is a host-ops wrapper around a running HiClaw deployment. It does not build or publish the main Hiclaw application. Instead, it maintains the state and repair logic that make a specific deployment behave the way the operator expects.

## Major Components

- `hiclaw-manager`
  - Runs OpenClaw as the manager gateway.
  - Uses `workspace/` as `/root/manager-workspace`.
  - Starts from `/opt/hiclaw/scripts/init/start-manager-agent.sh` inside the container.
- `hiclaw-controller`
  - Reconciles manager config and other cluster state.
  - Writes to the same `workspace/openclaw.json`.
- Host workspace at `workspace/`
  - Persistent volume shared with the manager container.
  - Contains `openclaw.json`, agent memory, runtime state, skills, and mirrored artifacts.
- Host keepers
  - `manager-config-keeper.sh` stabilizes `workspace/openclaw.json`.
  - `manager-bootstrap-keeper.sh` re-applies the patched manager startup script after container recreation.
  - `controller-bootstrap-keeper.sh` re-applies the patched Element Web startup script after controller recreation.
  - `mcp-keeper.sh` restores the browser MCP block when needed.
- `oauth2-proxy`
  - Protects `control.claw.designflow.app`.
- noVNC / Playwright MCP path
  - Separate browser automation path documented in [novnc-setup.md](/worksp/hiclaw/novnc-setup.md).

## Data Flow

### Manager startup

1. `hiclaw-manager` starts with the container image's startup script path.
2. `manager-bootstrap-keeper.sh` compares the container's startup script with the host copy at [start-manager-agent.sh](/worksp/hiclaw/start-manager-agent.sh).
3. If they differ, the keeper copies the host version into the container and restarts `hiclaw-manager` once.
4. The patched startup script:
   - keeps `commands.restart = true`
   - bootstraps ClawTalk before `openclaw gateway run`
   - rebuilds the bundled ClawTalk shim
   - removes stale plugin precedence that prevents the gateway from loading ClawTalk

### Controller chat UI startup

1. `hiclaw-controller` starts `element-web` under supervisord via `/opt/hiclaw/scripts/init/start-element-web.sh`.
2. In this deployment an older daemonized nginx master can survive long enough to keep ports `8088`, `18888`, and `8002` bound.
3. When that happens, the supervisor-owned `element-web` process crash-loops on `bind()` errors and the HiClaw chat UI looks disconnected or stale.
4. The host-owned [start-element-web.sh](/worksp/hiclaw/start-element-web.sh) now clears any stale nginx master before starting the foreground nginx process that supervisord expects to own.
5. That same startup patch injects `control-panel-btn.js` and `new-chat-btn.js` into Element Web and launches a controller-local Python helper on `127.0.0.1:8091`.
6. Nginx exposes the helper at `/hiclaw-api/new-chat`, so the HiClaw browser UI can create a separate manager room without opening OpenClaw.

### Config stabilization

1. `workspace/openclaw.json` is shared between the manager and controller.
2. The manager startup script and controller both mutate it.
3. OpenClaw also tracks health and backup state under `workspace/.openclaw/`.
4. `manager-config-keeper.sh` edits the host copy directly to keep critical settings stable and to sync `config-health.json` when necessary.

### Chat session routing

1. OpenClaw web chat uses the manager's main session key: `agent:main:main`.
2. In this deployment, Matrix direct messages are intentionally forced onto that same main session with `session.dmScope = "main"`.
3. That makes HiClaw DM chat and the OpenClaw web chat share one transcript instead of maintaining separate per-channel DM threads.
4. Separate HiClaw conversations are therefore modeled as separate Matrix rooms, not separate DMs.
5. Matrix group and private-room chats remain separate group/channel sessions.

### HiClaw-only separate chat workflow

1. The main admin DM remains the default conversation surface.
2. When the admin asks for a separate conversation, the manager should create a new private Matrix room rather than asking the admin to use OpenClaw directly.
3. The persistent helper for that lives at [workspace/skills/matrix-server-management/scripts/create-admin-chat-room.sh](/worksp/hiclaw/workspace/skills/matrix-server-management/scripts/create-admin-chat-room.sh).
4. The helper logs in as the admin account, creates a `trusted_private_chat` room, invites `@manager`, and sends the initial `@mention` that activates the new OpenClaw room session.
5. The browser-facing `New Chat` button now drives the same room-creation pattern through the controller-local `/hiclaw-api/new-chat` endpoint.

### ClawTalk bootstrap path

1. The host-owned startup patch modifies the ClawTalk npm plugin manifest to declare startup activation, tool contracts, and the `clawtalk` command alias.
2. It ensures `plugins.entries.clawtalk` exists in `openclaw.json`.
3. It removes stale `installRecords.clawtalk`.
4. It builds `/usr/lib/node_modules/openclaw/dist/extensions/clawtalk/` as a bundled shim.
5. The shim wraps `resolvePath()` so ClawTalk gets a stable data directory and can open `ws.log` and start its WebSocket service reliably.

## Constraints

- This repo does not control the upstream image contents. Container internals can be replaced by HiClaw upgrades or recreations.
- `workspace/` is persistent, but files inside the container image are not.
- The manager startup script inside the container is therefore a repair target, not a persistent storage location.
- `workspace/openclaw.json` is not single-writer. Any design that assumes exclusive ownership will drift.

## Intentional Behaviors That Look Wrong

- `commands.restart = true` is intentional.
  - A new developer might assume `false` is safer.
  - In this deployment it causes a controller-triggered restart loop because the controller later writes `true`, which OpenClaw interprets as a restart-triggering config change.
- `manager-bootstrap-keeper.sh` patches a file inside a running container.
  - That looks like an anti-pattern because it usually is.
  - Here it is the practical persistence boundary because the actual image source tree is not available in this repo, while the host filesystem and cron are.
- HiClaw direct chat and OpenClaw webchat intentionally collapse onto the same main session.
  - This trades channel isolation for a simpler operator experience.
- Separate HiClaw room chats still use separate session keys.
  - Only direct-message continuity is shared with webchat.
- A new developer might expect "new DM" to be the way to open another thread.
  - That is not how this deployment works because DMs are deliberately collapsed into the main session.
- A new developer might expect the `New Chat` frontend control to be implemented in an Element source repo.
  - In this deployment it is intentionally injected at startup because the upstream frontend build tree is not part of this workspace.
- `workspace/hiclaw/hiclaw-storage/...` recursive-looking content is not the application source tree.
  - It is a mirrored artifact of the live manager workspace and MinIO sync path.
  - Do not treat it as the authoritative location for edits.
- `start-manager-agent.sh` in this repo is intentionally a forked copy of the in-container script.
  - It exists so the host can restore required behavior after container recreation.

## Integration Points

- `fix-element-config.sh` patches `hiclaw-controller`, manager npm/mc wrappers, nginx config, and Docker network attachments after upgrades.
- `start-element-web.sh` and `controller-bootstrap-keeper.sh` are the persistent repair path for the controller-side chat UI startup.
- `oauth2-proxy/docker-compose.yml` defines the control UI auth sidecar.
- `novnc-setup.md` covers the browser/CDP path and the separate network dependency for the manager container.
