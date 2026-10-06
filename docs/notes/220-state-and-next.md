# Where ticket 220 stands, and what the session after this one should do

Written 2026-10-06, at the end of a session that took the tunnel from "cannot be
installed at all" to a green suite on an integration branch. Read this before
re-dispatching anything at ticket 220.

## The decision, and it is made

**The tunnel is a container**, running the vendor's own
`docker.io/cloudflare/cloudflared` image, and ADR-0015 part two is amended to say so.
It previously decided `cloudflared` would be a second pinned host binary; it is not.
`PINNED_ARTEFACTS` is `(podlet,)` again and `cloudflared.release` is deleted.

The reason the container route won is not only consistency. The branch's first
implementation was a **raw systemd unit with a multi-word `ExecStart=`**, which
`unitsource.format_line` refuses *by design* — so `weedr module add tendril` could not
run at all. A `[Container]` unit passes its arguments one `Exec=` line each, which is
how `gate`'s traefik already runs.

## The branch

`ticket/220-tunnel-module`, with develop merged in. The commits, oldest first:

| | |
|---|---|
| `120a9e6` | the prior session's foundation — config, overrides, roots, tendril scaffold |
| `0e9a574` | the module moved to `.guarden/`, like every other module |
| `d4b70e7` | **a track's `expose` defaults to `edge`** — see below |
| `8fe251e` | the note recording what the suite found |
| `27683f1` | **the container, and the ADR-0015 amendment** |
| `329dde1` | three section-header comments removed from `paths.py` |

## Five defects the suite found, all in the branch's own code

None of these was visible by reading. Each was found by writing `tests/t220-tendril.sh`
and driving the real CLI, which is the argument for the suite existing.

1. **`TRACK_DEFAULTS` was defined and never read.** `_tracks` built each `Track` with
   `expose=_str(row, "expose", where)`, which answers `""` for an absent key, and the
   validator rejects anything that is not `edge` or `tunnel`. So **every existing
   configuration failed to load** on the branch — production, staging and preview
   alike — and the module could not be added at all. Fixed with
   `or TRACK_DEFAULTS["expose"]`.
2. **A tunnel-destined route was rendered into the edge as well.** `render_service`
   took every route regardless of destination, so the route appeared in the edge's
   dynamic directory *and* the tunnel's — the one thing ADR-0015 forbids. It now skips
   `destination == "tunnel"`, and an all-tunnel service renders to nothing rather than
   an empty file.
3. **`roots` could not create `/var/lib/guarden/tunnel`.** It runs as `guarden` and the
   directory was root's. `weedr module add` creates it now, `guarden:guarden`, the way
   it already creates the edge's dynamic directory.
4. **The tunnel's ingress was not a file `cloudflared` would accept** — a bare list of
   rules with no `ingress:` wrapper and no `credentials-file`.
5. **It was rendered per service.** `cloudflared` reads one config, so it is one
   host-wide file at `/var/lib/guarden/tunnel/config.yml`.

## What is verified, and how

`tests/t220-tendril.sh` is green on `guarden-run-a`, on the merged tree, with
`--no-cache` (so it was observed, not inherited). It asserts: the empty-`tunnel_domain`
refusal, that `20-ingress-nat.conf` is byte-identical across the module add, that a
tunnel route is **absent** from the edge's dynamic directory and present in the
tunnel's, that the catch-all is `http_status:404` and last, and that the unit is a
`[Container]` with no `ExecStart=`.

## What is NOT done

- **The tunnel is never started.** That needs a real Cloudflare account and a delegated
  zone; the ticket marks it an operator acceptance step. Nothing here fakes it.
- **`weedr share` does not exist.** The issuance/expiry/reconciler family is unwritten.
  Before writing it, read `docs/notes/cloudflare-session-duration-exists.md`: the ticket
  and ADR-0015 both assert an Access policy has no expiration field, and that is **half
  wrong** — the schema has no `expir*` key, but a policy response carries a top-level
  `session_duration`, which is a browser-login duration. The design is unchanged (the
  vendor's policy stays a projection of guarden's record) but the ticket must stop
  claiming the field does not exist, and must decide what `session_duration` is.
- **`docs/tickets/220-tunnel-module.md` is not updated.** Its checklist still shows the
  pinned-binary decision and the systemd-user-unit shape. It needs a pass to match what
  was built.

## Traps this work paid for

- **A merge can silently drop a whole feature.** `merge(200)` at `1fc851e` resolved
  `tests/lxc.sh` from the ticket-200 side wholesale and took the ticket-210 cache wiring
  with it; develop ran an unwired harness while the ticket read `complete`. Restored at
  `27d878d`. When a commit appears in `git log -- <file>` but its content is absent from
  HEAD, a merge lost it — restore it, do not reimplement it.
- **Never adopt a dirty working copy without diffing it against HEAD.** A dead agent's
  `tests/lxc.sh` was adopted on the strength of its diff looking right; it was a stale
  767-line copy of a file whose committed version was 867 lines.
- **One harness process per runner name.** Two runs sharing `guarden-run-a` produce
  phantom failures with no diagnostic — a suite reporting state another suite wrote,
  green when re-run alone. `pgrep -af 'lxc.sh run'` must be empty before starting.
