# Deployment

## What deployment means here

There is no standalone application release pipeline. Deployment means keeping one live HiClaw installation operational across:

- manager/controller restarts
- container recreation (by HiClaw upgrade or manual `docker rm` + `docker run`)
- HiClaw upstream image upgrades that reset container-local changes

## Persistent Boundary

The persistent boundary is the host filesystem at `/worksp/hiclaw/`, not the inside of the containers.

| Survives container recreation | Does not survive |
|---|---|
| `workspace/` content (bind mount) | Changes made with `docker exec` not backed by a keeper |
| Host scripts and cron jobs | Container-overlay files (npm packages, `/usr/local/bin/mc`, nginx config, `hiclaw-chat-api.py`) |
| `oauth2-proxy/` config | |
| `traefik/claw.yml` | |

Files created by `fix-element-config.sh` (mc wrapper, npm wrapper, some nginx config) live on the container overlay and are lost on recreation. The persistent equivalents are delivered by `start-element-web.sh` and `start-manager-agent.sh` via the keeper scripts.

## Required Host Cron Jobs

```cron
* * * * * /worksp/hiclaw/manager-config-keeper.sh >> /worksp/hiclaw/manager-config-keeper.log 2>&1
* * * * * /worksp/hiclaw/manager-bootstrap-keeper.sh >> /worksp/hiclaw/manager-bootstrap-keeper.log 2>&1
* * * * * /worksp/hiclaw/controller-bootstrap-keeper.sh >> /worksp/hiclaw/controller-bootstrap-keeper.log 2>&1
```

Verify: `crontab -l`. All three must be present.

## Starting the System

### First-time or after both containers are stopped

```bash
cd /worksp/hiclaw

# Start controller first — MinIO, Matrix, and Element Web initialize before manager needs them
docker start hiclaw-controller
sleep 20

# Verify MinIO is clean BEFORE starting the manager
sudo find /var/lib/docker/volumes/hiclaw-data/_data/minio/hiclaw-storage \
  -maxdepth 8 -type d -name "hiclaw-storage" -print
# Must print only the root path — extra lines mean the recursion bug is present
# If extra lines appear: do NOT start the manager; follow architecture.md § MinIO recovery

# Start manager
docker start hiclaw-manager
sleep 30

# Verify MinIO is still clean after manager startup (manager pulls from MinIO on k8s startup)
sudo find /var/lib/docker/volumes/hiclaw-data/_data/minio/hiclaw-storage \
  -maxdepth 8 -type d -name "hiclaw-storage" -print
ls /worksp/hiclaw/workspace/hiclaw/ 2>/dev/null && echo "WARNING: recursion seed appeared" || echo "OK"

# Verify manager is healthy
docker exec hiclaw-manager openclaw clawtalk doctor
bash /worksp/hiclaw/manager-bootstrap-keeper.sh
```

### novnc-desktop

```bash
docker pull ghcr.io/u2giants/novnc-desktop:latest
docker stop novnc-desktop && docker rm novnc-desktop
docker run -d --name novnc-desktop \
  --network e10kwzww46ljhrgz1qj08j6a --ip 10.0.5.4 \
  -v novnc-e10kwzww46ljhrgz1qj08j6a-config:/config \
  -e PUID=1000 -e PGID=1000 -e TZ=UTC -e "TITLE=HiClaw Desktop" \
  --shm-size=2g --restart unless-stopped \
  ghcr.io/u2giants/novnc-desktop:latest
docker network connect coolify novnc-desktop
```

### oauth2-proxy

```bash
cd /worksp/hiclaw/oauth2-proxy
docker compose up -d
```

## Normal Container Recreation (automatic)

When HiClaw recreates `hiclaw-manager` or `hiclaw-controller`, the keeper cron jobs handle re-applying patches within 60 seconds:

1. HiClaw recreates the container with the stock startup script.
2. The keeper detects the script hash mismatch.
3. The keeper copies the host-owned patched script into the container and restarts it once.
4. The patched startup runs: MinIO sync pulls (with exclusions), ClawTalk bootstrap, gateway starts.

During the restart window the keeper may log `container startup script not readable yet; skipping this run` — this is expected while the container is still booting.

**Always run the MinIO recursion check after any restart.** See the check commands above.

## HiClaw Upgrade Workflow

After a HiClaw version upgrade (which recreates both containers):

