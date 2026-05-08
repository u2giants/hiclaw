# HiClaw — AI Context & Project Briefing

> **Read this first.** This file is the single source of truth for any AI session working on this project.
> Additional memory files are in `memory/` — load them too.

---

## What is HiClaw?

HiClaw is an AI-agent orchestration system. It runs on a single Linux server and consists of:

| Container | Role |
|---|---|
| `hiclaw-controller` | Core: orchestration, MinIO (object storage), database, API |
| `hiclaw-manager` | Manager agent: hosts OpenClaw gateway, runs Matrix/Element integration |
| `hiclaw-worker` | Ephemeral worker containers spawned per-task |
| `novnc` / `webtop` | Browser-in-a-container: Chrome via noVNC for CDP automation |
| `oauth2-proxy` | Google OAuth gate in front of services |
| `tuwunel` | Matrix homeserver (local, for agent messaging) |
| `element-web` | Matrix client UI |

**Network:** `hiclaw-net` (Docker bridge). Services reach each other by container name.

---

## Repository layout

```
hiclaw/
├── CLAUDE.md                    ← you are here
├── README.md                    ← user-facing overview
├── CLAWTALK_HANDOFF.md          ← detailed session handoff notes
├── novnc-setup.md               ← Chrome/noVNC troubleshooting notes
├── .env.example                 ← env var template (fill & copy to .env)
├── docs/
│   ├── architecture.md
│   ├── configuration.md
│   ├── deployment.md
│   └── development.md
├── memory/                      ← AI memory files (project knowledge, feedback)
│   ├── MEMORY.md                ← index
│   ├── project_openclaw_restart_loop.md
│   ├── feedback_hiclaw_restart.md
│   └── project_novnc_chrome.md
├── oauth2-proxy/
│   ├── docker-compose.yml
│   └── allowed-emails.txt
├── novnc-desktop/               ← noVNC container source (Dockerfile + scripts)
│   ├── Dockerfile
│   ├── novnc-startup.sh
│   └── cdp_proxy.py
├── scripts (at root):
│   ├── controller-bootstrap-keeper.sh   ← keeps hiclaw-controller alive
│   ├── manager-bootstrap-keeper.sh      ← keeps hiclaw-manager alive
│   ├── manager-config-keeper.sh         ← keeps openclaw.json config healthy
│   ├── mcp-keeper.sh                    ← keeps MCP server alive
│   ├── start-element-web.sh             ← starts Element Web container
│   ├── start-manager-agent.sh           ← starts hiclaw-manager container
│   ├── start-tuwunel.sh                 ← starts Matrix homeserver
│   └── fix-element-config.sh            ← one-off Element config fixer
```

---

## Shared volume (critical)

Both `hiclaw-controller` and `hiclaw-manager` mount the **same host directory**:

- Host path: `/worksp/hiclaw/workspace`
- In `hiclaw-controller`: mounted at `/root/hiclaw-fs/agents/manager`
- In `hiclaw-manager`: mounted at `/root/manager-workspace`

Key file: `/worksp/hiclaw/workspace/openclaw.json` — OpenClaw gateway config.
The controller writes to it; the manager reads it. This is how the controller tells the manager to restart or change config.

---

## Critical known issues & fixes

### 1. OpenClaw restart loop (IMPORTANT)

**Never set `commands.restart = false` in `openclaw.json`.** The controller's reconciliation loop always writes `commands.restart = true`. Setting it to false triggers a diff → restart → re-stabilizes at true. One extra restart is harmless, but it delays message processing.

**How to check:** `docker exec hiclaw-manager openclaw gateway call config.get --json`

**How to stabilize if looping:**
```bash
docker exec hiclaw-manager bash -c 'jq ".commands.restart = true" /root/manager-workspace/openclaw.json > /tmp/t.json && mv /tmp/t.json /root/manager-workspace/openclaw.json'
```

**SIGUSR1 deadlock (restart ignored):** Write a force restart intent:
```bash
docker exec hiclaw-manager bash -c 'echo "{\"kind\":\"gateway-restart\",\"pid\":1,\"createdAt\":$(date +%s%3N),\"force\":true}" > /root/.openclaw/gateway-restart-intent.json && kill -USR1 1'
```
⚠️ This causes a container restart (not in-process), so `start-manager-agent.sh` re-runs.

**In-process vs container restart:**
- In-process: PID 1 (openclaw) stays alive, reinitializes. `start-manager-agent.sh` does NOT re-run.
- Container restart: PID 1 exits, Docker restarts, `start-manager-agent.sh` re-runs.

