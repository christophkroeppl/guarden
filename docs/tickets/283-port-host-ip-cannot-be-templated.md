# 283 — podlet cannot parse `${VAR}` in a port's host-IP position

Found 2026-10-14 deploying the `odoo-btc-bcr` stack. **A guarden-level refusal, and
the diagnostic names podlet rather than guarden.**

## What happens

`devel.yaml:50` publishes the Odoo GUI as

```yaml
ports:
  - "127.0.0.1:${PORT:-19069}:8069"
```

and podlet refuses the whole compose:

```
Error: ... is not a valid compose file 3: error parsing host ip address:
invalid IP address syntax
```

Measured minimal reproduction — a one-service compose whose only content is that
port form fails identically:

```yaml
services:
  t:
    image: docker.io/library/alpine:3.20
    ports:
      - "127.0.0.1:${PORT:-19069}:8069"
```

and the same compose with the substitution resolved to a literal
(`"127.0.0.1:19069:8069"`) parses fine. So the parser reads the host-IP field
before it expands `${...}` and fails on the `$`.

## Why it matters

Compose's documented way to let an operator set the published port is exactly this
form, and the workz convention in this repository uses it deliberately so two
worktrees cannot be handed the same port. On a guarden host the substitution is
**not the repository's** anyway — guarden allocates the loopback publication
itself (`render._publications` writes `PublishPort=127.0.0.1:<allocated>:<port>`
from the ingress the manifest declares), so a compose `ports:` entry is redundant
at best. But the refusal is at parse time, so a repository that carries the
conventional form cannot even be converted, and the error names "invalid IP
address syntax" rather than "a port cannot be templated here".

## What this ticket wants

Either (or both):

- **A refusal that names the construct.** `compose.convert` could scan for a
  `ports:` entry containing `${` and refuse with a guarden message
  ("a port's host-IP cannot be templated; guarden allocates the loopback
  publication from the manifest's ingress") rather than passing it to podlet and
  reporting podlet's parser error. The current message sends a reader to the IP
  address, which is correct and unhelpful.
- **A substitution pass before podlet**, if guarden intends to support the form.
  This is the weaker option: it would let a repository state a host port, which is
  the thing guarden's ingress model exists to own.

## The measured refusal set for this stack (all podlet, all at convert time)

A minimal compose per construct, run through `compose.convert` on the deploy VM:

| construct | result |
|---|---|
| `ports: "127.0.0.1:${PORT}:8069"` | **refused** — invalid IP address syntax |
| `build: {context: ./odoo}` | **refused** — cannot convert `build` |
| `extends: {file: common.yaml, service: odoo}` | **refused** — cannot convert the service |
| `profiles: ["devel-setup"]` | **refused** — cannot convert the service |
| `shm_size: 1gb` | accepted |
| `network_mode: host` | accepted (guarden replaces it, per spec 6.3) |

`build:` and `extends:` and `profiles:` are each a documented Compose feature that
podlet cannot carry, and each refuses the entire file rather than the one service.
That is the real cost for a repository like this one, which uses `extends:` to
share a Doodba base across eight services: the deployed compose has to inline every
one of them.
