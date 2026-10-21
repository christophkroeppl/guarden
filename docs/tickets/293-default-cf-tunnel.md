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
  (review-exposure.out finding 1). **The correction was made in `5efe4f6`,
  which is on `develop`;** this branch re-states the fact rather than making
  the change a second time.
- Tunnel hostnames are still allocated by nobody (the backlog's open question;
  carried as ticket 324):
  `roots` publishes a route to whatever host the mutator allocated in
  `host.domain`; the tunnel zone (`[ingress] tunnel_domain`) is only used for
  previews. Per-service hostnames inside the CF zone are not part of this
  ticket.

## Status: fixed

- [x] With `cloudflared` enabled, a newly created service's slice says
      `destination = "tunnel"` and the tunnel ingress file carries its host,
      with no manifest change and no host-facing bind.
- [x] With `cloudflared` absent, a newly created service resolves
      `destination = "loopback"`: no edge router file, no edge uid accept on
      its route publication (fail-closed).
- [x] A track that says `expose = "tunnel"` on a box without the module
      resolves to `loopback` rather than rendering a tunnel nothing reads.
- [x] `soil --check` reports `drift` when a recorded destination no longer
      matches the current resolution.
- [x] Red first: `tests/t452-tunnel-default.sh` (reserved range t450–t459).

## What was already there, and what was missing

**The implementation was merged before this card was worked**, and the card's
own acceptance list was never checked. The work is therefore in the two
directions the repository insists on: the evidence, and the coverage.

**What was already on `develop`:**

- `69e8b2d` — the whole of "What to build": `TRACK_DEFAULTS["expose"]` unset,
  the value set `loopback|tunnel|edge` with the empty value accepted and
  anything else refused naming the track, `guarden.exposure.resolve()` as the
  one resolver, `service._allocate` and `render._routes` and
  `firewall.accept_lines` and `roots.render_service` reading it, the shipped
  `templates/guarden.toml` no longer pinning `expose = "edge"`, and the
  `soil firewall --check` drift item.
- `ce4bbff`, `837abaf`, `ccea9f3` and the `59c4489` merge — the fail-closed
  corrections and the record-as-authority reading, which are 293's rules as
  much as 294's.
- `tests/t452-tunnel-default.sh` — the behaviour suite, covering the four
  acceptance items above.

**What was missing, and is what this branch adds:**

1. **Two of the seven "What to build" items had no suite at all.** t452
   measures the DERIVED DEFAULT — a track that says nothing, a module set
   that answers — and a suite that says nothing about `expose` never
   exercises the field's own rules. So **the value set** (item 1: a track
   whose `expose` is a word the field does not carry is refused naming the
   track) and **the shipped table** (item 6: the file a fresh host is given
   states no posture) were both unmeasured. `tests/t453-expose-validation.sh`
   measures them.
2. **The RED had never been observed.** The implementation's own commit
   message quotes a RED line, but nothing recorded a run. The RED below is
   measured, and it is measured on the SOURCE and not on the test.

## The two uncovered claims, and why they are worth a suite

**The value set is a refusal, and a refusal nobody exercises is a guess.**
A field that accepted any word would make "the track states a posture" a
claim with no meaning — and a typo (`exose = "edge"`) would resolve as a
track that says nothing, which is the fail-closed answer: a private service
on a host the operator believed was public. The refusal is what makes the
typo loud, so it is the thing under test. t453 also asserts the
counter-example — a track that says `edge` is ACCEPTED and its route is
rendered into the edge — because a suite that only asserted refusals would
be green against a field that refused everything.

**The shipped table is what every fresh host is given.** A template that
pinned `expose = "edge"` would put every new service on the internet on a box
that never asked for it, and the file is written by `soil install` on a host
that has no table yet — so the claim is only measurable in that shape. t453
removes the table, lets the install seed it, and reads the posture off the
file the host ended up with rather than off the template in the checkout.

## The RED, verbatim, before the fix

**The revert is of the SOURCE and not of the test.** The two files 293
changed are put back to their pre-293 state and the tree is left otherwise
alone:

```
$ git checkout 69e8b2d^ -- src/guarden/config.py src/guarden/templates/guarden.toml
```

**The behaviour suite's own RED** — `t452-tunnel-default.sh`, the suite the
ticket's last acceptance item names, measured on the same revert:

```
$ GUARDEN_LXC_RUNNER=guarden-run-t293 timeout 1800 tests/lxc.sh run t452-tunnel-default --no-cache
sha: 38ad2356357aa031ec3f88de6ffc583d5ebfd410 (SOURCE REVERTED to 69e8b2d^, tests kept)
error: without the cloudflared module a new service rendered destination edge, not loopback
error: failed at line 57: return 1 (exit 1)
FAIL t452-tunnel-default.sh
error: t452-tunnel-default.sh exited 1; the suite stopped on an assertion, and its own line is above
1 suites: 1 ran, 0 inherited, 1 failures, 1 machines cut
note: --no-cache: all 1 suites ran and every result was recorded
```

**The diagnostic names the defect**, and it is the same line the
implementation's own commit message quoted — quoted, but never recorded as a
run. The pre-293 default was `edge`, so a new service on a host with no
`cloudflared` module was published on the internet by being created.

