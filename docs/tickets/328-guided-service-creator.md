# 328 — `weedr service create` should ask the operator the questions and build the tree

Blockers: none. Found 2026-10-19 by the operator's critique of the manual
deployment path (the Bitcoin Knots walkthrough, where the operator had to
hand-write a service tree, a manifest and a quadlet because the CLI offers no
way to).

**This ticket was revised after two adversarial reviews of the design**
(`nous/longcat-2.5-preview-free` — NEEDS_IMPROVEMENT, one BLOCKER; and
`kilocode/step-5-free` — APPROVED with five completeness gaps). All six
findings were checked against the tree and all six were REAL; the corrections
are folded in below and each is marked with the review that found it.

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
which is item 4's subject restated.

And the operator's bar, verbatim:

> err on the side of security of simplicity. If CLI stays a bit more cumbersome
> because of that, it's ok

So the bar is NOT "is this convenient". The bar is: **does the design keep the
capability split intact, and is every added convenience worth the boundary it
spends?** A design that is more cumbersome but keeps the split is CORRECT. A
design that is convenient and spends a boundary is WRONG, however good it
feels. Two of the operator's own questions are therefore **dropped** below —
not because they were refused, but because asking them would offer a choice
that does not exist.

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

## The shape

**A mode of `weedr service create`, not a new verb and not a set of verbs.**
(review: kilocode F5, nous Q6.) `create` is root-only and off the sudoers
rule, so a mode of it is too, and the platform's doctrine — "a flag on a
granted verb would grant the capability with it" — does not apply to it
because it is not a granted verb. A separate program would be wrong: it would
need its own sudoers entry or its own root path, fragmenting the privilege
model.

The mechanism reuses what `create` already does: the template chooser
(`weedr.py:623-661`), the re-exec under sudo after the answers are gathered
(`weedr.py:601-605`), and `create_service` (`service.py:470-537`).

**What is genuinely NEW** (review: nous F5): **the manifest.** The existing
`create` copies a template's quadlet files and writes a registry record; it
writes no `.guarden/service.yml`. The guided creator writes one — with
`state:`, `bulk:`, `ports:`, `firewall:`, `provides:` and `schema:`. That is
a capability `create` does not have today, and the implementer should know
they are adding it rather than only reusing `create_service`.

**The quadlet the creator writes is a STARTING POINT, not the final file.**
The renderer owns `PublishPort=` and `Network=` outright (`render.py:83-102`,
`OWNED_KEYS`) and overwrites them; it also resolves the volumes, the
credential lines and the publication. So the creator's quadlet is what the
operator asked for, and the renderer's version is what runs. (review:
kilocode F1.)

## What to build

A guided path that asks and then writes:

1. **Identity**: service name, environment/track, image, tag, and the
   `provides:` kind — one of the six legal ones (`db`, `secret`, `bitcoin`,
   `nbxplorer`, `btcpay`, `nostr`; `manifest.py:124`). A service with no
   `provides:` cannot be reached by any other service, so a creator that does
   not ask for the kind produces a dead end — the exact thing the operator was
   trying to avoid.
2. **The container's shape**: which ports the service wants, whether it wants
   a firewall rule, what volumes it wants (snapshotted `state:` vs `bulk:`).
3. **Credentials**: whether to set a secret, and which keys.
4. **The start**: whether to start it now, and — if so — the verification.

### The port question — ONE number, two meanings (review: nous F1, BLOCKER)

The `ports:` entry's `port:` is **both the container's own port and the public
port requested for it** — one number, two meanings, because a grant is a
translation from the public port to the container's port and a peer-to-peer
service exposes them the same (spec.md:1571-1575). So
`ports: [{ container: web, port: 8080 }]` asks for public port 8080 to reach
container `web`, and `weedr port open <name> 8080` matches that entry by the
number.

**The creator asks for ONE number per port.** (An earlier draft of this
ticket said two, which is what the review caught: the implementation would
have asked for two numbers or written the entry wrong.)

### The network question — DROPPED (review: nous F3, kilocode F1)

The operator asked "which network I want to attach to". **There is exactly one
legal answer**: the renderer owns `Network=` (`render.py:87`), refuses any
value that does not start with `pasta:` (`render.py:675-681`), and writes the
value from the `[network]` table in `guarden.toml`. Asking the question
offers a choice that does not exist, and an operator who answers "bridge"
gets a refusal from a later phase.

So the creator does not ask. It may **state** the network it will use
("the network is `pasta:`, from the host's `[network]` table"), which is
information rather than a false choice. This is the operator's own "err on
the side of simplicity" applied: the question is dropped, not answered.

### The pull (review: nous F2, kilocode F3)

The image pull starts in the background **as soon as the image and tag are
known**, not at the end, and it runs as the service user through the same
`_podman()` the probe and the build verb use (`service.py:1653-1681`).

**If the CLI is exited, the pull is aborted.** The abort sequence is: SIGTERM
the pull process, wait for it, then reclaim the space. And the honest reason
for the cleanup, which an earlier draft of this ticket got wrong:

- **The abort cannot be guaranteed.** A SIGKILLed CLI cannot abort a process
  it no longer controls, so the pull may be orphaned and keep running. The
  design should say so rather than promise what it cannot deliver.
- **"The partial image is deleted" is not a podman operation.** A partially
  pulled image is never committed, so `podman rmi` does not find it. The
  layers are unreferenced blobs in the service's store, and there is no
  targeted "delete this half-pulled image" operation — `podman system prune`
  reclaims them but prunes all unused layers, not just this pull's.
