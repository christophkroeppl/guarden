# 120: the build queue and the deploy order

**What to build:** Builds are serialised — one at a time, highest track weight first, previews
always last — and a deploy is always ensure, render, build, gate, stop, install, start. A failed
build or a blocked gate leaves the running container running, and a blocked gate leaves the deploy
itself **succeeding** — the service is installed and waiting, and `furrow` exits `0`.

**Blocked by:** 40 (loom), 60 (credentials)

**Status:** ready-for-agent

- [ ] A request is a service, a ref and a sha — **no path**, because the mutator builds the staging
      location from the project and the sha itself. Queue state is a directory of
      files under `/var/lib/guarden/queue`, readable with `ls`
- [ ] **Queue state is on disk, not in tmpfs, and survives a reboot.** A request that was
      acknowledged before the reboot is still built after it, which is the whole difference
      between a queue and a running service. The locks that protect it stay in
      `/run/guarden/locks` on tmpfs: a lock that outlived the process that took it would only be
      a stale lock
- [ ] With one lane, two builds are never in flight at once: at no sample is a second build
      process running
- [ ] Two queued production requests run before a queued staging request; staging before
      preview; within one priority the order is FIFO
- [ ] Priority comes from the `weight` on the track in `guarden.toml`, not from a
      fixed list in the code
- [ ] A manifest cannot state a priority: there is no key for it, and one is refused by name
- [ ] N identical requests for one service and sha collapse into one build
- [ ] The **order is ensure, render, build, gate, stop, install, start**, and the journal shows
      it in that order. Step zero is `weedr service ingest <name> --from poke <project>@<sha>` when
      the registry has no entry — a verb with no grant flag on it, and
      that is how a poke creates a service without being able to open a port
- [ ] **The build step is the mutator verb `weedr service build <name>`**, which takes no
      `--from`: a build has exactly one tree it may build and it is the service's own, which
      closes the `podman build` escalation a `build --from <dir>` would have been
- [ ] A failing build exits non-zero, leaves the previous units in place, and the container
      running before the deploy is still running
- [ ] A failing gate on a track with `gated = true` exits non-zero, names the key, and the
      container running before the deploy is still running. On a track with `gated = false` the
      same condition is one `warning:` line and the start proceeds
- [ ] A source with no build instruction produces no build call and prebuilt images work
      unchanged
- [ ] A deploy that only pulls a prebuilt image is not queued — only builds are
- [ ] `furrow deploy --now` skips queue position for that request and changes nobody else's
- [ ] `build.lanes` raises or lowers **build** concurrency; lowering never kills a build in
      flight and takes effect between builds
- [ ] **Lanes bound builds; a lock per service bounds deploys.** One deploy of one **slot**
      service holds `deploy-<service>` from its first step to its last, and one **instance** holds
      `deploy-<service>-<escaped-ref>` — on a `kind = "instance"` track every instance is deployed
      separately, and one shared lock would serialise the whole track's previews behind each other.
      The ref is the same escaped form as the registry key, never a raw ref. Two deploys of the
      same service cannot interleave their unit writes while different services proceed in
      parallel. The
      `queue` lock covers enqueue, dequeue and an in-flight request, and nothing else. Raising
      `build.lanes` retires build serialisation and never had deploy serialisation to retire, so
      it is not the knob for a deploy that races another deploy
- [ ] A test asserts two concurrent deploys of one service do not overlap, and that two deploys
      of different services may
- [ ] The lane count survives a process exit, because it is a root-owned file
- [ ] A failed build does not stall the queue: the next request runs
- [ ] A request enqueued while busy is still built after the process that enqueued it exits
- [ ] `furrow queue list` shows the order and the last failure's message
- [ ] Manual and gitops deploys enter the same queue and are serialised against each other
- [ ] Verified at the CLI seam, in the VM

---

## Implementation notes

Written by the agent that implemented this ticket. The reasoning lives here
rather than in comments, and the claims below are the ones a reviewer should
check the code against.

### What is where

`src/guarden/furrow.py` is the whole of it. `weedr service stop` gained a body
(`src/guarden/weedr.py`), because the order in ADR-0011 stops between the gate
and the install and no granted verb could do it. Tests are
`tests/t120-queue.sh` and `tests/t120-deploy.sh`.

### Two mechanisms, two locks

- **A lane is a claim in a request file.** `_claim` takes the `queue` lock,
  counts the requests in `state = "building"`, and marks one `building` with a
  lane number. It reads `[build] lanes` from `guarden.toml` on every claim, so
  lowering the count lands between builds and never kills one in flight - it is
  read, not owned.
