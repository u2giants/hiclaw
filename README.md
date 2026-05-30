# HiClaw Host Ops

Host-side operations layer for a running HiClaw deployment. **Not** the main HiClaw application source — this repo owns the surrounding infrastructure that keeps it alive.

**Read [AGENTS.md](AGENTS.md) first.** It is the authoritative guide for this project.

## What This Is

HiClaw is an AI agent orchestration platform on a single Linux server (`178.156.180.212`). Agents receive tasks via Matrix/Element chat, execute them with an LLM (DeepSeek via OpenRouter), and automate a live Chrome browser via CDP. Google OAuth gates all web-facing services.

This repo owns:
- The only Docker image we build: `ghcr.io/u2giants/novnc-desktop` (Chrome-in-a-box via noVNC)
- Host keeper scripts that repair container state across restarts
- OAuth2 auth sidecar config (`oauth2-proxy/`)
- Traefik dynamic routing config (`traefik/claw.yml`)

## Container Inventory

| Container | Image | Managed by |
|---|---|---|
| `hiclaw-controller` | `higress/hiclaw-embedded:v1.1.0` | `controller-bootstrap-keeper.sh` (cron) |
| `hiclaw-manager` | `higress/hiclaw-manager:v1.1.0` | `manager-bootstrap-keeper.sh` (cron) |
| `novnc-desktop` | `ghcr.io/u2giants/novnc-desktop:latest` | manual `docker run` |
| `oauth2-proxy` | `quay.io/oauth2-proxy/oauth2-proxy:latest` | `oauth2-proxy/docker-compose.yml` |

`hiclaw-controller` and `hiclaw-manager` are **not in Coolify** — keeper scripts manage them directly as cron jobs.

## Quick Health Check

```bash
crontab -l                                            # keepers registered?
docker ps --format "{{.Names}}\t{{.Status}}"         # all containers up?
docker logs hiclaw-manager --since 5m | grep -E 'gateway|error'
docker exec hiclaw-manager openclaw clawtalk doctor
```

## Docs

- Architecture and data flow: [docs/architecture.md](docs/architecture.md)
- Configuration and env vars: [docs/configuration.md](docs/configuration.md)
- Development and debugging: [docs/development.md](docs/development.md)
- Deploy and upgrade workflow: [docs/deployment.md](docs/deployment.md)
