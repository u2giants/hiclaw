---
name: Don't change commands.restart to false in hiclaw-manager
description: Setting commands.restart=false in the openclaw.json triggers a restart loop because the hiclaw-controller immediately rewrites it to true
type: feedback
originSessionId: 285f6a79-bddf-4181-adea-8dc1d85214f2
---
Do NOT set `commands.restart=false` in `/worksp/hiclaw/workspace/openclaw.json` or inside the hiclaw-manager container. The hiclaw-controller reconciliation loop always writes `commands.restart=true`, so changing it to false just triggers one more restart and then it reverts to true anyway.

**Why:** The controller's reconciliation detects the diff (false→true) and triggers a full OpenClaw restart. After restart, the system stabilizes with restart=true. Manually changing to false just adds an unnecessary restart.

**How to apply:** When investigating or fixing OpenClaw gateway issues, leave `commands.restart` at its current value (true). Only modify other fields. If the gateway is in a restart loop, check whether restart is oscillating between false/true, not whether it's true/false at one instant.