**The first half — the value set:**

```
$ GUARDEN_LXC_RUNNER=guarden-run-t293 timeout 1800 tests/lxc.sh run t453-expose-validation --no-cache
sha: 38ad2356357aa031ec3f88de6ffc583d5ebfd410 (SOURCE REVERTED to 69e8b2d^, tests kept)
error: stderr does not name loopback
error: failed at line 216: return 1 (exit 1)
FAIL t453-expose-validation.sh
error: t453-expose-validation.sh exited 1; the suite stopped on an assertion, and its own line is above
1 suites: 1 ran, 0 inherited, 1 failures, 1 machines cut
note: --no-cache: all 1 suites ran and every result was recorded
```

The diagnostic names the defect: the pre-293 field said "it must be 'edge' or
'tunnel'", so a refusal never named `loopback` — the value the ticket added
was a value the old field did not have.

**The second half — the shipped table** was measured on its own, with the
same revert in place, so the two claims are separately RED rather than one
of them carrying the other:

```
$ GUARDEN_LXC_RUNNER=guarden-run-t293 timeout 1800 tests/lxc.sh run t453b-shipped-table --no-cache
error: //etc/guarden/guarden.toml names expose = and should not
error: failed at line 329: return 1 (exit 1)
FAIL t453b-shipped-table.sh
1 suites: 1 ran, 0 inherited, 1 failures, 1 machines cut
```

(`t453b-shipped-table.sh` was the second half on its own, and it is **not** in
the tree: it was a measurement aid, and the claim it measured is the second
block of `t453-expose-validation.sh`, which is the file that shipped. The
file was deleted after the run, and `t453-expose-validation.sh` is the one
that is in the tree and is green below.)

**The source is then restored with `git checkout HEAD --` on the same two
files.**

## The GREEN, verbatim, with the fix

```
$ GUARDEN_LXC_RUNNER=guarden-run-t293 timeout 3000 tests/lxc.sh run t45 --no-cache
sha: 38ad2356357aa031ec3f88de6ffc583d5ebfd410
ok   t450-basicauth.sh
ok   t451-exposure.sh
ok   t452-tunnel-default.sh
ok   t453-expose-validation.sh
4 suites: 4 ran, 0 inherited, 0 failures, 4 machines cut
note: --no-cache: all 4 suites ran and every result was recorded
```

**The suites that had to stay green** — the exposure cluster and the three
that read the same tables:

| suite | what it pins | result |
|---|---|---|
| `t450-basicauth` | ticket 292's default login, the cluster's other half | ok |
| `t451-exposure` | ticket 294's record, the verbs and the refusals | ok |
| `t452-tunnel-default` | ticket 293's derived default | ok |
| `t453-expose-validation` | the value set and the shipped table | ok |
| `t220-tendril` | a track's `expose = "tunnel"` and the `[expose] tunnel` grant | ok |
| `t220-share` | the share issuance, which refuses an edge-destination route | ok |
| `t220-ssh-guard` | the host's SSH accept, in the same firewall file | ok |
| `t30-config` | the environment table's own refusals, beside the new one | ok |

**Every one of these ran on a real machine, cut from the golden, with the
real tools.** No suite was inherited from the cache: the runs used
`--no-cache`, and the lines above say "0 inherited".

## A finding the suite produced, which is worth stating

**The refusal names the track that carries the bad value, not the track of
the service being deployed.** t453 stages a table whose `production` row
carries `expose = "public"` and deploys a service on `staging`; the refusal
names `production`. That is correct — the table is read whole, and a table
with a bad row in it is refused whole, because the next service created
against it would resolve against it — and the suite asserts it. The first
draft of the suite asserted the opposite shape (the value on the deployed
track) and went red on it, which is how the shape was found. The code was
not changed for it: the behaviour is right, and the test was wrong.

**`public` is refused by this field, and that is deliberate.** `public` is
ticket 294's OPERATOR's word, and it is a value of the per-service RECORD
(`[exposure] value`), not of the track's `expose` field. A track that says
`public` is a track that says something the field does not carry, and the
refusal says so.

## Deliberately not changed

- **`docs/spec.md`** — spec 3.1's track-field list, 3.3's overrides sentence,
  3.4's registry example and 10's module set already state the derived
  default. The correction the ticket's "Known gaps" asked for was made in
  `5efe4f6` ("docs(spec): 292-294 — state the exposure cluster in the
  contract"), in the same change that made the code behave that way, and it
  is not re-made here.
- **`src/guarden/**`** — nothing under `src/` is changed by this branch. The
  implementation was already on `develop` and was already correct; what was
  missing was the measurement of two of its claims.
- **`fixtures/guarden.toml`, `fixtures/guarden-nomodules.toml`,
  `fixtures/guarden-measured.toml`** — these pin `expose = "edge"` on
  purpose: the suites that use them exercise the public posture explicitly.
  A suite that wants the derived posture removes the rows, and t452 does.
- **The tunnel hostname gap** (ticket 324) — carried out of this ticket's
  "Known gaps" so that merging the exposure cluster does not erase it, and
  `t452` measures it exactly: the ingress hostname is asserted as a WHOLE
  LINE, so a future zone-qualified name has to change the assertion on
  purpose.
