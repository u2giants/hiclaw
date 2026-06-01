# AGENTS.md — HiClaw Project

> **Start here.** Read this before touching anything. A new session should be productive within 5 minutes of reading this file.

---

## 1. What This Project Is

HiClaw is an AI agent orchestration platform running on a single dedicated Linux server (`178.156.180.212`). It is built on the HiClaw controller+manager stack (open-source, by Alibaba/Higress).

- **hiclaw-controller** (`higress/hiclaw-embedded:v1.1.2`) — runs Tuwunel (Matrix homeserver), Higress (AI gateway/LLM proxy), MinIO (object storage), and Element Web (chat UI). It is supervisord-managed inside one container.
- **hiclaw-manager** (`higress/hiclaw-manager:v1.1.2`) — runs the OpenClaw gateway (agent runtime). Agents receive tasks via Matrix DMs, call an LLM (DeepSeek via OpenRouter), and automate a live Chrome browser via CDP.
- **novnc-desktop** (`ghcr.io/u2giants/novnc-desktop:latest`) — Chrome in a box via noVNC; the only image this repo builds.
- **oauth2-proxy** — Google OAuth gate for all web-facing services.

Albert uses this system as his personal AI operations platform. He is not a developer — AI agents are expected to manage this system autonomously.

---

## 2. Multi-Model Note

There is no universal ignore-file standard across AI coding tools.
`.claudeignore` works for Claude Code; `.cursorignore` for Cursor;
`.copilotignore` for GitHub Copilot. When using any other AI tool
(Gemini, ChatGPT, etc.), paste this file as your first message
and follow the instructions in the 'What to ignore' section.

---

## 3. Repository / Package Structure

```
hiclaw/
├── AGENTS.md                    ← primary AI/developer guide (this file)
├── CLAUDE.md                    ← Claude Code-specific instructions
├── README.md                    ← user-facing overview
├── .env.example                 ← all env var names + descriptions (no real values)
├── .gitignore / .claudeignore / .cursorignore
├── .github/
│   ├── workflows/
│   │   └── build-and-push.yml   ← builds novnc-desktop → GHCR; Coolify step is dead
│   └── dependabot.yml
├── docs/
│   ├── architecture.md          ← system design, data flow
│   ├── configuration.md         ← all env vars, config files
│   ├── deployment.md            ← how things get deployed
│   └── development.md           ← local workflow and debugging
├── novnc-desktop/               ← THE ONLY DOCKER IMAGE WE BUILD
│   ├── Dockerfile
│   ├── novnc-startup.sh         ← Chrome watchdog, CDP proxy launch
│   ├── cdp_proxy.py             ← WebSocket proxy Chrome 9222→9223
│   └── recreate.sh              ← convenience wrapper for docker rm + run
├── traefik/
│   └── claw.yml                 ← Traefik dynamic config (mirror of /data/coolify/proxy/dynamic/claw.yml)
├── oauth2-proxy/
│   ├── docker-compose.yml
│   ├── .env                     ← live Google OAuth credentials (committed — contains secrets)
│   ├── .env.example
│   └── allowed-emails.txt
└── [keeper/start scripts at root]
    ├── controller-bootstrap-keeper.sh   ← keeps hiclaw-controller alive
    ├── manager-bootstrap-keeper.sh      ← keeps hiclaw-manager alive + handles openclaw updates
    ├── manager-config-keeper.sh         ← stabilizes openclaw.json against reconciler drift
    ├── mcp-keeper.sh                    ← ensures mcp.servers.browser stays in openclaw.json
    ├── start-element-web.sh             ← container entrypoint in hiclaw-controller (nginx + JS)
    ├── start-manager-agent.sh           ← container entrypoint in hiclaw-manager (1689 lines)
    ├── start-tuwunel.sh                 ← Matrix homeserver entrypoint in hiclaw-controller
    └── fix-element-config.sh            ← one-off post-upgrade repair script (idempotent)
```

**We do not own:** the hiclaw-controller and hiclaw-manager images (from Alibaba/Higress registry). Do not try to build or modify them. Their behavior is configured via `openclaw.json` and environment variables.

---

## 4. The Prime Directive

**Our code lives in:**
- `novnc-desktop/` — the only Docker image we build
- All `.sh` scripts at repo root — startup and keeper scripts
- `oauth2-proxy/` — our config for the auth proxy

**Off-limits without careful deliberation:**
- The running hiclaw-manager and hiclaw-controller containers — never hand-edit files inside them as a permanent fix. Script it or mount it.
- `/worksp/hiclaw/workspace/` — runtime data written by the containers. Treat as read-only except for `openclaw.json` targeted fixes.
- The Coolify UI for hiclaw-unmanaged containers — those are managed by our scripts.

**Rule:** If a fix involves `docker exec hiclaw-manager some-edit`, it is temporary. The permanent fix goes in `start-manager-agent.sh` or a mounted file so it survives container restarts.

---

## 5. Core Modification Inventory

Changes we made to files that live inside upstream container images or would otherwise be off-limits:

| File | Location | Change | Why |
|---|---|---|---|
| `start-manager-agent.sh` — openclaw.json block | Our script (we own it) | Clears `commands.restart` via `del(.commands.restart)` so startup does not leave the restart-trigger field populated | Prevents restart loop when keeper writes `commands:{restart:true}` and reconciler writes null — see Idiosyncratic Decision §commands.restart |
| `start-manager-agent.sh` — launch block | Our script (we own it) | Installs fake `/usr/local/bin/systemd-run`; exports `OPENCLAW_SYSTEMD_UNIT=openclaw-gateway`; validates npm openclaw install (json5 + openai/index.mjs); resets symlink to base image when invalid; records startup pkg hash to workspace volume | Enables UI update flow; catches broken OOM-partial installs; enables host-side hash detection |
| `manager-bootstrap-keeper.sh` | Our script (we own it) | Added `.openclaw-update-requested` marker consumption → `openclaw update --yes --json` + `sleep 30` + docker restart; changed `--memory-swap` from `768m` to `3g`; changed `--memory` from `768m` to `1536m` | Marker-based update flow; 30s sleep prevents SIGUSR1 write-truncation race; 768m swap = 0 available → OOM during npm install |
| `manager-config-keeper.sh` | Our script (we own it) | Fixed `.bak` path; added `channels.matrix.groups["*"]` deletion; enforces contextWindow for deepseek models; updates config-health.json hash atomically | Wrong `.bak` path let observe-recovery restore stale config; `"*"` wildcard rejected by OpenClaw schema |
| `clawtalk/index.cjs` + `package.json` | Inside hiclaw-manager at `.openclaw/npm/node_modules/clawtalk/` | CJS wrapper for ESM plugin; `openclaw` field points to `index.cjs` | clawtalk uses ES modules; OpenClaw requires CJS. **EPHEMERAL — recreated by `start-manager-agent.sh` bootstrap on every container start.** |

