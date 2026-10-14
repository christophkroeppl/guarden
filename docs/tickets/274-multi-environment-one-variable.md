# 274 — a Compose service's multiple `environment:` keys render as ONE variable

Blockers: none. Found 2026-10-13 deploying the first real service. **This is a
silent data-loss bug: the container starts with the wrong environment and no
error is printed anywhere.**

## What happens

`postgres-production`'s compose file declares three environment keys:

```yaml
environment:
  POSTGRES_USER: guarden
  POSTGRES_PASSWORD: guarden-dev
  PGDATA: /var/lib/postgresql/data/pgdata
```

The rendered unit carries them as **one** line:

```
Environment="POSTGRES_USER=guarden POSTGRES_PASSWORD=guarden-dev PGDATA=/var/lib/postgresql/data/pgdata"
```

and the generated unit systemd actually runs is:

```
ExecStart=… podman run … --env "POSTGRES_USER=guarden\x20POSTGRES_PASSWORD=guarden-dev\x20PGDATA=/var/lib/postgresql/data/pgdata" …
```

Measured on the host: the container receives **one** variable,
`POSTGRES_USER` = `"guarden POSTGRES_PASSWORD=guarden-dev PGDATA=/var/lib/postgresql/data/pgdata"`.
`POSTGRES_PASSWORD` and `PGDATA` do not exist.

## Why it matters

- A service that sets two or more environment keys is deployed with one
  malformed key and none of the others. The container usually starts (the first
  variable is present, just wrong) and fails later in a way that names the
  *symptom*, not the cause — here, postgres fell back to its default `PGDATA`,
  whose directory is the volume root, whose chown then hit `.snapshots` and
  exited 1. That sent the first diagnosis after `.snapshots` (ticket 273) when
  the real cause was the environment.
- Nothing prints a warning. The unit renders, `weedr service start` reports
  `started`, and the failure appears only in the container's own log.

## The mechanism, measured

- Quadlet does **not** split a quoted `Environment=` value: a hand-written
  `Environment="A=1 B=2"` generated `--env "A=1\x20B=2"`.
- Podman does **not** split it either: `podman run --env "A=1 B=2"` yields one
  variable `A="1 B=2"`; `--env A=1 --env B=2` yields two.
- So a converter that space-joins several assignments into one quoted value
  produces exactly this. The fixture `quadlet-app` passes only because its
  `Environment=` lines are already one key each, and a compose file's
  `environment:` map is the case that is not covered.

## The fix

Each environment key becomes its **own** `Environment=` line (or its own
`--env`), never a space-joined group. A regression test: a compose service with
two environment keys renders two `Environment=` lines and the container sees two
variables. The existing render tests should carry this case — the fixture set has
no compose service with more than one `environment:` key, which is why it was
missed.

## Evidence

- unit: `/var/lib/guarden/services/postgres-production/home/.config/containers/systemd/db.container`
- `podman run --env "A=1 B=2"` → `A=1 B=2` (one var); separate `--env` → both.
