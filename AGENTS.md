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

**I need to change what Element Web shows at login or after Google OAuth:**
→ Edit `start-element-web.sh` — it generates `auto-login.js`, `auth-ui-tweaks.js`, `control-panel-btn.js`, and the nginx `manager-console.conf` on container start → commit → pull on server → restart Element Web container

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
| Element Web container (nginx, JS injections, manager-console.conf) | `start-element-web.sh` |
| Matrix homeserver (tuwunel) | `start-tuwunel.sh` |
| OpenClaw runtime config | `/worksp/hiclaw/workspace/openclaw.json` (host file, not in git) |
| GitHub Actions pipeline | `.github/workflows/build-and-push.yml` |
| All env var documentation | `docs/configuration.md` + `.env.example` |
| Auto-login after Google OAuth | `start-element-web.sh` → `auto-login.js` section |
| nginx reverse proxy for control.claw (hiclaw-manager) | `start-element-web.sh` → `manager-console.conf` generation block |
| Model context window metadata | `start-manager-agent.sh` OpenRouter sync block (~line 772) |

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
| `novnc-desktop` | Chrome browser via noVNC for CDP automation | manually (not in Coolify) | `ghcr.io/u2giants/novnc-desktop:latest` | not in Coolify (deleted 2026-05-10) |
| `oauth2-proxy` | Google OAuth gate for web services | `oauth2-proxy/docker-compose.yml` (direct) | `quay.io/oauth2-proxy/oauth2-proxy:latest` | not in Coolify |
| `authentik` (+ worker) | Identity provider (separate from oauth2-proxy) | Coolify service `authentik` | `ghcr.io/goauthentik/server` | `qbtr8iksui67c7yoh8vswo7m` |

**Naming note:** `hiclaw-manager`, `hiclaw-controller`, and `oauth2-proxy` are in production with these names — do not rename. The `novnc-desktop` container is started manually via `docker run` with `--restart unless-stopped`; networks `e10kwzww46ljhrgz1qj08j6a` and `coolify` are both attached. CDP endpoint remains `10.0.5.4:9223` (static IP on the `e10kwzww46ljhrgz1qj08j6a` network).

---

## 10. What to Ignore

These exist on the server but are not in the repo and are not relevant to development:

- `workspace/` — runtime data: agent state, OpenClaw config, npm packages, browser cache. Written by containers at runtime. **Not in git.**
- `.state/` — keeper script state tracking (last container ID). **Not in git.**
- `*.log` — keeper and bootstrap logs. **Not in git.**

---

## 11. Idiosyncratic Decisions

### manager-config-keeper.sh always writes commands:{restart:true}

**Looks like:** The keeper is forcing `commands.restart=true` which sounds like it would keep triggering gateway restarts.

**Actually:** The gateway triggers a restart only when `commands` CHANGES in the diff — it is diff-based, not value-based. The gateway records its initial startup config (which has `commands.restart=true`) as the permanent baseline in `config-health.json`. Every reload diff compares the current file against that startup baseline. Writing `commands:{restart:true}` means the diff shows no change in `commands`, so the keeper's schema fixes are applied as instant hot reloads.

**The full mechanism is documented in:** `docs/configuration.md § commands.restart` — read that before touching this. It explains the baseline, why `{}` and `null` don't work, how to inspect the baseline, and what a broken state looks like.

**The incident history is in:** Critical Incident Log #2 — includes the full log pattern, the failed attempts, and why each one triggers a restart.

**Do not change because:** Writing `{}`, `null`, or `{restart:false}` produces a diff against the startup baseline → "config change requires gateway restart (commands)" every 5 minutes. `{restart:true}` is the only value that produces zero diff.

**Startup safety:** The startup script sets `commands.restart=true` before starting the gateway. The keeper's 60-second cron interval means it fires AFTER the gateway has already processed the startup signal and is running stably.

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

