# HiClaw Host Ops

This repo is the host-side operations layer for a running HiClaw deployment. It is **not** the main HiClaw application source tree. It owns:

- the only Docker image we build: `novnc-desktop` (Chrome browser-in-a-box for CDP automation)
- host startup and keeper scripts that repair container behavior across restarts
- OAuth2 auth sidecar config (`oauth2-proxy/`)
- Traefik dynamic routing config (`traefik/claw.yml`)

## Start Here

- Architecture and data flow: [docs/architecture.md](docs/architecture.md)
- All configuration and env vars: [docs/configuration.md](docs/configuration.md)
- Development, debugging, and validation: [docs/development.md](docs/development.md)
- Deploy and upgrade workflow: [docs/deployment.md](docs/deployment.md)

## Repo Layout

```text
/worksp/hiclaw/
├── AGENTS.md                        ← primary AI/developer guide — read this first
├── CLAUDE.md                        ← Claude Code-specific overrides
├── docs/                            ← project documentation
├── novnc-desktop/                   ← THE ONLY DOCKER IMAGE WE BUILD
│   ├── Dockerfile
│   ├── novnc-startup.sh             ← Chrome watchdog, CDP proxy launcher
│   └── cdp_proxy.py                 ← WebSocket proxy Chrome 9222→9223
├── oauth2-proxy/
│   ├── docker-compose.yml           ← oauth2-proxy container (OIDC via Authentik)
│   └── allowed-emails.txt           ← permitted Google accounts
├── traefik/
│   └── claw.yml                     ← Traefik dynamic config (copy of live /data/coolify/proxy/dynamic/claw.yml)
├── workspace/                       ← persistent hiclaw-manager runtime volume (NOT source code)
├── start-manager-agent.sh           ← host-owned patched manager startup script
├── start-element-web.sh             ← host-owned patched controller Element Web startup script
├── start-tuwunel.sh                 ← Matrix homeserver (Tuwunel/conduwuit) startup config
├── manager-bootstrap-keeper.sh      ← reapplies start-manager-agent.sh after container recreation
├── controller-bootstrap-keeper.sh   ← reapplies start-element-web.sh after controller recreation
├── manager-config-keeper.sh         ← keeps openclaw.json stable across controller/gateway churn
├── mcp-keeper.sh                    ← re-adds browser MCP config when the gateway strips it
└── fix-element-config.sh            ← post-upgrade one-shot repair script
```

## Container Inventory

| Container | Image | Managed by |
|---|---|---|
| `hiclaw-controller` | `higress/hiclaw-embedded:v1.1.0` | `controller-bootstrap-keeper.sh` (cron) |
| `hiclaw-manager` | `higress/hiclaw-manager:v1.1.0` | `manager-bootstrap-keeper.sh` (cron) |
| `novnc-desktop` | `ghcr.io/u2giants/novnc-desktop:latest` | manual `docker run` |
| `oauth2-proxy` | `quay.io/oauth2-proxy/oauth2-proxy:latest` | `oauth2-proxy/docker-compose.yml` |

`hiclaw-controller` and `hiclaw-manager` are **not in Coolify** — they are managed by keeper scripts running as cron jobs on the host.

## Quick Health Checks

```bash
crontab -l                                                 # verify keepers are registered
docker ps --format "{{.Names}}\t{{.Status}}"              # all containers running?
docker logs hiclaw-manager --since 5m | grep -E 'gateway|error'
docker exec hiclaw-manager openclaw clawtalk doctor

# MinIO recursion check — MUST print only the root path; extra lines = active bug
sudo find /var/lib/docker/volumes/hiclaw-data/_data/minio/hiclaw-storage \
  -maxdepth 8 -type d -name "hiclaw-storage" -print
ls /worksp/hiclaw/workspace/hiclaw/ 2>/dev/null && echo "WARNING: recursion seed present" || echo "OK"
```

## Known Intentional Behaviors

- **`HICLAW_RUNTIME=k8s`** is the active runtime mode. This causes the manager startup script to pull MinIO content into the workspace on every container start. The pulls have strict `--exclude` guards to prevent a recursive storage loop — do not remove them. See [docs/architecture.md § MinIO sync safety](docs/architecture.md#minio-sync-safety).
- **`commands.restart`**: startup forces it to `true` so the gateway does its initial reload. The keeper then normalizes `commands` to `{}` so the controller's periodic template writes never trigger another restart. This is deliberate — see [docs/configuration.md § commands.restart](docs/configuration.md#commandsrestart).
- **`session.dmScope = "main"`** collapses Matrix DMs into the same session as OpenClaw web chat. Separate admin conversations should use new Matrix rooms, not new DMs.
- **`start-manager-agent.sh`** in this repo is a forked copy of the in-container startup script. Container-internal copies are ephemeral; this host copy is the persistent source of truth.
- **`workspace/`** contains agent runtime state, skills, memory, and MinIO-synced content. It looks like source code but it is a live volume. Do not edit files under `workspace/hiclaw/hiclaw-storage/` — that path should not exist at all (see MinIO recursion check above).
