#!/bin/bash
# Re-apply Element Web config after a HiClaw upgrade.
# HiClaw upgrades recreate the container, resetting config.json.
# Run this script immediately after any `hiclaw-install.sh` upgrade.

set -e

docker exec hiclaw-controller sh -c 'cat > /opt/element-web/config.json << '"'"'CONF'"'"'
{
    "default_server_config": {
        "m.homeserver": {
            "base_url": "https://claw.designflow.app"
        }
    },
    "brand": "Element",
    "disable_guests": true,
    "disable_custom_urls": false,
    "features": {},
    "setting_defaults": {
        "e2ee.manuallyVerifyAllSessions": false,
        "UIFeature.advancedEncryption": false,
        "UIFeature.accessTokens": false
    },
    "e2ee": {
        "secure_backup_setup_at_login": false,
        "secure_backup_required": false
    }
}
CONF'

echo "Element Web config.json patched → claw.designflow.app"

# Write the Control Panel button JS (fixed-position button over the left panel)
docker exec hiclaw-controller bash -c 'cat > /opt/element-web/control-panel-btn.js << '"'"'EOF'"'"'
(function() {
  var ID = "hiclaw-cp-btn";
  function inject() {
    if (document.getElementById(ID)) return;
    if (!document.body) return;
    var a = document.createElement("a");
    a.id = ID;
    a.href = "https://control.claw.designflow.app/";
    a.target = "_blank";
    a.title = "Control Panel";
    a.textContent = "Control Panel";
    a.style.cssText = "position:fixed;left:70px;bottom:12px;width:232px;z-index:9000;padding:8px 14px;background:#0dbd8b;color:#fff;text-decoration:none;border-radius:8px;font-family:system-ui,-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif;font-size:13px;font-weight:600;text-align:center;box-shadow:0 1px 8px rgba(0,0,0,0.35);pointer-events:auto;";
    document.body.appendChild(a);
  }
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", function() { setTimeout(inject, 500); });
  } else {
    setTimeout(inject, 500);
  }
})();
EOF'

docker exec hiclaw-controller bash -c 'cat > /opt/element-web/new-chat-btn.js << '"'"'EOF'"'"'
(function() {
  var ID = "hiclaw-new-chat-btn";
  var ROOM_PREFIX = "Chat: ";
  var busy = false;

  function setState(btn, label, disabled) {
    btn.textContent = label;
    btn.style.opacity = disabled ? "0.7" : "1";
    btn.style.cursor = disabled ? "wait" : "pointer";
  }

  function focusNewRoom(roomName) {
    var deadline = Date.now() + 20000;
    function tryFocus() {
      var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
      var node;
      while ((node = walker.nextNode())) {
        var text = (node.nodeValue || "").trim();
        if (text !== roomName) continue;
        var el = node.parentElement;
        while (el && el !== document.body) {
          var role = el.getAttribute && el.getAttribute("role");
          if (el.tagName === "A" || el.tagName === "BUTTON" || role === "treeitem" || role === "button") {
            el.click();
            return true;
          }
          el = el.parentElement;
        }
      }
      return false;
    }

    if (tryFocus()) return;
    var timer = setInterval(function() {
      if (tryFocus()) {
        clearInterval(timer);
        return;
      }
      if (Date.now() > deadline) {
        clearInterval(timer);
        window.alert("New chat created. If it did not open automatically, it should now be visible in the room list.");
      }
    }, 750);
  }

  async function createRoom(btn) {
    if (busy) return;
    var raw = window.prompt("Name the new chat", "");
    if (raw === null) return;
    var name = raw.trim();
    if (!name) {
      window.alert("Please enter a chat name.");
      return;
    }

    busy = true;
    setState(btn, "Creating chat...", true);
    try {
      var res = await window.fetch("/hiclaw-api/new-chat", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name: name })
      });
      var body = await res.json().catch(function() { return {}; });
      if (!res.ok) {
        throw new Error(body.error || ("Request failed (" + res.status + ")"));
      }
      focusNewRoom(body.room_name || (ROOM_PREFIX + name));
    } catch (err) {
      window.alert("Could not create the new chat: " + (err && err.message ? err.message : String(err)));
    } finally {
      busy = false;
      setState(btn, "+ New Chat", false);
    }
  }

  function inject() {
    if (document.getElementById(ID)) return;
    if (!document.body) return;
    var btn = document.createElement("button");
    btn.id = ID;
    btn.type = "button";
    btn.title = "Create a new HiClaw chat room";
    btn.textContent = "+ New Chat";
    btn.style.cssText = "position:fixed;left:70px;bottom:56px;width:232px;z-index:9001;padding:8px 14px;background:#155eef;color:#fff;border:0;border-radius:8px;font-family:system-ui,-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif;font-size:13px;font-weight:700;text-align:center;box-shadow:0 1px 8px rgba(0,0,0,0.35);pointer-events:auto;";
    btn.addEventListener("click", function() { createRoom(btn); });
    document.body.appendChild(btn);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", function() { setTimeout(inject, 500); });
  } else {
    setTimeout(inject, 500);
  }
})();
EOF'

