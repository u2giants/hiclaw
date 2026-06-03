# CLAUDE.md — Claude Code Notes

Read `AGENTS.md` first. It is the authoritative operating guide.

## Claude Context

- Persistent memory path: `/home/ai/.claude/projects/-worksp-hiclaw/memory/`
- `.claudeignore` excludes runtime workspace, logs, caches, and generated state. Do not index ignored paths unless the user explicitly asks.
- `workspace/openclaw.json` is the only normal exception inside `workspace/`, and only for targeted OpenClaw config debugging/recovery.

## Allowed Operations

- Docker inspection and operations on HiClaw containers are allowed.
- Git commit/push to `u2giants/hiclaw` is allowed when requested.
- SSH/server shell access is routine for this host-ops repo because the repo runs directly on the production server.
- Durable changes still go through git. Do not leave permanent fixes as uncommitted `docker exec` edits inside upstream containers.

## Claude Preferences

- Use imperative commit messages: `Fix ...`, `Add ...`, `Update ...`.
- Include `Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>` only when the user specifically wants Claude attribution.
- For `novnc-desktop/cdp_proxy.py`, preserve the live inode when editing a bind-mounted file; use in-place edits.
