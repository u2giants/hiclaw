FROM lscr.io/linuxserver/webtop:ubuntu-mate

# Google Chrome
RUN apt-get update && apt-get install -y --no-install-recommends wget gnupg ca-certificates && \
    wget -qO- https://dl.google.com/linux/linux_signing_key.pub | \
        gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg && \
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" \
        > /etc/apt/sources.list.d/google-chrome.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends google-chrome-stable && \
    rm -rf /var/lib/apt/lists/* && \
    # Wrapper forces --no-sandbox (required in Docker).
    # --renderer-process-limit: cap renderer processes to prevent unbounded memory growth.
    # --aggressive-cache-discard: release disk/memory cache faster under memory pressure.
    # --disable-renderer-backgrounding: do not throttle background renderers — AI agents
    #   drive tabs that are not in the foreground, throttling breaks automation timing.
    # --disable-backgrounding-occluded-windows: same rationale for occluded windows.
    # --disable-background-networking: stop background fetches when no user is connected.
    # --disable-sync: no Chrome account sync (unnecessary in this environment).
    # Singleton files are only removed when Chrome is not already running: if Chrome is
    # running and something (e.g. Dropbox) calls this wrapper to open a URL, we must
    # NOT delete the Singleton or Chrome will spawn a second instance instead of passing
    # the URL to the existing session, doubling memory usage and eventually crashing the host.
    printf '#!/bin/bash\nmkdir -p /config/chrome-profile\nchown -R abc:abc /config/chrome-profile 2>/dev/null\nif ! pgrep -f "/opt/google/chrome/chrome" > /dev/null 2>&1; then\n    rm -f /config/chrome-profile/Singleton*\nfi\nexec /usr/bin/google-chrome-stable --no-sandbox --disable-dev-shm-usage --no-first-run --start-maximized --user-data-dir=/config/chrome-profile --remote-debugging-port=9222 --remote-debugging-address=0.0.0.0 --remote-allow-origins='"'"'*'"'"' --renderer-process-limit=4 --aggressive-cache-discard --disable-renderer-backgrounding --disable-backgrounding-occluded-windows --disable-background-networking --disable-sync "$@"\n' \
        > /usr/local/bin/google-chrome && \
    chmod +x /usr/local/bin/google-chrome && \
    sed -i 's|Exec=/usr/bin/google-chrome-stable|Exec=/usr/local/bin/google-chrome|g' \
        /usr/share/applications/google-chrome.desktop && \
    update-desktop-database /usr/share/applications/

# Dropbox daemon
RUN wget -qO /tmp/dropbox.tar.gz "https://www.dropbox.com/download?plat=lnx.x86_64" && \
    tar xzf /tmp/dropbox.tar.gz -C /opt && \
    ln -sf /opt/.dropbox-dist/dropboxd /usr/local/bin/dropboxd && \
    rm /tmp/dropbox.tar.gz

# Startup script and CDP proxy — baked in so the container works without external mounts
COPY novnc-startup.sh /custom-cont-init.d/99-start-chromium.sh
COPY cdp_proxy.py /custom-cont-init.d/cdp_proxy.py
RUN chmod +x /custom-cont-init.d/99-start-chromium.sh

# Insync + Caja integration for MATE file manager
RUN wget -qO- https://apt.insync.io/insynchq.gpg | \
        gpg --dearmor -o /usr/share/keyrings/insync.gpg && \
    chmod a+r /usr/share/keyrings/insync.gpg && \
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/insync.gpg] http://apt.insync.io/ubuntu noble non-free contrib" \
        > /etc/apt/sources.list.d/insync.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends insync insync-caja && \
    rm -rf /var/lib/apt/lists/*