**Prevention (implemented):** `start-manager-agent.sh` probes for the active openclaw `package.json` at startup (npm global install path `/usr/lib/node_modules/openclaw/package.json` first, then image built-in `/opt/openclaw/package.json`), hashes it, and writes the hash to `/root/manager-workspace/.openclaw-startup-pkg-hash` — which is bind-mounted at `/worksp/hiclaw/workspace/.openclaw-startup-pkg-hash` on the host. `manager-bootstrap-keeper.sh` (cron, every minute) reads the host-side hash file, computes the current hash from inside the running container using the same fallback probe, and calls `docker restart hiclaw-manager` when they differ.

**Why the hash file is in the workspace volume:** An earlier bug wrote to `${HOME}/.openclaw-startup-pkg-hash` (inside the container overlay), which the host-side keeper could not read. The workspace directory (`/root/manager-workspace/`) is bind-mounted from the host, so files written there are immediately visible to the keeper. The path on the host is `/worksp/hiclaw/workspace/.openclaw-startup-pkg-hash`.

**Do not change because:** Removing the startup hash write or the keeper check means updates silently break the sentinel, future "Update now" clicks hang, and `openclaw doctor` is required to recover.

---

### clawtalk plugin uses a CJS wrapper (index.cjs)

**Looks like:** The plugin should load its standard `build/index.js` entry point.

**Actually:** `build/index.js` is an ES module (`export default`). OpenClaw uses CJS `require()`. The CJS import of an ES module returns `{ __esModule: true, default: {...} }` and older OpenClaw versions fail to unwrap this.

**Why:** The `index.cjs` wrapper does the unwrapping explicitly: `const m = require('./build/index.js'); module.exports = m.default || m;`

**Do not change because:** Removing the wrapper causes clawtalk to fail to load in the gateway. **IMPORTANT: This wrapper lives inside the hiclaw-manager container and is lost on container restart. It must be recreated via `start-manager-agent.sh` or mounted from host. This is pending work.**

---

### nginx manager-console.conf uses Docker DNS resolver, not hardcoded IP

**Looks like:** The simplest way to proxy from hiclaw-controller's nginx to hiclaw-manager is `proxy_pass http://<IP>:8080`.

**Actually:** Docker reassigns container IPs when containers are recreated. After a `docker restart hiclaw-manager`, the IP changes and nginx starts returning 502 Bad Gateway for all control.claw requests — until the controller container is also restarted.

**Why:** `start-element-web.sh` generates `manager-console.conf` with:
```nginx
resolver 127.0.0.11 valid=10s;
set $upstream hiclaw-manager;
proxy_pass http://$upstream:8080;
```
`127.0.0.11` is Docker's embedded DNS resolver. By storing the hostname in a variable, nginx bypasses its startup-time DNS cache and re-resolves `hiclaw-manager` on each request. This means IP changes are transparent.

**Do not change because:** Switching back to a hardcoded IP causes 502s every time the manager container is recreated.

---

### OpenRouter model sync writes response to file, not shell variable

**Looks like:** `MODELS=$(curl ... openrouter.ai/api/v1/models)` and then use `$MODELS` in a jq call.

**Actually:** The OpenRouter response is large enough (~500KB+) to exceed bash's maximum argument size. Passing it as a shell variable or command argument triggers "Argument list too long" and the entire sync silently fails.

**Why:** `start-manager-agent.sh` writes the curl output to `/tmp/openrouter-models.json` and passes it to jq using `--slurpfile or_data /tmp/openrouter-models.json`. jq reads the file directly; the shell never holds the content in an argument.

**Do not change because:** Reverting to a shell variable causes silent sync failure for all models. After the sync, the updated config is also pushed back to MinIO (`mc cp`) so the background MinIO→Local sync that runs seconds later does not overwrite the fresh values.

---

### OpenRouter sync also pushes updated config to MinIO immediately

**Looks like:** The startup sequence updates `openclaw.json` locally, then MinIO sync runs later in the background and everything is consistent.

**Actually:** The k8s startup block runs `mc mirror hiclaw/hiclaw-storage/manager/ /root/manager-workspace/ --overwrite` a few seconds into startup. If the OpenRouter sync updates `openclaw.json` but doesn't push to MinIO, the subsequent background sync pulls the OLD config from MinIO and overwrites the fresh values.