---

## 6. Decision Tree

**I need to change Chrome behavior (flags, startup, watchdog):**
→ Edit `novnc-desktop/novnc-startup.sh` → commit → pipeline builds new image → apply: `bash /worksp/hiclaw/novnc-desktop/recreate.sh`

**I need to change Chrome's baked-in wrapper or Dockerfile:**
→ Edit `novnc-desktop/Dockerfile` → commit → pipeline → recreate novnc-desktop

**I need to change the CDP proxy (port forwarding, filtering):**
→ Edit `novnc-desktop/cdp_proxy.py` IN-PLACE on the server using the Edit tool (NOT Write, NOT cp) — see Idiosyncratic Decisions §cdp_proxy.py. Also commit the change.

**I need to change the OAuth gate (who can log in, redirect URL, cookie):**
→ Edit `oauth2-proxy/docker-compose.yml` and/or `allowed-emails.txt` → commit → `cd /worksp/hiclaw/oauth2-proxy && docker compose up -d`

**I need to add/change a Traefik routing rule:**
→ Edit `traefik/claw.yml` → commit → `docker cp traefik/claw.yml coolify-proxy:/traefik/dynamic/claw.yml` (Traefik hot-reloads; no restart needed)

**I need to change hiclaw-manager startup behavior:**
→ Edit `start-manager-agent.sh` → commit → git pull on server → the manager-bootstrap-keeper detects the script hash change and patches it into the container automatically within 1 minute → takes effect on next container restart

**I need to update openclaw via the UI:**
→ Click "Update now" in the OpenClaw Control UI. The fake `systemd-run` writes a marker; manager-bootstrap-keeper detects it within 60s and runs `openclaw update --yes --json` + `sleep 30` + `docker restart`. Do NOT run `openclaw update` directly — see Idiosyncratic Decisions §openclaw update.

**I need to update openclaw manually (emergency):**
→ Pause both manager-config-keeper and manager-bootstrap-keeper cron entries (replace with no-op). Wait for no SIGUSR1 activity in logs. Then: `docker update --memory 1536m --memory-swap 3g hiclaw-manager && docker exec hiclaw-manager openclaw update --yes`. Wait 30+ seconds. Re-enable crons. The bootstrap keeper hash check triggers `docker restart` automatically.

**I need to add or change an environment variable:**
→ Update `.env.example` + `docs/configuration.md` + `AGENTS.md` credentials section → commit

**I need to add a new allowed Google account:**
→ Edit `oauth2-proxy/allowed-emails.txt` → commit → restart oauth2-proxy

