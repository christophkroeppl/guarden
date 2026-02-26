# Coolify integration

This stack uses [Coolify](https://coolify.io/) as the dynamic deployment layer while keeping your existing static compose services.

## Routing / domain model
Set app domains inside Coolify to match your desired pattern:
- `dev` branch -> `dev.<DOMAIN>`
- `cursor/feature-cool-new-stuff` -> `feature.<DOMAIN>/cool-new-stuff`
- `codex/feature-hot-new-shizz` -> `feature.<DOMAIN>/hot-new-shizz`

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
- For rapid pushes, Coolify's queue and per-resource deployment locking avoid overlapping active deploys.

## Shared DB with per-branch database
Use one shared DB server resource (Postgres or MySQL) in Coolify, then per deployment:
- Pre-deploy hook: `CREATE DATABASE IF NOT EXISTS <db_name>;`
- Runtime env: set `DATABASE_URL` for that branch db.
- Cleanup hook (on preview removal): drop branch DB.

Example naming convention:
- `preview_<repo>_dev`
- `preview_<repo>_<feature_slug>`

## Stack wiring in this repo
- `compose.yaml` includes `./coolify/compose.yaml`.
- `coolify/compose.yaml` runs Coolify on the `backends` network and publishes it through existing Traefik labels.
- Coolify itself talks to Docker via the existing socket-proxy (`DOCKER_HOST=tcp://socket-proxy:2375`).
