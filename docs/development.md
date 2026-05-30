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
| `start-manager-agent.sh` | Manager startup, ClawTalk bootstrap, MinIO sync, openclaw.json initialization, OpenRouter model sync |
| `start-element-web.sh` | Controller Element Web, nginx, New Chat API, manager console proxy |
| `manager-config-keeper.sh` | `openclaw.json` stabilization (runs every minute via cron) |
| `manager-bootstrap-keeper.sh` | Keeps startup script current in the manager container; restarts only on openclaw package updates |
| `controller-bootstrap-keeper.sh` | Keeps startup script current in the controller container |
| `mcp-keeper.sh` | Re-adds browser MCP block (run manually) |
| `novnc-desktop/novnc-startup.sh` | Chrome watchdog, CDP proxy, browser launch flags |
| `novnc-desktop/cdp_proxy.py` | WebSocket proxy Chrome 9222→9223 (must be edited in-place — see below) |
| `workspace/openclaw.json` | Live shared manager/controller config |

## Safe Edit Workflows

### Manager startup script changes

```bash
bash -n /worksp/hiclaw/start-manager-agent.sh     # syntax check
bash /worksp/hiclaw/manager-bootstrap-keeper.sh    # apply silently (no restart unless openclaw pkg changed)
docker logs hiclaw-manager --since 5m | grep -E 'gateway|ClawTalk|error'
docker exec hiclaw-manager openclaw clawtalk doctor
```

The keeper patches the in-container startup script silently. Startup script changes only take effect at the next container start (natural or deliberate). The keeper does **not** restart the container for script-only edits — it only restarts when the openclaw package hash changes.

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

### openclaw.json live changes

Most fields hot-reload without a container restart:

```bash
# Edit directly — gateway picks up changes within seconds
python3 -m json.tool /worksp/hiclaw/workspace/openclaw.json >/dev/null && echo OK
# If the gateway reports a schema error:
docker exec hiclaw-manager openclaw doctor --fix
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

Expected steady state: `commands` is `{'restart': True}`. If it is `null`, `{}`, or `{'restart': False}`, the keeper will correct it within 60 seconds — but in the window before correction, the gateway may log a restart. If the manager is restarting every ~5 minutes, check `commands` and the `channels.matrix.groups` schema. See Critical Incidents 1 and 2 in AGENTS.md.

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

### control.claw returns 502 Bad Gateway

nginx in hiclaw-controller proxies to hiclaw-manager using Docker DNS (`resolver 127.0.0.11`), so the upstream hostname resolves dynamically. A 502 after manager recreation means nginx cached a stale IP before the fix, or the resolver block is missing.

```bash
# Check nginx upstream config inside controller
docker exec hiclaw-controller cat /etc/nginx/conf.d/manager-console.conf
# Must contain: resolver 127.0.0.11 valid=10s; set $upstream hiclaw-manager;
# If missing, run:
bash /worksp/hiclaw/controller-bootstrap-keeper.sh
```

### openclaw version / symlink

The base image ships openclaw at `/opt/openclaw/`. After an in-product update ("Update now" button), the package installs to `/usr/lib/node_modules/openclaw/` and the startup script updates the symlink at `/usr/local/bin/openclaw`. If the symlink still points to the old path:

```bash
docker exec hiclaw-manager ls -la /usr/local/bin/openclaw
docker exec hiclaw-manager openclaw --version
# If version looks wrong, the symlink may not have been updated yet.
# The keeper detects the package hash change and will restart the container.
# Check keeper log:
tail -20 /worksp/hiclaw/manager-bootstrap-keeper.log
```

### openclaw update hash path

The startup script writes the installed openclaw package hash to `/root/manager-workspace/.openclaw-startup-pkg-hash` inside the container. This path is bind-mounted to `/worksp/hiclaw/workspace/.openclaw-startup-pkg-hash` on the host. The keeper reads the host path. If the keeper is not detecting updates:

```bash
# Verify host-side hash file exists and is recent
ls -la /worksp/hiclaw/workspace/.openclaw-startup-pkg-hash
cat /worksp/hiclaw/workspace/.openclaw-startup-pkg-hash
# Compare to current openclaw package hash:
docker exec hiclaw-manager md5sum /usr/lib/node_modules/openclaw/package.json 2>/dev/null \
  || docker exec hiclaw-manager md5sum /opt/openclaw/package.json