**I need to fix the OpenClaw gateway config in-process:**
→ Modify `/worksp/hiclaw/workspace/openclaw.json` directly (it's a host file on the bind-mount) → the file-watcher triggers a reload automatically. BUT: the manager-config-keeper runs every ~15s and will overwrite changes that conflict with its invariants — check the keeper source first.

**I need to change what Element Web shows at login or after Google OAuth:**
→ Edit `start-element-web.sh` (it generates `auto-login.js`, `auth-ui-tweaks.js`, `manager-console.conf`, etc. on container start) → commit → git pull on server → controller-bootstrap-keeper will detect the script change and restart hiclaw-controller.

---

## 7. Task-to-File Navigation Map

| Task | File to touch |
|---|---|
| Traefik routing rules | `traefik/claw.yml` → apply with `docker cp traefik/claw.yml coolify-proxy:/traefik/dynamic/claw.yml` |
| Chrome launch flags / watchdog | `novnc-desktop/novnc-startup.sh` |
| Chrome Dockerfile / base image | `novnc-desktop/Dockerfile` |
| CDP WebSocket proxy | `novnc-desktop/cdp_proxy.py` (Edit tool in-place only) |
| Recreate novnc-desktop container | `novnc-desktop/recreate.sh` |
| OAuth allowed users | `oauth2-proxy/allowed-emails.txt` |
| OAuth config (client ID, redirect URL) | `oauth2-proxy/docker-compose.yml` |
| hiclaw-manager startup / env vars | `start-manager-agent.sh` |
| hiclaw-manager crash recovery / resource limits | `manager-bootstrap-keeper.sh` |
| openclaw update UI flow | `manager-bootstrap-keeper.sh` (consumes `.openclaw-update-requested`) |
| hiclaw-manager resource limits | `manager-bootstrap-keeper.sh` (`docker update --memory 1536m --memory-swap 3g --cpus 1`) |
| OpenClaw config stabilization | `manager-config-keeper.sh` |
| hiclaw-controller crash recovery | `controller-bootstrap-keeper.sh` |
| MCP browser tool keepalive | `mcp-keeper.sh` |
| Element Web nginx + JS injections | `start-element-web.sh` |
| Matrix homeserver (tuwunel) | `start-tuwunel.sh` |
| OpenClaw runtime config | `/worksp/hiclaw/workspace/openclaw.json` (host file, not in git) |
| GitHub Actions build pipeline | `.github/workflows/build-and-push.yml` |
| All env var documentation | `docs/configuration.md` + `.env.example` |
| Auto-login after Google OAuth | `start-element-web.sh` → `auto-login.js` section |
| nginx proxy for control.claw (18888→18799) | `start-element-web.sh` → `manager-console.conf` block |
| Model context window metadata | `start-manager-agent.sh` OpenRouter sync block (~line 772) |
| Post-upgrade container repair | `fix-element-config.sh` |

---

## 8. Data Model and External Identifiers

**No application database managed by this repo.** hiclaw-controller has its own embedded RocksDB (Tuwunel) and MinIO — we do not run migrations.

**Persistent storage:** MinIO inside hiclaw-controller (port 9000 internal, exposed on `http://hiclaw-controller:9000`).
- Bucket: `hiclaw-storage`
- Manager prefix: `hiclaw/hiclaw-storage/manager/`
- OpenClaw config in MinIO: `hiclaw/hiclaw-storage/manager/openclaw.json`

**OpenClaw config file (live):** `/worksp/hiclaw/workspace/openclaw.json` — bind-mounted from host into hiclaw-manager at `/root/manager-workspace/openclaw.json`. Also mounted read-only into hiclaw-controller at `/root/hiclaw-fs/agents/manager/openclaw.json`.

**Matrix DM room ID:** `!Yzg8FAvvzjKsYTBJb3:matrix-local.hiclaw.io:18080` — permanent, do not change.

**Matrix server domain:** `matrix-local.hiclaw.io:18080`

**AI gateway URL:** `http://aigw-local.hiclaw.io:8080/v1` (internal; LLM requests go through Higress)

**OpenClaw gateway API key (in openclaw.json + auth token):** `5de86910dec50bf9d9162682d9a7f468143b85ee68c5deb316ad081b5a97ab0c`

**CDP endpoint (hardcoded):** `http://10.0.5.4:9223` — static IP on the `e10kwzww46ljhrgz1qj08j6a` Docker network. Do not change without updating all openclaw.json MCP configs.

**Public domains:**
- `claw.designflow.app` — Element Web (Matrix chat UI)
- `control.claw.designflow.app` — OpenClaw control panel (hiclaw-manager)
- `gateway.claw.designflow.app` — OpenClaw gateway API
- `vnc.designflow.app` — noVNC desktop

**Traefik routing chain for control.claw:**
```
User → Traefik (coolify-proxy) → oauth2-proxy (Google auth) → hiclaw-controller port 18888 nginx
     → resolver 127.0.0.11 → hiclaw-manager:18799 (OpenClaw gateway)
```
The controller's nginx at port 18888 is generated by `start-element-web.sh` and injects the gateway token via `sub_filter`. See Idiosyncratic Decisions §nginx chain.

---

## 9. Container and Service Inventory

| Container | Image | Function | Managed By | Networks | Key Ports |
|---|---|---|---|---|---|
| `hiclaw-controller` | `higress/hiclaw-embedded:v1.1.2` | Tuwunel Matrix + Higress AI gateway + MinIO + Element Web nginx | `controller-bootstrap-keeper.sh` (cron) | `hiclaw-net` | 8001→18001, 8080→18080, 8088→18088 |
| `hiclaw-manager` | `higress/hiclaw-manager:v1.1.2` | OpenClaw gateway + agent runtime + Matrix client | `manager-bootstrap-keeper.sh` (cron) | `hiclaw-net` | 18799→127.0.0.1:18888 |
| `novnc-desktop` | `ghcr.io/u2giants/novnc-desktop:latest` | Chrome browser via noVNC; CDP automation target | `novnc-desktop/recreate.sh` (manual) | `e10kwzww46ljhrgz1qj08j6a` (IP 10.0.5.4) + `coolify` | 3000/tcp |
| `oauth2-proxy` | `quay.io/oauth2-proxy/oauth2-proxy:latest` | Google OAuth gate for Traefik forwardAuth | `oauth2-proxy/docker-compose.yml` | `coolify` | 4180/tcp |
| `coolify-proxy` | `traefik:v3.6` | Reverse proxy + TLS termination | Coolify | `coolify` | 80, 443 |
| `coolify` | `ghcr.io/coollabsio/coolify:4.1.1` | Deployment UI (does NOT manage manager/controller) | systemd | `coolify` | 8000→8080 |

**Resource limits on hiclaw-manager** (set by `manager-bootstrap-keeper.sh` on each patch cycle):
- `--memory 1536m` (1536 MiB RAM)
- `--memory-swap 3g` (3 GiB total = ~1.5 GiB usable swap)
- `--cpus 1`

**Resource limits on hiclaw-controller** (set by `controller-bootstrap-keeper.sh`):
- `--memory 2g --memory-swap 2g --cpus 2`

**NOT in Coolify:** hiclaw-manager, hiclaw-controller, oauth2-proxy, novnc-desktop. Coolify manages only the proxy, its own DB/Redis, and unrelated services. See Idiosyncratic Decisions §not in Coolify.

**Image versions currently deployed:** both controller and manager on `v1.1.2` (upgraded from v1.1.0). openclaw inside manager: `2026.5.28` (npm-installed overlay over base image `2026.4.14`).

---

## 10. What to Ignore

These exist on the server but are not in the repo and are not relevant to development:

- `workspace/` — runtime data: agent state, OpenClaw config, npm packages, browser cache. Written by containers at runtime. **Not in git.**
- `.state/` — keeper script state tracking (last container ID hashes). **Not in git.**
- `*.log` — keeper and bootstrap logs. **Not in git.**
- `workspace/openclaw.json.clobbered.*` — observe-recovery forensic snapshots of truncated/corrupted configs. Normal; excluded from MinIO sync. See Idiosyncratic Decisions §clobbered files.
- `workspace/.openclaw/` — openclaw internal state, plugin installs, Matrix crypto DB. Do not modify.
- `workspace/hiclaw/` — if this directory exists, it is a MinIO recursion artifact. Delete it immediately and investigate. See Incident 4.

---

## 11. Idiosyncratic Decisions

### Fake systemd-run enables openclaw update on Linux without systemd

**Looks like:** `/usr/local/bin/systemd-run` is an unusual file to create. `OPENCLAW_SYSTEMD_UNIT=openclaw-gateway` looks like a leftover env var.

**Actually:** On Linux, openclaw's `detectRespawnSupervisor()` returns `"systemd"` only when `OPENCLAW_SYSTEMD_UNIT` (or `INVOCATION_ID` / `JOURNAL_STREAM`) is set. Without it, `update.run` returns `managed-service-handoff-unavailable` and the UI "Update now" button does nothing. The managed-service handoff path spawns a detached helper via `systemd-run --user --scope`. Our fake intercepts that call, writes `.openclaw-update-requested` to the bind-mounted workspace, and exits 0. The gateway thinks the handoff succeeded and schedules a SIGUSR1 in-process restart. `manager-bootstrap-keeper.sh` (cron, every minute) sees the marker, removes it, runs `docker exec hiclaw-manager openclaw update --yes --json`, waits 30 seconds, then runs `docker restart hiclaw-manager`.

**Do not change because:** Removing `OPENCLAW_SYSTEMD_UNIT` restores `managed-service-handoff-unavailable`. Removing the fake `systemd-run` throws "systemd-run is required". Both are recreated on every container start by `start-manager-agent.sh`.

---

### openclaw update MUST go through the keeper (not direct docker exec)

**Looks like:** Running `docker exec hiclaw-manager openclaw update --yes` directly is the simplest way to update.

**Actually:** The direct command bypasses the memory-limit expansion needed for npm install. The container's Docker resource limits are `--memory 1536m --memory-swap 3g` — the keeper sets these on each patch cycle, but `npm install` for openclaw peaks above 1536m and needs the swap headroom. The keeper runs: `docker update --memory 1536m --memory-swap 3g` before any update. Direct exec without those limits causes SIGKILL mid-install.

Additionally: after the update, openclaw sends itself SIGUSR1 for an in-process restart. This restart includes a write phase where `openclaw.json` is rewritten. If `docker restart` fires during this window, the file is truncated (103 confirmed instances during 2026-05-31 incident). The keeper adds `sleep 30` between the update completion and the docker restart.

**Do not change because:** Bypassing the keeper risks partial installs (json5/openai missing), truncated configs, and crash loops. Emergency manual procedure is in section 6 Decision Tree.

---

### openclaw.json truncation: 30-second sleep prevents mid-write docker restart

**Looks like:** `sleep 30` after `openclaw update` in `manager-bootstrap-keeper.sh` seems arbitrary.

**Actually:** When `openclaw update --yes --json` completes, openclaw does an in-process SIGUSR1 restart (because `OPENCLAW_NO_RESPAWN=1`). During this restart it rewrites `openclaw.json` on the bind-mounted volume. The write takes up to ~10 seconds on the server's storage. If `docker restart` fires before the write completes, the container is killed mid-write and the volume file is left truncated (consistently at 8788 bytes vs the full 9283 bytes). This happened 103 times in the period 2026-05-31T16:50 to 2026-06-01T00:19, leaving 211 `.clobbered.*` forensic files.

**Evidence:** 211 `workspace/openclaw.json.clobbered.*` files with size distribution: 103 at 8788 bytes, 59 at 9375 bytes, 43 at 9283 bytes. All from the period before the sleep was added.

**Fix (committed a93488c):** `sleep 30` inserted in `manager-bootstrap-keeper.sh` between openclaw update completion and the hash-change docker restart.

**Do not change because:** Removing the sleep re-introduces the truncation race. The 30 seconds is a conservative bound; actual write takes 5-15 seconds but the sleep covers storage I/O variance.

---

### npm install validation checks json5 AND openai/index.mjs, not just json5

**Looks like:** Checking for `json5/package.json` was the original validation. Why add `openai/index.mjs`?

**Actually:** A different OOM failure mode (2026-06-01) left the `openai` package in a state where all `.mjs` files were absent but `.map` files were present. `json5/package.json` was intact, so the existing validation passed. The gateway crashed on first request with `Cannot find module openai/index.mjs`. The json5 check was necessary but not sufficient.

**Current validation in `start-manager-agent.sh`** (both must exist for npm install to be accepted):
1. `/usr/lib/node_modules/openclaw/node_modules/json5/package.json`
2. `/usr/lib/node_modules/openclaw/node_modules/openai/index.mjs`

If either is absent: remove the broken install directory, reset the `/usr/local/bin/openclaw` symlink to `/opt/openclaw/` (base image, v2026.4.14), continue startup. The base image version always works.

**Do not change because:** The binary-existence check for `openclaw.mjs` itself is insufficient — a partial install that passes binary existence can still crash the gateway on first real request.

---

### commands.restart must not persist in openclaw.json

**Looks like:** The startup script sets `commands.restart=true` so the gateway starts. The config keeper sets it back to `{restart:true}` on every run. This looks like it would cause continuous restarts.

**Actually:** The OpenClaw gateway only restarts when `commands.restart` CHANGES relative to the startup baseline recorded in `config-health.json`. The baseline is captured from the file as loaded at first boot. If the startup file has `commands.restart:true` and every subsequent write also has `commands.restart:true`, the diff shows no change → no restart triggered.

The problem arises when `commands.restart` is LEFT in the file after startup. The ManagerReconciler (inside hiclaw-controller) writes `commands:null` approximately every 47 seconds. That is a diff from `{restart:true}` to `null` → restart triggered. The config keeper's job is to prevent that drift by immediately rewriting `{restart:true}` whenever the reconciler sets it to null.

However: the startup script itself does NOT write `commands.restart:true` into openclaw.json as a permanent field. Instead, `start-manager-agent.sh` uses `del(.commands.restart)` in its jq patches to remove the field before launch, then sets it via the gateway's startup signal. The keeper then maintains it in steady state.

**If a restart loop appears (every ~47s or ~5min):**
1. Check: `sudo python3 -c "import json; d=json.load(open('/worksp/hiclaw/workspace/openclaw.json')); print(d.get('commands'))"`
2. Expected: `{'restart': True}`
3. If null, {}, or missing: keeper is not running or failing. Check: `crontab -l | grep keeper`
4. Check config-health.json baseline matches: see Incident 2 emergency recovery.

---

### channels.matrix.groups must never have a wildcard key "*"

**Looks like:** Having a catch-all `"*"` group key would be convenient for default group policy.

**Actually:** The current OpenClaw schema uses `additionalProperties: false` on the groups object. Any key not explicitly listed (including `"*"`) causes config validation to fail with `invalid config: must NOT have additional properties`. When validation fails, every config reload is rejected with "config reload skipped (invalid config)", AND `update.run` returns `managed-service-handoff-unavailable`. This is a silent failure — the gateway keeps running on the last good config but all config changes are silently dropped.

**Where it comes from:** The ManagerReconciler writes `channels.matrix.groups["*"]` as part of its template on every reconcile cycle (~every 47s).

**Fix:** `manager-config-keeper.sh` deletes the `"*"` key on every run (Python: `d['channels']['matrix']['groups'].pop('*', None)`). The keeper runs every ~15 seconds (the file-watcher triggers it on the reconciler's write), so the key is present for at most ~15 seconds at a time.

---

### config-health.json must be updated atomically with openclaw.json

**Looks like:** Writing `openclaw.json` is sufficient to change the config.

**Actually:** OpenClaw's observe-recovery mechanism (`watch_config_health`) monitors `config-health.json`. It stores the last known good hash, byte count, and file stat metadata for `openclaw.json`. When a hash mismatch is detected (e.g., after a truncated write), observe-recovery restores from the `.bak` file and overwrites the current `openclaw.json`.

If you write a new `openclaw.json` without updating `config-health.json`, observe-recovery sees a hash mismatch and immediately reverts your change. The keeper updates both atomically: writes the new config, then rewrites the `lastKnownGood` entry in `config-health.json` with the new hash and current stat fields.

**Also required:** Delete `openclaw.json.bak` after any config update. If the `.bak` exists and its hash matches the old (pre-change) config, observe-recovery will restore from it and undo the change.

**File paths:**
- Config: `/worksp/hiclaw/workspace/openclaw.json`
- Backup: `/worksp/hiclaw/workspace/openclaw.json.bak`
- Health state: `/worksp/hiclaw/workspace/.openclaw/logs/config-health.json`

---

### hiclaw-manager and hiclaw-controller are NOT in Coolify

**Looks like:** These are the core services — why aren't they Coolify-managed?

**Actually:** They use a shared bind mount (`/worksp/hiclaw/workspace`) that Coolify's docker-compose model cannot accommodate cleanly for this image. More critically, `start-manager-agent.sh` (1689 lines) performs complex initialization that cannot be expressed as a Compose file: conditional runtime selection, Matrix account registration, MinIO sync with exclude guards, OpenRouter model sync, clawtalk bootstrap, hash recording. These must run inside the container as PID 1.

Keeper scripts run as cron jobs and handle: restart-on-crash, startup script patching, resource limit re-application, openclaw update detection. This is fully equivalent to what Coolify would provide, without the UI overhead.

**Do not change because:** Migrating to Coolify is a multi-day project requiring a complete rewrite of the startup logic. Low priority while the keepers work reliably.

---

### manager-config-keeper.sh modifies openclaw.json every ~15 seconds (this is normal)

**Looks like:** The keeper writing to `openclaw.json` every 15 seconds triggers constant file-watcher events and SIGUSR1 restarts — this seems like a bug or a loop.

**Actually:** The keeper writes only when it detects a change that needs fixing (reconciler wrote `commands:null`, wrote `"*"` group key, drifted contextWindow, etc.). After the fix, the new file hash is written to `config-health.json`. The file-watcher sees the hash change and triggers a hot reload. If the change is a schema-only fix (no `commands.restart` diff), the reload completes in ~1 second with no gateway restart. This is normal and expected — the config momentarily drifts, the keeper fixes it, the gateway hot-reloads.

The ONLY case where keeper activity causes a full gateway restart is if `commands.restart` is missing or wrong relative to the startup baseline. The keeper ensures `{restart:true}` is always present, which matches the baseline and produces zero diff on the `commands` field.

**If you see constant restart loops in logs:** Check that `commands` in the live config is exactly `{"restart": true}`. Any deviation means either the keeper is not running or the baseline was reset.

---

### .clobbered.* files are observe-recovery artifacts (normal, excluded from MinIO sync)

**Looks like:** 211 files named `openclaw.json.clobbered.2026-05-31T...` in `workspace/` look like a serious problem.

**Actually:** When the bootstrap keeper detects that `openclaw.json` has been replaced with a worse version (shorter file, failed jq validation), it saves the bad version as `openclaw.json.clobbered.<ISO8601-timestamp>` before restoring from `.last-good`. These are forensic records.

The 211 files are from the period 2026-05-31T16:50 to 2026-06-01T00:19 when the truncation race was active (see Incident — openclaw.json truncation). After the 30s sleep fix (commit a93488c), no new clobbered files should accumulate.

**These files are excluded from MinIO sync** via the `--exclude '*.clobbered.*'` flag in the `mc mirror` call in `start-manager-agent.sh`. Safe to delete if disk space is needed: `rm /worksp/hiclaw/workspace/openclaw.json.clobbered.*`

---

### The Traefik→nginx→OpenClaw chain for control.claw

**Looks like:** Traefik should route directly to hiclaw-manager port 18799.

**Actually:** The chain is:
1. `control.claw.designflow.app` → Traefik (`coolify-proxy`) → `hiclaw-controller:18888` (port 18888 inside the controller container, generated by `start-element-web.sh`)
2. Inside hiclaw-controller nginx: `resolver 127.0.0.11; set $upstream hiclaw-manager; proxy_pass http://$upstream:18799;`
3. nginx also injects the gateway auth token via `sub_filter '</head>'` inline script so the Control UI auto-authenticates

The nginx intermediate step exists because:
- The auth token injection cannot happen at the Traefik layer
- The Docker DNS resolver (`127.0.0.11`) in the nginx config is required for IP-change resilience (hardcoded IPs break after `docker rm + run`)
- hiclaw-controller is on the `hiclaw-net` network and can resolve `hiclaw-manager` by name

**Port mapping note:** `hiclaw-manager:18799/tcp` is bound to `127.0.0.1:18888` on the host. The `18888` host port is NOT the same as the `18888` nginx port inside hiclaw-controller — the controller container uses the Docker network to reach hiclaw-manager directly via the container name, not via the host port binding.

---

### OPENCLAW_NO_RESPAWN=1 prevents spawning a detached child on config reload

**Looks like:** Setting `OPENCLAW_NO_RESPAWN=1` disables respawning — this sounds like it would cause the gateway to exit permanently on a restart signal.

**Actually:** Without `OPENCLAW_NO_RESPAWN`, a SIGUSR1 (config reload) causes openclaw to `exec` a new process, which on Linux causes the terminal to lose the child, which in a Docker PID 1 context means the container dies. `OPENCLAW_NO_RESPAWN=1` keeps the restart in-process (not via exec), so the container stays alive.

**Trade-off:** In-process restart means the Node.js module cache is NOT cleared. This is why openclaw updates require a full `docker restart` to take effect — the new hash-stamped dist files cannot be loaded into a running process that has cached the old file paths.

**Do not change because:** Removing this env var causes the container to exit on every config reload, which happens every ~15-47 seconds. The container would restart continuously.

---

### workspace/ bind-mount survives container restart but NOT docker rm

**Looks like:** `/worksp/hiclaw/workspace/` is persistent storage, so it survives everything.

**Actually:** `docker stop` + `docker start` preserves the container overlay (any files written inside the container persist). `docker rm` destroys the overlay. The bind-mount at `/worksp/hiclaw/workspace/` (on the host filesystem) always survives — but any files installed into the container overlay (npm packages at `/usr/lib/node_modules/openclaw/`, the fake systemd-run at `/usr/local/bin/systemd-run`, the clawtalk shim) are lost.

After `docker rm` + `docker run`:
- openclaw falls back to base image version (`/opt/openclaw/`, v2026.4.14) because npm install is gone
- Startup script recreates fake systemd-run, clawtalk shim, and hash file
- `manager-bootstrap-keeper.sh` detects the hash change (base image vs npm-installed) and triggers the UI update flow via the marker mechanism within ~2 minutes

**Rule:** Never `docker rm hiclaw-manager` during debugging. Use `docker stop` / `docker start`. If recreation is unavoidable, expect openclaw to run on v2026.4.14 until the update flow completes.

---

### MinIO sync: local→MinIO every 10s on file change; MinIO→local every 5 minutes

**Looks like:** The background sync loops in `start-manager-agent.sh` seem to create a risk of overwriting config changes.

**Actually:** The OpenRouter model sync (runs at startup) pushes updated `openclaw.json` to MinIO IMMEDIATELY after patching it (`mc cp ... openclaw.json hiclaw/hiclaw-storage/manager/openclaw.json`). This prevents the subsequent MinIO→local pull (which fires 5 minutes after the k8s startup block) from overwriting the freshly-patched config with the old stale MinIO copy.

The local→MinIO loop polls for files modified in the last 15 seconds and syncs every 10 seconds. It does not include `.clobbered.*` files (excluded) or the recursive `hiclaw/` prefix (excluded).

**If config changes are being mysteriously reverted:** Check if the MinIO copy is stale. Run: `docker exec hiclaw-manager mc cat hiclaw/hiclaw-storage/manager/openclaw.json | jq '.models.providers["hiclaw-gateway"].models | length'` and compare to the local count.

---

### cdp_proxy.py must be edited in-place (Edit tool, never Write or cp)

**Looks like:** Normal file replacement should work for a Python script.

**Actually:** `cdp_proxy.py` is bind-mounted into the novnc-desktop container. Docker bind mounts track the **inode**, not the path. When you replace a file on the host by writing a new file and moving it over the old one, Docker's bind mount still points to the old inode. The container process continues reading the old version.

**Always use:** The Edit tool (which edits in-place, preserving the inode) or `sed -i`. Never use Write tool or `cp src dst`.

---

### pkill uses unescaped | for alternation (ERE, not BRE)

**Looks like:** `pkill -f "google-chrome|/opt/google/chrome/chrome"` — the pipe looks like it should be escaped.

**Actually:** pkill uses Extended Regular Expressions (ERE). In ERE, `|` is alternation. `\|` is a literal pipe character. The previous version used `\|`, which silently matched nothing and allowed stale Chrome instances to survive — causing double-Chrome OOM (Incident 3).

---

### Chrome wrapper's pgrep guard must stay

**Looks like:** The Chrome wrapper checking pgrep before deleting Singleton files is unnecessary complexity.

**Actually:** Without the guard: if `google-chrome https://...` is called while Chrome is running (e.g., Dropbox OAuth callback), the wrapper deletes the lock file and Chrome spawns a second full instance. Two Chrome instances = ~2.2 GB RSS on a memory-constrained server = OOM crash (Incident 3, 2026-05-08).

**The guard:** Only delete Singleton files when `pgrep -x google-chrome` returns non-zero (no Chrome running). When Chrome is already running, skip the cleanup and Chrome opens the URL as a new tab in the existing instance.

---

### auto-login.js injects Matrix session directly, bypassing loginToken SSO flow

**Looks like:** The natural auto-login after Google OAuth is to use Element's `loginToken` URL parameter.

**Actually:** The `loginToken` flow triggers a full fresh login, which always presents the "verify this device" cross-signing screen in Element 1.12.x. This cannot be suppressed without rebuilding Element.

`start-element-web.sh` generates `auto-login.js` which POSTs to `/hiclaw-api/session` (a hiclaw-controller endpoint that returns a pre-existing access token + device ID) and writes these directly to `localStorage` under the `mx_*` keys. Element reads these on page load, enters "restore session" mode, and skips cross-signing entirely.

**Consequence:** The first login on a fresh install requires the manual SSO flow. All subsequent logins use the injected session.

---

### OpenRouter model sync writes response to file, not shell variable

**Looks like:** `MODELS=$(curl ... openrouter.ai/api/v1/models)` then jq should work.

**Actually:** The OpenRouter response is ~500KB+. Passing it as a shell variable or argument triggers "Argument list too long". `start-manager-agent.sh` writes the curl output to `/tmp/openrouter-models.json` and passes it to jq via `--slurpfile or_data /tmp/openrouter-models.json`. After sync, the updated config is pushed to MinIO immediately to prevent the background MinIO→local pull from overwriting the fresh values.

---

### openclaw schema rejects unknown model fields — del(.pricing) is required

**Looks like:** Extra fields in the models array are harmless.

**Actually:** OpenClaw validates each model object against a strict JSON schema. The `pricing` field (from OpenRouter API, previously written into openclaw.json by an early buggy sync version) causes the gateway to reject the entire config on startup, falling back to defaults and losing all customizations. `start-manager-agent.sh` runs `del(.pricing)` on every model entry on every startup as a defensive cleanup pass.

---

### bootstrap_clawtalk_plugin() deletes installs.json on every container start

**Looks like:** Deleting `installs.json` on every start forces a slow full rescan.

**Actually:** Required by an ordering constraint. The bootstrap creates the clawtalk bundled shim AFTER writing `installs.json`. Without the deletion, the gateway starts with a cached `installs.json` that predates the shim and reports "plugin not found: clawtalk". The rebuild adds ~1 second to startup time.

---

## 12. Credentials and Environment

All variable names are in `.env.example`. Real values are never committed to `.env.example`. Real values live in the container environment (set when containers were created) and in `oauth2-proxy/.env` (committed — contains live Google OAuth credentials).

| Variable | Purpose | Where to get it |
|---|---|---|
| `HICLAW_ADMIN_PASSWORD` | Higress console + MinIO admin | From whoever set up hiclaw-controller |
| `HICLAW_LLM_API_KEY` | OpenRouter API key (`sk-or-v1-...`) | OpenRouter dashboard → API Keys |
| `HICLAW_MANAGER_GATEWAY_KEY` | Manager↔gateway auth | Auto-generated at startup, stored in `/data/hiclaw-secrets.env` inside manager |
| `HICLAW_MANAGER_PASSWORD` | Manager Matrix account password | Same |
| `HICLAW_AUTH_TOKEN` | Long-lived JWT (ES256, aud=hiclaw-controller) | Generated during initial setup |
| `HICLAW_FS_SECRET_KEY` | MinIO secret key | Generated during setup |
| `HICLAW_REGISTRATION_TOKEN` | Matrix user registration token | Set during setup |
| `GOOGLE_CLIENT_ID` | Google OAuth2 client ID | Google Cloud Console → Credentials |
| `GOOGLE_CLIENT_SECRET` | Google OAuth2 client secret | Same |
| `OAUTH2_PROXY_COOKIE_SECRET` | 32-byte base64 cookie signing secret | `docker inspect oauth2-proxy` |
| `COOLIFY_API_TOKEN` | Coolify API access | Coolify UI → Settings → API Keys |

**GitHub Secrets:**

| Secret | Value |
|---|---|
| `COOLIFY_BASE_URL` | `https://coolify.designflow.app` |
| `COOLIFY_API_TOKEN` | Coolify API token |
| `COOLIFY_SERVICE_UUID` | `e10kwzww46ljhrgz1qj08j6a` — **DELETED from Coolify 2026-05-10; kept for reference only** |

**Runtime-computed secrets** (generated by `start-manager-agent.sh` if not in env):
- `HICLAW_MANAGER_GATEWAY_KEY` — 32-char random hex, persisted to `/data/hiclaw-secrets.env`
- `HICLAW_MANAGER_PASSWORD` — 16-char random hex, same file

---

## 13. Deployment

**novnc-desktop (the only Docker image we build):**
1. Commit changes to `novnc-desktop/` and push to `main`
2. GitHub Actions triggers automatically (shellcheck + ruff → build + push to GHCR)
3. Builds `ghcr.io/u2giants/novnc-desktop:latest` + `:sha-<commit>`
4. CI calls Coolify API to restart service — this FAILS (service was deleted 2026-05-10); ignore the error
5. To apply: `bash /worksp/hiclaw/novnc-desktop/recreate.sh`

**Shell scripts and configs (keeper scripts, oauth2-proxy, traefik, etc.):**
- No automated deploy — these run directly on the host
- After push: SSH to server, `cd /worksp/hiclaw && git pull`
- Then restart the affected service (see Decision Tree)
- For keeper script changes: the bootstrap keeper detects script hash changes and patches the running container within 1 minute (no manual restart required for script-only changes)

**Restart novnc-desktop from scratch:**
```bash
bash /worksp/hiclaw/novnc-desktop/recreate.sh
# Which runs:
docker pull ghcr.io/u2giants/novnc-desktop:latest
docker stop novnc-desktop && docker rm novnc-desktop
docker run -d --name novnc-desktop \
  --network e10kwzww46ljhrgz1qj08j6a --ip 10.0.5.4 \
  --dns 1.1.1.1 --dns 8.8.8.8 \
  -v novnc-e10kwzww46ljhrgz1qj08j6a-config:/config \
  -e PUID=1000 -e PGID=1000 -e TZ=UTC -e "TITLE=HiClaw Desktop" \
  --shm-size=2g --restart unless-stopped \
  ghcr.io/u2giants/novnc-desktop:latest
docker network connect coolify novnc-desktop
```
`--dns 1.1.1.1 --dns 8.8.8.8` is **required** — the host resolver uses Tailscale DNS (`100.100.100.100`) unreachable from inside Docker. `--ip 10.0.5.4` is **required** — hardcoded as the CDP endpoint in all openclaw.json MCP configs.

**hiclaw-manager / hiclaw-controller:** Images come from Alibaba's registry. We don't build them. To upgrade: update the image tag in `start-manager-agent.sh` (manager) or `controller-bootstrap-keeper.sh` (controller), commit, git pull on server, restart the affected container.

**Quick health check:**
```bash
crontab -l                                             # keepers registered?
docker ps --format "{{.Names}}\t{{.Status}}"          # all containers up?
docker logs hiclaw-manager --since 5m | grep -E 'gateway|error|SIGUSR1'
docker exec hiclaw-manager openclaw clawtalk doctor
```

---

## 14. Critical Incident Log

### Incident 1 — OpenClaw restart loop (2026-05-05)

**Root cause:** `start-manager-agent.sh` set `commands.restart = false` at startup. The controller reconciler then wrote `true`, triggering a restart. After restart, script set it to false again — infinite loop.

**Fix:** Changed startup script to not leave `commands.restart` in a state that diffs against the reconciler baseline. Config keeper maintains `{restart:true}` to match the startup baseline.

**Rule:** Never set `commands.restart=false`. See Idiosyncratic Decisions §commands.restart.

---

### Incident 2 — 5-minute gateway restart loop (commands normalization) (2026-05-09, re-investigated 2026-05-21)

**Symptom in `docker logs hiclaw-manager`:**
```
[reload] config reload skipped (invalid config): channels.matrix.groups.*: must NOT have additional properties
[reload] config change requires gateway restart (commands.restart)
[gateway] signal SIGUSR1 received
[gateway] restart mode: in-process restart (OPENCLAW_NO_RESPAWN)
← repeats every ~5 minutes →
```

**Root cause:** The ManagerReconciler writes `commands:null` every 5 minutes. Any value for `commands` that differs from the startup baseline (`{restart:true}`) triggers a restart. Writing `{}`, `null`, or `{restart:false}` all produce a diff.

**Fix:** `manager-config-keeper.sh` always writes `{restart:true}` — the only value that matches the startup baseline and produces zero diff.

**Emergency recovery:**
```bash
sudo python3 -c "
import json, os
path = '/worksp/hiclaw/workspace/openclaw.json'
d = json.load(open(path))
d['commands'] = {'restart': True}
open(path, 'w').write(json.dumps(d, indent=2))
print('done')
"
```

---

### Incident 3 — Chrome double-instance OOM crash (2026-05-08)

**Root cause 1:** Chrome watchdog used `pkill -f "chrome\|pattern"` — `\|` in ERE is literal pipe, not alternation. pkill matched nothing; old Chrome survived.

**Root cause 2:** Chrome wrapper unconditionally deleted Singleton files before launch. Dropbox OAuth callback opened `google-chrome https://...` → second full Chrome instance → 2.2 GB combined RSS → OOM.

**Fix:** Changed `\|` to `|` in watchdog pkill. Added pgrep guard: only delete Singleton files when Chrome is not running.

---

### Incident 4 — MinIO recursive storage path / server crash (2026-05-20)

**Root cause:** `HICLAW_RUNTIME=k8s` causes the k8s startup block to run `mc mirror hiclaw/hiclaw-storage/manager/ /root/manager-workspace/ --overwrite`. The workspace is bind-mounted into hiclaw-controller as `/root/hiclaw-fs/agents/manager/`. The ManagerReconciler pushes the workspace back to MinIO as `hiclaw/hiclaw-storage/manager/`. Since the mirror pull brought `hiclaw/hiclaw-storage/` INTO the workspace, the push created a nested copy. Each restart cycle added one more nesting level until disk usage exploded.

**Fix:** Added `--exclude` guards to the k8s `mc mirror` call: `hiclaw/*`, `hiclaw-fs`, `*.clobbered.*`, `.npm/*`, `.codex/*`, `.cache/*`.

**Cleanup check:**
```bash
sudo find /var/lib/docker/volumes/hiclaw-data/_data/minio/hiclaw-storage \
  -maxdepth 8 -type d -name "hiclaw-storage" -print
# Should print only the root path. Any extra lines = recursion returning.
```

---

### Incident 5 — clawtalk plugin lost on container restart (resolved 2026-05-08)

**Root cause:** CJS wrapper for the clawtalk ESM plugin lived in the container overlay. Lost on restart.

**Fix:** `bootstrap_clawtalk_plugin()` in `start-manager-agent.sh` recreates the shim and clears `installs.json` on every container start. `bot_connected ✓` verified.

---

### Incident 6 — Swap exhausted by stale Claude Code session; npm OOM crash loop (2026-05-30)

**Root cause:** A 9-day-old abandoned bash session (PID 527449) was consuming 828 MB swap. Combined with npm install peak memory, OOM killed mid-install. Partial install left json5 missing → persistent gateway crash loop.

**Fix:** Killed stale process (freed 828 MB swap). Recreated container from base image. Updated via UI update path.

**Rule:** Do NOT run `npm install -g openclaw@latest` directly. Use "Update now" UI button.

---

### Incident 7 — openclaw hash detection broken: container overlay vs. workspace volume (2026-05-30)

**Root cause:** Startup script wrote hash to `${HOME}/.openclaw-startup-pkg-hash` (inside container overlay, invisible to host). Keeper read from `/worksp/hiclaw/workspace/.openclaw-startup-pkg-hash` (always empty). Hash comparison always skipped; version changes never triggered docker restart.

**Fix:** Changed startup script to write hash to `/root/manager-workspace/.openclaw-startup-pkg-hash` (bind-mounted path, visible to host at `/worksp/hiclaw/workspace/.openclaw-startup-pkg-hash`).

**Rule:** Any state the keeper needs must be written to a bind-mounted path. Never write keeper-readable state to `/root/` or `${HOME}/` container paths.

---

### Incident 8 — control.claw 502 Bad Gateway after manager container recreation (2026-05-30)

**Root cause:** `manager-console.conf` used hardcoded container IP. `docker rm + run` gave the new container a different IP from Docker's DHCP pool.

**Fix:** `start-element-web.sh` generates the nginx config with `resolver 127.0.0.11 valid=10s; set $upstream hiclaw-manager; proxy_pass http://$upstream:18799;` — Docker DNS re-resolves on each request.

---

### Incident 9 — OpenRouter sync poisoned config with 'pricing' field (2026-05-30)

**Root cause:** Early sync expression spread the full OpenRouter model object into openclaw.json. The `pricing` field failed OpenClaw's strict schema validation, crashing the gateway on every start and losing all config customizations.

**Fix:** Sync expression extracts only `contextWindow` and `maxTokens`. Defensive `del(.pricing)` pass runs on every startup.

---

### Incident 10 — openclaw update.run always returning managed-service-handoff-unavailable (2026-05-31)

**Root causes:**
1. `channels.matrix.groups["*"]` wildcard key failed schema validation → every `update.run` rejected
2. `manager-config-keeper.sh` deleting wrong `.bak` path → observe-recovery kept restoring stale config with `"*"` key
3. No systemd in Docker → `detectRespawnSupervisor()` returned null → handoff path unavailable

**Fix:** Keeper strips `"*"` key. Correct `.bak` path. Fake systemd-run + `OPENCLAW_SYSTEMD_UNIT` + keeper-based marker consumption.

---

### Incident 11 — openclaw downgraded after container recreation; npm OOM crash loop (2026-05-31)

**Root causes:**
1. `docker rm` destroyed npm overlay → fell back to base image v2026.4.14
2. `--memory-swap 768m` = 0 swap available → npm install OOM-killed mid-install
3. Startup validation only checked json5 (not openai) → broken install accepted → gateway crashed

**Fix:** `--memory-swap 3g` (via `--memory 1536m`). Dual validation: json5 + openai/index.mjs. Fallback to base image on failed validation.

---

### Incident 12 — openclaw.json truncation loop: 103+ files at 8788 bytes (2026-05-31)

**Root cause:** `manager-bootstrap-keeper.sh` ran `openclaw update --yes --json`, then immediately ran `docker restart hiclaw-manager`. openclaw's in-process SIGUSR1 restart was still mid-write to `openclaw.json` when the container was killed. The write was consistently interrupted at 8788 bytes (vs full 9283 bytes). This happened 103 times over ~7.5 hours, producing 211 `.clobbered.*` forensic files.

**Evidence:** `workspace/openclaw.json.clobbered.*` — 103 files at exactly 8788 bytes, timestamps from 2026-05-31T16:50 to 2026-06-01T00:19.

**Fix (committed a93488c):** `sleep 30` inserted in `manager-bootstrap-keeper.sh` between `openclaw update` completion and the hash-check + docker restart block.

**Rule:** Never docker restart hiclaw-manager immediately after openclaw update. The 30-second window is required for the in-process SIGUSR1 write to complete.

---

### Incident 13 — openai/index.mjs missing from partial npm install (2026-06-01)

**Root cause:** Different OOM failure mode from Incident 11: the `openai` package ended up with all `.mjs` files absent but `.map` files intact. `json5/package.json` was present, so the validation passed. Gateway crashed on first request with `Cannot find module openai/index.mjs`. Control.claw returned 502.

**Fix (committed 57ff7c1):** Added second validation check: `/usr/lib/node_modules/openclaw/node_modules/openai/index.mjs` must exist. If absent: remove broken install, fall back to `/opt/openclaw/`.

---

### Incident 14 — 502 on control.claw from jq parse errors + YOLO reconciler diff loop (2026-05-31)

**Root causes:**
1. `start-manager-agent.sh` had inline bash comments (`# comment`) inside jq string expressions. jq parsed these as jq comments but broke the surrounding pipeline context → `jq: parse error: Unfinished JSON term at EOF at line 344` on every keeper run → startup script never completed config patching → config drift never fixed
2. The YOLO settings block (`tools.exec`, `tools.elevated`, `agents.defaults.elevatedDefault`) was written to openclaw.json at startup. The v1.1.2 ManagerReconciler writes null for these fields every ~47 seconds → constant diff → SIGUSR1 → restart cycle → control.claw unavailable ~40% of the time
3. openclaw 2026.5.28 was OOM-crashing with fatal heap limit at 768m RAM every ~45 seconds

**Fix (commits daedd9e, b5cf73b, c3a3319):** Removed inline comments from jq expressions. Removed the YOLO defaults block entirely so the reconciler baseline matches startup config. Increased manager container RAM from 768m to 1536m, swap from 2g to 3g.

---

## 15. Pending Work

- [x] Clawtalk loads automatically on container start
- [x] openclaw update detection fixed (hash written to workspace volume)
- [x] control.claw 502 after manager restart fixed (Docker DNS in nginx)
- [x] openclaw symlink fixed after npm update (dual validation: json5 + openai/index.mjs)
- [x] OpenRouter model metadata sync (deepseek contextWindow 1048576)
- [x] openclaw update.run fixed (fake systemd-run + OPENCLAW_SYSTEMD_UNIT + marker flow)
- [x] npm OOM during openclaw update fixed (--memory-swap 3g)
- [x] openclaw.json truncation race fixed (sleep 30 in keeper)
- [x] jq parse errors from inline comments fixed
- [x] YOLO reconciler diff loop fixed (removed YOLO block from startup)
- [x] Manager RAM increased to 1536m (no more heap-limit OOM at 768m)
- [ ] Other models still use hardcoded context windows — gpt-5.4, claude-opus-4-6, kimi-k2.5, etc. use Higress gateway alias IDs with no OpenRouter equivalent. Need a mapping table or canonical ID migration.
- [ ] Rebuild `ghcr.io/u2giants/novnc-desktop` image — Chrome wrapper fix (pgrep guard) is in the source; new image has not been built/pushed since the fix.
- [ ] Mount clawtalk modifications from host — currently recreated inside the container by the bootstrap. Should be a host-mounted bind so changes survive container recreation without a script update.
- [ ] Move hiclaw-manager and hiclaw-controller to Coolify — low priority; keepers work reliably.
- [ ] Move oauth2-proxy to Coolify — low priority.
- [ ] Verify tuwunel (Matrix homeserver) status — `start-tuwunel.sh` exists; confirm it is running and healthy.
- [ ] Set up git pull automation on server — script changes require manual `git pull` after push.
- [ ] Clean up 211 `.clobbered.*` files from workspace if disk space is needed.
