#!/bin/bash
mkdir -p /config/.config/autostart

# Set Chrome as default browser (must run as abc user with DISPLAY set)
mkdir -p /config/.local/share/applications
cat > /config/.local/share/applications/mimeapps.list << 'MIMEEOF'
[Default Applications]
x-scheme-handler/http=google-chrome.desktop
x-scheme-handler/https=google-chrome.desktop
text/html=google-chrome.desktop
MIMEEOF
su abc -c "DISPLAY=:1 xdg-settings set default-web-browser google-chrome.desktop" 2>/dev/null || true

# Dropbox
cat > /config/.config/autostart/dropbox.desktop << 'DESKTOP'
[Desktop Entry]
Type=Application
Name=Dropbox
Exec=/usr/local/bin/dropboxd
Hidden=false
NoDisplay=false
X-MATE-Autostart-enabled=true
DESKTOP

# Insync
cat > /config/.config/autostart/insync.desktop << 'DESKTOP'
[Desktop Entry]
Type=Application
Name=Insync
Exec=insync start
Hidden=false
NoDisplay=false
X-MATE-Autostart-enabled=true
DESKTOP

# Patch Chrome preferences to prevent session restore.
# Sets restore_on_startup=5 (open NTP) and exit_type=Normal (no crash
# recovery dialog), so Chrome starts clean after an OOM kill or restart.
patch_chrome_prefs() {
    local prefs="/config/chrome-profile/Default/Preferences"
    if [ -f "$prefs" ]; then
        python3 - "$prefs" << 'PYEOF'
import json, sys
path = sys.argv[1]
try:
    with open(path) as f:
        p = json.load(f)
    p.setdefault('session', {})['restore_on_startup'] = 5
    p.setdefault('profile', {})['exit_type'] = 'Normal'
    with open(path, 'w') as f:
        json.dump(p, f)
except Exception as e:
    print('prefs patch failed:', e, file=sys.stderr)
PYEOF
    fi
}

# Chrome watchdog — keeps Chrome alive for OpenClaw/OpenManus CDP automation.
# Chrome is the user browser AND the CDP browser (port 9222).
(while true; do
  mkdir -p /config/chrome-profile/Default
  chown -R abc:abc /config/chrome-profile 2>/dev/null
  rm -f /config/chrome-profile/Singleton*

  # Prevent session restore: patch prefs and remove saved session files so
  # Chrome can't reload the previous tab set after an OOM kill or restart.
  patch_chrome_prefs
  rm -f "/config/chrome-profile/Default/Last Session" \
        "/config/chrome-profile/Default/Last Tabs" \
        "/config/chrome-profile/Default/Current Session" \
        "/config/chrome-profile/Default/Current Tabs"

  # Kill any stale Chrome processes left over from a previous crash before
  # restarting, so we don't accumulate zombie renderer trees.
  # Use unescaped | for ERE alternation (pkill uses ERE; \| matches a literal pipe).
  pkill -f "google-chrome|/opt/google/chrome/chrome" 2>/dev/null
  sleep 2

  su abc -c "DISPLAY=:1 /usr/local/bin/google-chrome" 2>/dev/null
  sleep 3
done) &

# Wait until Chrome CDP is up on port 9222
echo "Waiting for Chrome CDP..."
for i in $(seq 1 60); do
  if curl -sf http://127.0.0.1:9222/json/version > /dev/null 2>&1; then
    echo "Chrome CDP ready after $((i*2))s"
    break
  fi
  sleep 2
done

# Start CDP proxy
echo "Starting CDP proxy..."
python3 /custom-cont-init.d/cdp_proxy.py &
echo "CDP proxy running"