```bash
# 1. Apply the one-off post-upgrade repair script
/worksp/hiclaw/fix-element-config.sh

# 2. Verify keepers have applied the patches
bash /worksp/hiclaw/manager-bootstrap-keeper.sh
bash /worksp/hiclaw/controller-bootstrap-keeper.sh

# 3. Verify manager health
docker exec hiclaw-manager openclaw clawtalk doctor

# 4. Verify controller Element Web
docker exec hiclaw-controller curl -s http://127.0.0.1:8088/hiclaw-api/healthz

# 5. Reconnect networks (fix-element-config.sh does this, but verify)
docker network connect coolify hiclaw-controller 2>/dev/null || true
docker network connect e10kwzww46ljhrgz1qj08j6a hiclaw-manager 2>/dev/null || true

# 6. Verify cron
crontab -l
```

`fix-element-config.sh` also:
- Installs a mc wrapper inside `hiclaw-manager` that intercepts MinIO sync and re-injects the `mcp` key after every pull
- Installs an npm wrapper inside `hiclaw-manager` for the "Update now" button
- Fixes the `channels.matrix.groups.*.allow → enabled` key in the MinIO-persisted `openclaw.json`

These container-internal patches are ephemeral (lost on next recreation). The persistent versions come from `start-manager-agent.sh` and `start-element-web.sh`.

## novnc-desktop Image Update

Changes to `novnc-desktop/` trigger a GitHub Actions build automatically on push to `main`. To apply the new image:

```bash
docker pull ghcr.io/u2giants/novnc-desktop:latest
docker stop novnc-desktop && docker rm novnc-desktop
# re-run the docker run command above
```

Rollback: replace `:latest` with `:sha-<previous-commit>`.

## Script/Config Changes (no image involved)

```bash
# On the host server:
cd /worksp/hiclaw && git pull

# Then restart affected service:
# keeper scripts: cron picks up automatically
# start-manager-agent.sh: bash manager-bootstrap-keeper.sh (detects hash change, restarts manager)
# start-element-web.sh: bash controller-bootstrap-keeper.sh (detects hash change, restarts controller)
# oauth2-proxy: cd oauth2-proxy && docker compose up -d
# traefik: docker cp traefik/claw.yml coolify-proxy:/traefik/dynamic/claw.yml
```

## Manual Recovery

If automation has not converged after 2 minutes:

```bash
bash /worksp/hiclaw/manager-bootstrap-keeper.sh
bash /worksp/hiclaw/manager-config-keeper.sh
bash /worksp/hiclaw/mcp-keeper.sh
docker exec hiclaw-manager openclaw clawtalk doctor
```

## oauth2-proxy — Authentication Provider

Provider: Google OAuth direct (`--provider=google`). Authentik is no longer in the auth path.

| Setting | Value |
|---|---|
| Provider | `google` |
| Redirect URI | `https://control.claw.designflow.app/oauth2/callback` |
| Cookie domain | `claw.designflow.app` and `*.claw.designflow.app` |
| Allowed emails | `oauth2-proxy/allowed-emails.txt` |
| Credentials file | `oauth2-proxy/.env` (not committed — see `oauth2-proxy/.env.example`) |

To add a permitted email: edit `allowed-emails.txt`, commit, pull on server, then:

```bash
cd /worksp/hiclaw/oauth2-proxy && docker compose up -d
```

To rotate credentials: update `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET` in `oauth2-proxy/.env`. Get new credentials from Google Cloud Console → APIs & Services → Credentials → OAuth 2.0 Client IDs. The redirect URI `https://control.claw.designflow.app/oauth2/callback` must be registered there as an authorized redirect URI.

After updating credentials, `docker compose up -d` picks up the new `.env` without a full recreate.

**After any oauth2-proxy change, verify the Element Web auto-login still works** (open an incognito window and log in with Google — you should land directly in the chat without a second login step). See [architecture.md § Google SSO Auto-Login](architecture.md#google-sso-auto-login) for why this is sensitive.

## Release / Change Management

1. Edit on the host or in a local branch
2. Validate against the running system
3. Commit with a clear imperative message
4. Push to `main`
5. Pull on server: `cd /worksp/hiclaw && git pull`
6. Apply (see above)

No separate publish step for shell scripts or configs. Only `novnc-desktop/` changes trigger a CI build.
