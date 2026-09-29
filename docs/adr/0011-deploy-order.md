# Deploy order: ensure, render, build, gate, stop, install and start

A deploy is a fixed sequence, and the order is the point:

0. **Ensure the service exists.** If the registry has no entry, `weedr service add` runs first,
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

Real dependencies are expressed where they belong: loom writes `Requires=` and `After=` into
a consumer's units for each edge in the manifest, so a database starts before the service that
dials it and the user manager resolves it without knowing what environment anything is in.
Everything else starts when systemd starts it, in parallel, which is what a service manager
is for.
