# 294 — public exposure is a manual act, recorded per service per environment

Blockers: none. Filed 2026-10-19 from
`BACKLOG-manual-public-exposure-per-env.md` (wave 4). Operator decisions
(binding): exposure is recorded **per service per environment**; `public` is
selectable **only on gated tracks** — staging can never go public; a manifest
that requests public exposure is refused with a guarden one-liner; drift is
diagnosable through `soil --check` when exposure moves off its default; the
record lives on the root-owned config surface, and where no spec-sanctioned
surface exists that sub-part is reported as a gap instead of an invented
table. DECIDED 2026-10-18 (operator, before AFK): gated tracks only.

## What is being asked

The default for every service in every environment is private (loopback, or
tunnel when the cf module is installed — ticket 293). Making one service
reachable from the public internet is one explicit root-side act that changes
exactly one record, on a gated track, and can be undone the same way.

## Spec citations for the chosen mechanism

- **The record: the registry, per service (hence per environment).** Spec 3.4:
  `/var/lib/guarden/registry/<name>.toml`, "written only by the mutator", the
  "single record of a service's identity … only what cannot be derived from
  the manifest and the host is stored". A service name carries its track
  (spec 5.1), so one registry file **is** one service × environment entry, and
  the file is `root:guarden` (AGENTS: the registry, every `overrides.toml` and
  all of `/etc/guarden` are root-owned). The registry already carries
  post-spec tables written the same way — `route_destinations`, `[gate]`,
  `[immutable]`, `[generated]` — so `[exposure]` is one more of that class
  rather than a new surface. **Why not overrides.toml:** spec 3.3 closes it —
  six tables and "Nothing else is overridable" — so an `[exposure]` table there
  would be an invented one; **why not a `guarden.toml` table:** spec 3.1's
  table set carries none, and the per-environment track field is not
  per-service. Neither sanctioned surface fits a per-service record; the
  registry is the record surface the spec does sanction.
