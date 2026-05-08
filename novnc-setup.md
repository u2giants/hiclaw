# noVNC / Browser Agent Setup

## What this is

The `novnc-e10kwzww46ljhrgz1qj08j6a` container is a full Ubuntu MATE desktop (linuxserver/webtop) with Chromium pre-configured to open fidelity.com. The browser is remotely controllable by HiClaw agents via the Chrome DevTools Protocol (CDP), while the user can simultaneously watch what the agent is doing at **vnc.designflow.app**.

## Architecture

```
HiClaw agent (hiclaw-manager)
   → Playwright MCP server (npx @playwright/mcp, spawned by openclaw)
      → CDP HTTP  http://10.0.5.4:9223  (JSON discovery, tab listing)
      → CDP WS    ws://10.0.5.4:9224    (WebSocket control)
         → cdp_proxy.py (inside noVNC container)
            → Chromium localhost:9222 (the visible browser)

User watches via noVNC web UI → vnc.designflow.app
```

## Container details

- **Container name:** `novnc-e10kwzww46ljhrgz1qj08j6a`
- **Image:** `lscr.io/linuxserver/webtop:ubuntu-mate`
- **Networks:** `e10kwzww46ljhrgz1qj08j6a` (10.0.5.4), `e10kwzww46ljhrgz1qj08j6a_default` (10.0.7.2)
- **Web UI port:** 3000 (HTTP), 3001 (HTTPS) — proxied via Coolify/Traefik to `vnc.designflow.app`

## CDP proxy

The proxy runs inside the noVNC container and makes Chrome's CDP (which binds to localhost only) accessible cross-container.

- **Script:** `/config/custom-cont-init.d/cdp_proxy.py`
- **Startup hook:** `/config/custom-cont-init.d/99-start-chromium.sh` starts the proxy at container boot
- HTTP port 9223: JSON discovery endpoint (lists browser info, tabs)
- WebSocket port 9224: transparent WebSocket tunnel for CDP commands

The proxy rewrites `localhost:9222` → `10.0.5.4:9224` in JSON responses so Playwright can connect to the correct address.

## Chromium configuration

Chromium auto-starts via MATE desktop autostart: `/config/.config/autostart/chromium-watchdog.desktop`

Key flags:
- `--remote-debugging-port=9222` — enables CDP
- `--remote-allow-origins=*` — allows cross-origin CDP connections
- `--proxy-server=socks5://10.0.5.1:1080` — routes traffic through a SOCKS5 proxy
- `--user-data-dir=/config/chromium-profile` — persistent profile (saved across restarts)
- Opens `https://www.fidelity.com` on start

## openclaw MCP registration

The Playwright MCP server is registered in openclaw as the `browser` MCP server:

```json
{
  "command": "npx",
  "args": ["@playwright/mcp", "--cdp-endpoint", "http://10.0.5.4:9223"],
  "type": "stdio"
}
```

Saved in: `/root/manager-workspace/openclaw.json` (= `/worksp/hiclaw/workspace/openclaw.json` on the host)

To verify registration:
```bash
docker exec hiclaw-manager openclaw mcp list
```

**Keeping the MCP config after upgrades:** The HiClaw gateway strips unknown keys when it syncs config to MinIO, which can drop the `mcp` block. If the browser tool disappears after a gateway restart or upgrade, run:
```bash
/worksp/hiclaw/mcp-keeper.sh
```

## Network connections

`hiclaw-manager` must be connected to the noVNC container's network to reach CDP:
```bash
docker network connect e10kwzww46ljhrgz1qj08j6a hiclaw-manager
```

This persists across `hiclaw-manager` restarts (Docker remembers network connections) but NOT across container recreations. If the MCP stops working after an upgrade:
```bash
docker network connect e10kwzww46ljhrgz1qj08j6a hiclaw-manager
```

## Default save / download location

All file downloads and Save As dialogs in the noVNC desktop default to the Google Drive hiclaw folder:

```
/config/hiclaw  →  /config/Insync/u2giants@gmail.com/Google Drive/hiclaw
```

`/config/hiclaw` is a symlink; Insync syncs it to Google Drive automatically.

**What's configured:**
- Chromium managed policy (`/etc/chromium/policies/managed/hiclaw.json`) — enforces `DownloadDirectory`, cannot be overridden in Chrome settings
- Chromium `Preferences` — `savefile.default_directory` sets the Save As dialog default
- XDG user dirs (`/config/.config/user-dirs.dirs`) — `XDG_DOWNLOAD_DIR` and `XDG_DOCUMENTS_DIR` point there, used by MATE file manager and GTK file pickers
- GTK bookmarks — `/config/hiclaw` appears as a sidebar shortcut in file dialogs

**Persistence:** `/config/custom-cont-init.d/50-hiclaw-save-defaults.sh` re-applies the policy and XDG dirs on every container restart.

**To re-apply manually (e.g. after Chrome clears prefs on crash):**
```bash
docker exec novnc-e10kwzww46ljhrgz1qj08j6a bash /config/custom-cont-init.d/50-hiclaw-save-defaults.sh
```

## Giving agents a task

From the command line (for testing):
```bash
docker exec hiclaw-manager openclaw agent --agent main -m "Log into fidelity.com with username X and password Y, then download the last 10 years of monthly statements"
```

From Element Web (normal use): just chat with the agent in the Matrix room — it has the `browser` tool available.

## Troubleshooting

**CDP proxy not responding:**
```bash
docker exec novnc-e10kwzww46ljhrgz1qj08j6a pkill -f cdp_proxy
docker exec -d novnc-e10kwzww46ljhrgz1qj08j6a python3 /config/custom-cont-init.d/cdp_proxy.py
```

**hiclaw-manager can't reach 10.0.5.4:**
```bash
docker network connect e10kwzww46ljhrgz1qj08j6a hiclaw-manager
```

**Chromium not running:**
```bash
docker exec novnc-e10kwzww46ljhrgz1qj08j6a ps aux | grep chromium
# Restart via watchdog:
docker exec -d novnc-e10kwzww46ljhrgz1qj08j6a bash -c 'DISPLAY=:1 /usr/lib/chromium/chromium --no-first-run --no-default-browser-check --disable-gpu --no-sandbox --disable-dev-shm-usage --disable-blink-features=AutomationControlled --proxy-server=socks5://10.0.5.1:1080 --remote-debugging-port=9222 --remote-allow-origins="*" --user-data-dir=/config/chromium-profile https://www.fidelity.com >> /tmp/chromium.log 2>&1'
```
