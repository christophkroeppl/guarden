# Coolify integration

This stack uses [Coolify](https://coolify.io/) as the dynamic deployment layer while keeping your existing static compose services.

## Stack (compose)

- **coolify** – main app (Traefik + Basic Auth, subdomain, socket-proxy for Docker). Runs as `USER_ID:GROUP_ID` (same as other app containers). Persists `./data` and `./data/ssh` (SSH keys).
- **coolify-pg** – PostgreSQL 15 (Alpine); required by Coolify.
- **coolify-redis** – Redis 7 (Alpine); required by Coolify.
- **coolify-realtime** – Soketi for realtime; required by Coolify.

All share an internal `coolify` network; only the app is on `backends` for Traefik.

## First-time setup (step-by-step)

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

Coolify expects SSH keys under `./data/ssh` (see [Coolify FAQ](https://coolify.io/docs/knowledge-base/faq#permission-denied-publickey)). Use the same path layout as the [official install script](https://github.com/coollabsio/coolify/blob/main/scripts/install.sh): a `keys/` subdirectory and, for localhost, a key named `id.<user>@host.docker.internal` (e.g. `id.root@host.docker.internal`). Create the dirs and ensure ownership:

```bash
mkdir -p coolify/data/ssh/keys
# If USER_ID/GROUP_ID are set, e.g. 1000:1000:
chown -R "${USER_ID:-1000}:${GROUP_ID:-1000}" coolify/data
```

### 3. Start the stack

From repo root (so the stack that includes Coolify is used):

```bash
docker compose up -d
```

### 4. Generate SSH key and register it in Coolify (required before "Select server type")

Coolify stores keys in the **database** (PrivateKey model) and assigns them to servers. The "Select server type" step loads the default server and calls `$server->privateKey->getPublicKey()`; if no key is assigned, you get **`Call to a member function getPublicKey() on null`**. You must both create a key **file** and **register it in Coolify and assign it to the localhost server** before that step.

**4a. Create the key file** (match the [install script](https://github.com/coollabsio/coolify/blob/main/scripts/install.sh) layout):

```bash
# Use the same key name as official install (replace root with your host user if different)
docker exec -u root -it coolify sh -c 'mkdir -p /var/www/html/storage/app/ssh/keys && ssh-keygen -t ed25519 -a 100 -f /var/www/html/storage/app/ssh/keys/id.root@host.docker.internal -q -N "" -C coolify'
docker exec -u root coolify chown -R "${USER_ID:-1000}:${GROUP_ID:-1000}" /var/www/html/storage/app/ssh
```

(If your host user is not `root`, use `id.$(whoami)@host.docker.internal` instead of `id.root@host.docker.internal`.)

**4b. Register the key in Coolify and assign it to the localhost server** — choose one:

- **Option A – UI (recommended):** Before continuing onboarding to "Select server type", go to **Security → Private Keys**, add a new key and paste the contents of `coolify/data/ssh/keys/id.root@host.docker.internal`. Then go to **Servers → localhost** (or the default server) → **Private key** tab and select that key. Then continue onboarding.
- **Option B – One-off script:** If you cannot leave onboarding, run this once so the default server has a key in the database (replace the key path if you used a different name):

```bash
docker exec -it coolify php artisan tinker --execute="
\$path = '/var/www/html/storage/app/ssh/keys/id.root@host.docker.internal';
if (!is_file(\$path)) { \$path = '/var/www/html/storage/app/ssh/id_ed25519'; }
\$content = file_get_contents(\$path);
\$teamId = \App\Models\Team::first()->id;
\$key = \App\Models\PrivateKey::createAndStore(['name' => 'Default', 'description' => 'Default', 'private_key' => \$content, 'is_git_related' => false, 'team_id' => \$teamId]);
\$server = \App\Models\Server::first();
\$server->private_key_id = \$key->id;
\$server->save();
echo 'Assigned key to server: ' . \$server->name . PHP_EOL;
"
```

Then reload the onboarding page and continue to "Select server type".

**4c. (Optional) Add public key to host `authorized_keys`** for localhost SSH access (see [Coolify FAQ](https://coolify.io/docs/knowledge-base/faq#permission-denied-publickey)):

```bash
cat coolify/data/ssh/keys/id.root@host.docker.internal.pub >> ~/.ssh/authorized_keys
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys
```

### 5. Complete Coolify setup in the UI

1. Open `https://${COOLIFY_SUBDOMAIN}.${NAMECHEAP_DOMAIN__KROEPPL_ONLINE}` (Traefik Basic Auth with your htpasswd user).
2. Register / create the initial Coolify admin account.
3. Go through onboarding. At **Select server type** choose your server type (e.g. local Docker). The server should already have a key assigned from step 4.
4. Finish any remaining onboarding steps (add server, connect Git, etc.) as needed.

### Troubleshooting

- **`Call to a member function getPublicKey() on null`** at `/onboarding?step=select-server-type`: The default server has no **Private Key** assigned in the database. Coolify keys are stored in the DB and linked to servers; a key file alone is not enough. Follow step 4: create the key file, then either add the key in **Security → Private Keys** and assign it to the localhost server (option A), or run the one-off tinker script (option B).

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

---

## Sources:
### Setup
- [Coolify: Manual Installation](https://coolify.io/docs/get-started/installation#manual-installation)
- [Coolify: Non-Root User](https://coolify.io/docs/knowledge-base/server/non-root-user)
### Container Management
- [Coolify: Docker Compose](https://coolify.io/docs/knowledge-base/docker/compose)
