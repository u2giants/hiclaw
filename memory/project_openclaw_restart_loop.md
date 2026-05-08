---
name: OpenClaw restart loop root cause
description: Why the hiclaw-manager OpenClaw gateway enters restart loops and how to stabilize it
type: project
originSessionId: 285f6a79-bddf-4181-adea-8dc1d85214f2
---
The HiClaw controller (hiclaw-controller container) periodically writes to the shared workspace file `/worksp/hiclaw/workspace/openclaw.json` (mounted as `/root/manager-workspace/openclaw.json` in hiclaw-manager). These writes include `"commands": {"restart": true}`. When OpenClaw detects a config change where `commands.restart` changes from `false` to `true`, it triggers a full gateway restart.

**Root cause chain:**
1. On container start, `start-manager-agent.sh` runs two jq passes:
   - Pass 1 (line 710): sets `commands.restart = (.commands.restart // false)` ← PATCHED
   - Pass 2 / k8s overlay (line 785): sets `commands.restart = (.commands.restart // false)` ← PATCHED
   - Final file state: preserves existing value, defaults to false if missing
2. hiclaw-controller reconciliation loop writes `restart=true` → diff false→true → full restart
3. After restart, OpenClaw re-reads `restart=true` as its "last known" state
4. Controller writes `restart=true` again → diff true→true (NO CHANGE) → only hot reload
5. System stabilizes

**The loop problem:**
If something resets `restart` to `false` (like a container restart re-running start-manager-agent.sh), step 2 repeats.

**Fix applied (2026-05-05, session 2):**
Both `.commands.restart = false` lines in `/opt/hiclaw/scripts/init/start-manager-agent.sh` (lines 710 and 785) were changed to `.commands.restart = (.commands.restart // false)`. This preserves `true` if the value is already true, and only defaults to `false` if the key is missing or null. Backup at `.bak2`. NOTE: This change is in the container overlay and will be lost on container image update.

**Current state (as of 2026-05-05 ~21:04 UTC):**
- Running OpenClaw v2026.5.4 (latest), installed via npm global
- `commands.restart=true` in both file and runtime config
- Gateway stable after in-process restart (PID 1, no container restart)
- `sigusr1ExternalAllowed=true` in module state (set by config change, persists across in-process restart)
- start-manager-agent.sh patched — future container restarts will preserve restart=true

**Update button fix (session 2, 2026-05-05):**
The button was failing silently (30-40 seconds then no version change) because:
1. npm install succeeded (runGatewayUpdate status=ok)
2. `scheduleGatewaySigusr1Restart` was called post-update
3. SIGUSR1 arrived at the handler but `consumeGatewaySigusr1RestartAuthorization()` returned false (authorization deadlock from a previous ignored SIGUSR1 that left `emittedRestartToken > consumedRestartToken`)
Recovery: Write `{"kind":"gateway-restart","pid":1,"createdAt":<now_ms>,"force":true}` to `/root/.openclaw/gateway-restart-intent.json` then `kill -USR1 1` — this bypasses all authorization checks via the restart intent file path in the SIGUSR1 handler.

**In-process vs container restart:**
- In-process restart: PID 1 (openclaw) stays alive, reinitializes, `start-manager-agent.sh` does NOT re-run. Triggered by config change (false→true) or authorized SIGUSR1.
- Container restart: PID 1 exits, Docker restarts container, `start-manager-agent.sh` re-runs. Triggered by: openclaw process crashing, or restart intent file + SIGUSR1 triggering a "fresh PID" restart path.

**Why Matrix messages were going unanswered:**
Each restart caused the Matrix sync token to advance past pending admin messages. After restart, messages older than the sync token were "skipped" by the Matrix plugin. The admin's messages from 09:02 NY time (13:02 UTC) were delayed ~54 minutes before being processed.

**Architecture notes:**
- hiclaw-controller container has `/worksp/hiclaw/workspace` mounted at `/root/hiclaw-fs/agents/manager`
- hiclaw-manager container has `/worksp/hiclaw/workspace` mounted at `/root/manager-workspace`
- These are the SAME host directory - so controller writes go directly to manager's config
- hiclaw-controller MinIO push to `agents/manager/openclaw.json` FAILS due to permission errors (using `default` MinIO user without write permission)
- OPENCLAW_NO_RESPAWN is NOT in env but gateway uses "in-process restart (OPENCLAW_NO_RESPAWN)" mode
- Running OpenClaw is at `/usr/lib/node_modules/openclaw/` (npm global install, v2026.5.4 as of this session)
- `/opt/openclaw/` is a DIFFERENT (older, v2026.4.14) development/source directory — NOT the running version
- Gateway token: `5de86910dec50bf9d9162682d9a7f468143b85ee68c5deb316ad081b5a97ab0c`
- Matrix DM room: `!Yzg8FAvvzjKsYTBJb3:matrix-local.hiclaw.io:18080`

**How to apply:** When HiClaw Matrix messages go unanswered, first check if `commands.restart` is oscillating between true/false. Use `docker exec hiclaw-manager openclaw gateway call config.get --json` to check the runtime value. To stabilize: ensure `commands.restart=true` in both file and runtime. If runtime differs from file, use `docker exec hiclaw-manager bash -c 'jq ".commands.restart = true" /root/manager-workspace/openclaw.json > /tmp/t.json && mv /tmp/t.json /root/manager-workspace/openclaw.json'`.

**Restart intent file (emergency restart bypass):**
If SIGUSR1 is deadlocked (restart ignored, "coalesced already in-flight"), write:
`docker exec hiclaw-manager bash -c 'echo "{\"kind\":\"gateway-restart\",\"pid\":1,\"createdAt\":$(date +%s%3N),\"force\":true}" > /root/.openclaw/gateway-restart-intent.json && kill -USR1 1'`
WARNING: This causes a container restart (not in-process), so start-manager-agent.sh will re-run.