```

### OpenRouter context window sync

On startup, `start-manager-agent.sh` fetches live model data from OpenRouter and patches `contextWindow` and `maxTokens` for any model whose ID matches an OpenRouter model ID. This currently works for `deepseek/deepseek-v4-pro` (1M context). Models accessed via Higress gateway alias IDs (e.g., `gpt-5.4`, `claude-opus-4-6`) are not matched and retain hardcoded values.

```bash
# Check what context window the gateway sees for a model
docker exec hiclaw-manager openclaw model list | grep deepseek
# Verify the startup sync ran
docker logs hiclaw-manager --since 10m | grep -i openrouter
```

If the sync produced an openclaw schema error (unknown field), check that the startup script strips the `pricing` field before writing to openclaw.json:

```bash
docker logs hiclaw-manager --since 10m | grep -iE 'pricing|schema|unknown'
```

### Google SSO / Element Web login not working

**Symptom: Second login screen appears after Google OAuth.**

```bash
# Verify oauth2-proxy is running and using Google (not OIDC/Authentik)
docker logs oauth2-proxy 2>&1 | grep "OAuthProxy configured"
# Expected: "OAuthProxy configured for Google Client ID: 904..."
```

If it shows an OIDC issuer URL instead, the wrong provider is configured — check `oauth2-proxy/docker-compose.yml` and `oauth2-proxy/.env`.

**Symptom: Element shows login form / welcome screen after Google auth.**

Open browser DevTools → Console on `claw.designflow.app`. Look for `auto-login.js` errors. Then check:

```bash
# Is auto-login.js being served?
docker exec hiclaw-controller curl -s http://127.0.0.1:8088/auto-login.js | head -5

# Does the session endpoint work?
docker exec hiclaw-controller curl -s -X POST http://127.0.0.1:8088/hiclaw-api/session
# Expected: {"access_token": "...", "user_id": "@admin:...", "device_id": "hiclaw_web_auto"}

# Is the Python helper running?
docker exec hiclaw-controller ps -ef | grep hiclaw-chat-api | grep -v grep
docker exec hiclaw-controller tail -20 /var/log/hiclaw-chat-api.log
```

If the session endpoint returns an error, the Python helper may have crashed or `HICLAW_ADMIN_PASSWORD` may not be set in the controller container's environment.

**Symptom: Redirect loop (URL changing rapidly with different tokens).**

`auto-login.js` is calling the session API repeatedly. This means the localStorage check is not finding the session. Possible causes: the keys are being set but Element is immediately clearing them (crypto init conflict), or the script is loading before the localStorage write from a previous run completed. Force-clear and retry:

```bash
# In browser DevTools:
localStorage.clear(); location.reload();
```

**Symptom: "We couldn't log you in / browser has forgotten it".**

This error comes from Element's SSO callback path. Something is triggering the `/?loginToken=` flow instead of the direct localStorage injection. Check that `auto-login.js` in the container matches what is in `start-element-web.sh` (run the bootstrap keeper to force a resync).

```bash
bash /worksp/hiclaw/controller-bootstrap-keeper.sh
```

For full design context, see [architecture.md § Google SSO Auto-Login](architecture.md#google-sso-auto-login).

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

Edit `start-manager-agent.sh` for manager behavior, `start-element-web.sh` for controller/Element Web behavior. The keeper scripts detect changes (via sha256sum comparison) and patch the in-container startup script silently. The new script runs at the next natural container restart.

### Adding an openclaw.json setting that must survive controller reconciliation

Add it to `manager-config-keeper.sh`. Make sure to also update `config-health.json` after writing (the script already does this — follow the same pattern).

### Adding a MinIO sync exclusion

Add `--exclude "<pattern>"` to the `mc mirror` call in `start-manager-agent.sh`. Never remove existing exclusions — they prevent the storage recursion bug.

### Adding OpenRouter model context sync

The startup script matches openclaw model IDs directly against OpenRouter model IDs. To cover Higress gateway alias IDs, add a mapping table in `start-manager-agent.sh` before the sync loop. Strip any fields openclaw does not recognize (currently `pricing`) using `del()` in the jq pipeline before writing to openclaw.json.

### Avoid these patterns

- One-off `docker exec` fixes without a host-side keeper — they do not survive container recreation
- Editing files under `workspace/hiclaw/hiclaw-storage/` — this path indicates the recursion bug has triggered
- Running `mc mirror` inside the manager with the workspace as source and a MinIO manager path as destination without verifying the workspace does not contain a MinIO mirror subdirectory
- Setting `commands.restart = false` anywhere — see AGENTS.md Idiosyncratic Decisions
- Running `npm install -g openclaw@latest` directly in the container when swap is low — use the in-product "Update now" button instead, which runs `openclaw update` under a controlled process