**Why:** After the OpenRouter sync and the `del(.pricing)` cleanup pass, `start-manager-agent.sh` immediately runs `mc cp /root/manager-workspace/openclaw.json hiclaw/hiclaw-storage/manager/openclaw.json` so MinIO and local are in sync before the background pull can fire.

**Do not change because:** Removing the immediate MinIO push means the background sync undoes the model metadata updates on every restart.

---

### openclaw schema rejects unknown model fields — del(.pricing) is required

**Looks like:** Extra fields in the models array are harmless — the gateway just ignores them.

**Actually:** OpenClaw validates each model object against a strict JSON schema. The `pricing` field (added by the OpenRouter sync in an earlier buggy version and preserved in MinIO) causes the gateway to reject the entire config with a schema validation error on startup, falling back to defaults and losing all customizations.

**Why:** `start-manager-agent.sh` runs a `del(.pricing)` jq pass over every model in the `hiclaw-gateway` provider list on every startup, before any other config updates. This is defensive: even if a future version of the sync accidentally reintroduces `pricing`, the cleanup pass removes it.

**Do not change because:** Removing the cleanup pass allows poisoned MinIO configs to crash the gateway on next startup.

---

### auto-login.js injects session directly, bypassing the SSO token flow

**Looks like:** The natural way to auto-log into Element after Google OAuth is to use Element's `loginToken` URL parameter (the standard Matrix SSO redirect).

**Actually:** The `loginToken` flow triggers a full fresh login, which always presents the "verify this device" cross-signing screen. This cannot be suppressed in Element 1.12.x without rebuilding the app.

**Why:** `start-element-web.sh` generates `auto-login.js` which calls `POST /hiclaw-api/session` — a hiclaw-controller API endpoint that returns a pre-existing access token, user ID, and device ID. The script writes these directly into `localStorage` under the `mx_*` keys that Element reads on page load. Element then enters "restore session" mode (not "new login" mode) and skips the cross-signing screen entirely.

**Consequence:** The user must have an existing Matrix session established at least once. On a fresh install, the first login must be done manually via the SSO flow; subsequent logins use the injected session.

**Do not change because:** Using the `loginToken` redirect causes the cross-signing screen to appear on every login, requiring the user to click through a multi-step verification flow. The direct session injection bypasses this completely.

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
| `COOLIFY_SERVICE_UUID` | `e10kwzww46ljhrgz1qj08j6a` (openmanus-stack / novnc) — **DELETED from Coolify 2026-05-10; kept for reference only** |

---

## 13. Deployment

**novnc-desktop (the only Docker image we build):**
1. Commit changes to `novnc-desktop/` and push to `main`
2. GitHub Actions (`.github/workflows/build-and-push.yml`) triggers automatically
3. Builds `ghcr.io/u2giants/novnc-desktop:latest` + `:sha-<commit>`
4. CI tries to call Coolify API to restart the service — this will fail (service was deleted); ignore the error
5. To apply a new image: `docker pull ghcr.io/u2giants/novnc-desktop:latest && docker stop novnc-desktop && docker rm novnc-desktop` then re-run the `docker run` command from the decision tree below

**Shell scripts and configs (keeper scripts, oauth2-proxy, etc.):**
- No automated deploy — these run directly on the host
- After pushing changes: SSH to server, `cd /worksp/hiclaw && git pull`
- Then restart the affected service manually (see Decision Tree)

