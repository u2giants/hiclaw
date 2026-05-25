# oauth2-proxy

Google OAuth gate for all `*.claw.designflow.app` web services.

## Files

| File | Purpose |
|------|---------|
| `docker-compose.yml` | Container definition — provider, flags, network |
| `allowed-emails.txt` | Whitelist of Google accounts permitted to log in |
| `.env` | **Not committed.** Runtime credentials (see below) |
| `.env.example` | Variable names and descriptions |

## Required `.env`

Create `oauth2-proxy/.env` (never commit it):

```
GOOGLE_CLIENT_ID=<your-client-id>.apps.googleusercontent.com
GOOGLE_CLIENT_SECRET=GOCSPX-<your-secret>
OAUTH2_PROXY_COOKIE_SECRET=<random-32-byte-base64>
```

Get credentials from Google Cloud Console → APIs & Services → Credentials → OAuth 2.0 Client IDs. The redirect URI `https://control.claw.designflow.app/oauth2/callback` must be listed as an authorized redirect URI in that app.

To generate a cookie secret: `python3 -c "import os,base64; print(base64.b64encode(os.urandom(32)).decode())"`.

## Manage

```bash
# Start / restart after any config change
cd /worksp/hiclaw/oauth2-proxy && docker compose up -d

# Add a permitted email: edit allowed-emails.txt, then:
docker compose up -d   # live reload — no restart needed for email list changes

# View logs
docker logs oauth2-proxy --since 10m
```

## Relationship to Element Web auto-login

oauth2-proxy gates the Traefik layer (HTTP auth check). After passing it, the user still needs a Matrix session to use Element Web. `start-element-web.sh` injects `auto-login.js` which creates that session automatically — the user never sees a second login screen. See [docs/architecture.md § Google SSO Auto-Login](../docs/architecture.md#google-sso-auto-login) for the full design. If the auto-login breaks, check this proxy first (wrong provider or missing credentials cause cascading failures).
