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
(src/guarden/templates/services/postgres/postgres.container). The operator picks a template
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

- The existing `src/guarden/templates/services/*` templates become the *starting points*
  the creator fills in, rather than the finished artefacts they are now.
- The `provides:` kind question matters more than it looks: a service with no
  `provides:` cannot be reached by any other service, so a creator that does
  not ask for it produces a service that is a dead end — which is the exact
  thing the operator was trying to avoid when they asked for this.

## IMPLEMENTED

Implemented on `develop`, uncommitted. The guided mode is `weedr service
create --guided`, and it is a **mode of the existing verb** — `create` is
root-only and off the sudoers rule, so a mode of it is too, and the platform's
doctrine does not apply to it because it is not a granted verb.

### What was built

| file | what it holds |
|---|---|
| `src/guarden/creator.py` | the questions, the validation, the tree writer, the background pull and its abort, the three verification checks |
| `tests/test_creator.py` | 44 unit tests: the patterns reject bad values, a non-TTY is refused, no secret material reaches the tree, no granting verb is called, the manifest parses, the two halves are told apart |
| `tests/t133-guided-create.sh` | the VM suite: the prompts driven through a pty, the tree, the manifest, the rendered unit, the request/grant split, the three checks |
| `tests/pty-drive.py` | a stdlib pty driver, so a suite can type answers into a program that insists on a terminal |
| `src/guarden/weedr.py` | the wiring: `--guided`, `--tree`, `--plant`, `--start`; `_create_guided` (the half that asks) and `_create_guided_root` (the half that creates) |
| `src/guarden/service.py` | `Source` gained a `tree` kind, so the mutator reads a tree the creator wrote |

**The flow is the one the ticket specifies.** The questions are asked by the
**NON-ROOT** process, before `_become_root` is called: `_create_guided` gathers
and validates every answer at the operator's terminal, writes the tree, and
then re-execs as root with the answers travelling as arguments. The root half
(`_create_guided_root`) receives an already-well-formed request and creates the
service from the tree. The design's earlier draft inverted this; the
implementation does not.

**The creator RECORDS what the service asks for.** The manifest carries
`ports:` and `firewall:` as requests, and the creator **prints** the commands
`weedr port open <name> <port>` and `weedr firewall open <name> <rule>` for
the operator to run by hand. It calls no granting verb — the unit test asserts
this by searching the module's own source for a call, not by a mock's call
log. The request/grant split survives.

**A secret is read at a terminal, with the echo off, through the existing
`credentials.prompt()`.** `creator.read_secret` checks `sys.stdin.isatty()`
*before* reading anything and refuses with one line when stdin is not a
terminal; the value then goes through `credentials.plant()` into the
root-owned encrypted blob. The tree carries the credential's NAME (in the
`.guarden/.env.schema` shape) and never a value — the `Secret` dataclass has
one field, so there is nowhere for a value to live.

**The network is not asked.** The renderer owns `Network=` and refuses anything
that is not `pasta:`; the creator states nothing about it and the rendered unit
carries `Network=pasta` because the renderer wrote it.

**One port number per port, two meanings.** The creator asks for
`container:port` and writes one `ports:` entry per answer. The renderer owns
`PublishPort=`, so the creator's own unit carries no `PublishPort=` at all —
the VM suite asserts the absence, and asserts the *rendered* unit carries the
loopback publication.

**The pull starts in the background as soon as the image and the tag are
known** — before the remaining questions are asked. On the way out (exception,
refusal or Ctrl-C) it is aborted: SIGTERM, wait, then kill-and-wait.

**The verification is exactly three checks**: the unit is active
(`systemctl --user --machine <name>@ is-active <unit>`), the container is
running (`podman ps --filter name=<container>`), and the publication is
listening (`ss -tln` shows the allocated loopback port in LISTEN). There is no
fourth check.

### The measured output

`just lint` — **All checks passed!**
`just unit` — **Ran 78 tests, OK** (44 of them in `tests/test_creator.py`).

**From the VM (`tests/t133-guided-create.sh`, on the golden VM) — the suite is
GREEN:**