**Restart novnc-desktop from scratch:**
```bash
# Or just run: bash /worksp/hiclaw/novnc-desktop/recreate.sh
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
**`--dns` is required.** The host resolver uses Tailscale DNS (`100.100.100.100`) which is unreachable from inside Docker. Without explicit DNS the browser has no internet. `--ip 10.0.5.4` is also required — it is hardcoded as the CDP endpoint for browser MCP.
**Rollback:** replace `:latest` with `:sha-<previous-commit>` in the run command.

**hiclaw-manager / hiclaw-controller:** Images come from Alibaba's registry (`higress-registry.cn-hangzhou.cr.aliyuncs.com`). We don't build or push these. To upgrade, update the image tag in `start-manager-agent.sh` and restart.

---

## 14. Critical Incident Log

### Incident 1 — OpenClaw restart loop (2026-05-05)

**What happened:** hiclaw-manager entered a continuous restart loop. Matrix messages went unanswered for ~54 minutes because each restart advanced the Matrix sync token past pending messages.

**Root cause:** `start-manager-agent.sh` was setting `commands.restart = false` unconditionally at startup. The controller reconciliation loop then wrote `true`, triggering a restart. After restart, the script ran again, set it to false again — infinite loop.

**Fix:** Lines 710 and 785 of `start-manager-agent.sh` changed to set `commands.restart = true` unconditionally at startup (not false). The controller's subsequent write of `null` is handled by `manager-config-keeper.sh` which writes `commands: {restart: true}` to maintain a stable diff against the startup baseline — see Incident 2.

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

### Incident 2 — 5-minute OpenClaw restart loop (commands normalization) (2026-05-09, re-investigated 2026-05-21)

**What happened:** hiclaw-manager gateway restarted with code 1012 every ~5 minutes, dropping all WebSocket connections and disrupting Matrix sessions. The container stayed up (in-process restart via SIGUSR1, not a Docker restart), but connected clients were dropped ~12 times per hour.

**Symptom — what you see in `docker logs hiclaw-manager`:**
```
[reload] config reload skipped (invalid config): channels.matrix.groups.*: invalid config: must NOT have additional properties
[reload] config reload skipped (invalid config): ...    ← 2–4 of these, ~15 seconds apart
[reload] config change detected; evaluating reload (agents.defaults.elevatedDefault, channels.matrix.accessToken, plugins.allow, commands.restart, tools, meta)
[reload] config change requires gateway restart (commands.restart)
[gateway] signal SIGUSR1 received
[gateway] received SIGUSR1; restarting
[gateway] restart mode: in-process restart (OPENCLAW_NO_RESPAWN)
[gateway] starting HTTP server...
[gateway] starting channels and sidecars...
← 5 minutes of silence, then repeats from the top →
```

The cycle is exactly 5 minutes because the controller reconciles every 5 minutes.

---

**Root cause — requires understanding three things:**

**Thing 1: The controller writes a broken config every ~5 minutes.**
The controller's ManagerReconciler pushes a template to `openclaw.json` that includes:
- `channels.matrix.groups["*"]: {allow: true, requireMention: true}` — `allow` is not in the schema; OpenClaw requires `enabled`
- `commands: null` (the controller clears commands in its template)

The invalid `allow` field causes the gateway to skip the reload entirely.

**Thing 2: The gateway's reload diff compares against the STARTUP BASELINE — not its in-memory state.**
When the gateway starts, the startup script writes `commands.restart=true` to `openclaw.json`. The gateway loads this config and records it as the "last known good" in `workspace/.openclaw/logs/config-health.json` (hash + metadata). **This startup version — with `commands.restart: true` — becomes the permanent baseline for all future reload diff evaluations.** The gateway does not update this baseline during subsequent in-process restarts.

You can inspect the baseline:
```bash
sudo python3 -c "
import json
h = json.load(open('/worksp/hiclaw/workspace/.openclaw/logs/config-health.json'))
for path, info in h['entries'].items():
    lg = info['lastKnownGood']
    print(path, '  hash:', lg['hash'][:16], '  bytes:', lg['bytes'], '  observed:', lg['observedAt'])
"
```
The `/root/manager-workspace/openclaw.json` entry is the active baseline. Its hash corresponds to the file the gateway loaded when it first started (10000+ bytes, includes runtime fields the gateway adds: accessToken, tools, meta, and `commands.restart: true`).

**Thing 3: `commands` is a restart-triggering field — and any diff in it triggers a full restart.**
When the gateway evaluates a reload, it computes a field-by-field diff between (a) the current file and (b) the startup baseline. If `commands` or `commands.restart` appears as a changed field, the gateway forces a full in-process restart instead of a hot reload.

---

**Why the loop forms:**
```
1. Startup: script writes commands.restart=true → gateway starts → records this as baseline
2. ~5 min: controller writes commands:null + invalid groups schema
3. Gateway: tries to reload → rejects (invalid groups schema)
4. ~1 min: keeper runs → fixes groups (allow→enabled) → writes commands:{} or preserves null
5. Gateway: file changed → evaluates diff against startup baseline
   - Baseline has: commands.restart=true
   - Current file has: commands:{} or commands:null
   - DIFF: commands.restart CHANGED → "config change requires gateway restart (commands.restart)"
