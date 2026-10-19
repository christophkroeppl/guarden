# 293 — default new services behind the cloudflare tunnel (root-owned), loopback-only otherwise

Blockers: none (ticket 294's record is read by this one; both are filed
together). Filed 2026-10-19 from `BACKLOG-default-cloudflare-tunnel.md`
(wave 4). Operator decisions (binding): the root-owned default puts new
services behind the cloudflare tunnel **only when the cf module is installed**,
otherwise the posture is fail-closed loopback-only — no crash, no
half-configured unit; public exposure stays a manual act (ticket 294).

## What is being asked

A new service's routes are published **nowhere outside the box** by default:
through the tunnel when `cloudflared` is an enabled module, and loopback-only
when it is not. Nothing in a repository moves a service in front of or behind
the tunnel.

## Spec citations for the chosen mechanism

- **The setting surface** — the per-environment default is the track's
  existing `expose` field: spec 3.3 already reads *"the track's `expose` field
  already defaults to `edge`"*, and spec 10 puts the environment set and the
  host's policy in root-owned `guarden.toml`. The field's value set grows by
  one — `loopback` | `tunnel` | `edge` — and **absent** becomes the honest
  default: an unset `expose` resolves from the module set (spec 3.1 `[modules]
  enabled`, spec 10's "the module set"), which is the operator's own
  root-owned answer and needs no second table.
- **Fail-closed** — `tunnel` resolves to `loopback` whenever `cloudflared` is
  not enabled, so a track that asks for a tunnel on a box without one is
  private rather than dangling: the same "refuse rather than guess" rule
  spec 6.3 gives the renderer, applied to exposure.
- **The three consumers read one resolver** — the mutator's allocation
  (`service._allocate`), the renderer's slice (`render._routes`) and the
  firewall's accept set (`firewall.accept_lines`) all compute the destination
  through `guarden.exposure`, so the slice `roots` reads, the registry's
  `route_destinations` and the uid-matched accepts cannot disagree. The
  duplication that exists today (mutator and renderer each re-derive
  `tunnel`/`track expose`) is exactly the drift this removes.
- **Effect per destination** — `tunnel`: rendered into the tunnel ingress
  (`roots.render_tunnel`, spec 6.4) and accepted for the tunnel's uid only;
  no edge router, no host-facing bind (a rendered `PublishPort` is always
  `127.0.0.1`, spec 7.4/7.5, and stays so). `loopback`: no edge router, no
  tunnel entry, no edge uid on the publication — the service's own publication
  and its declared consumers, nothing else (spec 7.6).
- **Grandfathering** — a track that states `expose` keeps stating it, and the
  registries the running fleet already holds keep their recorded
  `route_destinations`; the derived default is for services created after the
  change and for hosts whose tracks do not say. Stated, not implied: the eleven
  live services on `guarden-deploy` are not re-postured by an upgrade.

## What happens if it stays out

The default destination is `edge`, i.e. the host's public ingress: every new
route is on the internet by being created, on every track, with no tunnel in
front of it. "Private unless decided" (ADR-0006's shape for ports) does not
hold for exposure at all.

## What to build

1. `TRACK_DEFAULTS["expose"]` becomes unset; validation accepts
   `loopback|tunnel|edge` and the empty value, and refuses anything else with
   the track named (the way `kind`/`cap` mistakes are refused, spec 3.1).
2. `guarden.exposure.resolve()` — one pure function: recorded per-service
   value (ticket 294) > track `expose` > derived (`tunnel` if `cloudflared`
   enabled else `loopback`), with `tunnel` collapsing to `loopback` when the
   module is absent.
3. `service._allocate` and `render._routes` both call it; the registry's
   `route_destinations` and the slice's `destination` are its outputs.
4. `roots.render_service` renders only `edge` destinations (today it skips
   only `tunnel`); a loopback service produces no file and the sweep removes
   the one it had.
5. `firewall.accept_lines` grants the edge uid on a route publication only
   when that route's destination is `edge`.
6. The shipped `src/guarden/templates/guarden.toml` stops pinning
   `expose = "edge"` on the three default tracks, so a fresh host gets the
   derived posture. Fixtures that pin the old posture do so explicitly.
7. Drift: a `soil --check` item (firewall phase, reported and never corrected —
   same class as the two host invariants, spec 6.1) whose `holds` is "every
   service's recorded `route_destinations` match what its exposure resolves to
   now", so a track edit or a module removal that moves a service off its
   recorded default is one `drift:` line naming the service.

## Known gaps (reported, not invented)

- **Spec 3.3's sentence "defaults to `edge`" is corrected in this branch.** The
  spec is the contract and a ticket sits below it in the authority order
  (`docs/spec.md:12`), so nothing here supersedes a sentence of it: spec 3.1's
  track-field list and 3.3's overrides sentence were rewritten to state the
  derived default, in the same change that made the code behave that way
  (review-exposure.out finding 1).
- Tunnel hostnames are still allocated by nobody (the backlog's open question;
  carried as ticket 306):
  `roots` publishes a route to whatever host the mutator allocated in
  `host.domain`; the tunnel zone (`[ingress] tunnel_domain`) is only used for
  previews. Per-service hostnames inside the CF zone are not part of this
  ticket.

## Status: ready-for-agent

- [ ] With `cloudflared` enabled, a newly created service's slice says
      `destination = "tunnel"` and the tunnel ingress file carries its host,
      with no manifest change and no host-facing bind.
- [ ] With `cloudflared` absent, a newly created service resolves
      `destination = "loopback"`: no edge router file, no edge uid accept on
      its route publication (fail-closed).
- [ ] A track that says `expose = "tunnel"` on a box without the module
      resolves to `loopback` rather than rendering a tunnel nothing reads.
- [ ] `soil --check` reports `drift` when a recorded destination no longer
      matches the current resolution.
- [ ] Red first: `tests/t452-tunnel-default.sh` (reserved range t450–t459).