```
MEASURE: the installed template set: postgres vaultwarden
MEASURE: a non-terminal is refused: error: the guided creator needs a terminal; stdin is not one, so it is refused
MEASURE: the guided run exited 0
MEASURE: the creator wrote the manifest
MEASURE: the creator wrote the unit: web.container
MEASURE: the tree carries no credential material
MEASURE: the ports before the grant: SERVICE              REQUESTED             GRANTED               PENDING
guidedprobe-staging  8080                  none                  8080
MEASURE: the port is requested and not granted, which is the split
MEASURE: the service home holds:  /home /home/.config /home/.config/containers /home/.guarden /home/.guarden/service.yml /home/.guarden/quadlet /state /state/data /state/data/.snapshots /bulk
MEASURE: the units it installed: 2
MEASURE: the rendered unit: /var/lib/guarden/services/guidedprobe-staging/home/.config/containers/systemd/web.container
MEASURE: the rendered unit carries the image
MEASURE: the rendered unit carries the loopback publication
MEASURE: the rendered unit carries the pasta network
MEASURE: the unit state before the start: inactive
MEASURE: the start: started guidedprobe-staging
MEASURE: the allocated publication: 20000
MEASURE: the publication is listening on 20000
MEASURE: the port is requested and not granted, which is the split
MEASURE: the probe service is removed
ok   t133-guided-create.sh
```

The `port list` line is the request/grant split, measured by the host: the
port is in the **REQUESTED** column and the **GRANTED** column says `none`.
The `rendered unit` lines are the renderer's own output — the creator's unit
carried no `PublishPort=` and no `Network=`, and the rendered one carries
both. The `publication is listening` line is the third verification check,
answered by `ss -tln` on the allocated loopback port.

**The tree the creator writes, and what the renderer makes of it:**

```
provides:
- db
ports:
- container: web
  port: 8080
state:
- data
```

```
[Container]
Image=docker.io/library/postgres:17-alpine
ContainerName=web
Volume=/…/state/data:/var/lib/data
Secret=DB_PASSWORD,type=mount
```

### The divergences from this ticket's design

Every one of them is listed, because a silent divergence is worse than a
smaller feature.

1. **The creator does not use the shipped templates as its starting point.**
   The ticket's Notes say the templates "become the starting points the
   creator fills in". The implementation writes a quadlet of its own
   (`Image=`, `Description=`, and the volume mounts) rather than copying
   `src/guarden/templates/services/<name>/*.container` and editing it. The
   reason: a template's unit carries a `PublishPort=`, a `Volume=` and a
   `Secret=` that are the RENDERER's to own, and filling a template in would
   mean either dropping those keys (so the copy is not the template) or
   keeping them (so the tree is a template with the renderer's own keys
   pre-set). **The templates are still installed and still used by the
   non-guided `create --template` path** — they were not changed.

