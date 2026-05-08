# Deployment

## What deployment means here

There is no standalone application release pipeline in this repo. Deployment here means keeping one live HiClaw installation operational across:

- manager/container restarts
- `hiclaw-manager` container recreation
- HiClaw upgrades that reset container-local changes

## Persistent Boundary

The persistent boundary for this repo is the host filesystem under `/worksp/hiclaw`, not the inside of the containers.

That means:

- files in `workspace/` survive container recreation
- host scripts and cron survive container recreation
- direct container edits do not survive recreation unless a host script reapplies them
- manager workspace customizations such as `workspace/AGENTS.md` additions and `workspace/skills/...` helper scripts also survive manager container recreation

## Required Host Automation

Install these cron jobs on the host:

```cron
* * * * * /worksp/hiclaw/manager-config-keeper.sh >> /worksp/hiclaw/manager-config-keeper.log 2>&1
* * * * * /worksp/hiclaw/manager-bootstrap-keeper.sh >> /worksp/hiclaw/manager-bootstrap-keeper.log 2>&1
* * * * * /worksp/hiclaw/controller-bootstrap-keeper.sh >> /worksp/hiclaw/controller-bootstrap-keeper.log 2>&1
```

Why both exist:

- `manager-config-keeper.sh` stabilizes `workspace/openclaw.json`
- `manager-bootstrap-keeper.sh` restores the patched manager startup script after container replacement
- `controller-bootstrap-keeper.sh` restores the patched Element Web startup script after controller replacement

## Upgrade Workflow

### After a HiClaw upgrade

Run:

```bash
/worksp/hiclaw/fix-element-config.sh
```

Why:

- upgrades can recreate `hiclaw-controller`
- that resets Element Web config, nginx fragments, npm wrappers, mc wrappers, and some network attachments

Then verify:

```bash
docker exec hiclaw-manager openclaw clawtalk doctor
bash /worksp/hiclaw/manager-bootstrap-keeper.sh
docker exec hiclaw-controller curl -s http://127.0.0.1:8088/hiclaw-api/healthz
crontab -l
```

## Container Recreation Workflow

You should not need to do anything manually in the normal case.

Expected behavior:

1. HiClaw recreates `hiclaw-manager`.
2. Host cron runs `manager-bootstrap-keeper.sh`.
3. The keeper copies the patched [start-manager-agent.sh](/worksp/hiclaw/start-manager-agent.sh) into the new container.
4. The keeper restarts the container once if the container is still using the stock startup script.
5. The patched startup path bootstraps ClawTalk before the gateway starts.
6. The separate-chat helper in `workspace/skills/matrix-server-management/scripts/create-admin-chat-room.sh` is already present again because it lives in the persistent workspace, not in the container image.

During the restart window, the keeper may log `container startup script not readable yet; skipping this run`. That is expected while the container is still early in boot.

Verify with:

```bash
docker logs hiclaw-manager --since 10m | grep -E 'Bootstrapping ClawTalk|ClawTalk authenticated|http server listening'
docker exec hiclaw-manager openclaw clawtalk doctor
```

For the HiClaw chat UI path, also verify:

```bash
docker exec hiclaw-controller ps -ef | grep nginx | grep -v grep
docker exec hiclaw-controller sh -lc 'ss -ltnp | grep -E ":(8088|18888|8002)\\b" || true'
docker exec hiclaw-controller curl -s http://127.0.0.1:8088/hiclaw-api/healthz
```

## Manual Recovery

If automation did not converge:

```bash
bash /worksp/hiclaw/manager-bootstrap-keeper.sh
bash /worksp/hiclaw/manager-config-keeper.sh
bash /worksp/hiclaw/mcp-keeper.sh
docker exec hiclaw-manager openclaw clawtalk doctor
```

## `oauth2-proxy` Sidecar

The control UI auth sidecar is managed separately:

```bash
cd /worksp/hiclaw/oauth2-proxy
docker compose up -d
```

This repo currently stores the proxy configuration directly in `docker-compose.yml`. Treat that file as live deployment config, not a template.

## Release/Change Management

For changes in this repo:

1. edit the host-owned script or config
2. validate it against the running deployment
3. ensure the change is reflected in docs
4. keep the host copy authoritative so cron can restore it later

There is no separate publish step unless you are also changing the upstream HiClaw image outside this repo.