- **`deploy-<service>` is a flock held from the first step to the last**, and
  `deploy-<service>-<escaped-ref>` for one instance.

The lock order in spec 3.5 puts `queue` **before** `deploy-*`, and `conf.lock`
refuses a lower lock inside a higher one. That is why the lane is claimed and
retired by the caller, around the deploy, and never from inside it: a lane claim
taken while holding `deploy-<service>` is the deadlock the order exists to
prevent. It is also why a request holds its lane for its whole deploy rather
than only across the build - the alternative would need the two nested.

### A build instruction is decided from the repository, before the render

Whether a request takes a lane is settled at enqueue time, so it is read from
the staged tree rather than from a render: a Compose service carrying `build:`,
or a quadlet unit carrying any `Build*` key in `[Container]`. A source that
declares none is a prebuilt-image deploy and never waits for a lane (ADR-0010).

### The gate is read back, not converted

`weedr service gate` answers `1` on a blocked gate because that is what it was
asked and it changed nothing. `furrow` calls it, reads `[gate] state` out of the
registry, and branches - so the verb that says `1` and the deploy that says `0`
are never both spoken about the same attempt (spec 6.6).

### `--from` is required, and the spec allows a case this cannot do

spec 6.6 says `--from` "**may** be omitted when the registry already has an
entry, in which case the render uses the manifest and unit source already in the
service's home". That path is not implementable as written: the service's tree
is `0700` to the service user (spec 2.1), `guarden` is not that user, and `loom`
runs unprivileged, so an unprivileged renderer cannot read the home either. A
redeploy with no `--from` would have nothing to render. `furrow` requires
`--from` and says why in the refusal. **This is a spec conflict, not resolved
here** - it wants either a guarden-readable copy of each service's manifest and
unit source, or the mutator's own render step. Until one exists, "a hand-run
`furrow deploy` names a project and a sha, never a folder" holds with nothing
lost.

### Three gaps found in the mutator, none fixed here

1. **`weedr service build` has no body.** The ticket says the build step *is*
   that verb and `furrow` calls it correctly, but `t10-help.sh` asserts the verb
   is not implemented and no ticket claims the body. A deploy of a source with a
   build instruction therefore fails at the build step on any box today.
2. **The `guarden` sudoers rule is written in spec 6.6 and installed by no
   program.** `soil install` does not write it. `furrow` calls
   `sudo -n /usr/lib/guarden/bin/weedr ...`; on a host where `furrow` runs as
   root (the VM harness) it calls the mutator directly, because going through
   `sudo` anyway would leave the harness unable to deploy.
3. **`weedr service ingest` does not install rendered units** - spec 5.3 step 11
   says it does, and `service.create` never calls `units.install`. So the
   deploy's *install* step has no mutator verb that installs anything: `ingest`
   is the reconcile verb on the grant and is what `furrow` calls, and it will
   install the render once step 11 exists. Until then a deploy cannot reach a
   successful `weedr service start`, because no unit was ever installed.

### Not satisfied, and why

- **"A test asserts two concurrent deploys of one service do not overlap, and
  that two deploys of different services may."** `t120-deploy.sh` asserts that
  the lock file for `deploy-<service>` and for
  `deploy-<service>-<escaped-ref>` is what is taken, and which names exist.
  Observing two real deploys not overlapping needs two real containers and a
  real running unit to interrupt, which is the golden VM's work (ticket 140).
- **"A request enqueued while busy is still built after the process that
  enqueued it exits."** `furrow` writes the request before it drains, so the
  file exists from the first moment; `t120-queue.sh` asserts a request file
  survives a deploy that failed. The reclaim of a claim whose pid is gone is in
  the code but is not exercised by a test, because driving it needs two
  concurrent `furrow` processes.
- **"The lane count survives a process exit."** The count is read from
  `guarden.toml` on every claim rather than held anywhere, so it survives
  trivially; `t120-queue.sh` asserts the file carries it and that
  `furrow status` reports the file's value after editing it.

### Deliberately out of scope

`furrow preview drop` keeps `cli.pending`. It is ticket 110's verb ("the drop is
available by hand through `furrow preview drop`"), and the `guarden-queue.path`
unit named in spec 6.9 was not added: no verb in spec 6.6's fixed list drains the
queue, and adding one would fail `assert_verbs furrow deploy preview queue
status` in `t10-help.sh`.