- **"A later start would find it and use it" is FALSE.** A half-pulled image
  is not a runnable image; podman cannot create a container from it. The start
  would fail its inspect, pull again, and only then run.

So the real cost of an uncleaned pull is **disk space, not correctness or
safety**. The mechanism is still worth having — an orphaned pull is a process
the operator did not ask to keep running — but it is justified by disk and by
tidiness, not by a hazard that does not exist.

### The verification (review: nous F4, kilocode F4)

When the operator says start, the CLI verifies. **Three checks, all
well-defined:**

1. the unit is active — `systemctl --user --machine <name>@ is-active <unit>`;
2. the container is running — `podman ps --filter name=<container>` returns a row;
3. the publication is listening — `ss -tln` shows the allocated loopback port
   in `LISTEN`.

**A fourth check — "the service answers" — is NOT in scope.** There is no
general way for the CLI to know that an arbitrary image is serving: an HTTP
service answers with a 200, a database with a connection, a Bitcoin node with
a protocol handshake. Without a per-service probe specification the check is
either unimplementable or a false positive — and a false positive here is the
exact failure the verification exists to catch, so a stub check is worse than
none. An operator who wants an application-level probe asks for one, as a
separate thing.

**The two failure modes the checks must not have:** reporting "started" for a
container that is running but not serving, and treating a loopback
publication as if it were open to the world.

## The security question, answered from the code

**Does this create issues with the security model? Partly — and the parts are
knowable, so this is not a blocker.**

The three properties that make the model work, and what this feature does to
each:

1. **"A sudoers rule cannot tell one argument from another, so a flag on a
   granted verb would grant the capability with it."** (weedr.py:5) — the
   granted verbs are granted *whole*. A guided creator that took the image,
   the ports and the firewall rule as **flags on a granted verb** would be
   exactly the shape this rule forbids. It is not: the creator is a mode of
   `create`, which is root-only and off the rule, so the rule does not apply
   to it at all.

   **The flow, stated correctly** (review: nous F6): the questions are asked
   by the **non-root** process — the prompting happens before `_become_root`
   is called (`weedr.py:598-600`) — and the root half receives the
   already-validated answers as arguments (`weedr.py:601-605`). An earlier
   draft of this ticket said the questions are "asked by a root verb", which
   inverted the flow. The mechanism was right; the wording was not.

2. **The firewall is a request/grant split, and the grant is the operator's
   separate act.** A manifest *asks* for a rule; `weedr firewall open` and
   `weedr port open` are **root and on no sudoers rule** (firewallrules.py:4,
   ports.py:36-62), so nothing that answers a push can reach them. A guided
   creator that asked "do you want a ferm rule?" and then **granted it in the
   same breath** would collapse that split — the request and the grant become
   one act.

   **So the creator RECORDS the request in the manifest, and the grant stays a
   separate verb the operator runs afterwards.** The creator must **not**
   invoke `weedr port open` or `weedr firewall open` on the operator's
   behalf — it **prints the commands** the operator needs to run. (review:
   nous Q2/Q3.) The same holds for a public port.

3. **A secret is planted with the terminal's echo off and lives in a
   root-owned blob** (`weedr secret set`), and the materialiser is what puts
   it in the service's store. The creator asking "do you want to set a
   secret?" is safe **iff** the value is still read at the terminal with the
   echo off. The creator calls the existing `weedr secret set`; it does not
   reimplement it, and it accepts no secret on a command line, in a flag, or
   in a file.

   **The mechanism, stated explicitly** (review: kilocode F6):
   `credentials.prompt()` reads from **stdin** when stdin is not a terminal
   (`credentials.py:334-341`), so a creator that asks for a secret in a
   pipeline would take the value from a pipe — where there is no echo to turn
   off, because whatever produced the pipe already had the value in the
   clear. **The creator must check `sys.stdin.isatty()` before reading a
   secret value**, exactly as the template chooser does (`weedr.py:641-645`),
   and refuse with one line when it is not a terminal.

**Verdict: the feature is compatible with the security model, with three
constraints carried into the implementation:**

- the questions are asked at the terminal, unprivileged, and the answers reach
  a root-only verb that is off the sudoers rule;
- the creator records what the service ASKS for, and the operator's grant of a
  public port or a firewall rule stays a separate act — the creator prints
  the commands, it does not run them;
- a secret is read only at a terminal, with the echo off, through the
  existing verb.

None of the three is a reason to hold the ticket back. **Queue it.**

## The validation that makes it safe, and where it is checked

Every value the operator types is checked against a closed pattern before it
is written, and no value reaches a granted verb:

| value | checked against | where |
|---|---|---|
| service name | `^[a-z0-9][a-z0-9._-]*$`, no `..` | `names.py:34, 49-60` |
| volume names | `^[a-z0-9][a-z0-9._-]*$` | `manifest.py:105, 349-360` |
| secret keys | `^[A-Za-z_][A-Za-z0-9_]*$` | `credentials.py:57, 68-73` |
| image reference | podman validates the reference; it is an argument, never a path | `service.py:1468` |
| ports | a number in range, written as a manifest entry; the renderer owns `PublishPort` | `manifest.py:126-127` |
| network | **not asked** — the renderer owns it | `render.py:87, 675-681` |

## Notes

- The existing `examples/services/*` templates become the *starting points*
  the creator fills in, rather than the finished artefacts they are now.
- The `provides:` kind question matters more than it looks: a service with no
  `provides:` cannot be reached by any other service, so a creator that does
  not ask for it produces a service that is a dead end — which is the exact
  thing the operator was trying to avoid when they asked for this.
