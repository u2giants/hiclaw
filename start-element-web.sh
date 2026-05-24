#!/bin/bash
# start-element-web.sh - Generate Element Web config and start Nginx

MATRIX_DOMAIN="${HICLAW_MATRIX_DOMAIN:-matrix-local.hiclaw.io:8080}"
# Browser-facing homeserver URL.
# If the configured value is blank, loopback, or plain HTTP, fall back to the
# current request origin so Element talks to the same public HTTPS host that
# served the app.
ELEMENT_HOMESERVER_URL="${HICLAW_ELEMENT_HOMESERVER_URL:-}"
case "${ELEMENT_HOMESERVER_URL}" in
    ""|http://*|https://127.0.0.1*|https://localhost*|http://127.0.0.1*|http://localhost*)
        ELEMENT_HOMESERVER_URL="__PUBLIC_BASE_URL__"
        ;;
esac
# Brand name for Element Web (defaults to "Element" if not set)
ELEMENT_BRAND="${HICLAW_ELEMENT_BRAND:-Element}"

# Generate Element Web config.json pointing to local Matrix Homeserver
cat > /opt/element-web/config.json << EOF
{
    "default_server_config": {
        "m.homeserver": {
            "base_url": "${ELEMENT_HOMESERVER_URL}"
        }
    },
    "brand": "${ELEMENT_BRAND}",
    "disable_guests": true,
    "disable_custom_urls": false,
    "force_verification": false,
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
EOF

# Configure nginx worker processes (default is auto, which uses CPU core count)
sed -i 's/worker_processes.*auto;/worker_processes 2;/' /etc/nginx/nginx.conf 2>/dev/null || \
sed -i 's/^worker_processes [0-9]*;/worker_processes 2;/' /etc/nginx/nginx.conf 2>/dev/null || \
grep -q '^worker_processes' /etc/nginx/nginx.conf || \
sed -i '1i worker_processes 2;' /etc/nginx/nginx.conf

# Create browser bypass script as external JS file (allowed by CSP script-src 'self')
# This avoids adding 'unsafe-inline' to CSP, preserving XSS protection
echo 'window.localStorage.setItem("mx_accepts_unsupported_browser","true");' > /opt/element-web/browser-bypass.js

# Auto-login: after Google OAuth, seamlessly log the user into Matrix using a
# short-lived login token from the hiclaw-chat-api. Checks localStorage first
# so already-logged-in users are never interrupted.
cat > /opt/element-web/auto-login.js << 'EOF'
(function () {
  // Skip if a Matrix session already exists in localStorage.
  for (var i = 0; i < localStorage.length; i++) {
    var k = localStorage.key(i);
    if (k && k.indexOf('mx_access_token') !== -1 && localStorage.getItem(k)) return;
  }
  // Skip if we're already processing a login token (avoid redirect loop).
  if (window.location.search.indexOf('loginToken=') !== -1) return;

  fetch('/hiclaw-api/matrix-auth', { method: 'POST' })
    .then(function (r) { return r.ok ? r.json() : Promise.reject(r.status); })
    .then(function (data) {
      if (data.login_token) {
        // Element reads homeserver URL from this key before exchanging the token.
        localStorage.setItem('mx_sso_hs_url', window.location.origin);
        window.location.replace('/?loginToken=' + encodeURIComponent(data.login_token));
      }
    })
    .catch(function () { /* API unavailable — user sees normal login screen */ });
})();
EOF

cat > /opt/element-web/control-panel-btn.js << 'EOF'
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
EOF

cat > /opt/element-web/auth-ui-tweaks.js << 'EOF'
(function() {
  var GOOGLE_LABELS = [
    "continue with google",
    "sign in with google",
    "log in with google",
    "continue with single sign-on",
    "sign in with single sign-on",
    "log in with single sign-on",
    "continue with sso",
    "sign in with sso",
    "log in with sso"
  ];
  var SKIP_LABELS = [
    "skip for now",
    "continue without verifying",
    "verify later",
    "do this later",
    "not now",
    "later",
    "skip",
    "can't confirm?",
    "i'll verify later",
    "i don't want secure messages"
  ];

  function normalize(text) {
    return (text || "").replace(/\s+/g, " ").trim().toLowerCase();
  }

  function svgDataUri(svg) {
    return "data:image/svg+xml;utf8," + encodeURIComponent(svg);
  }

  var googleIcon = svgDataUri(
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 18 18">' +
      '<path fill="#EA4335" d="M9 7.364v3.534h4.914c-.216 1.136-.864 2.098-1.836 2.745l2.966 2.302c1.728-1.593 2.726-3.939 2.726-6.727 0-.648-.058-1.271-.165-1.854H9z"/>' +
      '<path fill="#34A853" d="M9 18c2.43 0 4.468-.806 5.958-2.182l-2.966-2.302c-.823.552-1.875.879-2.992.879-2.298 0-4.244-1.55-4.94-3.633H.994v2.375A8.997 8.997 0 0 0 9 18z"/>' +
      '<path fill="#4A90E2" d="M4.06 10.762A5.41 5.41 0 0 1 3.784 9c0-.612.106-1.206.276-1.762V4.863H.994A8.997 8.997 0 0 0 0 9c0 1.452.347 2.827.994 4.137l3.066-2.375z"/>' +
      '<path fill="#FBBC05" d="M9 3.605c1.321 0 2.507.454 3.441 1.345l2.581-2.582C13.463.918 11.425 0 9 0A8.997 8.997 0 0 0 .994 4.863L4.06 7.238C4.756 5.155 6.702 3.605 9 3.605z"/>' +
    '</svg>'
  );

  function styleGoogleButton(button) {
    if (!button || button.dataset.hiclawGoogleStyled === "1") return;
    button.dataset.hiclawGoogleStyled = "1";
    button.style.background = "#ffffff";
    button.style.color = "#1f1f1f";
    button.style.border = "1px solid #dadce0";
    button.style.borderRadius = "999px";
    button.style.boxShadow = "0 1px 2px rgba(16,24,40,0.08)";
    button.style.fontWeight = "600";
    button.style.minHeight = "44px";
    button.style.padding = "10px 18px";
    button.style.display = "inline-flex";
    button.style.alignItems = "center";
    button.style.justifyContent = "center";
    button.style.gap = "12px";
    button.style.fontFamily = "Arial, sans-serif";

    var text = normalize(button.textContent);
    if (!/google/.test(text)) {
      button.textContent = "Continue with Google";
    }

    if (!button.querySelector(".hiclaw-google-mark")) {
      var icon = document.createElement("span");
      icon.className = "hiclaw-google-mark";
      icon.setAttribute("aria-hidden", "true");
      icon.style.width = "18px";
      icon.style.height = "18px";
      icon.style.display = "inline-block";
      icon.style.flex = "0 0 18px";
      icon.style.backgroundImage = 'url("' + googleIcon + '")';
      icon.style.backgroundRepeat = "no-repeat";
      icon.style.backgroundPosition = "center";
      icon.style.backgroundSize = "18px 18px";

      var label = document.createElement("span");
      label.className = "hiclaw-google-label";
      label.textContent = button.textContent;

      button.textContent = "";
      button.appendChild(icon);
      button.appendChild(label);
    }
  }

  function findGoogleButtons() {
    Array.from(document.querySelectorAll("button, a[role='button'], a")).forEach(function(el) {
      var text = normalize(el.textContent);
      if (GOOGLE_LABELS.indexOf(text) !== -1) {
        styleGoogleButton(el);
      }
    });
  }

  function autoSkipVerification() {
    var bodyText = normalize(document.body && document.body.textContent);
    if (!bodyText) return;
    if (bodyText.indexOf("verify this device to set up secure messaging") === -1 &&
        bodyText.indexOf("confirm your identity") === -1) {
      return;
    }

    var buttons = Array.from(document.querySelectorAll("button, a[role='button'], a"));
    for (var i = 0; i < buttons.length; i++) {
      var text = normalize(buttons[i].textContent);
      if (SKIP_LABELS.indexOf(text) !== -1) {
        buttons[i].click();
        return;
      }
    }
  }

  function run() {
    findGoogleButtons();
    autoSkipVerification();
  }

  var observer = new MutationObserver(run);
  observer.observe(document.documentElement, { childList: true, subtree: true });

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", run);
  } else {
    run();
  }
})();
EOF

