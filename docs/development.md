# Development

## What "development" means here

This repo is shell scripts, a single Dockerfile, and deployment state. There is no local app build, test suite, or lint pipeline. Normal workflow:

1. Edit a host script or config
2. Syntax-check it
3. Apply to running containers if needed
4. Verify with container logs and OpenClaw commands

## Prerequisites

- SSH access to the host at `178.156.180.212`
- Docker CLI access on the host
- Permission to edit the host crontab (`crontab -e` as the deployment user)
- For `novnc-desktop` image changes: a push to `main` triggers GitHub Actions — no local Docker build needed

## Key Working Files

| File | What it controls |
|---|---|
| `start-manager-agent.sh` | Manager startup, ClawTalk bootstrap, MinIO sync, openclaw.json initialization |
| `start-element-web.sh` | Controller Element Web, nginx, New Chat API, manager console proxy |
| `manager-config-keeper.sh` | `openclaw.json` stabilization (runs every minute via cron) |
| `manager-bootstrap-keeper.sh` | Keeps startup script current in the manager container |
| `controller-bootstrap-keeper.sh` | Keeps startup script current in the controller container |
| `mcp-keeper.sh` | Re-adds browser MCP block (run manually) |
| `novnc-desktop/novnc-startup.sh` | Chrome watchdog, CDP proxy, browser launch flags |
| `novnc-desktop/cdp_proxy.py` | WebSocket proxy Chrome 9222→9223 (must be edited in-place — see below) |
| `workspace/openclaw.json` | Live shared manager/controller config |

## Safe Edit Workflows

### Manager startup script changes

```bash
bash -n /worksp/hiclaw/start-manager-agent.sh     # syntax check
bash /worksp/hiclaw/manager-bootstrap-keeper.sh    # apply + restart if changed
docker logs hiclaw-manager --since 5m | grep -E 'gateway|ClawTalk|error'
docker exec hiclaw-manager openclaw clawtalk doctor
```

### Config keeper changes

```bash
bash -n /worksp/hiclaw/manager-config-keeper.sh
bash /worksp/hiclaw/manager-config-keeper.sh
python3 -m json.tool /worksp/hiclaw/workspace/openclaw.json >/dev/null
```

### Controller Element Web changes

```bash
bash -n /worksp/hiclaw/start-element-web.sh
bash /worksp/hiclaw/controller-bootstrap-keeper.sh
docker logs hiclaw-controller --since 5m | tail -50
docker exec hiclaw-controller curl -s http://127.0.0.1:8088/hiclaw-api/healthz
```

### oauth2-proxy changes (allowed emails, redirect URL)

```bash
# edit oauth2-proxy/allowed-emails.txt or oauth2-proxy/docker-compose.yml
cd /worksp/hiclaw/oauth2-proxy
docker compose up -d --force-recreate
```

### Traefik routing changes

```bash
# edit traefik/claw.yml
docker cp traefik/claw.yml coolify-proxy:/traefik/dynamic/claw.yml
# Traefik hot-reloads automatically — no restart needed
```

### cdp_proxy.py changes

```bash
# Use the Edit tool or sed -i — never cp or Write (would create a new inode)
# Docker bind mounts track the inode, not the path.
# After editing in-place, the running novnc-desktop container sees the change immediately.
```

### novnc-desktop image changes

```bash
# Commit changes to novnc-desktop/ and push to main
# GitHub Actions builds ghcr.io/u2giants/novnc-desktop:latest automatically
# To apply the new image:
docker pull ghcr.io/u2giants/novnc-desktop:latest
docker stop novnc-desktop && docker rm novnc-desktop
# then re-run the docker run command from docs/deployment.md
```

---

## Debugging

### MinIO recursion check (run after every restart)

```bash
# Must print ONLY the root path. Extra lines = active recursion bug — stop containers immediately
sudo find /var/lib/docker/volumes/hiclaw-data/_data/minio/hiclaw-storage \
  -maxdepth 8 -type d -name "hiclaw-storage" -print

# Must return "not found" — any result = recursion seed in workspace
ls /worksp/hiclaw/workspace/hiclaw/ 2>/dev/null && echo "PROBLEM" || echo "OK"
```

