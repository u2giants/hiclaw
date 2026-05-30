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