docker exec hiclaw-controller bash -c 'cat > /opt/element-web/hiclaw-chat-api.py << '"'"'EOF'"'"'
#!/usr/bin/env python3
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MATRIX_URL = os.environ.get("HICLAW_MATRIX_URL", "http://hiclaw-controller:6167").rstrip("/")
MATRIX_DOMAIN = os.environ.get("HICLAW_MATRIX_DOMAIN", "matrix-local.hiclaw.io:18080")
ADMIN_USER = os.environ.get("HICLAW_ADMIN_USER", "admin")
ADMIN_PASSWORD = os.environ.get("HICLAW_ADMIN_PASSWORD", "")
MANAGER_USER = os.environ.get("HICLAW_MANAGER_USER", "manager")
ADMIN_FULL_ID = f"@{ADMIN_USER}:{MATRIX_DOMAIN}"
MANAGER_FULL_ID = f"@{MANAGER_USER}:{MATRIX_DOMAIN}"
ROOM_PREFIX = "Chat: "

def fail(message, code=500):
    raise RuntimeError(f"{code}:{message}")

def matrix_request(method, path, payload=None, token=None):
    url = f"{MATRIX_URL}{path}"
    data = None
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            raw = resp.read().decode("utf-8")
            return resp.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", "ignore")
        try:
            body = json.loads(raw) if raw else {}
        except Exception:
            body = {"error": raw or exc.reason}
        return exc.code, body

def login():
    if not ADMIN_PASSWORD:
        fail("HICLAW_ADMIN_PASSWORD is not available inside hiclaw-controller")
    status, body = matrix_request(
        "POST",
        "/_matrix/client/v3/login",
        {
            "type": "m.login.password",
            "identifier": {"type": "m.id.user", "user": ADMIN_USER},
            "password": ADMIN_PASSWORD,
        },
    )
    token = body.get("access_token")
    if status != 200 or not token:
        fail(f"admin login failed: {body.get('error', body)}", 502)
    return token

def create_room(token, title):
    safe = " ".join(title.split()).strip()
    if not safe:
        fail("chat name cannot be empty", 400)
    if len(safe) > 80:
        safe = safe[:80].rstrip()
    room_name = f"{ROOM_PREFIX}{safe}"
    status, body = matrix_request(
        "POST",
        "/_matrix/client/v3/createRoom",
        {
            "name": room_name,
            "topic": f"Separate HiClaw conversation: {safe}",
            "invite": [MANAGER_FULL_ID],
            "preset": "trusted_private_chat",
            "power_level_content_override": {
                "users": {
                    ADMIN_FULL_ID: 100,
                    MANAGER_FULL_ID: 100
                }
            }
        },
        token=token,
    )
    room_id = body.get("room_id")
    if status not in (200, 201) or not room_id:
        fail(f"room creation failed: {body.get('error', body)}", 502)

    txn = f"new-chat-{int(time.time())}"
    msg_status, msg_body = matrix_request(
        "PUT",
        f"/_matrix/client/v3/rooms/{urllib.parse.quote(room_id, safe='')}/send/m.room.message/{txn}",
        {
            "msgtype": "m.text",
            "body": f'{MANAGER_FULL_ID} This is a separate admin chat named "{safe}". Treat this room as an isolated conversation thread and keep replies in this room.',
            "m.mentions": {"user_ids": [MANAGER_FULL_ID]},
        },
        token=token,
    )
    if msg_status not in (200, 201) or "event_id" not in msg_body:
        fail(f"initial message failed: {msg_body.get('error', msg_body)}", 502)

    return {"room_id": room_id, "room_name": room_name, "event_id": msg_body["event_id"]}

