# Ticket 220: three defects the suite found, and one fork it exposed

**Status: 1 fixed, 1 design fork for the operator, 1 test-suite work in progress.**

`tests/t220-tendril.sh` was written to assert the tunnel's routing decision. Driving the
real CLI found four things, three of which are defects in the branch's own code and one of
which is a design question this note does not decide.

## Fixed — `d4b70e7`: a track's `expose` did not default

`config.TRACK_DEFAULTS` carries `"expose": "edge"`, and `_tracks` never read it. It built
each `Track` with `expose=_str(row, "expose", where)`, which answers `""` for an absent
key, and the validator below it rejects anything that is not `"edge"` or `"tunnel"`.

So on this branch **every existing configuration failed to load** — `production`, `staging`
and `preview` alike, none of which states `expose` — and `weedr module add cloudflared` could
not run at all. The fix is one expression: `or TRACK_DEFAULTS["expose"]`.

Worth noting how it was found: not by reading. The config parses, the track table is
well-formed, and the diagnostic named a field nobody had written. It took a suite driving
the real CLI to surface it.

## Fixed — the suite's own install/packages order

`soil packages --apply` refuses until the pinned-artefact records exist, and it is
`soil install` that seeds them from the templates. `cloudflared` is in `PINNED_ARTEFACTS`
(ADR-0015), so the tunnel makes a pre-existing ordering requirement load-bearing: a
packages run before install is a rejected input, not a missing package. The suite now runs
install first. **This is a fact about the tree, not about the suite** — any operator
running `soil packages` on a fresh host hits it.

## The fork — how does a `[Container]`-model repo run a program that is not in an image?

`modules/tendril/tendril-production/.guarden/quadlet/tendril-production.container` (as the file
was named then; the module is `cloudflared` and the service `cloudflared-production` today) was
hand-written as a **raw systemd unit**:

```
[Service]
ExecStart=/usr/lib/guarden/bin/cloudflared tunnel --config /etc/guarden/tendril-production/config.yml run
```

`unitsource.format_line` refuses that, by design: `ExecStart=` is not in `QUOTABLE`, so a
value with a space in it is a rejected input rather than a unit that parses as something
other than it means. Every other module ships a podman `[Container]` unit instead — `gate-traefik`,
`homepage` and `auth-authelia` all declare `[Container]` with `Image=`, and the program runs *inside*
a container.

**So the question the ticket left open is a real one, and it is the operator's:**

- **A — the tunnel is a `[Container]` service like every other**, running a cloudflared
  image. Consistent with spec §2 ("everything deployed is a service") and with every other
  module. But the ticket's own text says "`cloudflared` runs as a systemd user unit in its
  own user manager" and that "it cannot be an ordinary service" is not stated anywhere —
  only that it must dial out before any container is up. A container that dials out is
  still egress-only.
- **B — the tunnel is a host-level program run by a generated systemd unit**, which needs
  `unitsource` to gain a quotable `ExecStart=` (or the unit to be expressed another way).
  This matches the ticket's text and ADR-0015's "the pin is a url and two digests" — the
  pinned binary is fetched to the host, so running it from the host is the direct reading.
  But it makes the tunnel the one service that is not a `[Container]`, which is a second
  class of thing.

**Recommendation: A.** It keeps one model, the tunnel's egress-only property is unaffected
by containerising it, and a cloudflared image is the vendor's own supported distribution
path — which also removes the 40 MB pinned binary and the `raw` format reader that ADR-0015
just specified. That last point is the cost of A: it contradicts ADR-0015's part two, so A
means superseding that ADR. B is cheaper to land and keeps the ADR intact. This is a
scope-and-consistency call, not a bug, so it is recorded rather than made.

## What the suite still needs

The suite is written and runs; it reached the `ExecStart=` refusal above before the fork
stopped it. Once the fork is decided it needs one more pass: the assertion that a
tunnel-destination route is **absent** from `/var/lib/guarden/edge/dynamic/` and present in
`/var/lib/guarden/tunnel/ingress/` is written but not yet observed green, because the module
cannot be added until the fork is settled.
