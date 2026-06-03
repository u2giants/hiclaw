# Development Guide

## Prerequisites

- Docker and Docker Compose on the server (`178.156.180.212`)
- `gh` CLI for GitHub operations
- SSH access to `178.156.180.212` (for reading logs and running docker commands — not for deployments)
- `sudo` access on the server for files owned by root (e.g., `/worksp/hiclaw/workspace/openclaw.json`)

---

## Viewing Live Logs

```bash
# Manager (OpenClaw gateway)
docker logs hiclaw-manager --follow

# Controller (Matrix, Higress, MinIO)
docker logs hiclaw-controller --follow

# Traefik proxy
docker logs coolify-proxy --follow

# Filter for hiclaw startup messages only
docker logs hiclaw-manager 2>&1 | grep "\[hiclaw"

# Filter for OpenClaw gateway messages
docker logs hiclaw-manager 2>&1 | grep "\[gateway\]"

# Filter for errors
docker logs hiclaw-manager 2>&1 | grep -E "(ERROR|error|Cannot find|jq: parse|Unfinished)"
```

---

## Checking System Health

```bash
# All hiclaw containers
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "hiclaw|novnc|oauth2"

# Is the OpenClaw gateway listening?
docker exec hiclaw-controller curl -s -o /dev/null -w "%{http_code}" http://hiclaw-manager:18799/
# Expected: 200

# Is the control panel backend reachable?
docker exec hiclaw-controller curl -s -o /dev/null -w "%{http_code}" http://localhost:18888/
# Expected: 200 (or 502 if manager is down)

# Matrix server health
curl -s http://localhost:18080/_matrix/client/versions | python3 -m json.tool | head -5

# MinIO health (from controller)
docker exec hiclaw-controller mc ls hiclaw/hiclaw-storage/manager/ | head -5

# OpenClaw version running
docker exec hiclaw-manager openclaw --version 2>/dev/null

# Manager restart count (high number = recent crash loop)
docker inspect hiclaw-manager --format 'Restarts={{.RestartCount}}'
```

---

## Diagnosing a 502 on control.claw.designflow.app

The request path is: Browser → Traefik (`coolify-proxy`) → Controller nginx (port 18888) → Manager OpenClaw gateway (port 18799).

A 502 means one of those links is broken.

```bash
# Step 1: Is the manager running?
docker ps --format "{{.Names}}\t{{.Status}}" | grep hiclaw-manager

# Step 2: Is manager stuck in a restart loop?
docker inspect hiclaw-manager --format '{{.RestartCount}} restarts'
# High number + "Restarting" status = crash loop

# Step 3: Check why it's crashing
docker logs hiclaw-manager 2>&1 | grep -E "\[hiclaw|jq: parse|Cannot find|Unfinished" | tail -20

# Step 4: Is port 18799 listening?
docker exec hiclaw-manager grep -i "496f\|496F" /proc/net/tcp 2>/dev/null
# Should return a line with state "0A" (LISTEN)

# Step 5: Can the controller reach the manager?
docker exec hiclaw-controller curl -sv http://hiclaw-manager:18799/ 2>&1 | head -10
```

---

## Diagnosing a Restart Loop

**Symptom:** `docker ps` shows `Restarting (N) X seconds ago` or container stays up for only ~50 seconds.

### Common causes:

**1. Truncated openclaw.json (jq parse error)**
```
jq: parse error: Unfinished JSON term at EOF at line 344, column 4
```
Fix: restore from backup — see "Restoring a Truncated openclaw.json" below.

**2. Missing openai/index.mjs (npm partial install)**
```
Cannot find module '/usr/lib/node_modules/openclaw/node_modules/openai/index.mjs'
```
Fix: delete the broken npm install so the startup script falls back to the base image.
```bash
docker exec hiclaw-manager rm -rf /usr/lib/node_modules/openclaw/
# Container will restart automatically and use base image /opt/openclaw/
```
Then trigger a proper update (see "Triggering an OpenClaw Version Update" below).

**3. Reconciler diff loop (`commands` drift)**
OpenClaw's config reconciler writes `commands: null` every ~47 seconds. The config keeper must restore `commands` to `{"restart": true}` so the file matches the startup baseline and avoids a SIGUSR1 restart loop.
Fix: run the config keeper manually.
```bash
bash /worksp/hiclaw/manager-config-keeper.sh
```

---

## Reading Stability Bundles

When OpenClaw crashes at startup it writes a stability bundle:
```bash
ls /worksp/hiclaw/workspace/.openclaw/logs/stability/
cat /worksp/hiclaw/workspace/.openclaw/logs/stability/openclaw-stability-*.json | python3 -m json.tool
```
The bundle contains the crash reason, stack trace, and config snapshot at the time of crash.

---

## The .clobbered.* Files

`openclaw.json.clobbered.TIMESTAMP` files are created by OpenClaw's observe-recovery mechanism when it detects a hash mismatch between `openclaw.json` and `config-health.json`. It saves the mismatched file as `.clobbered.` and restores from `.bak`.

- These files are **normal operational noise** — not errors.
- They are excluded from MinIO sync (`start-manager-agent.sh` uses `--exclude "*.clobbered.*"`).
- Large accumulations (200+) usually indicate the truncation race was active (see Critical Incidents in AGENTS.md).
- Safe to delete: `sudo rm /worksp/hiclaw/workspace/openclaw.json.clobbered.*`

