# Lanes bound builds, and one lock bounds a deploy

A small box thrashes itself with two concurrent builds, and two deploys racing each other leave
half-written units. Those are two different hazards with two different mechanisms, and the
distinction is the point of this document.

**Lanes bound builds.** `furrow` serialises builds: one at a time by default, from a queue that
is FIFO within a priority. Priority comes from the track's `weight` in `guarden.toml`, so the
shipped tracks put production first, staging next and previews last — and a preview's priority is
not negotiable by its own manifest, because a repository that could set its own priority could set
it above production.

Repeated requests for the same service and sha collapse into one build, so a burst of pushes
becomes a single deploy. `furrow deploy <service> --now` skips queue position for an operator
who must ship now, and does not change anyone else's position.

The lane count is a root-owned number in `guarden.toml`, not a code change. Adding a lane
starts the next queued build sooner; removing one drains and never kills a build in flight.
Scaling lanes from observed load is backlog — the override is how we get there without
re-litigating the default. Queue state is a directory of files under `/var/lib/guarden/queue`, so
`ls` answers "what is waiting", and a reboot does not lose an accepted request. The locks that
protect it are on tmpfs in `/run/guarden/locks`, because a lock that outlived the process that
took it would only be a stale lock. The `queue` lock covers enqueue, dequeue and the state of an
in-flight request.

**`deploy-<service>` bounds deploys.** One deploy of one **slot** service holds that lock from
its first step to its last, so two deploys of the same service cannot overlap and write its units
over each other, while different services proceed in parallel. An **instance** takes
`deploy-<service>-<escaped-ref>` instead, because every instance on a `kind = "instance"` track
is deployed — and forked, and rolled back — separately, and one lock per service would serialise
a whole track's previews behind each other. The ref in the lock name uses the same escaped form
as the registry's instance key, never a raw ref, because a raw one may contain `/` and a lock
file whose name contains one is a path that does not exist. This is what delivers the second half of the
opening sentence, and it is worth being blunt about what it is not: the queue never serialised
deploys, so raising `build.lanes` retires build serialisation and never had deploy serialisation
to retire. A box with four lanes still runs one deploy of `myapp-production` at a time.

Only builds are queued. A deploy that pulls a prebuilt image and rewrites units does not
compete for CPU or disk with anything, and putting it behind a build lane would make the box
feel broken for no reason. It still takes `deploy-<service>`.
