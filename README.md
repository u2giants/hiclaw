# HiClaw Host Ops

This repo is the host-side operations layer for a running HiClaw deployment. It is not the main Hiclaw application source tree. It owns:

- the persistent manager workspace at `workspace/`
- host scripts that repair or extend container behavior
- cron-based keepers that make those repairs survive restarts and container recreation
- a small `oauth2-proxy` sidecar for the control UI

## Start Here

- Architecture: [docs/architecture.md](/worksp/hiclaw/docs/architecture.md)
- Configuration: [docs/configuration.md](/worksp/hiclaw/docs/configuration.md)
- Development and debugging: [docs/development.md](/worksp/hiclaw/docs/development.md)
- Deployment and upgrade workflow: [docs/deployment.md](/worksp/hiclaw/docs/deployment.md)
- Browser/noVNC setup: [novnc-setup.md](/worksp/hiclaw/novnc-setup.md)

## Repo Layout

```text
/worksp/hiclaw/
├── docs/                         # Maintained project documentation
├── workspace/                    # Persistent /root/manager-workspace volume for hiclaw-manager
│   └── skills/matrix-server-management/scripts/create-admin-chat-room.sh
│                                 # Manager-side helper for new HiClaw-only chat rooms
├── start-manager-agent.sh        # Host-owned patched manager startup script
├── start-element-web.sh          # Host-owned patched controller Element Web startup script
├── manager-bootstrap-keeper.sh   # Re-applies the patched startup script after container recreation
├── controller-bootstrap-keeper.sh # Re-applies the patched Element Web startup script after container recreation
├── manager-config-keeper.sh      # Keeps openclaw.json stable across controller/gateway churn
├── mcp-keeper.sh                 # Re-adds the browser MCP block when the gateway strips it
├── fix-element-config.sh         # Re-patches hiclaw-controller and manager-side helpers after upgrades
├── oauth2-proxy/                 # Control UI auth sidecar config
├── CLAWTALK_HANDOFF.md           # Historical incident note for the ClawTalk integration
└── novnc-setup.md                # Specialized browser-agent setup guide
```

## Current Operational Guarantees

- ClawTalk is bootstrapped by the manager startup path, not by a one-off container edit.
- That startup patch survives `hiclaw-manager` container recreation because `manager-bootstrap-keeper.sh` reapplies it from the host.
- HiClaw direct chat and OpenClaw web chat intentionally share the same manager session.
- HiClaw now exposes a real `New Chat` button in the Element Web UI, backed by a controller-local room-creation API.
- Separate HiClaw conversations are private Matrix rooms, not extra direct-message threads.
- The HiClaw chat UI no longer relies on a stale daemonized nginx process inside `hiclaw-controller`; `controller-bootstrap-keeper.sh` restores the patched Element Web startup script after controller recreation.
- `commands.restart` is intentionally forced to `true` so the gateway does not fall back into the controller-triggered restart loop.
- `workspace/openclaw.json` is a shared, contested file. The keepers exist because the controller, gateway, and MinIO sync all mutate it.

## Quick Checks

```bash
crontab -l
docker ps --filter name=hiclaw-manager
docker exec hiclaw-manager openclaw clawtalk doctor
docker logs hiclaw-manager --since 5m | grep -E 'ClawTalk|http server listening'
```

## Intentional Quirks

- `start-manager-agent.sh` in this repo is not the original upstream script. It is a host-managed patched copy used as the source of truth for repairing new `hiclaw-manager` containers.
- `session.dmScope = "main"` is intentional. It makes Matrix DMs reuse `agent:main:main` so the HiClaw and OpenClaw chat surfaces stay aligned for the manager conversation.
- If the admin wants another simultaneous conversation without touching OpenClaw, the correct primitive is a new private HiClaw room. Multiple independent DMs with the same manager account are not the supported model in this deployment.
- The `New Chat` button is intentionally injected by the host-managed controller startup patch instead of living in upstream Element source, because this repo owns the deployment wrapper rather than the original frontend codebase.
- `start-element-web.sh` in this repo is also a host-managed patched copy. It forcefully clears stale nginx masters before starting the supervisor-owned foreground nginx, because duplicate nginx instances make the HiClaw chat UI look disconnected while the manager keeps running.
- `workspace/` contains many files that look source-controlled but are really runtime state, mirrored artifacts, or HiClaw-managed content. Treat it as a live volume first, not a clean code checkout.
- `CLAWTALK_HANDOFF.md` is historical debugging context, not the current design doc.
