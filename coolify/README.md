# Coolify integration

This stack uses [Coolify](https://coolify.io/) as the dynamic deployment layer while keeping your existing static compose services.

## Stack (compose)

- **coolify** – main app (Traefik + Basic Auth, subdomain, socket-proxy for Docker). Runs as `USER_ID:GROUP_ID` (same as other app containers). Persists `./data` and `./data/ssh` (SSH keys).
- **coolify-pg** – PostgreSQL 15 (Alpine); required by Coolify.
- **coolify-redis** – Redis 7 (Alpine); required by Coolify.
- **coolify-realtime** – Soketi for realtime; required by Coolify.

All share an internal `coolify` network; only the app is on `backends` for Traefik.

## First-time setup (step-by-step)
https://github.com/coollabsio/coolify/blob/v4.x/docker-compose.dev.yml

### 1. Set environment variables

In the project `.env` set:

- `USER_ID` and `GROUP_ID` (same as other stacks, e.g. your host uid/gid so the container can write to `./data` and `./data/ssh`). If unset, defaults to `9999:9999` as per coolify container defaults.
- `COOLIFY_SUBDOMAIN` (e.g. `coolify`) and `NAMECHEAP_DOMAIN__KROEPPL_ONLINE`.
- `COOLIFY_DB_PASSWORD`, `COOLIFY_REDIS_PASSWORD` – strong random values (e.g. `openssl rand -base64 24`).
- `COOLIFY_PUSHER_APP_ID` (e.g. `coolify`), `COOLIFY_PUSHER_APP_KEY`, `COOLIFY_PUSHER_APP_SECRET` – random strings (e.g. `openssl rand -base64 24` for key and secret).
- `COOLIFY_APP_KEY` – generate with:
  ```bash
  docker run --rm ghcr.io/coollabsio/coolify:latest php artisan key:generate --show
  ```
  Paste the output into `COOLIFY_APP_KEY`.

### 2. Create SSH directory and ensure ownership (required before onboarding)

Coolify expects SSH keys at `./data/ssh`. Create it and ensure it (and `./data`) are owned by `USER_ID:GROUP_ID` so the container can write:

```bash
mkdir -p coolify/data/ssh
# If USER_ID/GROUP_ID are set, e.g. 1000:1000:
chown -R "${USER_ID:-1000}:${GROUP_ID:-1000}" coolify/data
```

This also avoids the onboarding error **Select server type** (`/onboarding?step=select-server-type`): `Call to a member function getPublicKey() on null` when a key is generated in step 4.

### 3. Start the stack

From repo root (so the stack that includes Coolify is used):

```bash
docker compose up -d
```

### 4. Generate SSH key inside the container (before onboarding server step)

Before or when you reach **Select server type** in the Coolify UI, create an SSH key so Coolify has a key to use. With `user: USER_ID:GROUP_ID`, the container runs as that user; if the mount is owned by the same user, a normal exec works. If you get “Permission denied”, run as root and fix ownership:

```bash
# Container runs as USER_ID:GROUP_ID; if data/ssh is owned by that user, this works:
docker exec -it coolify sh -c 'mkdir -p /var/www/html/storage/app/ssh && ssh-keygen -t ed25519 -f /var/www/html/storage/app/ssh/id_ed25519 -N ""'

# If you get "Permission denied", create as root then chown to container user (e.g. 1000:1000):
docker exec -u root -it coolify sh -c 'mkdir -p /var/www/html/storage/app/ssh && ssh-keygen -t ed25519 -f /var/www/html/storage/app/ssh/id_ed25519 -N ""'
docker exec -u root coolify chown -R "${USER_ID:-9999}:${GROUP_ID:-9999}" /var/www/html/storage/app/ssh
```

Then continue the onboarding; the `getPublicKey() on null` error should be resolved.

### 5. Complete Coolify setup in the UI

1. Open website (Traefik Basic Auth with your htpasswd user).
2. Register / create the initial Coolify admin account.
3. Go through onboarding. At **Select server type** choose your server type (e.g. local Docker); the SSH key from step 4 will be used.
4. Finish any remaining onboarding steps (add server, connect Git, etc.) as needed.

### Troubleshooting

- **`Call to a member function getPublicKey() on null`** at `/onboarding?step=select-server-type`: Coolify is looking for an SSH key that does not exist. Ensure `coolify/data/ssh` exists, the compose volume `./data/ssh:/var/www/html/storage/app/ssh` is in use, and run step 4 above to generate the key inside the container, then retry the step.

## Routing / domain model
Set app domains inside Coolify to match your desired pattern:
- `dev` branch -> `dev.<DOMAIN>`
- `cursor/feature-cool-new-stuff` -> `feature.<DOMAIN>/cool-new-stuff`
- `codex/feature-hot-new-shizz` -> `feature.<DOMAIN>/hot-new-shizz`
- `claude/feature-amazing` -> `feature.<DOMAIN>/amazing`

Recommended Coolify config for feature branches:
1. Create one app resource pointed at your GitHub repo.
2. Enable branch deployments / preview deployments.
3. Add branch filter: `dev` and `*/feature-*`.
4. Use a branch slug transform to strip `<prefix>/feature-` and map to path prefix.
5. Domain template:
   - `dev` -> `https://dev.<DOMAIN>`
   - features -> `https://feature.<DOMAIN>/<slug>`

## Build behavior
- Configure GitHub webhook from your app repo to Coolify.
- Coolify builds on push.
- For rapid pushes, Coolify's queue and per-resource deployment locking avoid overlapping active deploys; newer deploys replace older running targets.

## Shared DB with per-branch database
Use one shared DB server resource (Postgres or MySQL) in Coolify, then per deployment:
- Pre-deploy hook: `CREATE DATABASE IF NOT EXISTS <db_name>;`
- Runtime env: set `DATABASE_URL` for that branch db.
- Cleanup hook (on preview removal): drop branch DB.
