# 281 — a compose `healthcheck:` cannot be expressed, and the refusal is correct

Found 2026-10-14 rendering the `supplements` deployment compose. **Not a defect —
a rule worth writing down, because it is easy to hit and the message is the only
warning you get.**

## What happens

A Compose `healthcheck:` becomes `HealthCmd=` in the rendered unit, and
`HealthCmd` is **not in `unitsource.QUOTABLE`**. So a healthcheck whose command
contains a space is refused:

```
error: .../catalog-admin.container: the value of HealthCmd= has a space in it and
HealthCmd does not take a quoted value: "fetch('http://localhost:3000/healthz')..."
```

Measured: `weedr service ingest` for a compose with three `healthcheck:` blocks
failed with exactly this, naming the container and the value.

## Why the refusal is right

`QUOTABLE` is `{Description, Environment, EnvironmentFile, Label, Exec,
NotifyAccess, SyslogIdentifier}` — the keys systemd accepts a quoted value for.
`HealthCmd=` is not one, so there is no spelling of "a command with a space" that
renders: quoting it produces a unit systemd will not parse, and not quoting it
produces `HealthCmd=fetch(...)` with the arguments split. Refusing is the only
honest answer, and the message says which key and which value.

## What a repository should do

Drop the compose `healthcheck:` from the deployed file and rely on the image's own
`HEALTHCHECK` (the `Containerfile` already carries one for supplements, using
`bun -e` — a single word, so it could be expressed if it were needed). A
healthcheck is not a thing a deployed compose can state here; it belongs in the
image.

## The same class as the `Environment=` trap

Both are `format_line` refusing to write a line that would mean one thing and
parse as another. The `Environment=` case was the *silent* one (a quoted join
collapsed to a single variable and the service started anyway); this one is the
loud one, and it is loud because `HealthCmd` was never in `QUOTABLE` — the guard
added for `Exec`/`Environment` did not have to be extended to catch it.
