---
name: noVNC Chrome Setup Issues
description: Hard-won fixes for Chrome/Chromium in the webtop container at vnc.designflow.app, including the double-Chrome OOM crash root cause (2026-05-08)
type: project
originSessionId: bb911f7a-85ed-4902-a81a-62c314affe9f
---
# noVNC Chrome Setup — What Went Wrong and How to Fix It

## Container context
- Image: `ghcr.io/u2giants/novnc-desktop` (custom, built from `lscr.io/linuxserver/webtop:ubuntu-mate`)
- Desktop user inside container: `abc` (uid 1000)
- Startup script: `/home/ai/novnc-desktop/novnc-startup.sh` → copied into image as `/custom-cont-init.d/99-start-chromium.sh`
- Chrome wrapper: `/usr/local/bin/google-chrome` (inside container, baked into image)
- Chrome profile: `/config/chrome-profile` (on persistent volume)

## Critical fixes applied

### 1. Chrome requires --no-sandbox in Docker
Chrome crashes silently without `--no-sandbox --disable-dev-shm-usage`. Symptoms: "starting chrome" appears in taskbar for ~20 seconds then disappears, no error shown. Fix: wrapper at `/usr/local/bin/google-chrome` adds these flags.

### 2. Chrome profile must be owned by abc, not root
If Chrome is ever launched via `docker exec` (as root), it creates `/config/chrome-profile` owned by root. MATE then launches Chrome as `abc` which gets `Permission denied` on the Singleton lock.

**Fix:** wrapper runs `chown -R abc:abc /config/chrome-profile` before launching. Never launch Chrome via `docker exec` for testing.

### 3. Both .desktop files must be patched
- `/usr/share/applications/google-chrome.desktop` (MATE app menu)
- `/config/Desktop/google-chrome.desktop` (desktop icon)

### 4. Stale Singleton* files cause 20-second hang
Fix: wrapper conditionally deletes Singleton files — but ONLY when Chrome is not already running (see bug #6 below).

### 5. xdg-settings default browser must be set as abc user
```bash
su abc -c "DISPLAY=:1 xdg-settings set default-web-browser google-chrome.desktop"
```

### 6. **CRITICAL: Double-Chrome OOM crash (2026-05-08)**
The server crashed today from memory exhaustion (swap fully exhausted at 3.8/4 GB, RAM at 422 MB free). Two Chrome instances were running simultaneously (~2.2 GB RSS combined).

**Root cause 1 — broken pkill pattern**: The Chrome watchdog in `novnc-startup.sh` used:
```bash
pkill -f "google-chrome\|/opt/google/chrome/chrome"
```
pkill uses ERE, where `\|` means a **literal pipe character** (not alternation). So pkill silently matched nothing. When the watchdog tried to restart Chrome, the old instance survived.

**Root cause 2 — wrapper nukes Singleton unconditionally**: The Chrome wrapper always ran `rm -f /config/chrome-profile/Singleton*` before launching. When Dropbox called `google-chrome https://dropbox.com/...` to open a browser auth URL, the wrapper deleted the Singleton files even though Chrome was already running. This made Chrome think no instance was running and spawned a fresh browser (with the Dropbox URL), leaving the existing instance abandoned. Both ran forever.

**Fixes applied (2026-05-08):**
- `novnc-startup.sh` line 75: Changed `"google-chrome\|/opt/google/chrome/chrome"` → `"google-chrome|/opt/google/chrome/chrome"` (unescaped `|` for ERE alternation)
- `novnc-startup.sh` sleep after pkill: 1s → 2s (more time for Chrome to die before restart)
- Chrome wrapper (`/usr/local/bin/google-chrome`): Added pgrep check — only delete Singleton files when Chrome is NOT already running:
  ```bash
  if ! pgrep -f "/opt/google/chrome/chrome" > /dev/null 2>&1; then
      rm -f /config/chrome-profile/Singleton*
  fi
  ```
- Dockerfile updated with the same wrapper fix; image rebuild needed to make it persistent.
- Rogue Chrome instance (PID 3280 inside container, started 08:55) killed manually — freed ~700 MB RAM.
- Wrapper fix applied in-place (inode-preserving `cat >`) to running container.

## Current wrapper content
```bash
#!/bin/bash
mkdir -p /config/chrome-profile
chown -R abc:abc /config/chrome-profile 2>/dev/null
if ! pgrep -f "/opt/google/chrome/chrome" > /dev/null 2>&1; then
    rm -f /config/chrome-profile/Singleton*
fi
exec /usr/bin/google-chrome-stable --no-sandbox --disable-dev-shm-usage --no-first-run --start-maximized --user-data-dir=/config/chrome-profile --remote-debugging-port=9222 --remote-debugging-address=0.0.0.0 --remote-allow-origins='*' --renderer-process-limit=4 --disable-background-networking --disable-sync "$@"
```

## 7. Bind-mount inode staleness breaks cdp_proxy.py updates
When `/data/coolify/services/.../cdp_proxy.py` is REPLACED (not edited in-place) on the host, Docker's bind mount in the running container still points to the OLD inode.

**Fix permanently:** Edit files IN-PLACE (e.g., `sed -i 's/old/new/' file`) to preserve the inode.

## Architecture: Chrome is the only browser
Chrome (`google-chrome`) is both the user's personal browser AND the CDP automation browser:
- Profile: `/config/chrome-profile`
- CDP port: 9222 (internal), proxied to 9223 via cdp_proxy.py
- OpenClaw/OpenManus connects via `http://novnc:9223`
- Kept alive by Chrome watchdog in startup script

## Watchdog internals (novnc-startup.sh)
The watchdog is a background bash subshell `( while true; do ... ) &`. It:
1. Deletes session files + patches Chrome prefs
2. Kills stale Chrome with pkill (see bug #6 for the fix)
3. Starts Chrome in FOREGROUND via `su abc -c "DISPLAY=:1 /usr/local/bin/google-chrome"`
4. Blocks until Chrome exits, then loops

The watchdog subshell runs as PID 581 inside the container (reparented from the cont-init.d script). It stays alive for the container's lifetime, blocked on the `su abc` process while Chrome is running.

## TODO: rebuild image
The Dockerfile fix for the wrapper is committed to `/home/ai/novnc-desktop/` but the image has not been rebuilt yet. Until it's rebuilt and the container restarted, the running container has the in-place wrapper fix but the cont-init.d watchdog script still has the old `\|` pkill bug (harmless while Chrome is running, since the watchdog is foreground-blocked).
