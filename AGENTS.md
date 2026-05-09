# AGENTS.md — HiClaw Project

> **Start here.** Read this before touching anything. A new session should be productive within 5 minutes of reading this file.

---

## 1. What This Project Is

HiClaw is an AI agent orchestration platform running on a single dedicated Linux server (`178.156.180.212`). It hosts the HiClaw controller+manager stack (open-source, by Alibaba/Higress) which provides an AI agent runtime: agents receive tasks via a Matrix/Element chat interface, execute them using an LLM (currently DeepSeek via OpenRouter), and interact with the world through a live Chrome browser (CDP automation). The noVNC service provides that browser-in-a-box. Google OAuth gates all web-facing services. Albert uses this system as his personal AI operations platform.

Key moving parts: **hiclaw-controller** (orchestration + storage), **hiclaw-manager** (agent runtime, OpenClaw gateway), **noVNC/Chrome** (browser automation), **oauth2-proxy** (Google auth gate), **Matrix/Tuwunel** (messaging), **Element Web** (chat UI).

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
│   │   └── build-and-push.yml   ← builds novnc-desktop → GHCR → Coolify redeploy
│   └── dependabot.yml
├── docs/
│   ├── architecture.md          ← system design, data flow
│   ├── configuration.md         ← all env vars, config files
│   ├── deployment.md            ← how things get deployed
│   └── development.md           ← local workflow
├── novnc-desktop/               ← THE ONLY DOCKER IMAGE WE BUILD
│   ├── Dockerfile               ← builds ghcr.io/u2giants/novnc-desktop
│   ├── novnc-startup.sh         ← container startup: Chrome watchdog, CDP proxy
│   └── cdp_proxy.py             ← WebSocket proxy Chrome port 9222→9223
├── traefik/
│   └── claw.yml                 ← Traefik dynamic config (copy of /data/coolify/proxy/dynamic/claw.yml)
├── oauth2-proxy/
│   ├── docker-compose.yml       ← oauth2-proxy container config
│   └── allowed-emails.txt       ← whitelist of Google accounts allowed in
└── [keeper/start scripts at root]
    ├── controller-bootstrap-keeper.sh   ← keeps hiclaw-controller alive
    ├── manager-bootstrap-keeper.sh      ← keeps hiclaw-manager alive
    ├── manager-config-keeper.sh         ← keeps openclaw.json config sane
    ├── mcp-keeper.sh                    ← keeps MCP server alive
    ├── start-element-web.sh             ← starts Element Web container
    ├── start-manager-agent.sh           ← starts hiclaw-manager container (complex)
    ├── start-tuwunel.sh                 ← starts Matrix homeserver
    └── fix-element-config.sh            ← one-off Element config fixer (idempotent)
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
- `/worksp/hiclaw/workspace/` — runtime data written by the controller. Treat as read-only except for `openclaw.json` targeted fixes.
- The Coolify UI for hiclaw-unmanaged containers — those are managed by our scripts.

**Rule:** If a fix involves `docker exec hiclaw-manager some-edit`, it is temporary. The permanent fix goes in `start-manager-agent.sh` or a mounted file so it survives container restarts.

---

## 5. Core Modification Inventory

Changes made to files outside our own directories (upstream merge conflict checklist):

| File | Location | Change | Why |
|---|---|---|---|
| `start-manager-agent.sh` lines 710, 785 | Our script (we own it) | Changed `.commands.restart = false` → `.commands.restart = (.commands.restart // false)` | Prevents restart loop — see Idiosyncratic Decisions #1 |
| `clawtalk/index.cjs` | Inside hiclaw-manager container at `/root/manager-workspace/.openclaw/npm/node_modules/clawtalk/` | Created CJS wrapper for ESM plugin | clawtalk uses ES modules; OpenClaw requires CJS. See Critical Incident Log. **EPHEMERAL — lost on container restart.** |
| `clawtalk/package.json` openclaw field | Same container | Changed `build/index.js` → `index.cjs` | Points OpenClaw at the CJS wrapper |
| `clawtalk installs.json` | Same container | Removed `installRecords.clawtalk` entry | Prevents plugin re-registration conflict |