6. SIGUSR1 → restart → new startup cycle begins → baseline STAYS at original hash → loop
```

The keeper's intent was correct (fix the schema), but the fix itself triggered the restart because `commands` changed relative to the startup baseline.

---

**Why `commands:{}` does NOT work (and why it looks like it should):**
The intuition "just match the gateway's running state" is wrong because the gateway's running state is NOT the baseline. The baseline is the STARTUP FILE (which had `commands.restart:true`). Writing `commands:{}` changes `commands.restart` from `true` (startup) to absent — that's a diff → restart.

**Why `commands:null` does NOT work:**
Same problem. The startup baseline has `commands.restart:true`. Null has no `restart` key. Diff: `commands.restart` changed → restart.

**Why `commands:{restart:false}` does NOT work:**
`commands.restart` changed from `true` to `false` → restart. Plus subsequent controller write sets it to `null`, which is another diff.

---

**Fix:** `manager-config-keeper.sh` writes `commands: {restart: true}` always. This matches the startup baseline's `commands.restart: true` exactly — zero diff — so the gateway processes the keeper's schema fixes as a hot reload with no disruption.

**How to verify the fix is working:**
```bash
# Check current commands value
sudo python3 -c "import json; d=json.load(open('/worksp/hiclaw/workspace/openclaw.json')); print('commands:', d.get('commands'))"
# Expected: {'restart': True}

# Watch logs for one full cycle (~8 min) — should see only these patterns, no SIGUSR1:
docker logs hiclaw-manager --since 10m 2>&1 | grep '\[reload\]'
# OK pattern: "config reload skipped (invalid config)" followed by nothing (keeper ran, zero diff)
# BROKEN pattern: "config reload skipped" followed by "config change requires gateway restart"
```

**Confirmed fixed (2026-05-21):** After the fix, two full controller write cycles occurred (02:32 and 02:37). Each produced "reload skipped" rejections then silence — the keeper ran and produced zero diff. No SIGUSR1. The loop was broken.

**Rule:** `manager-config-keeper.sh` must always write `commands: {restart: true}`. Do not write `{}`, `null`, or `false`. See Idiosyncratic Decision #1.

---

### Incident 3 — Chrome double-instance OOM crash (2026-05-08)

**What happened:** Server ran out of memory (swap exhausted at 3.8/4 GB, ~422 MB RAM free). Two Chrome instances were running simultaneously, consuming ~2.2 GB RSS combined. Server became unresponsive.

**Root cause 1:** Chrome watchdog used `pkill -f "chrome\|pattern"` — `\|` in ERE is a literal pipe, not alternation. pkill matched nothing, so the old Chrome instance survived when the watchdog tried to restart it.

**Root cause 2:** Chrome wrapper unconditionally deleted `Singleton*` files before launch. When Dropbox called `google-chrome https://...` to open a browser auth URL, the wrapper deleted the lock and Chrome spawned a fresh second instance alongside the existing one.

**Fix:** Changed `\|` to `|` in `novnc-startup.sh` (watchdog pkill). Added pgrep guard in Chrome wrapper — only delete Singleton files when Chrome is NOT already running.

**Rule:** The Chrome wrapper's pgrep guard must not be removed. The unescaped `|` in pkill must not be re-escaped. See Idiosyncratic Decisions #4 and #5.

**Recovery:** `docker exec novnc-... pkill -f "/opt/google/chrome/chrome"` — kills all Chrome, watchdog restarts one clean instance within ~5 seconds.

---

### Incident 4 — MinIO recursive storage path / server crash (2026-05-20)