2. **The creator does not choose a template at all.** The ticket's flow has
   the creator reusing "the template chooser" (`weedr.py:623-661`). The
   implementation asks for the image and the tag instead, because the operator
   named the image in the request ("I want CLI to ask me about service name,
   environment, image, tag"). A template is a starting point for a
   particular image; asking for the image directly asks for the thing the
   operator actually wants.

3. **The pull runs as the CALLER, not as the service user.** The ticket says
   the pull "runs as the service user through the same `_podman()` the probe
   and the build verb use". The implementation's `pull_background` runs
   `podman pull` as the process's own user by default, and only as the service
   user when a service name is passed (`runuser -u <name> -- env USER=…
   LOGNAME=… podman pull`). In the guided flow the pull starts BEFORE the
   service exists, so there is no service user to run it as — the service is
   created later, by the root half. **Consequence: the image lands in the
   calling user's podman store, not in the service's own store.** The service
   pulls it again into its own store on its first start. This is a real
   divergence and it costs a second pull; the alternative (deferring the pull
   until after the service exists) contradicts the ticket's own requirement
   that the pull start "as soon as image+tag are known".

4. **The abort does not reclaim disk, and the docs say so.** The ticket's own
   analysis says "delete the partial image" is not a podman operation and the
   real cost is DISK. The implementation's `abort_pull` stops the process and
   waits for it; it does **not** run `podman system prune` (which would prune
   every unused layer on the box, not just this pull's) and it does not
   `podman rmi` (which would not find a half-pulled image, because a
   half-pulled image is never committed). The cost of an uncleaned pull is
   therefore disk, exactly as the ticket's analysis concluded. The abort
   cannot be guaranteed against a SIGKILL, and nothing here claims it is.

5. **The three checks are run by the root half, after the start, and their
   result is PRINTED — it does not change the exit code.** The ticket says
   "verification should be done automatically if start has been selected by
   user in cli", and the ticket lists the three checks; it does not say what a
   failed check does to the exit code. The implementation reports each check
   with `ok`/`FAIL` and the run still exits `0`, because the service WAS
   started and the checks are a report about the host rather than a refusal
   of the work. **This is the one place where a reader could reasonably want
   the opposite**, and it is a deliberate choice rather than an oversight.

6. **The `provides:` kind is asked but is not required.** The ticket says a
   creator that does not ask for the kind produces a dead end. The creator
   asks, and an operator who answers "none" gets a service with no
   `provides:` — the question is asked, and the answer is honoured. Forcing
   one would refuse a service nothing needs to reach.

7. **The tree is written by the unprivileged half, into a directory the
   operator chose (`--tree`, defaulting to `./<name>`).** The root half then
   reads it from that path. The ticket does not say where the tree lives. A
   tree in the operator's own directory is readable by the operator and
   editable before it is deployed, which is what "a starting point" means —
   but it also means the root half reads a path the caller named, so the
   tree's contents are the caller's input and are validated by
   `manifest_mod.read()` before anything is created. The creator refuses a
   tree that already holds something.

8. **The service is created by `service.create` with a `tree` source, not by
   `service.create_service` (the template path).** `create_service` copies a
   template's quadlet files and writes no manifest; the guided mode needs a
   manifest, and the manifest is what the ticket calls "genuinely NEW". So
   `service.Source` gained a third kind — `tree` — whose `directory()` is the
   path the creator wrote. `service._project_from` returns `""` for it: a tree
   belongs to no registered project, so the manifest's own `project:` is what
   the record carries.

9. **The environment is taken from `--env` and is NOT asked.** The ticket's
   "Identity" step lists "environment/track" as something the creator asks
   for. The implementation reads it from the existing `--env` flag (default
   `production`) and validates it, rather than asking a second time — the
   flag is the verb's own answer to that question, and asking both would
   offer two answers to one question.

10. **The tree is STAGED before it is rendered.** The renderer runs as
    `guarden` (`loom` is handed the tree as `guarden`, ADR-0012), and the
    tree the operator wrote is in their own home — `/root` is `0700` — so a
    tree handed to the renderer as it stands is a tree the renderer cannot
    enter. `creator.stage_tree` copies the render inputs into a root-owned
    `0755` directory and the copy is this invocation's own, so it goes away
    with it. This is the same staging a poke's tree has always had
    (`hose.py:unpack` writes `0755` and `0644` for the same reason).

11. **The two halves are told apart by `--plant`/`--start`, and not by the
    privilege.** The unprivileged half asks and writes; the root half
    creates. The re-exec carries `--plant` (always, even with no key) and
    `--start`, and those flags are what the root half is recognised by.

    **This was a real defect, and the VM suite caught it.** The dispatch was
    first keyed on "the tree exists and we are root" — and the creator
    MAKES the tree directory, so the root half ran on an empty tree and
    refused with "the tree carries no .guarden/service.yml" without ever
    asking a question. The suite's `MEASURE: the guided run exited 1` is
    what found it. `tests/test_creator.py:DispatchTest` now pins the
    dispatch, and the reasoning is in the code where the bug was.

12. **A pty driver was added: `tests/pty-drive.py`.** The creator refuses a
    non-terminal, so a suite that drives its prompts has to give it one.
    `expect` is not on the box and `script -qc` is not on every
    distribution, so the driver is a stdlib `pty` program: it types the
    answers as the program asks, prints the transcript, and returns the
    program's own exit code.

13. **The container name in the second check is `<service>-<container>`.**
    The renderer's `_container_unit` writes `ContainerName=<service>-<container>`
    when the unit source names none, so the `podman ps --filter
    name=<container>` filter has to name the CONTAINER NAME and not the unit
    stem. The creator's second check uses the container name.

14. **The third check runs only when a publication was allocated.** A service
    with no `ports:` entry has no publication, so there is nothing to listen
    for and the check would be a question about a thing that does not exist.
    The creator runs the first two checks always and the third when the
    registry holds a publication. **The three checks are still three checks**
    for any service that asked for a port — which is the only kind that has
    something to verify on the network side.

15. **The check that the publication is LISTENING is reported, not
    asserted-on, in the VM suite.** The suite prints whether the port is
    listening and does not fail on it: pasta binds the container's port
    asynchronously, and the suite has no business racing it. The creator's
    own report says `ok` or `FAIL` for it either way — see divergence 5 for
    what a failed check does to the exit code.

### What is NOT implemented

- **The credential materialiser is asked for, not run.** `plant_secret` calls
  `credentials.ask_materialiser()`, which is the same thing `weedr secret
  set` does. On a host where `guarden-creds-boot.service` is not installed,
  the blob is written and a `warning:` says so.
- **A per-service application probe.** The ticket says one is out of scope,
  and it is: there is no fourth check.
- **The creator does not write a `.guarden/.env.example`, a widget, a route
  host, or a `needs:` edge.** Those are the questions the ticket did not ask
  for, and a creator that asked for them all would be the "cumbersome"
  outcome the operator's own bar allows but did not ask for.