**Note:** All in-container modifications are ephemeral and will be lost on container restart. Permanent fix requires mounting these files from the host or baking into `start-manager-agent.sh`.

---

## 6. Decision Tree

**I need to change Chrome behavior (flags, startup, watchdog):**
→ Edit `novnc-desktop/novnc-startup.sh` → commit → pipeline builds new image → Coolify redeploys novnc

**I need to change Chrome's baked-in wrapper or Dockerfile:**
→ Edit `novnc-desktop/Dockerfile` → commit → pipeline → Coolify redeploy

**I need to change the CDP proxy (port forwarding, filtering):**
→ Edit `novnc-desktop/cdp_proxy.py` IN-PLACE on the server (`sed -i` or Edit tool) — see Idiosyncratic Decision #3 for why. Also commit the change.

**I need to change the OAuth gate (who can log in, redirect URL, cookie):**
→ Edit `oauth2-proxy/docker-compose.yml` → commit → manually restart oauth2-proxy on server: `cd /worksp/hiclaw/oauth2-proxy && docker compose up -d`

**I need to add/change a Traefik routing rule:**
→ Edit `traefik/claw.yml` → commit → apply: `docker cp traefik/claw.yml coolify-proxy:/traefik/dynamic/claw.yml` (Traefik hot-reloads automatically, no restart needed)

**I need to change hiclaw-manager startup behavior:**
→ Edit `start-manager-agent.sh` → commit → git pull on server → restart manager: `docker stop hiclaw-manager && ./manager-bootstrap-keeper.sh`

**I need to add or change an environment variable:**
→ Update `.env.example` + `docs/configuration.md` + `AGENTS.md` credentials section → commit

**I need to add a new allowed Google account:**
→ Edit `oauth2-proxy/allowed-emails.txt` → commit → restart oauth2-proxy