**What happened:** Server hard-crashed at 20:32. After reboot at 20:33, MinIO was consuming ~1 GB RSS and ~30% CPU. Investigation found a recursive MinIO object path: `hiclaw-storage/manager/hiclaw/hiclaw-storage/manager/hiclaw/hiclaw-storage/...` (multiple nesting levels, previously 9+ GB). A local copy of the same recursive tree existed in the workspace at `/worksp/hiclaw/workspace/hiclaw/hiclaw-storage/manager/`. 617 `openclaw.json.clobbered.*` files accumulated from May 4-5.

**Root cause:** `HICLAW_RUNTIME=k8s` (confirmed from `docker inspect hiclaw-manager`) causes the k8s startup block in `start-manager-agent.sh` (lines 171-182) to execute `mc mirror hiclaw/hiclaw-storage/manager/ /root/manager-workspace/ --overwrite` on every container start — pulling the entire MinIO `manager/` prefix into the workspace. The controller's internal ManagerReconciler then pushes the workspace (mounted at `/root/hiclaw-fs/agents/manager/` in the controller) back to `hiclaw/hiclaw-storage/manager/`. Since the workspace now contained `hiclaw/hiclaw-storage/` from the pull, the push created a nested copy in MinIO. Each restart cycle added one more level of nesting.

**Cascade:**
1. Manager starts → pulls MinIO `manager/` → workspace (workspace now has `hiclaw/hiclaw-storage/` inside it)
2. Controller's ManagerReconciler pushes workspace → MinIO `manager/` (includes the nested `hiclaw/hiclaw-storage/` subdirectory)
3. Next restart: pull brings back a deeper nested copy → push creates an even deeper one
4. Over time: `manager/hiclaw/hiclaw-storage/manager/hiclaw/hiclaw-storage/manager/...` grows unboundedly

The `openclaw.json.clobbered.*` files are created by OpenClaw's observe-recovery mechanism when it detects config hash mismatches (triggered by `manager-config-keeper.sh` fixing the schema). They lived in the workspace and would be pushed to MinIO with the workspace — adding more noise but not causing the crash.

**Fix applied (2026-05-20):**
1. Cleaned workspace: `rm -rf /worksp/hiclaw/workspace/hiclaw/ /worksp/hiclaw/workspace/hiclaw-fs` (removed 9GB recursive local copy)
2. Deleted 617 stale `openclaw.json.clobbered.*` files from workspace (from the resolved May 4-5 restart loop)
3. Added `--exclude` guards to the k8s startup `mc mirror` pull in `start-manager-agent.sh` (lines 186-193) to permanently block these paths from entering the workspace

**Rule:** Never pull `hiclaw/*`, `hiclaw-fs`, `*.clobbered.*`, `.npm/*`, `.codex/*`, or `.cache/*` into the workspace from MinIO. The k8s startup pull (`mc mirror ... /root/manager-workspace/`) must use the exclusion flags now present in the script.

**Cleanup check (run after any suspected recursion):**
```bash
BASE="/var/lib/docker/volumes/hiclaw-data/_data/minio/hiclaw-storage"
sudo find "$BASE" -maxdepth 8 -type d -name "hiclaw-storage" -print
# Should print ONLY the root: .../minio/hiclaw-storage
# Any additional lines mean the recursion has returned — stop containers immediately
```

**Recovery if recursion returns:**
```bash
docker stop hiclaw-manager hiclaw-controller
# Clean workspace local copy
sudo rm -rf /worksp/hiclaw/workspace/hiclaw/
# Clean MinIO nested content (only the recursive subtree, not the real manager/ content)
# Use mc rm --recursive from inside a temporary container with mc access to:
#   hiclaw/hiclaw-storage/manager/hiclaw/ (everything under this prefix)
# Then restart containers
docker start hiclaw-controller && sleep 15 && docker start hiclaw-manager
```

---

### Incident 5 — clawtalk plugin lost on container restart (resolved 2026-05-08)

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

### Incident 6 — Swap exhausted by stale Claude Code session; npm OOM crash loop (2026-05-30)