cat > /opt/element-web/new-chat-btn.js << 'EOF'
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
EOF

cat > /opt/element-web/hiclaw-chat-api.py << 'EOF'
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

def issue_login_token():
    token = login()
    status, body = matrix_request(
      "POST",
      "/_matrix/client/v1/login/get_token",
      {
        "auth": {
          "type": "m.login.password",
          "identifier": {"type": "m.id.user", "user": ADMIN_USER},
          "password": ADMIN_PASSWORD,
        }
      },
      token=token,
    )
    login_token = body.get("login_token")
    if status != 200 or not login_token:
      fail(f"login token request failed: {body.get('error', body)}", 502)
    return {"login_token": login_token, "expires_in_ms": body.get("expires_in_ms", 0)}

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
      if self.path == "/matrix-auth":
        try:
          self._send(200, issue_login_token())
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
        return
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
chmod 755 /opt/element-web/hiclaw-chat-api.py

# Generate Nginx config for Element Web
cat > /etc/nginx/conf.d/element-web.conf << 'NGINX'
server {
    listen 8088;
    root /opt/element-web;
    index index.html;
    set $public_scheme $scheme;
    if ($http_x_forwarded_proto != "") {
        set $public_scheme $http_x_forwarded_proto;
    }

    # Inject external scripts rather than inline code so CSP stays intact.
    sub_filter '</head>' '<script src="browser-bypass.js"></script><script src="auto-login.js"></script><script src="auth-ui-tweaks.js"></script><script src="control-panel-btn.js"></script><script src="new-chat-btn.js"></script></head>';
    sub_filter_once on;
    sub_filter_types text/html;

    location = /hiclaw-api/new-chat {
        proxy_pass http://127.0.0.1:8091/new-chat;
        proxy_http_version 1.1;
        proxy_read_timeout 30s;
        proxy_send_timeout 30s;
        add_header Cache-Control "no-store";
    }

    location = /hiclaw-api/matrix-auth {
        proxy_pass http://127.0.0.1:8091/matrix-auth;
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
    }

    location = /config.json {
        alias /opt/element-web/config.json;
        default_type application/json;
        add_header Cache-Control "no-cache";
        sub_filter_once on;
        sub_filter_types application/json;
        sub_filter '__PUBLIC_BASE_URL__' '$public_scheme://$http_host';
    }

    location ~* ^/(config.*\.json|index\.html|i18n|version)$ {
        add_header Cache-Control "no-cache";
    }
}
NGINX

