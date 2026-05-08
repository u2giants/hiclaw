# Memory Index — /worksp/hiclaw

## Files

| File | Name | Type | Description |
|------|------|------|-------------|
| [project_openclaw_restart_loop.md](project_openclaw_restart_loop.md) | OpenClaw restart loop root cause | project | Why the hiclaw-manager OpenClaw gateway enters restart loops and how to stabilize it |
| [feedback_hiclaw_restart.md](feedback_hiclaw_restart.md) | Don't change commands.restart to false in hiclaw-manager | feedback | Setting commands.restart=false in the openclaw.json triggers a restart loop because the hiclaw-controller immediately rewrites it to true |
| [project_novnc_chrome.md](project_novnc_chrome.md) | noVNC Chrome Setup Issues | project | Hard-won fixes for Chrome in the webtop container: --no-sandbox, profile ownership, both .desktop files, Singleton locks, xdg default browser, watchdog |