**What happened:** A Claude Code session from 9 days earlier left a bash process (PID 527449) consuming 828 MB of swap. When npm install was run to update openclaw, the combined swap demand caused OOM kills. The partial install left openclaw missing its `json5` dependency, causing a persistent gateway crash loop. Container had to be recreated from the base image (`higress/hiclaw-manager:v1.1.0`).

**Root cause:** Stale long-running shell processes from abandoned AI coding sessions accumulate in swap. On a memory-constrained server (4 GB swap, ~400–600 MB free RAM), any large npm install risks OOM if swap is already occupied by leaking background processes.

**Recovery steps taken:**
1. Identified the stale process: `sudo cat /proc/527449/cmdline` showed it was a bash login shell from 9 days ago
2. Killed it: `kill 527449` — freed 828 MB swap immediately
3. Container was already broken (missing json5); recreated from base image
4. `start-manager-agent.sh` re-ran all bootstraps correctly on fresh container
5. openclaw update was applied via "Update now" UI button (not direct npm install)

**Rule:** Do NOT run `npm install -g openclaw@latest` directly inside the container. Use the "Update now" button in the OpenClaw Control UI. The keeper detects the hash change and triggers a clean container restart. Direct npm install bypasses the keeper mechanism and risks OOM on memory-constrained servers.

**If swap appears exhausted:** Check for stale long-running processes before any large memory operation:
```bash
# Find processes using swap
for pid in /proc/[0-9]*/status; do
    awk '/^Pid:|^VmSwap:/{printf "%s ", $2}' "$pid"
    echo
done 2>/dev/null | awk '$2 > 10000 {print}' | sort -k2 -rn | head -20
# Kill confirmed-stale processes, then retry
```

---

### Incident 7 — openclaw hash detection broken: container overlay vs. workspace volume (2026-05-30)

**What happened:** The "Update now" button ran `openclaw update` inside the container (updating the npm-installed version), but the keeper never detected the change and never triggered a container restart. The new openclaw version was silently ignored; the gateway kept running with old module files.

**Root cause:** `start-manager-agent.sh` was writing the startup hash to `${HOME}/.openclaw-startup-pkg-hash` (i.e., `/root/.openclaw-startup-pkg-hash` inside the container). This path is on the container's overlay filesystem — it is invisible to the host. The keeper read from `/worksp/hiclaw/workspace/.openclaw-startup-pkg-hash` (the host-side path), which never had data, so `startup_pkg_hash` was always empty and the comparison always skipped.

**Fix:** The startup script now writes to `/root/manager-workspace/.openclaw-startup-pkg-hash`. The `/root/manager-workspace/` directory is bind-mounted from `/worksp/hiclaw/workspace/` on the host, so the file is immediately visible to the keeper at `/worksp/hiclaw/workspace/.openclaw-startup-pkg-hash`.

**Additionally fixed:** Both the startup script and the keeper now probe for the openclaw package.json at the npm global install path first (`/usr/lib/node_modules/openclaw/package.json`), falling back to the image built-in (`/opt/openclaw/package.json`). This handles both updated containers (npm path exists) and fresh-from-image containers (only the opt path exists).

**Rule:** The startup hash file must be written to a bind-mounted path visible to the host. Never write state that the keeper needs to `/root/` or `${HOME}/` — those paths are on the container overlay.

---

### Incident 8 — control.claw 502 Bad Gateway after manager container recreation (2026-05-30)

**What happened:** After `docker restart hiclaw-manager`, the control.claw web UI returned 502 Bad Gateway for all API calls. The nginx inside hiclaw-controller was proxying to hiclaw-manager via a hardcoded container IP that Docker had reassigned to a different container after recreation.

**Root cause:** The `manager-console.conf` nginx config used `proxy_pass http://<static-IP>:8080`. Docker's IPAM reassigns IPs when containers are removed and recreated (not just restarted). A `docker rm + docker run` cycle gives the new container a different IP from the DHCP pool.

