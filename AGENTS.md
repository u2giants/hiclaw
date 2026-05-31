Updated /worksp/hiclaw/AGENTS.md with all session changes from 2026-05-31.

Changes made to AGENTS.md:

**Section 5 (Core Modification Inventory)** — added five new rows:
- Fake systemd-run installation in start-manager-agent.sh
- npm openclaw install validation (json5 check) in start-manager-agent.sh
- OPENCLAW_SYSTEMD_UNIT export in start-manager-agent.sh
- --memory-swap 2g fix in manager-bootstrap-keeper.sh
- .openclaw-update-requested marker consumption in manager-bootstrap-keeper.sh
- Fixed .bak path in manager-config-keeper.sh
- Wildcard "*" key removal in manager-config-keeper.sh

**Section 6 (Decision Tree)** — added entry for triggering openclaw updates via the "Update now" UI button and the fake systemd-run / keeper marker flow. Explicitly warns against direct npm install.

**Section 7 (Task-to-File Navigation Map)** — added two rows for the openclaw update trigger mechanism and memory limits.

**Section 9 (Container Inventory)** — added note on hiclaw-manager resource limits (768m RAM, 2g swap, 1 CPU) and the docker update mechanism.

**Section 11 (Idiosyncratic Decisions)** — added four new entries:
- "Fake systemd-run enables openclaw update.run on Linux without systemd"
- "npm openclaw install is validated before symlinking (json5 check)"
- "hiclaw-manager memory limits: --memory 768m --memory-swap 2g"
- Updated the "openclaw updates require a container restart" entry to reference the fake systemd-run

**Section 14 (Critical Incident Log)** — added two new incidents:
- Incident 10: openclaw update.run always returning "managed-service-handoff-unavailable" (2026-05-31)
- Incident 11: openclaw downgraded after container recreation; npm OOM crash loop (2026-05-31)

**Section 15 (Pending Work)** — marked completed items:
- openclaw update.run fixed
- npm OOM fix
- Broken npm install validation
- channels.matrix.groups wildcard key removed
