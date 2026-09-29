# Deploy order: ensure, render, build, gate, stop, install and start

A deploy is a fixed sequence, and the order is the point:

0. **Ensure the service exists.** If the registry has no entry, `weedr service ingest` runs first,
   from the staged tree; it has no flag that could grant a port, because the grant is the
   separate verb `weedr port open`. This is where a poke creates a service.
1. **Render.** `loom` turns the manifest plus the registry into units, and the mutator installs
   what the render will need, without starting anything.
2. **Build.** If the unit source has a build instruction, the build runs as the service user,
   through the mutator verb `weedr service build <name> --from <the staged source>`. It is a
   mutator verb because an unprivileged `furrow` cannot become the service user, and because the
   subuid range belongs to the service user and only it may map container-root into it; `furrow`
   never touches podman. A failed build exits `1` and the running container is still running.
3. **Gate.** On a track with `gated = true`, every `@required` key in the schema must exist as a
   podman secret with a value that is neither empty, nor prefixed `EXAMPLE-`, nor equal to
   `changeme`. A failed gate exits `1`, names the key, and the running container is still
   running. On a track with `gated = false` the same condition produces one `warning:` line
   naming the key, and the start proceeds — that is the whole difference between the two, and
   it is the only difference.
4. **Stop.** Units stop.
5. **Install and start.** The rendered units are installed, the sha is recorded, the user
   manager reloads, units start.

Build and gate both precede the stop on purpose: the two ways a deploy can fail for
non-transient reasons happen while the old container is still serving, so a deploy that fails
either has changed nothing that was serving traffic.

**One deploy of one service holds `deploy-<service>` across all of it, from step zero to the
start.** Two deploys of the same service therefore cannot interleave their unit writes, and
different services proceed in parallel. The lock is the whole of the "a deploy racing another
deploy leaves half-written units" defence, and it is not the queue: the queue serialises builds
(ADR-0010), and raising `build.lanes` retires build serialisation without ever having serialised
deploys.

There are no boot waves, and no fixed delay. Boot ordering is not a property of the host, it
is a property of a service's dependencies, and it belongs where the dependencies are declared.
The only ordering in this system is between a service and the services it declared it needs.

Real dependencies are expressed in the **system** manager, because they cannot be expressed in
the user managers. Each service runs its own `systemd --user` instance under its own uid, so a
unit in the consumer's manager cannot `Requires=` a unit in the provider's manager: the
dependency does not resolve, because the two units are in different dependency graphs and
systemd does not cross user managers. An earlier revision of this document had `loom` write
`Requires=` and `After=` straight into a consumer's container units, and that cannot work.

The mechanism is one target per service, in the system manager, plus one host-wide target to
pull them in:

- **`guarden-order.target`**, in the root path, `Wants=` every enabled service's target. It is
  what the root path pulls in, and it is what makes the whole set startable at boot.
- **`<name>.target`**, one per service, `Wants=` the targets of the services its manifest declared
  under `needs:`, and `After=` them. The mutator writes it root-owned, converges the symlinks
  under `/etc/systemd/system/<name>.target.wants/`, and adds `After=guarden-order.target` and
  `Wants=guarden-order.target` to the service's **quadlet directory drop-in** — which is the only
  place a user-manager unit can acquire a dependency on something in the system manager.
- `loom` emits the *edges* — the `Wants=`/`After=` lines inside `<name>.target` — and the mutator
  installs it. That keeps the unprivileged renderer's output separated by one install step from
  the privileged target, and it is the same renderer/mutator split as everywhere else.

So the ordering is still declared where the dependencies are declared, and the root path still
does not sequence services: systemd resolves the target graph, and a database's target being
pulled in before a consumer's is what "a database starts before the service that dials it"
means. **There is no fixed delay and no boot wave** — a service with no edges starts in
parallel with everything else, and the graph is a dependency graph, not a sequence (spec §6.10). What this
buys is the ordering that was previously promised and previously impossible, and the cost is one
system target per service and a symlink directory to converge.

**The credential gate is a state, not a moment, and it runs before the stop.** `weedr service
gate <name>` evaluates it and changes nothing else; `weedr service start` re-evaluates it every
time. So a push to a gated track with no credentials planted creates the service, builds the
image, installs the units and **does not start the container** — and the deploy **exits 0**, so
CI is green. The operator plants the credentials and runs `weedr service start`, and the service
comes up without a second push. The gate's verdict is a registry field rather than a line in the
journal, so `weedr service list` can say *why* a service is not running. Disabling the unit with
systemd was considered and rejected: it is not the same condition (a non-gated track with a
missing optional key must not be disabled), a service has N units, and `disable` does not stop an
explicit start anyway.

A consumer whose provider is down is *not* held up by this, and that is deliberate: the
dependency is a `Wants=`, not a `Requires=`, so a failed provider does not prevent the consumer
from starting. The consumer's own dial fails and it retries, which every one of these
applications already does. A hard `Requires=` would make one dead database take down everything
that declares it, and a service manager whose failure mode is "everything stops" is not one.