# Generate Nginx config for Manager Console reverse proxy.
# OpenClaw runtime: injects gateway token via inline script for auto-login.
# CoPaw runtime: plain reverse proxy, no token injection needed.
HICLAW_MANAGER_IPV4="$(getent ahostsv4 hiclaw-manager 2>/dev/null | awk 'NR==1 {print $1}')"
if [ -z "${HICLAW_MANAGER_IPV4}" ]; then
    HICLAW_MANAGER_IPV4="127.0.0.1"
fi
if [ "${HICLAW_MANAGER_RUNTIME:-openclaw}" = "openclaw" ]; then
    OPENCLAW_TOKEN="${HICLAW_MANAGER_GATEWAY_KEY:-}"
    cat > /etc/nginx/conf.d/manager-console.conf << NGINX
# Manager Console (OpenClaw) — reverse proxy to the manager container with auto-token injection
# Injects the gateway token via inline script that sets location.hash with #token=...
# This is the only reliable method across all openclaw versions — the Control UI
# reads the token from the URL hash on load (both old and new versions support this).
# CSP must be stripped to allow the inline script, and proxy headers (Host, X-Real-IP)
# are omitted to avoid triggering untrusted-proxy detection in the gateway.
server {
    listen 18888;

    location / {
        proxy_pass http://${HICLAW_MANAGER_IPV4}:18799;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        # Disable upstream compression so sub_filter can modify HTML responses
        proxy_set_header Accept-Encoding "";
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;

        # Strip upstream CSP so inline token-injection script can run
        proxy_hide_header Content-Security-Policy;

        # Auto-inject gateway token via URL hash redirect (works across all openclaw versions)
        sub_filter_types text/html;
        sub_filter_once on;
        sub_filter '</head>' '<script>(function(){var T="${OPENCLAW_TOKEN}";if(!T||location.hash.indexOf("token=")!==-1)return;location.replace(location.pathname+"#token="+T)})();</script></head>';
    }
}
NGINX
else
    cat > /etc/nginx/conf.d/manager-console.conf << 'NGINX'