If recursion is found, do not restart. Follow the recovery steps in [architecture.md § MinIO sync safety](architecture.md#minio-sync-safety).

### ClawTalk not connected

```bash
docker exec hiclaw-manager openclaw clawtalk doctor
docker logs hiclaw-manager --since 10m | grep -E 'clawtalk|ClawTalk'
docker exec hiclaw-manager openclaw clawtalk logs --since 100
```

Look for:
- `loading clawtalk from /usr/lib/node_modules/openclaw/dist/extensions/clawtalk/index.js`
- `ClawTalk authenticated`
- `ClawTalk service started`

If `bot_connected` is false immediately after startup, wait 10 seconds — the gateway-side WebSocket needs time to authenticate after the gateway starts.

### Manager restart loop

```bash
docker logs hiclaw-manager --since 15m | grep -E 'commands|SIGUSR1|restarting|1012'
python3 -c "import json; d=json.load(open('/worksp/hiclaw/workspace/openclaw.json')); print(d.get('commands'))"
```

Expected steady state: `commands` is `{}` (empty object). If it contains any keys, the keeper will normalize it within 60 seconds. If the manager is restarting every ~5 minutes, check `commands` and the `channels.matrix.groups` schema. See Critical Incidents 1 and 2 in AGENTS.md.

### Browser MCP disappeared

```bash
bash /worksp/hiclaw/mcp-keeper.sh
docker exec hiclaw-manager openclaw mcp list
```

### HiClaw chat UI looks disconnected or stale

Check for the stale nginx master first:

```bash
docker logs hiclaw-controller --since 10m | tail -100
docker exec hiclaw-controller ps -ef | grep nginx | grep -v grep
docker exec hiclaw-controller sh -lc 'ss -ltnp | grep -E ":(8088|18888|8002)\\b" || true'
```

Repeated `element-web exited` lines or `bind()` failures on ports 8088/18888/8002 mean the controller has a stale nginx master — run `bash /worksp/hiclaw/controller-bootstrap-keeper.sh`.

### New Chat button does nothing

```bash
docker exec hiclaw-controller curl -s http://127.0.0.1:8088/hiclaw-api/healthz
docker exec hiclaw-controller ps -ef | grep hiclaw-chat-api | grep -v grep
docker exec hiclaw-controller tail -50 /var/log/hiclaw-chat-api.log
```

### Is the startup patch current?

```bash
bash /worksp/hiclaw/manager-bootstrap-keeper.sh
```

Expected: `startup patch already current for <container-id>`. Transient: `container startup script not readable yet; skipping this run` (the container is still booting — retry in 30 seconds).

### openclaw.json validate

```bash
python3 -m json.tool /worksp/hiclaw/workspace/openclaw.json >/dev/null && echo OK || echo INVALID
```

### Keeper logs

```bash
tail -30 /worksp/hiclaw/manager-config-keeper.log
tail -30 /worksp/hiclaw/manager-bootstrap-keeper.log
tail -30 /worksp/hiclaw/controller-bootstrap-keeper.log
```

---

## There Is No Build/Test System

- Build: none for shell scripts; GitHub Actions for `novnc-desktop`
- Unit tests: none
- Lint: none — use `bash -n` for shell scripts, `python3 -m json.tool` for JSON
- Best available validation: manual keeper execution + `docker logs` + `openclaw ... doctor`

---

## Extending the System

### Extending startup behavior

Edit `start-manager-agent.sh` for manager behavior, `start-element-web.sh` for controller/Element Web behavior. The keeper scripts detect changes (via sha256sum comparison) and apply them automatically.

### Adding an openclaw.json setting that must survive controller reconciliation

Add it to `manager-config-keeper.sh`. Make sure to also update `config-health.json` after writing (the script already does this — follow the same pattern).

### Adding a MinIO sync exclusion

Add `--exclude "<pattern>"` to the `mc mirror` call in `start-manager-agent.sh` lines 186-193. Never remove existing exclusions — they prevent the storage recursion bug.

### Avoid these patterns

- One-off `docker exec` fixes without a host-side keeper — they do not survive container recreation
- Editing files under `workspace/hiclaw/hiclaw-storage/` — this path indicates the recursion bug has triggered
- Running `mc mirror` inside the manager with the workspace as source and a MinIO manager path as destination without verifying the workspace does not contain a MinIO mirror subdirectory
- Setting `commands.restart = false` anywhere — see AGENTS.md Idiosyncratic Decisions
