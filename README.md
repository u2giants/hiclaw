# HiClaw Host Ops

Host-side infrastructure layer for a running HiClaw deployment. **Not** the HiClaw application source — this repo owns the surrounding keeper scripts, Docker image, and routing config that keep it alive.

**Read [AGENTS.md](AGENTS.md) for the full operating guide.**

## What This Is

HiClaw is an AI agent orchestration platform (by Alibaba/Higress) running on a single Linux server (`178.156.180.212`). Agents receive tasks via Matrix/Element chat, execute them using DeepSeek via OpenRouter, and automate a live Chrome browser via CDP. The OpenClaw gateway (inside `hiclaw-manager`) handles the agent runtime. Google OAuth gates all web-facing services.

## Key URLs

| Service | URL |
|---|---|
| Element chat UI | https://claw.designflow.app |
| Control panel (OpenClaw) | https://control.claw.designflow.app |
| Gateway API | https://gateway.claw.designflow.app |
| noVNC desktop | https://vnc.designflow.app |

## Container Quick Reference

| Container | Purpose | Status |
|---|---|---|
| `hiclaw-controller` | Orchestration, MinIO, Higress AI gateway, Element Web, Matrix (Tuwunel) | `docker logs hiclaw-controller --since 5m` |
| `hiclaw-manager` | Agent runtime, OpenClaw gateway, Matrix integration | `docker logs hiclaw-manager --since 5m` |
| `novnc-desktop` | Chrome via noVNC for CDP browser automation | `docker ps --filter name=novnc-desktop` |
| `oauth2-proxy` | Google OAuth gate for all web services | `docker ps --filter name=oauth2-proxy` |

`hiclaw-controller` and `hiclaw-manager` are **not in Coolify** — managed by keeper scripts as cron jobs.

## Emergency Recovery

```bash
# openclaw.json corrupted? Restore from backup:
cp /worksp/hiclaw/workspace/openclaw.json.bak /worksp/hiclaw/workspace/openclaw.json

# Check all containers are up:
docker ps --format "{{.Names}}\t{{.Status}}"

# Check keeper crons are registered:
crontab -l
```

## Docs

- [docs/architecture.md](docs/architecture.md) — system design and data flow
- [docs/configuration.md](docs/configuration.md) — all env vars and config files
- [docs/development.md](docs/development.md) — debugging and safe edit workflows
- [docs/deployment.md](docs/deployment.md) — deploy, upgrade, and recovery procedures
