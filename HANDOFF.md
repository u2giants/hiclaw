# Handoff

**Delete this file once the containers are restarted and the MinIO recursion check passes.**

---

## Context

The server crashed on 2026-05-20 ~20:32. The crash was investigated, a root-cause fix was applied, the workspace was cleaned, and all documentation was updated. Both HiClaw containers are intentionally stopped.

The next developer's job is: restart the containers, verify the fix holds, and confirm the system is healthy.

---

## What Was Done This Session

### Fixed
- **Root cause identified:** `HICLAW_RUNTIME=k8s` causes `start-manager-agent.sh` to pull MinIO `hiclaw/hiclaw-storage/manager/` into the workspace on every startup. The controller's internal ManagerReconciler pushes workspace back to MinIO. Since the workspace accumulated a `hiclaw/hiclaw-storage/` local copy from the pull, each cycle added one more nesting level — `manager/hiclaw/hiclaw-storage/manager/hiclaw/hiclaw-storage/...` — eventually 9+ GB.
- **Fix applied** (`7f87b32`): Added `--exclude "hiclaw/*"`, `--exclude "hiclaw-fs"`, `--exclude "*.clobbered.*"`, `--exclude ".npm/*"`, `--exclude ".codex/*"`, `--exclude ".cache/*"` to the k8s startup `mc mirror` pull in `start-manager-agent.sh` lines 186-193.
- **Workspace cleaned:** Removed `/worksp/hiclaw/workspace/hiclaw/` (9GB recursive local MinIO mirror) and dangling `hiclaw-fs` symlink.
- **617 stale clobbered files removed** from workspace (May 4-5 restart loop artifact from Incident 1/2).
- **MinIO is currently clean:** 30MB total, no recursive paths visible.
- **Documentation rewritten** to accurately reflect current codebase state, including the recursion mechanism, exclusion guards, and the `commands.restart` behavior (which previous docs incorrectly described as "always `true`" — it's actually `true` on startup, then `{}` in steady state).
- **AGENTS.md updated** with Incident 4 (MinIO recursion).

### Committed and pushed
- `7f87b32` — the startup script fix + Incident 4 docs
- Doc update commit — all five doc files rewritten

---

## Current State

| Item | State |
|---|---|
| `hiclaw-controller` | **Stopped** (Exited 0) |
| `hiclaw-manager` | **Stopped** (Exited 0) |
| `novnc-desktop` | unknown — check with `docker ps` |
| `oauth2-proxy` | unknown — check with `docker ps` |
| MinIO | Clean — 30MB, no recursive paths |
| workspace | Clean — `hiclaw/` and `hiclaw-fs` removed |
| Fix committed | Yes — `7f87b32` on main |
| Fix pulled to server | Yes — already on disk |

---

## Exact Next Actions

### 1. Verify git is current on server

```bash
cd /worksp/hiclaw && git log --oneline -3
# Should show 7f87b32 as the most recent commit
```

### 2. Staged restart with monitoring

```bash
# Start controller first
docker start hiclaw-controller
sleep 20

# CRITICAL: Check MinIO before starting manager
sudo find /var/lib/docker/volumes/hiclaw-data/_data/minio/hiclaw-storage \
  -maxdepth 8 -type d -name "hiclaw-storage" -print
# Expected output: ONLY the root path line
# If extra lines appear: DO NOT start manager. The controller itself is generating recursion.
# In that case: docker stop hiclaw-controller, and re-read architecture.md § MinIO recovery

# Start manager (only if MinIO check passed)
docker start hiclaw-manager
sleep 30

# Check MinIO again — manager startup k8s pull runs at this point
sudo find /var/lib/docker/volumes/hiclaw-data/_data/minio/hiclaw-storage \
  -maxdepth 8 -type d -name "hiclaw-storage" -print
# Still only one line? Good — the fix is working.

# Check workspace — no hiclaw/ directory should have been created
ls /worksp/hiclaw/workspace/hiclaw/ 2>/dev/null && echo "PROBLEM: recursion seed returned" || echo "OK"
```

### 3. Verify manager health

```bash
docker exec hiclaw-manager openclaw clawtalk doctor
bash /worksp/hiclaw/manager-bootstrap-keeper.sh   # should say "already current"
docker logs hiclaw-manager --since 5m | grep -E 'gateway|ClawTalk|error'
```

### 4. Verify Element Web / New Chat

```bash
docker exec hiclaw-controller curl -s http://127.0.0.1:8088/hiclaw-api/healthz
docker exec hiclaw-controller ps -ef | grep nginx | grep -v grep
```

### 5. Check cron

```bash
crontab -l
# Must have all three keepers registered
```

### 6. Delete this HANDOFF.md

```bash
rm /worksp/hiclaw/HANDOFF.md
git add -A && git commit -m "Remove HANDOFF.md — containers verified healthy post-fix"
git push
```

---

## If MinIO Recursion Reappears

Stop both containers immediately:

```bash
docker stop hiclaw-manager hiclaw-controller
sudo rm -rf /worksp/hiclaw/workspace/hiclaw/
sudo rm -f /worksp/hiclaw/workspace/hiclaw-fs
```

Then read [docs/architecture.md § MinIO sync safety](docs/architecture.md#minio-sync-safety) for the full recovery procedure.

The recursion should not recur with the fix applied, but if it does, the source is in the manager startup k8s block (`start-manager-agent.sh` lines 186-193) — check that the `--exclude "hiclaw/*"` flag is present and that mc is receiving it (the mc wrapper from `fix-element-config.sh` may be intercepting the call).

---

## Known Pre-Existing Pending Work (not from this session)

These are from AGENTS.md § Pending Work and were not touched this session:

- [ ] Rebuild `ghcr.io/u2giants/novnc-desktop` image — Chrome pgrep wrapper fix is applied in-container but image not rebuilt/pushed yet. Will trigger automatically on next push to `novnc-desktop/`.
- [ ] Mount clawtalk modifications from host — currently recreated by `start-manager-agent.sh` on each restart.
- [ ] Verify Tuwunel (Matrix homeserver) status — `start-tuwunel.sh` exists but tuwunel container not observed in recent `docker ps`.
- [ ] Set up git pull automation on server.

---

## Key Decisions Made This Session

- **Chose `--exclude` guards over an allowlist** for the mc mirror pull. An allowlist (only sync known-safe paths) would be safer long-term but requires knowing all the legitimate paths the controller populates. The exclusion list of dangerous paths is narrower and less likely to break existing functionality.
- **Cleaned workspace `hiclaw/` immediately** rather than quarantining. MinIO is authoritative; the workspace copy was confirmed to be a pull artifact with no unique content.
- **Deleted 617 clobbered files** without quarantine. These are observe-recovery backups from the resolved May 4-5 restart loop — no value; only noise that would be pushed to MinIO on the next startup.
- **Left `fix-element-config.sh` mc wrapper unchanged.** The mc wrapper intercepts `mc mirror` calls inside the manager container and re-injects the MCP config after pulls. This wrapper runs BEFORE our exclusion flags reach `mc.real`, so it does not interfere with the exclusions. Verified by reading the wrapper logic: it only modifies `openclaw.json` after mirror, passes all args through to `mc.real`.