# Manager Console (CoPaw) — plain reverse proxy to the manager container
server {
    listen 18888;

    location / {
        proxy_pass http://__HICLAW_MANAGER_IPV4__:18799;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
NGINX
    sed -i "s/__HICLAW_MANAGER_IPV4__/${HICLAW_MANAGER_IPV4}/g" /etc/nginx/conf.d/manager-console.conf
fi

# Generate Nginx config for Higress WASM plugin server (port 8002).
# This serves /usr/share/nginx/html/plugins/* to Envoy so it can fetch
# WASM modules (ai-proxy, key-auth, ai-statistics, etc.). Without this,
# Envoy fails to load AI plugins and forwards requests to upstream LLMs
# without Host header rewrite, resulting in 404s from the LLM backend.
# The base higress/all-in-one image normally runs this as a separate
# `plugin-server` supervisord program with its own nginx instance, but
# our embedded supervisord overrides that config — so we serve it from
# the same nginx as Element Web instead, listening on both v4 and v6
# loopback (Envoy's wasm fetcher uses `localhost` which may resolve to ::1).
cat > /etc/nginx/conf.d/plugin-server.conf << 'NGINX'
server {
    listen 8002;
    listen [::]:8002;
    server_name localhost;

    root /usr/share/nginx/html;
    server_tokens off;

    location = /healthz {
        return 200 'ok';
        add_header Content-Type text/plain;
    }

    error_page 500 502 503 504 /50x.html;
    location = /50x.html {
        root /usr/share/nginx/html;
    }
}
NGINX

# Remove default nginx site if exists
rm -f /etc/nginx/sites-enabled/default

# This container can retain an older daemonized nginx master across manual patching
# or wrapper-script changes. If we start a second nginx instance, element-web enters
# a crash loop and the HiClaw chat UI appears disconnected even though the manager is
# still processing messages. Always clear any existing nginx master before starting
# the foreground instance that supervisord expects to own.
if pgrep -x nginx >/dev/null 2>&1; then
    nginx -s quit 2>/dev/null || pkill -TERM nginx 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -x nginx >/dev/null 2>&1 || break
        sleep 1
    done
    pgrep -x nginx >/dev/null 2>&1 && pkill -KILL nginx 2>/dev/null || true
fi

if pgrep -f /opt/element-web/hiclaw-chat-api.py >/dev/null 2>&1; then
    pkill -f /opt/element-web/hiclaw-chat-api.py 2>/dev/null || true
    for _ in 1 2 3 4 5; do
        pgrep -f /opt/element-web/hiclaw-chat-api.py >/dev/null 2>&1 || break
        sleep 1
    done
fi

python3 /opt/element-web/hiclaw-chat-api.py >> /var/log/hiclaw-chat-api.log 2>&1 &

exec nginx -g 'daemon off;'