**I need to fix the OpenClaw gateway (in-process):**
→ Modify `/worksp/hiclaw/workspace/openclaw.json` directly (it's a host file) → the manager picks it up automatically

---

## 7. Task-to-File Navigation Map

| Task | File to touch |
|---|---|
| Traefik routing rules | `traefik/claw.yml` → apply with `docker cp traefik/claw.yml coolify-proxy:/traefik/dynamic/claw.yml` |
| Chrome launch flags | `novnc-desktop/novnc-startup.sh` |
| Chrome Dockerfile | `novnc-desktop/Dockerfile` |
| CDP WebSocket proxy | `novnc-desktop/cdp_proxy.py` (edit in-place on server) |
| OAuth allowed users | `oauth2-proxy/allowed-emails.txt` |
| OAuth config (client ID, redirect URL) | `oauth2-proxy/docker-compose.yml` |
| hiclaw-manager startup / env vars | `start-manager-agent.sh` |
| hiclaw-manager crash recovery | `manager-bootstrap-keeper.sh` |
| OpenClaw config watchdog | `manager-config-keeper.sh` |
| hiclaw-controller crash recovery | `controller-bootstrap-keeper.sh` |
| MCP server keepalive | `mcp-keeper.sh` |
| Element Web container | `start-element-web.sh` |
| Matrix homeserver (tuwunel) | `start-tuwunel.sh` |
| OpenClaw runtime config | `/worksp/hiclaw/workspace/openclaw.json` (host file, not in git) |
| GitHub Actions pipeline | `.github/workflows/build-and-push.yml` |
| All env var documentation | `docs/configuration.md` + `.env.example` |

---

## 8. Data Model / Custom Objects

**No application database managed by this repo.** hiclaw-controller has its own embedded database — we do not run migrations against it.

**Persistent storage:** MinIO object storage inside hiclaw-controller (port 9000). Bucket: `hiclaw-storage`. Prefix: `hiclaw/hiclaw-storage`.

**OpenClaw config file:** `/worksp/hiclaw/workspace/openclaw.json` — this is the live config. Both controller and manager read/write it via shared volume mount.

**Matrix DM room ID:** `!Yzg8FAvvzjKsYTBJb3:matrix-local.hiclaw.io:18080` — permanent, do not change.

---

## 9. Container Inventory

| Container Name | Function | Managed By | Image | Coolify UUID |
|---|---|---|---|---|
| `hiclaw-controller` | Core orchestration, MinIO, internal DB, agent API | `controller-bootstrap-keeper.sh` | `higress/hiclaw-embedded:v1.1.0` | not in Coolify |
| `hiclaw-manager` | Manager agent, OpenClaw gateway, Matrix integration | `manager-bootstrap-keeper.sh` | `higress/hiclaw-manager:v1.1.0` | not in Coolify |
| `novnc-e10kwzww46ljhrgz1qj08j6a` | Chrome browser via noVNC for CDP automation | Coolify service `openmanus-stack` | `ghcr.io/u2giants/novnc-desktop:latest` | `e10kwzww46ljhrgz1qj08j6a` |
| `oauth2-proxy` | Google OAuth gate for web services | `oauth2-proxy/docker-compose.yml` (direct) | `quay.io/oauth2-proxy/oauth2-proxy:latest` | not in Coolify |
| `authentik` (+ worker) | Identity provider (separate from oauth2-proxy) | Coolify service `authentik` | `ghcr.io/goauthentik/server` | `qbtr8iksui67c7yoh8vswo7m` |

**Naming note:** `hiclaw-manager`, `hiclaw-controller`, and `oauth2-proxy` are in production with these names — do not rename. The novnc container name includes the Coolify service UUID — this is Coolify-managed and expected.

---

## 10. What to Ignore

These exist on the server but are not in the repo and are not relevant to development:

- `workspace/` — runtime data: agent state, OpenClaw config, npm packages, browser cache. Written by containers at runtime. **Not in git.**
- `.state/` — keeper script state tracking (last container ID). **Not in git.**
- `*.log` — keeper and bootstrap logs. **Not in git.**

---

## 11. Idiosyncratic Decisions

### OpenClaw commands.restart stays true

**Looks like:** `commands.restart=true` in `openclaw.json` is a bug — it looks like the gateway is being told to restart constantly.

**Actually:** This is the stable state. The hiclaw-controller reconciliation loop always writes `commands.restart=true`. OpenClaw only triggers a restart when the value *changes* from false→true. Once it's true, subsequent writes of true are a no-op.

**Why:** The controller uses this field as a one-shot "restart now" signal. It always writes true; OpenClaw level-triggers only on the false→true edge.

**Do not change because:** Setting it to false triggers one unnecessary restart (the diff false→true causes OpenClaw to restart), then it reverts to true anyway. If it somehow gets stuck in an oscillating loop, see Critical Incident Log #1.

---

### hiclaw-manager and hiclaw-controller are NOT in Coolify

**Looks like:** These are the core services — why aren't they Coolify-managed like everything else?

**Actually:** They use a shared volume mount (`/worksp/hiclaw/workspace`) that Coolify's docker-compose model doesn't accommodate cleanly for this image version. They're managed by keeper scripts that run as background processes on the host.

**Why:** The hiclaw images have specific startup requirements (env vars injected mid-startup, config patching via jq) that are baked into `start-manager-agent.sh`. Moving them to Coolify would require rewriting that startup logic as a compose file.

**Do not change because:** The keeper scripts handle restart-on-crash, config patching, and environment injection. Migrating to Coolify is a future project, not a quick change.

---

### Chrome wrapper checks pgrep before deleting Singleton files

**Looks like:** Unnecessary complexity — why not always clean up stale lock files?

**Actually:** If you always delete `Singleton*` before launch, and another app (e.g. Dropbox OAuth callback) calls `google-chrome https://...` while Chrome is already running, you nuke the lock and Chrome spawns a second full instance. Two Chrome instances + limited RAM = OOM crash (happened 2026-05-08, ~2.2 GB RSS combined).

**Why:** The pgrep guard means: only delete the lock when no Chrome is running, which is safe. When Chrome is already running, the new URL opens as a new tab in the existing instance.

**Do not change because:** Removing the guard causes double-Chrome OOM on any external URL open.

---

### cdp_proxy.py must be edited in-place (sed -i, never replaced)

**Looks like:** Normal file replacement should work.

**Actually:** `cdp_proxy.py` is bind-mounted into the novnc container. When you replace a file on the host (write new file, move over old), Docker's bind mount still points to the old inode. The container never sees the update.

**Why:** Docker bind mounts track the inode, not the path.

**Do not change because:** Using the Write tool or `cp` creates a new inode. Always use Edit tool (which edits in-place) or `sed -i`. This is also why the file is committed to git — the deployed version on the server must be the inode-stable original.

---

### pkill uses unescaped | for alternation

**Looks like:** `pkill -f "google-chrome|/opt/google/chrome/chrome"` — the pipe looks like it should be escaped.

**Actually:** pkill uses Extended Regular Expressions (ERE). In ERE, `|` is alternation. `\|` is a literal pipe character. The correct form for "match either pattern" is the unescaped `|`.

**Why:** Previous version used `\|`, which silently matched nothing, allowing the Chrome watchdog to fail to kill stale instances — causing double-Chrome crashes.

**Do not change because:** Escaping it again breaks the pattern matching and the watchdog stops working.

---

### bootstrap_clawtalk_plugin() deletes installs.json on every start

**Looks like:** Deleting `installs.json` on every container start is destructive — it makes OpenClaw rebuild its entire plugin registry from scratch.

**Actually:** This is required. The bootstrap creates the clawtalk bundled shim (`/usr/lib/node_modules/openclaw/dist/extensions/clawtalk/`) AFTER writing to `installs.json`. OpenClaw caches the plugin list in `installs.json` and won't rescan unless the file is absent or a version migration is detected. Without the deletion, the gateway starts with a cached `installs.json` that predates the shim and reports "plugin not found: clawtalk".

**Why:** Ordering constraint — `installs.json` is written during the Python step, bundled shim is created during the bash step. Can't write the shim first because the shim copies from the npm package manifest which the Python step also modifies.

**Do not change because:** Removing the `rm -f installs.json` line causes clawtalk to fail to load on every container restart with "plugin not found: clawtalk (stale config entry ignored)". OpenClaw regenerates `installs.json` correctly on fresh start — the rebuild adds ~1 second to startup time.

---

### openclaw updates require a container restart (hash-stamped modules)

**Looks like:** Clicking "Update now" in the OpenClaw UI should update and restart the gateway in-place.

**Actually:** OpenClaw builds its dist directory with content-hash-stamped filenames (Vite/Rollup output). When `openclaw update` installs a new version, those filenames change. The running process already has old paths cached in loaded module references — so the in-process restart (forced by `OPENCLAW_NO_RESPAWN=1`) silently fails to load the new files. The gateway keeps running with the old code; the "Update now" button immediately reverts.

**Why:** Node.js module cache + `OPENCLAW_NO_RESPAWN=1` + hash-renamed files = stale references survive in-process restart. OpenClaw's own restart-after-update step also skips because it can't find a systemd service ("No installed gateway service found; skipped restart").

**Prevention (implemented):** `start-manager-agent.sh` writes a hash of `/usr/lib/node_modules/openclaw/package.json` to `~/.openclaw-startup-pkg-hash` on each startup. The `manager-bootstrap-keeper.sh` (cron, every minute) reads this hash and compares it to the live package hash inside the running container. If they differ — indicating an in-container update ran — it calls `docker restart hiclaw-manager`, which starts fresh and loads the new module files correctly.

**Do not change because:** Removing the startup hash write or the keeper check means updates silently break the sentinel, future "Update now" clicks hang, and `openclaw doctor` is required to recover.

---

### clawtalk plugin uses a CJS wrapper (index.cjs)

**Looks like:** The plugin should load its standard `build/index.js` entry point.

**Actually:** `build/index.js` is an ES module (`export default`). OpenClaw uses CJS `require()`. The CJS import of an ES module returns `{ __esModule: true, default: {...} }` and older OpenClaw versions fail to unwrap this.

**Why:** The `index.cjs` wrapper does the unwrapping explicitly: `const m = require('./build/index.js'); module.exports = m.default || m;`

**Do not change because:** Removing the wrapper causes clawtalk to fail to load in the gateway. **IMPORTANT: This wrapper lives inside the hiclaw-manager container and is lost on container restart. It must be recreated via `start-manager-agent.sh` or mounted from host. This is pending work.**

---

## 12. Credentials and Environment

All variable names are in `.env.example`. Real values are never committed. Sources:

| Variable | Where to get it |
|---|---|
| `HICLAW_ADMIN_PASSWORD` | From the person who set up hiclaw-controller |
| `HICLAW_LLM_API_KEY` | OpenRouter dashboard → API Keys |
| `HICLAW_MANAGER_GATEWAY_KEY` | Generated during initial hiclaw setup, stored in `.env` on server |
| `HICLAW_MANAGER_PASSWORD` | Same as above |
| `HICLAW_AUTH_TOKEN` | Long-lived JWT, generated during setup |
| `HICLAW_FS_SECRET_KEY` | MinIO secret key, generated during setup |
| `GOOGLE_CLIENT_ID` | Google Cloud Console → APIs & Services → Credentials |
| `GOOGLE_CLIENT_SECRET` | Same |
| `OAUTH2_PROXY_COOKIE_SECRET` | Random 32-byte base64 string — extract from running container: `docker inspect oauth2-proxy` |
| `COOLIFY_API_TOKEN` | Coolify UI → Settings → API Keys (also in GitHub Secrets) |

**GitHub Secrets set on this repo:**

| Secret | Value |
|---|---|
| `COOLIFY_BASE_URL` | `https://coolify.designflow.app` |
| `COOLIFY_API_TOKEN` | Coolify API token |
| `COOLIFY_SERVICE_UUID` | `e10kwzww46ljhrgz1qj08j6a` (openmanus-stack / novnc) |

---

## 13. Deployment

**novnc-desktop (the only Docker image we build):**
1. Commit changes to `novnc-desktop/` and push to `main`
2. GitHub Actions (`.github/workflows/build-and-push.yml`) triggers automatically
3. Builds `ghcr.io/u2giants/novnc-desktop:latest` + `:sha-<commit>`
4. Calls Coolify API to restart the `openmanus-stack` service
5. Coolify pulls new `:latest` and restarts the novnc container

**Shell scripts and configs (keeper scripts, oauth2-proxy, etc.):**
- No automated deploy — these run directly on the host
- After pushing changes: SSH to server, `cd /worksp/hiclaw && git pull`
- Then restart the affected service manually (see Decision Tree)

**Rollback novnc-desktop:** In Coolify UI → openmanus-stack → change image tag to `:sha-<previous-commit>` and redeploy.

**hiclaw-manager / hiclaw-controller:** Images come from Alibaba's registry (`higress-registry.cn-hangzhou.cr.aliyuncs.com`). We don't build or push these. To upgrade, update the image tag in `start-manager-agent.sh` and restart.

---

## 14. Critical Incident Log

### Incident 1 — OpenClaw restart loop (2026-05-05)

**What happened:** hiclaw-manager entered a continuous restart loop. Matrix messages went unanswered for ~54 minutes because each restart advanced the Matrix sync token past pending messages.

**Root cause:** `start-manager-agent.sh` was setting `commands.restart = false` unconditionally at startup. The controller reconciliation loop then wrote `true`, triggering a restart. After restart, the script ran again, set it to false again — infinite loop.

**Fix:** Lines 710 and 785 of `start-manager-agent.sh` changed to `.commands.restart = (.commands.restart // false)` — preserves existing `true`, only defaults to `false` if the key is missing.

**Rule:** Never set `commands.restart=false` in `openclaw.json`. See Idiosyncratic Decision #1.

**Emergency recovery** (if loop recurs):
```bash
# Check current value
docker exec hiclaw-manager openclaw gateway call config.get --json

# Force stable state
docker exec hiclaw-manager bash -c 'jq ".commands.restart = true" /root/manager-workspace/openclaw.json > /tmp/t.json && mv /tmp/t.json /root/manager-workspace/openclaw.json'

# If SIGUSR1 is deadlocked (restart ignored):
docker exec hiclaw-manager bash -c 'echo "{\"kind\":\"gateway-restart\",\"pid\":1,\"createdAt\":$(date +%s%3N),\"force\":true}" > /root/.openclaw/gateway-restart-intent.json && kill -USR1 1'
# WARNING: the force restart causes a container restart (not in-process)
```

---

### Incident 2 — Chrome double-instance OOM crash (2026-05-08)

**What happened:** Server ran out of memory (swap exhausted at 3.8/4 GB, ~422 MB RAM free). Two Chrome instances were running simultaneously, consuming ~2.2 GB RSS combined. Server became unresponsive.

**Root cause 1:** Chrome watchdog used `pkill -f "chrome\|pattern"` — `\|` in ERE is a literal pipe, not alternation. pkill matched nothing, so the old Chrome instance survived when the watchdog tried to restart it.

**Root cause 2:** Chrome wrapper unconditionally deleted `Singleton*` files before launch. When Dropbox called `google-chrome https://...` to open a browser auth URL, the wrapper deleted the lock and Chrome spawned a fresh second instance alongside the existing one.

**Fix:** Changed `\|` to `|` in `novnc-startup.sh` (watchdog pkill). Added pgrep guard in Chrome wrapper — only delete Singleton files when Chrome is NOT already running.

**Rule:** The Chrome wrapper's pgrep guard must not be removed. The unescaped `|` in pkill must not be re-escaped. See Idiosyncratic Decisions #2 and #4.

**Recovery:** `docker exec novnc-... pkill -f "/opt/google/chrome/chrome"` — kills all Chrome, watchdog restarts one clean instance within ~5 seconds.

---

### Incident 3 — clawtalk plugin lost on container restart (ongoing)

**What happened:** The clawtalk npm plugin (for ClawTalk integration) loads correctly in the OpenClaw CLI but not in the running gateway. A CJS wrapper was created inside the hiclaw-manager container to fix the ESM/CJS incompatibility, but it lives on the container's overlay filesystem and is wiped on every container restart.

**Status:** Resolved (2026-05-08). `bootstrap_clawtalk_plugin()` in `start-manager-agent.sh` creates the bundled shim on every container start AND deletes `installs.json` so the gateway does a full plugin rescan and discovers the shim. `bot_connected ✓` verified.

**Recovery after container restart:**
```bash
# Recreate the CJS wrapper inside the container
docker exec hiclaw-manager bash -c "cat > /root/manager-workspace/.openclaw/npm/node_modules/clawtalk/index.cjs << 'EOF'
'use strict';
const m = require('./build/index.js');
const plugin = m.default || m;
module.exports = plugin;
EOF"

# Update package.json to point at the wrapper
docker exec hiclaw-manager bash -c "jq '.openclaw.extensions = [\"./index.cjs\"] | .clawdbot.extensions = [\"./index.cjs\"]' /root/manager-workspace/.openclaw/npm/node_modules/clawtalk/package.json > /tmp/pkg.json && mv /tmp/pkg.json /root/manager-workspace/.openclaw/npm/node_modules/clawtalk/package.json"

# Restart gateway in-process
docker exec hiclaw-manager bash -c 'jq ".commands.restart = true" /root/manager-workspace/openclaw.json > /tmp/t.json && mv /tmp/t.json /root/manager-workspace/openclaw.json'
```

---

## 15. Pending Work

- [x] **Clawtalk loads automatically on container start** — `bootstrap_clawtalk_plugin()` in `start-manager-agent.sh` creates the bundled shim and deletes `installs.json` so the gateway does a fresh plugin scan and discovers clawtalk. All critical checks pass (`bot_connected ✓`).
- [ ] **Rebuild `ghcr.io/u2giants/novnc-desktop` image** — Chrome wrapper fix (pgrep guard) is applied to the running container in-place but the Dockerfile fix has not been built and pushed yet. Next push to `novnc-desktop/` will trigger this automatically.
- [ ] **Mount clawtalk modifications from host** — instead of recreating them inside the container, mount the fixed files from `/worksp/hiclaw/workspace/` so they survive container restarts permanently.
- [ ] **Move hiclaw-manager and hiclaw-controller to Coolify** — currently managed by keeper scripts. Low priority; scripts work reliably.
- [ ] **Move oauth2-proxy to Coolify** — currently run via `docker-compose.yml` directly. Works fine; Coolify management would add UI visibility.
- [ ] **Verify tuwunel (Matrix homeserver) status** — `start-tuwunel.sh` exists but tuwunel was not visible in recent `docker ps` output. Confirm whether it is running or if Matrix is handled differently.
- [ ] **Set up git pull automation on server** — shell script/config changes deploy by git push but require a manual `git pull` on the server. A post-receive webhook or cron would automate this.