---

## Restoring a Truncated openclaw.json

If the manager is crash-looping with a jq parse error:

```bash
# Option 1: restore from the local .bak
sudo cp /worksp/hiclaw/workspace/openclaw.json.bak /worksp/hiclaw/workspace/openclaw.json

# Option 2: restore from MinIO (if local .bak is also bad)
docker exec hiclaw-controller mc cp \
  hiclaw/hiclaw-storage/manager/openclaw.json.bak \
  hiclaw/hiclaw-storage/manager/openclaw.json

# Verify the file is valid JSON
python3 -m json.tool < /worksp/hiclaw/workspace/openclaw.json > /dev/null && echo "OK"

# The manager will pick up the restored file on its next restart cycle automatically.
# If it doesn't restart on its own within 60 seconds:
docker restart hiclaw-manager
```

---

## Making Config Changes to openclaw.json

**Safe procedure while gateway is running:**

1. Edit `/worksp/hiclaw/workspace/openclaw.json` directly (it's bind-mounted as `/root/manager-workspace/openclaw.json`).
2. OpenClaw's file watcher detects the change and evaluates a reload.
3. **Most field changes** trigger a graceful in-process reload (SIGUSR1) — no disconnect.
4. **Plugin config changes** (`plugins.entries.*`) require a gateway restart — users will see a ~10s disconnect.

**Do NOT:**
- Edit openclaw.json while a jq pipeline is also writing it (the startup script, keeper, or MinIO sync) — partial writes truncate the file.
- Change `commands` away from `{"restart": true}` — the reconciler loop will cause continuous restarts.
- Add a wildcard `"*"` key to `channels.matrix.groups` — OpenClaw schema rejects it.

**After editing, the MinIO sync pushes the change automatically within 10 seconds.**

---

## Triggering an OpenClaw Version Update

The correct procedure — do NOT run `openclaw update` directly inside the container.

```bash
# Step 1: Write the update marker
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > /worksp/hiclaw/workspace/.openclaw-update-requested

# Step 2: Run the bootstrap keeper (or wait for its next cron cycle)
bash /worksp/hiclaw/manager-bootstrap-keeper.sh
# The keeper will:
#   1. Run: docker exec hiclaw-manager openclaw update --yes --json
#   2. Sleep 30s (to let the in-process SIGUSR1 restart complete and flush writes)
#   3. Detect the package hash changed → docker restart hiclaw-manager

# Step 3: Verify the new version
docker exec hiclaw-manager openclaw --version
```

**Why the keeper, not direct?** `openclaw update` triggers a SIGUSR1 in-process restart inside OpenClaw. If `docker restart` runs before that restart finishes writing openclaw.json, the file gets truncated. The keeper's `sleep 30` prevents this race.

---

## Running the Keepers Manually

```bash
# Bootstrap keeper: patches startup script into container, re-applies memory limits,
# handles openclaw updates, detects hash changes → docker restart
bash /worksp/hiclaw/manager-bootstrap-keeper.sh

# Config keeper: stabilizes openclaw.json fields (clawtalk entry, bootstrapMaxChars,
# dmScope=main, commands={"restart":true}, no wildcard groups, context window enforcement)
bash /worksp/hiclaw/manager-config-keeper.sh
```

Both run automatically every minute from the `ai` user's crontab. Running them manually is safe.

---

## Testing the Gateway WebSocket

To verify the control panel WebSocket works end-to-end:

```bash
# From inside the controller (simulates Traefik backend)
docker exec hiclaw-controller curl -sv \
  -H "Connection: Upgrade" \
  -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  -H "Sec-WebSocket-Version: 13" \
  http://hiclaw-manager:18799/ 2>&1 | head -20
# Expected: HTTP 101 Switching Protocols
```

If you get `Connection refused`: manager port 18799 is not listening yet (still starting up, or crashed).
If you get `000`: DNS resolution failure or network issue.

---

## Common Failure Modes Quick Reference

| Symptom | Likely cause | First check |
|---|---|---|
| 502 on control.claw | Manager down / crash loop | `docker ps \| grep hiclaw-manager` |
| Manager restarts every ~50s | openclaw crash after startup | `docker logs hiclaw-manager 2>&1 \| tail -20` |
| jq parse errors in logs | Truncated openclaw.json | `wc -c /worksp/hiclaw/workspace/openclaw.json` (should be ~9300 bytes) |
| `Cannot find module openai/index.mjs` | Partial npm install | `docker exec hiclaw-manager ls /usr/lib/node_modules/openclaw/node_modules/openai/index.mjs` |
| Control panel "protocol mismatch" | Version skew (base image vs npm-updated) | `docker exec hiclaw-manager openclaw --version` |
| WebSocket 1006 disconnect | Gateway not running when UI connects | Check gateway port 18799 is listening |
| Reload loop every 15-30s | Config keeper modifying openclaw.json | Normal if only models/clawtalk fields — check if plugins.entries changes |
| 288+ restarts in inspect | Long-running crash loop (historical) | Check `docker inspect hiclaw-manager --format '{{.RestartCount}}'` |