- **The verb:** `weedr expose set <name> <loopback|tunnel|public>` and
  `weedr expose unset <name>` — root-side, **on no sudoers rule**, in the
  table spec 5.1 gives for exactly this ("grant a public port → `weedr port
  open` → no"): no verb on the privileged surface carries a flag that widens
  authority, so the act is a verb and the values are arguments to one verb
  that never widens anything a deploy can reach.
- **Gated tracks only:** refusal `exit 2` naming the track, shaped like the
  other gate-adjacent refusals (spec 6.4 refuses a non-gated auth provider
  with the track named). `gated` is the track's own field (spec 3.1), so the
  rule is read from the root-owned track table and never from a name in code.
- **`tunnel` requires the module:** `weedr expose set <name> tunnel` is
  refused (exit 2) when `cloudflared` is not enabled, and resolution
  collapses a recorded `tunnel` to `loopback` anyway (ticket 293's fail-closed
  rule), so a module removal leaves a private service and a drift line rather
  than a unit that dials a tunnel that is not there.
- **A manifest requesting public is refused:** spec 4's closed key sets and
  its existing specific refusals (`environment:`, `track:`, `published_ports:`)
  — one more key, `exposure` (and `public`), refused **by name** with a message
  that says where the decision *is* recorded, the exact shape spec 4 demands
  for `environment`. Exit `2`, one line, `error:`.
- **Drift:** ticket 293's `soil --check` item — a recorded destination that no
  longer matches the current resolution is `drift:` naming the service. The
  item is reported and never corrected (spec 6.1's class for facts an operator
  owns): exposure moves through the verb, never through a converge.

## Vocabulary

The record speaks the operator's three values — `loopback`, `tunnel`,
`public`. The route slice and `route_destinations` keep the code's existing
three — `loopback`, `tunnel`, `edge` — because `edge` is what `roots`,
`firewall`, `share` and the existing suites already read, and **`public` maps
to `edge`**: the edge is the host's forwarded 80/443 ingress, and `weedr share
list` already refuses an edge-destination route with "the edge is public
already". One mapping, stated once here.

## What happens if it stays out

Reachability from the internet has no record at all: the default destination
`edge` publishes every new route, promotion and demotion happen by editing a
track or by installing a module, nothing distinguishes an operator's decision
from a side effect, and no check can tell an operator that a service they
believed was private has moved.

## What to build

1. Registry: `[exposure] value = "loopback" | "tunnel" | "public"`, written
   only by the two verbs; absent means "default" and that is a state, like
   `[gate]` being absent.
2. `weedr expose set/unset/list` (+ `--json` on list), HANDLERS entries, and
   the verbs named in weedr's epilog as *not on the guarden sudoers rule*.
   `set` on a non-gated track → exit 2 naming the track; `set tunnel` with cf
   absent → exit 2 naming the module; an unknown value → exit 2 listing the
   three.
3. Resolution precedence (ticket 293's resolver): recorded value > track
   `expose` > derived (`tunnel` if `cloudflared` else `loopback`), with
   `public` mapping to the `edge` destination and `tunnel` collapsing to
   `loopback` without the module. Setting/unsetting re-resolves the recorded
   `route_destinations` in the same act, so the verb changes exactly one
   record and nothing else is left stale.
4. Manifest refusal for `exposure` / `public` (top level and inside a block),
   one line naming where the decision is recorded.
5. Drift through `soil --check` (ticket 293's item).

## Known gaps (reported, not invented)

- **Per-port exposure is not offered.** The backlog's open question ("per
  service×environment, or per port/route of the service?") is answered here
  with the dispatch decision's granularity: one record per service per
  environment. A service that wants one public route and three private ones is
  not expressible; the per-label `[expose] tunnel` grant (spec 3.3) still
  exists for tunnel labels and is deliberately *not* widened by this ticket.
- **Promotion does not re-check ticket 292's auth.** The backlog asks whether
  exposing an unauthenticated service should be refused or warned. Basic auth
  is the default for every new service (292), so the case is "grandfathered
  service with no credential" — refusing there would strand the existing fleet,
  and no root-owned opt-out exists yet to reason about the converse. No
  coupling is built; the interaction stays an open question for the grilling
  that follows this wave.
- **Fork/instance inheritance is untouched**: an instance shares its service's
  registry, so it shares the record — stated, not decided anew; lineage is
  spec 8.3's and this ticket does not read it.

## What the implementation settled, and what the suite had to be taught

Two things were found while closing this ticket, and both are this ticket's
own claims rather than new features. They are recorded here because the next
reader of `exposure.py` and of `hostprep._exposure_offenders` needs them, and
because one of them is a property of the design that is not visible from the
code.

### A service that holds a record cannot drift

The drift item compares a service's **recorded** `route_destinations` with
what its exposure **resolves to now**. A service with a record always agrees
with itself: the record overrides the track (spec 3.4's projection rule — the
record is the authority), so the expected value is what the record says.

What moves underneath a service is the **default it was minted under** — the
track's `expose`, the enabled module set — and that is what the item
compares. So the drift is a service with **no record** whose recorded
destinations were minted under a default that has since moved. The first
version of the assertion tried to make a *recorded* service drift, and the
machine refused it: the suite was right and the assertion was wrong.

The offender is named in the line, in parentheses after the item's sentence
(`… (off: <service>)`), so the whole parenthesised list is what an assertion
names — a bare service name would pass on any other drift that happened to
mention it.

### The whole-host check is the wrong instrument for a per-item claim

The acceptance item says `soil --check`, which is every phase. The whole-host
form reaches the item (the firewall phase carries it) but its **exit code is
never the exposure item's exit code**: a throwaway machine that only ran
`soil install` reports the sysctl keys unset and the recurring units
uninstalled, so the whole-host check exits `1` for reasons that have nothing
to do with exposure. Measured on the cut: thirteen drift lines, none of them
the exposure item's.

`soil firewall --check` is the phase that owns the item, and its exit code is
that item's and no other's. The whole-host spelling is what an operator
types; the phase spelling is what the claim is measurable with.

## Status: verified

- [x] A fresh service with no record and no `cloudflared` renders
      loopback-only in every environment with zero config. Asserted by
      `tests/t452-tunnel-default.sh` (the derived default, fail-closed in both
      directions), by `tests/t451-exposure.sh` on a **slot** track (a service on
      a track that says `loopback` renders `loopback` with no record and no
      configuration), and on the **instance** track — the third environment, a
      preview service, whose slice is a different file at a different path and
      which the suite had not covered at all. The preview's `expose` row is
      **removed**, not pinned, because the claim is about the derived default:
      with the row gone the track says nothing and the module set is the only
      input left, so the service renders `loopback` or the claim is false.
- [x] `weedr expose set <service> public` on a gated track changes exactly one
      registry record; the next render/slice carries the `edge` destination,
      the edge router appears, and the edge uid accept appears on the route
      publication. `unset` reverses it. Asserted by
      `tests/t451-exposure.sh`, and the promotion had to be made **observable**
      first: the fixture pins `expose = "edge"` on every track, so a service
      created on that host already resolves to `edge` and a public promotion
      changed nothing an observer could see — the slice said `edge` before the
      act and `edge` after it. The production track is pinned to `loopback`
      **before** the service is created, so the record is the only thing on the
      box that can make the route public. The three consequences are then
      asserted as three: no router and no edge uid before, both after, and
      neither after the `unset`.
- [x] `weedr expose set <service> public` on `staging` (non-gated) is refused
      exit 2 naming the track; the record is unchanged. Asserted by
      `tests/t451-exposure.sh`.
- [x] A manifest carrying `exposure: public` is refused with one `error:`
      guarden line naming where the decision is recorded. Asserted at the top
      level **and** inside a block, both by name rather than by the generic
      closed-key-set line.
- [x] `soil --check` reports `drift` for a service whose recorded exposure no
      longer matches its current resolution. Asserted by
      `tests/t451-exposure.sh` through the phase that owns the item, with the
      offender's parenthesised list named, and with the check changing
      nothing — the act is the way back.
- [x] **The record is ONE service's**: a second service on the same gated
      track is never promoted with the first, and its publication holds no
      edge accept. A promotion that reached the track instead of the service
      would publish the whole environment.
- [x] Red first: `tests/t451-exposure.sh` (reserved range t450–t459).

### The three new assertions are mutation-tested

A green suite proves nothing until the assertion has teeth, and a mutation the
run cannot reach is a no-op. Each of the three was broken on the path the run
takes, and each turned the suite red with the failing line naming the
assertion:

| mutation | where | the suite went red at |
|---|---|---|
| the edge uid is not granted on an `edge` route | `firewall.accept_lines` | `50-services.conf does not name mod owner uid-owner 994 … jump ACCEPT;` |
| the edge router is not rendered for an `edge` route | `roots.render_service` | `…/edge/dynamic/routed-production.yml did not appear` |
| the derived default resolves to a tunnel nobody carries | `exposure._tunnel_or_loopback` | `a preview on a track with no posture rendered destination tunnel, not loopback` |
| the offender list is truncated to one | `hostprep._exposure_offenders` | `stderr does not name (off: routed-preview, routed2-production)` |

The last row is the one the instance-track assertion bought. The preview service
holds no record and was minted under a `loopback` track, so it is a second
offender beside `routed2-production` — and an assertion that named a bare
service would have passed on a check that reported one and dropped the other.
The whole sorted list is what is asserted.

### The runs

- `tests/t451-exposure.sh` — GREEN on `f2e52bb`, on `6a9e232`, and on `56f0f49`
  (the instance-track assertion added), each on a cut from the golden,
  `--no-cache`.
- The four mutation runs above — RED, each on its own cut, each reverted.
- `tests/t450-basicauth.sh`, `tests/t451-exposure.sh`,
  `tests/t452-tunnel-default.sh` — GREEN together on `56f0f49`, `--no-cache`,
  three cuts, zero failures: the exposure cluster and the basic-auth suite
  that shares the gate module.