**start-manager-agent.sh patch:** Lines 710 and 785 use `.commands.restart = (.commands.restart // false)` — preserves `true` if already set. The change is in the container overlay and will be lost on image update.

**Why Matrix messages go unanswered:** Each restart advances the Matrix sync token past pending messages. Messages received during the restart window get skipped.

### 2. Chrome / noVNC double-browser OOM crash

**Symptom:** Server runs out of memory; two Chrome instances running simultaneously.

**Root cause 1 — broken pkill pattern:** `pkill -f "chrome\|pattern"` — `\|` is a literal pipe in pkill's ERE, not alternation. The old Chrome never dies. Fixed to `pkill -f "chrome|pattern"` (unescaped `|`).

**Root cause 2 — unconditional Singleton deletion:** Chrome wrapper deleted `Singleton*` files before launch, even when Chrome was already running. When another app (e.g. Dropbox) opened a URL via `google-chrome https://...`, this triggered a second full Chrome instance.

**Current wrapper** (`/usr/local/bin/google-chrome` inside novnc container):
```bash
#!/bin/bash
mkdir -p /config/chrome-profile
chown -R abc:abc /config/chrome-profile 2>/dev/null
if ! pgrep -f "/opt/google/chrome/chrome" > /dev/null 2>&1; then
    rm -f /config/chrome-profile/Singleton*
fi
exec /usr/bin/google-chrome-stable --no-sandbox --disable-dev-shm-usage \
  --no-first-run --start-maximized \
  --user-data-dir=/config/chrome-profile \
  --remote-debugging-port=9222 --remote-debugging-address=0.0.0.0 \
  --remote-allow-origins='*' \
  --renderer-process-limit=4 --disable-background-networking --disable-sync "$@"
```

**TODO:** Rebuild `ghcr.io/u2giants/novnc-desktop` image with this wrapper baked in. Files are in `novnc-desktop/`.

### 3. Bind-mount inode staleness

When replacing files on the host that are bind-mounted into a running container (e.g., `cdp_proxy.py`), use in-place edits (`sed -i`) not file replacement. Replacing creates a new inode; the container still sees the old one.

---

## How to restart things

```bash
# Restart hiclaw-manager (manager agent)
docker restart hiclaw-manager

# Restart hiclaw-controller
docker restart hiclaw-controller

# Check OpenClaw gateway status
docker exec hiclaw-manager openclaw gateway call config.get --json

# Check all running hiclaw containers
docker ps --filter name=hiclaw

# Run keeper scripts (normally run by systemd/cron/background shell)
/worksp/hiclaw/manager-bootstrap-keeper.sh &
/worksp/hiclaw/controller-bootstrap-keeper.sh &
/worksp/hiclaw/manager-config-keeper.sh &
```

---

## Architecture notes

- **OpenClaw version:** v2026.5.4 (npm global, at `/usr/lib/node_modules/openclaw/`)
  - `/opt/openclaw/` is a different, older (v2026.4.14) source directory — NOT the running version
- **LLM provider:** OpenRouter (`https://openrouter.ai/api/v1`), model `deepseek/deepseek-v4-pro`
- **Embedding model:** `text-embedding-v4`
- **Matrix homeserver:** `tuwunel` at `matrix-local.hiclaw.io:18080`
- **Matrix DM room:** `!Yzg8FAvvzjKsYTBJb3:matrix-local.hiclaw.io:18080`
- **MinIO:** Built into `hiclaw-controller`, port 9000. The `default` MinIO user does NOT have write permission to `agents/manager/` — controller writes to the shared volume directly instead.
- **CDP automation:** Chrome inside novnc container, port 9222 (internal) → proxied to 9223 via `cdp_proxy.py`
  - OpenClaw/OpenManus connects at `http://novnc:9223`

---

## Key file locations (on host)

| Path | Purpose |
|---|---|
| `/worksp/hiclaw/workspace/openclaw.json` | OpenClaw gateway config (shared volume) |
| `/worksp/hiclaw/workspace/` | Entire manager workspace |
| `/home/ai/novnc-desktop/` | noVNC Docker build context |
| `/home/ai/.claude/projects/-worksp-hiclaw/memory/` | Claude Code memory files |

---

## Memory files

See `memory/` directory in this repo. Key entries:
- `project_openclaw_restart_loop.md` — full root cause analysis + fix for the restart loop
- `feedback_hiclaw_restart.md` — never set restart=false
- `project_novnc_chrome.md` — Chrome OOM fix, watchdog internals, cdp_proxy inode issue

---

## Owner

- GitHub: u2giants
- Email: u2giants@gmail.com