**Fix:** `start-element-web.sh` now generates `manager-console.conf` with:
```nginx
resolver 127.0.0.11 valid=10s;
set $upstream hiclaw-manager;
proxy_pass http://$upstream:8080;
```
Docker's embedded DNS resolver (`127.0.0.11`) resolves `hiclaw-manager` by container name. Storing the hostname in a variable forces nginx to re-resolve on each request rather than caching the IP at startup. Valid for 10 seconds means stale entries expire quickly after a restart.

**Rule:** Never hardcode container IPs in nginx proxy configs. Always use Docker DNS (`resolver 127.0.0.11`) with a hostname variable.

---

### Incident 9 — OpenRouter sync poisoned config with 'pricing' field (2026-05-30)

**What happened:** An early version of the OpenRouter model sync wrote the full OpenRouter model object (including `pricing`) into the `hiclaw-gateway` models list. OpenClaw's strict JSON schema validation rejected the config on startup, causing the gateway to fall back to defaults and lose all customizations (Matrix token, model list, plugins).

**Root cause:** The jq sync expression passed `.` (the entire OpenRouter model object) into the openclaw model entry instead of extracting only the fields openclaw understands (`contextWindow`, `maxTokens`). The `pricing` field is present in every OpenRouter model object.

**Two-part fix:**
1. The jq sync expression was corrected to only set `contextWindow` and `maxTokens`, never copy the full OpenRouter object
2. A defensive `del(.pricing)` cleanup pass runs on every startup regardless, before the gateway starts — this prevents any previously-poisoned MinIO config from causing failures

**Additionally:** The immediate MinIO push after sync was added to prevent the background MinIO→Local sync from overwriting the cleaned config with the old poisoned version.

**Rule:** When syncing external model data into openclaw config, always extract specific fields. Never spread external objects directly into openclaw's model schema.

---

## 15. Pending Work

- [x] **Clawtalk loads automatically on container start** — `bootstrap_clawtalk_plugin()` in `start-manager-agent.sh` creates the bundled shim and deletes `installs.json` so the gateway does a fresh plugin scan and discovers clawtalk. All critical checks pass (`bot_connected ✓`).
- [x] **openclaw update detection fixed** — hash is now written to workspace volume (bind-mounted), visible to host-side keeper. Both startup script and keeper probe npm path first, fall back to image built-in.
- [x] **control.claw 502 after manager restart fixed** — nginx now uses Docker DNS resolver with hostname variable instead of hardcoded IP.
- [x] **openclaw symlink fixed after npm update** — startup script runs `ln -sf /usr/lib/node_modules/openclaw/openclaw.mjs /usr/local/bin/openclaw` if npm-installed version exists.
- [x] **OpenRouter model metadata sync** — deepseek/deepseek-v4-pro now shows 1048576 context window from OpenRouter live data. Sync runs on every startup.
- [ ] **Other models still use hardcoded context windows** — gpt-5.4, claude-opus-4-6, deepseek-chat, kimi-k2.5, etc. use Higress gateway alias IDs that have no OpenRouter equivalent. Their context windows cannot be auto-synced without a mapping table or by changing the model IDs to match OpenRouter's canonical IDs.
- [ ] **Rebuild `ghcr.io/u2giants/novnc-desktop` image** — Chrome wrapper fix (pgrep guard) is applied to the running container in-place but the Dockerfile fix has not been built and pushed yet. Next push to `novnc-desktop/` will trigger this automatically.
- [ ] **Mount clawtalk modifications from host** — instead of recreating them inside the container, mount the fixed files from `/worksp/hiclaw/workspace/` so they survive container restarts permanently.
- [ ] **Move hiclaw-manager and hiclaw-controller to Coolify** — currently managed by keeper scripts. Low priority; scripts work reliably.
- [ ] **Move oauth2-proxy to Coolify** — currently run via `docker-compose.yml` directly. Works fine; Coolify management would add UI visibility.
- [ ] **Verify tuwunel (Matrix homeserver) status** — `start-tuwunel.sh` exists but tuwunel was not visible in recent `docker ps` output. Confirm whether it is running or if Matrix is handled differently.
- [ ] **Set up git pull automation on server** — shell script/config changes deploy by git push but require a manual `git pull` on the server. A post-receive webhook or cron would automate this.
