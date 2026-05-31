# CLAUDE.md — Claude Code Instructions

**Read AGENTS.md first.** Everything substantive is there.

---

## Memory

Claude Code persistent memory for this project: `/home/ai/.claude/projects/-worksp-hiclaw/memory/`

AGENTS.md is the authoritative source of truth. Memory files supplement it with session-specific discoveries.

## Context Management

`.claudeignore` excludes `workspace/`, `.state/`, and `*.log` — do not index these.

Never read or modify files in `workspace/` unless directly debugging OpenClaw config (`workspace/openclaw.json` is the one exception).

## Operations Permissions

- **Docker:** full access — `docker exec`, `docker inspect`, `docker restart` on any hiclaw container
- **Git:** push to `u2giants/hiclaw` on GitHub
- **Coolify API:** `https://coolify.designflow.app` — full API access
- **Do not SSH as deployment method** — code changes go through git → GitHub Actions → Coolify

## Commit Style

- Present tense, imperative: "Add", "Fix", "Update", not "Added", "Fixed"
- Be specific: "Fix Chrome double-instance OOM by adding pgrep guard in wrapper"
- Always add: `Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>`

## Tool Preferences

- Use Read/Edit/Write over bash cat/sed/echo
- Use `gh` CLI for GitHub operations over raw curl
- When editing `cdp_proxy.py` on the server, use Edit tool (preserves inode) — never Write or cp

## Key Facts

- Owner: Albert (business owner, not a developer — do everything yourself)
- Server: `178.156.180.212`
- The only Docker image built from this repo: `ghcr.io/u2giants/novnc-desktop`
- hiclaw-manager and hiclaw-controller are NOT in Coolify — managed by keeper scripts

## OpenClaw Update Mechanism

openclaw runs inside the novnc-desktop container. Updates are triggered indirectly:

- Container startup script installs a fake `/usr/local/bin/systemd-run` and sets `OPENCLAW_SYSTEMD_UNIT=openclaw-gateway`
- When `update.run` is called, openclaw writes `.openclaw-update-requested` marker (via fake systemd-run) instead of calling real systemd
- `manager-bootstrap-keeper.sh` detects the marker and runs the actual update via `docker exec` with `--memory-swap 2g` (required to avoid npm OOM)
- npm install is validated by checking `json5/package.json`; broken installs are removed and the symlink falls back to the base image

Do not bypass this mechanism by running `openclaw update` directly inside the container — the keeper handles sequencing and memory limits.

The `channels.matrix.groups` config must never contain a wildcard key `"*"` — the keeper strips it on every run.
