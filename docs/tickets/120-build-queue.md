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
