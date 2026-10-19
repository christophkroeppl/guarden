# 328 — `weedr service create` should ask the operator the questions and build the tree

Blockers: **none, but the security question below has to be answered in the
ticket, not in the implementation.** Found 2026-10-19 by the operator's
critique of the manual deployment path (the Bitcoin Knots walkthrough, where
the operator had to hand-write a service tree, a manifest and a quadlet
because the CLI offers no way to).

## What the operator asked for

> 1: build the service tree. This should be doable through weedr. I want CLI to
>    ask me about service name, environment, image, tag and create tree and
>    files from provided values and templates.
>
> 2: Quadlet — same. I want to be asked which ports I want to expose, which
>    network I want to attach to, if I want to add a ferm rule, etc.
>
> 3: CLI should also ask me if I want to set a secret and at the end of all of
>    it: if I want to start the service right away. Pulling of container should
>    start in the background as soon as image & tag has been set. If CLI is
>    exited, pull gets aborted and deleted.
>
> 4: verification should be done automatically if start has been selected by
>    user in cli.
>
> 5: should also be done by cli

**5** is read as: the verification is the CLI's job too, not the operator's —
which is item 4's subject restated. Items 1–4 are one feature: a guided
creator.

## Why it matters

Today the manual path is a wall of hand-written files. A real deployment of a
third-party image took **twelve steps the operator had to know by heart**:
mkdir the tree, write `.guarden/service.yml`, write the quadlet, plant the
secret, start the credential materialiser, `weedr service add --from …`, start
it, and then verify by hand. The `deploy-fresh-manual-fleet.md` record of the
six-service fleet even names commands (`weedr service set-image`,
`weedr service set-env`) that **do not exist in the codebase** — the
deployment worked, but the document that claims to describe it is fiction.

`weedr service create` exists and takes a `--template`, but the templates
carry a *file* and nothing else: "A template declares no `state:` and no
`bulk:`, so guarden creates no subvolume and no snapper configuration for it"
(examples/services/postgres/postgres.container). The operator picks a template
and gets a service with no manifest — so it cannot `provide:` anything, so
**nothing can reach it** and the operator writes the manifest by hand anyway.

## What to build

A guided path — one verb, or a set of verbs that compose into one — that asks
and then writes:

1. **Identity**: service name, environment/track, image, tag. Produces
   `.guarden/service.yml` (with `project:`, `units:`, and a `provides:` kind
   the operator picks from the six legal ones: `db`, `secret`, `bitcoin`,
   `nbxplorer`, `btcpay`, `nostr`) and the quadlet with the image and tag
   filled in.
2. **The container's shape**: which ports to publish, which network to attach
   to, whether to ask for a ferm rule, what volumes the service wants
   (snapshotted `state:` vs `bulk:`), and what it provides.
3. **Credentials**: whether to set a secret, and which keys.
4. **The start**: whether to start it now, and — if so — the verification.

### The pull (item 3's second half)

The image pull starts in the background **as soon as the image and tag are
known**, not at the end. If the CLI is exited, **the pull is aborted and the
partial image is deleted** — a half-pulled image in the service's store is
state nobody asked for, and a later `start` would find it and use it.

### The verification (items 4 and 5)

When the operator says start, the CLI verifies it: the unit is active, the
container is running, the publication is listening, and the service answers.
That is the same evidence the manual fleet record had to gather by hand, and
it is exactly the evidence a future `weedr service status` reports.

## The security question, answered from the code

**Does this create issues with the security model? Partly — and the parts are
knowable, so this is not a blocker.**

The three properties that make the model work, and what this feature does to
each:

1. **"A sudoers rule cannot tell one argument from another, so a flag on a
   granted verb would grant the capability with it."** (weedr.py:5) — the
   granted verbs are granted *whole*. A guided creator that takes the image,
   the ports and the firewall rule as **flags** would be exactly the shape
   this rule forbids: one granted verb that can open a port, write a ferm
   rule and set an image is a capability bundle, and a sudoers rule cannot
   narrow it. **So the questions must be asked interactively, at the
   terminal, by a root verb — not as flags on a granted verb.** That is
   already how `create` works (it re-execs under sudo *after* the answers are
   gathered, weedr.py:532-560), so the feature fits the existing model
   rather than bending it.

2. **The firewall is a request/grant split, and the grant is the operator's
   separate act.** A manifest *asks* for a rule; `weedr firewall open` and
   `weedr port open` are **root and on no sudoers rule** (firewallrules.py:4,
   ports.py:36-62), so nothing that answers a push can reach them. A guided
   creator that asked "do you want a ferm rule?" and then **granted it in the
   same breath** would collapse that split — the request and the grant become
   one act, and the grant stops being a separate decision. **The creator may
   RECORD the request in the manifest; the grant stays a separate verb the
   operator runs afterwards.** The same holds for a public port: the creator
   may record `ports:`, and `weedr port open` stays the act that publishes it
   to the world.

3. **A secret is planted with the terminal's echo off and lives in a
   root-owned blob** (`weedr secret set`), and the materialiser is what puts
   it in the service's store. The creator asking "do you want to set a
   secret?" is safe **iff** the value is still read at the terminal with the
   echo off — the creator must not accept a secret on a command line, in a
   flag, or in a file the operator then has to delete. The existing
   `weedr secret set` already does it correctly; the creator should call it,
   not reimplement it.

**Verdict: the feature is compatible with the security model, with two
constraints carried into the implementation:**

- the questions are asked at the terminal by a root verb, never as flags on a
  granted verb;
- the creator records what the service ASKS for, and the operator's grant of a
  public port or a firewall rule remains a separate act.

Neither constraint is a reason to hold the ticket back. **Queue it.**

## Notes

- The `provides:` kind question matters more than it looks: a service with no
  `provides:` cannot be reached by any other service, so a creator that does
  not ask for it produces a service that is a dead end — which is the exact
  thing the operator was trying to avoid when they asked for this.
- The port question has to distinguish the container's own port (what the
  quadlet publishes) from the public port (what `weedr port open` grants) —
  the two are different numbers, and the spec is explicit that `port:` under
  `ports:` is the container's.
- The existing `examples/services/*` templates become the *starting points*
  the creator fills in, rather than the finished artefacts they are now.
