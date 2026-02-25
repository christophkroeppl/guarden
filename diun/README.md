# Diun – Docker Image Update Notifier

[Diun](https://crazymax.dev/diun/) watches your Docker images and notifies you (e.g. via Telegram) when new tags are available.

## Telegram notifications

### 1. Create a Telegram bot and get the token

1. Open Telegram and search for **@BotFather**.
2. Send `/newbot` and follow the prompts (name and username for the bot).
3. BotFather replies with a **token** like `123456789:ABCdefGHI...`. Copy it.

### 2. Get your chat ID

1. Search for **@userinfobot** or **@getidsbot** in Telegram.
2. Start the bot (e.g. Send “Start” or any message).
3. The bot replies with your **chat ID** (a number like `123456789`). Copy it.

(To notify a group, add the bot to the group and use **@getidsbot** to get the group chat ID, often a negative number.)

### 3. Add secrets to `.env`

In the repo root (e.g. `srv/.env`), add:

```bash
# Diun – Telegram
DIUN_NOTIF_TELEGRAM_TOKEN=123456789:ABCdefGHI_your_full_token_here
DIUN_NOTIF_TELEGRAM_CHATIDS=123456789
```

- **Multiple chat IDs:** comma-separated, no spaces: `123456789,-987654321`
- **Topic in a forum:** use format `CHAT_ID:TOPIC_ID`, e.g. `-1001234567890:42`

### 4. Start Diun

From the `diun` directory:

```bash
docker compose up -d
```

Check logs:

```bash
docker compose logs -f
```

You should see Diun start, run a first check, and (if there are updates) send a Telegram message.

### 5. Test notifications

To send a test notification (e.g. to verify Telegram), run Diun’s [`notif test`](https://crazymax.dev/diun/usage/command-line/) **inside** the already-running Diun container so it can reach the gRPC server on localhost (avoids Docker DNS issues with one-off containers):

From the `diun` directory:

```bash
docker compose run --rm diun notif test
```


## Which images are watched?

By default only containers with the label **`diun.enable=true`** are watched. Add that label to any service you want to track.

Example (in a service’s `compose.yaml`):

```yaml
labels:
  - diun.enable=true
```

Optional labels (see [Docker provider docs](https://crazymax.dev/diun/providers/docker/)):

- `diun.watch_repo` – watch all tags of the image (use with care, can hit rate limits)
- `diun.notify_on` – e.g. `new;update` (default)
- `diun.include_tags` / `diun.exclude_tags` – semi-colon separated list or regex for which tags to consider

## Schedule

Default: every 6 hours (`0 */6 * * *`) with 30s jitter. Override with `DIUN_WATCH_SCHEDULE` in the compose `environment` or in `.env`.