class Handler(BaseHTTPRequestHandler):
    def _send(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/healthz":
            self._send(200, {"ok": True})
            return
        self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/new-chat":
            self._send(404, {"error": "not found"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            raw = self.rfile.read(length).decode("utf-8") if length else "{}"
            payload = json.loads(raw) if raw else {}
            title = str(payload.get("name", "")).strip()
            if payload.get("dry_run"):
                self._send(200, {"ok": True, "room_name": f"{ROOM_PREFIX}{title}"})
                return
            token = login()
            self._send(200, create_room(token, title))
        except RuntimeError as exc:
            code_text, _, message = str(exc).partition(":")
            try:
                code = int(code_text)
            except ValueError:
                code = 500
                message = str(exc)
            self._send(code, {"error": message})
        except Exception as exc:
            self._send(500, {"error": str(exc)})

    def log_message(self, fmt, *args):
        sys.stdout.write("[hiclaw-chat-api] " + (fmt % args) + "\n")
        sys.stdout.flush()

if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 8091), Handler).serve_forever()
EOF
chmod +x /opt/element-web/hiclaw-chat-api.py'

docker exec hiclaw-controller sh -c 'cat > /etc/nginx/conf.d/element-web.conf << '"'"'NGINXEOF'"'"'
server {
    listen 8088;
    root /opt/element-web;
    index index.html;

    location = /hiclaw-api/new-chat {
        proxy_pass http://127.0.0.1:8091/new-chat;
        proxy_http_version 1.1;
        proxy_read_timeout 30s;
        proxy_send_timeout 30s;
        add_header Cache-Control "no-store";
    }

    location = /hiclaw-api/healthz {
        proxy_pass http://127.0.0.1:8091/healthz;
        proxy_http_version 1.1;
        proxy_read_timeout 10s;
        proxy_send_timeout 10s;
        add_header Cache-Control "no-store";
    }

    location / {
        try_files $uri $uri/ /index.html;
        sub_filter_once on;
        sub_filter_types text/html;
        sub_filter '"'"'</body>'"'"' '"'"'<script src="browser-bypass.js"></script><script src="control-panel-btn.js"></script><script src="new-chat-btn.js"></script></body>'"'"';
    }

    location ~* ^/(config.*\.json|index\.html|i18n|version)$ {
        add_header Cache-Control "no-cache";
        sub_filter_once on;
        sub_filter_types text/html;
        sub_filter '"'"'</body>'"'"' '"'"'<script src="browser-bypass.js"></script><script src="control-panel-btn.js"></script><script src="new-chat-btn.js"></script></body>'"'"';
    }
}
NGINXEOF'

docker exec hiclaw-controller sh -c '
if pgrep -f /opt/element-web/hiclaw-chat-api.py >/dev/null 2>&1; then
  pkill -f /opt/element-web/hiclaw-chat-api.py 2>/dev/null || true
  sleep 1
fi
nohup python3 /opt/element-web/hiclaw-chat-api.py >> /var/log/hiclaw-chat-api.log 2>&1 &
nginx -s reload'

echo "Element Web nginx config patched → Control Panel and New Chat buttons injected"

# Install the npm wrapper in hiclaw-manager so "Update now" button works.
# The wrapper copies HiClaw-specific extensions after npm installs a new openclaw,
# then updates the /usr/local/bin/openclaw symlink so the container restart picks up the new version.
docker exec hiclaw-manager bash -c 'cat > /usr/local/bin/npm << '"'"'WRAPEOF'"'"'
#!/bin/bash
# HiClaw npm wrapper: patches openclaw installs with HiClaw-specific extensions.
/usr/lib/node_modules/npm/bin/npm-cli.js "$@"
EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ] && ([[ "$1" == "install" ]] || [[ "$1" == "i" ]]) && echo "$@" | grep -qE "\-g|--global" && echo "$@" | grep -q "openclaw"; then
    NEW_ROOT="/usr/lib/node_modules/openclaw"
    OLD_ROOT="/opt/openclaw"
    if [ -d "$NEW_ROOT/dist/extensions" ] && [ -d "$OLD_ROOT/dist/extensions" ]; then
        for ext_dir in "$OLD_ROOT/dist/extensions"/*/; do
            ext=$(basename "$ext_dir")
            [ ! -d "$NEW_ROOT/dist/extensions/$ext" ] && cp -r "$ext_dir" "$NEW_ROOT/dist/extensions/"
        done
        ln -sf "$NEW_ROOT/openclaw.mjs" /usr/local/bin/openclaw
    fi
fi

exit $EXIT_CODE
WRAPEOF
chmod +x /usr/local/bin/npm
ln -sf /usr/local/bin/npm /usr/bin/npm'

echo "hiclaw-manager npm wrapper installed → Update now button will work"

# Install the mc wrapper + inject script in hiclaw-manager so MCP config survives
# gateway restarts and MinIO sync cycles that strip unknown keys.
# The wrapper intercepts incoming mc mirror (startup) and outgoing mc mirror/cp
# (periodic sync), re-injecting the 'mcp' key and keeping openclaw.json.bak in
# sync so openclaw's health-check restore doesn't overwrite our changes.
docker exec hiclaw-manager bash -c 'cat > /usr/local/bin/mc-mcp-inject.py << '"'"'PYEOF'"'"'
#!/usr/bin/env python3
import json, sys, os

path = sys.argv[1]
mcp_cfg = {
    "servers": {
        "browser": {
            "command": "npx",
            "args": ["@playwright/mcp", "--cdp-endpoint", "http://10.0.5.4:9223"],
            "type": "stdio"
        }
    }
}

def inject(p):
    if not os.path.isfile(p):
        return
    try:
        d = json.load(open(p))
        if d.get("mcp") != mcp_cfg:
            d["mcp"] = mcp_cfg
            json.dump(d, open(p, "w"), indent=2)
    except Exception:
        pass

try:
    inject(path)
    bak = os.path.join(os.path.dirname(path), ".openclaw", "openclaw.json.bak")
    inject(bak)
except Exception:
    pass
PYEOF
chmod +x /usr/local/bin/mc-mcp-inject.py'

docker exec hiclaw-manager bash -c '
[ -f /usr/local/bin/mc.real ] || mv /usr/local/bin/mc /usr/local/bin/mc.real
cat > /usr/local/bin/mc << '"'"'WRAPEOF'"'"'
#!/bin/bash
REAL=/usr/local/bin/mc.real
INJECT=/usr/local/bin/mc-mcp-inject.py
WORKSPACE=/root/manager-workspace/openclaw.json
MINIO_MGR=hiclaw/hiclaw-storage/manager/openclaw.json

if [[ "$1" == "cp" ]]; then
    for arg in "$@"; do
        case "$arg" in
            *openclaw.json*)
                case "$arg" in
                    *hiclaw-storage*|*.bak*|*clobbered*) ;;
                    *) [ -f "$arg" ] && python3 "$INJECT" "$arg" 2>/dev/null ;;
                esac
                ;;
        esac
    done

elif [[ "$1" == "mirror" ]]; then
    SRC="" DEST=""
    for arg in "${@:2}"; do
        [[ "$arg" == --* ]] && continue
        [ -z "$SRC" ] && { SRC="$arg"; continue; }
        [ -z "$DEST" ] && { DEST="$arg"; break; }
    done

    if [[ "$DEST" == *"manager-workspace"* ]]; then
        "$REAL" "$@"
        EXIT=$?
        [ -f "$WORKSPACE" ] && python3 "$INJECT" "$WORKSPACE" 2>/dev/null
        [ -f "$WORKSPACE" ] && "$REAL" cp "$WORKSPACE" "$MINIO_MGR" 2>/dev/null || true
        exit $EXIT

    elif [[ "$SRC" == *"manager-workspace"* ]]; then
        [ -f "$WORKSPACE" ] && python3 "$INJECT" "$WORKSPACE" 2>/dev/null
    fi
fi

exec "$REAL" "$@"
WRAPEOF
chmod +x /usr/local/bin/mc'

echo "hiclaw-manager mc wrapper installed → MCP browser tool persists across restarts"

# Fix manager-console nginx proxy: use Docker hostname instead of 127.0.0.1
# (hiclaw-controller is a separate container; 127.0.0.1:18799 doesn't reach hiclaw-manager)
docker exec hiclaw-controller sh -c 'cat > /etc/nginx/conf.d/manager-console.conf << '"'"'NGINXEOF'"'"'
server {
    listen 18888;
    location / {
        proxy_pass http://hiclaw-manager:18799;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Accept-Encoding "";
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_hide_header Content-Security-Policy;
        sub_filter_types text/html;
        sub_filter_once on;
        sub_filter '"'"'</head>'"'"' '"'"'<script>(function(){var T="5de86910dec50bf9d9162682d9a7f468143b85ee68c5deb316ad081b5a97ab0c";if(!T||location.hash.indexOf("token=")!==-1)return;location.replace(location.pathname+"#token="+T)})();</script></head>'"'"';
    }
}
NGINXEOF
nginx -s reload'

echo "manager-console nginx proxy patched → token auto-injected for control.claw.designflow.app"

# Ensure hiclaw-controller is on the coolify network so Traefik can reach port 18888.
# HiClaw upgrades recreate the container, dropping any manually added network connections.
docker network connect coolify hiclaw-controller 2>/dev/null && \
    echo "hiclaw-controller connected to coolify network" || \
    echo "hiclaw-controller already on coolify network"

# Reconnect hiclaw-manager to the noVNC network for Playwright MCP / CDP access.
docker network connect e10kwzww46ljhrgz1qj08j6a hiclaw-manager 2>/dev/null && \
    echo "hiclaw-manager connected to noVNC network (CDP access restored)" || \
    echo "hiclaw-manager already on noVNC network"

# Fix deprecated channels.matrix.groups.*.allow key in MinIO-persisted openclaw.json.
# New openclaw versions reject the legacy 'allow' field; must use 'enabled' instead.
# This also fixes the local file so the currently running gateway picks it up.
docker exec -u root hiclaw-manager bash -c '
mc cp hiclaw/hiclaw-storage/manager/openclaw.json /tmp/openclaw-minio.json 2>/dev/null && \
python3 -c "
import json, sys
with open(\"/tmp/openclaw-minio.json\") as f:
    d = json.load(f)
changed = False
for room, cfg in d.get(\"channels\",{}).get(\"matrix\",{}).get(\"groups\",{}).items():
    if \"allow\" in cfg:
        cfg[\"enabled\"] = cfg.pop(\"allow\")
        changed = True
if changed:
    with open(\"/tmp/openclaw-minio-fixed.json\", \"w\") as f:
        json.dump(d, f, indent=2)
    sys.exit(0)
else:
    sys.exit(1)
" && mc cp /tmp/openclaw-minio-fixed.json hiclaw/hiclaw-storage/manager/openclaw.json && \
cp /tmp/openclaw-minio-fixed.json /root/manager-workspace/openclaw.json && \
echo "MinIO openclaw.json groups.allow→enabled fixed" || echo "MinIO openclaw.json groups already correct"
'
