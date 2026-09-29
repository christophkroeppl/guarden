# 30: weedr — identities, service roots, configuration

**What to build:** `weedr service ingest` and `weedr service remove` create and destroy everything
that makes a service a service: the registry record, the system user, the home, the quadlet
directory, and the subvolumes and snapper configurations for its declared state volumes.
Configuration is read from the root-owned files, and never written by us.

**Blocked by:** 10 (harness and program skeletons)

**Status:** ready-for-agent

- [ ] `/etc/guarden/guarden.toml` is read with the standard library; an invalid file is exit 1
      with the file and the key named
- [ ] The environment set is the `[[environments]]` table in that file, and each row is a
      **track**. A service name whose last `-`-separated segment is not one of the table's `name`
      values is refused naming both the name and the known tracks. The three shipped rows are
      defaults, not a list in the code, so appending a `preprod` block needs no change here
- [ ] `weedr service ingest <name> --from poke <project>@<sha>` and `weedr service add <name>
      --from <service>` both parse the environment from the last `-`-separated segment and
      refuses a name that carries none, an unknown environment, a name over 31 characters, or a
      name containing `..`. **The 31-character limit is on the service name, not on `project`**:
      `project` has no limit of its own, and what is checked is the resulting service name
- [ ] A name with no environment resolves to **the first track in table order with
      `gated = false` and `kind = "slot"`** — `staging` in the shipped table, resolved by rule and
      not by the hardcoded word — and the resolved name is printed. It must not default to a track
      with `gated = true`, and if no such track exists the name is exit `1` naming that fact
- [ ] `--from` is **required**. A service is created from a manifest on disk and guarden never
      infers where one is; the command is refused without it
- [ ] `workload` and `project` are separate registry fields and may differ. `workload` is the
      service name without its environment segment; `project` is the manifest's `project` field,
      defaulting to the basename of the `--from` directory
- [ ] The user is created with the system allocator for subuid and subgid — `useradd --system
      --add-subuids-for-system`, which needs shadow-utils 4.11 or later. Where that option is
      missing the user is created plain and the ranges are written afterwards with `usermod
      --add-subuids` and `usermod --add-subgids`. Either way `/etc/subuid` and `/etc/subgid`
      are read back and a missing range is exit `1` naming the service. The read-back is not
      belt and braces: an unallocated range is a container that starts and then cannot map its
      own root, which is a long way from the cause
- [ ] The call log shows a **distinct** range per service user. One hardcoded range for every
      service is unacceptable, not a fallback: it maps every container's root to the same host
      uid, so the moment two services share a directory the ownership is ambiguous and the
      firewall's uid matching stops meaning what it says
- [ ] The home is `/var/lib/guarden/services/<name>/home`, owned by the service user, with a
      `.config/containers/systemd` directory, and linger is enabled
- [ ] **The service's entire tree — its own directory, its home and every state and bulk volume
      under it — is `0700`, owned by the service user, with no carve-out for the home.** The
      `0700` is what the whole scheme rests on: without it every service user reads every other
      service's state volumes straight off the host filesystem, and the per-consumer credentials
      and the uid-matched firewall rules stop being controls and become decoration
- [ ] **The registry file and each `overrides.toml` are `0640 root:guarden`**, not world
      readable. The registry describes the whole topology — every uid, every edge, every port,
      every snapshot seed — and a service that can read it can read the map of the box
- [ ] `/var/lib/guarden/stakes/` and `/var/lib/guarden/queue/` are **`0770 root:guarden`**, because
      `stakes` and `furrow` run as `guarden` and *create and remove* the files in them. `0750` is
      a defect, not a tightening: group bits of `r-x` let `furrow` read the queue and not write
      to it, so the deploy queue could not accept a request and `stakes pin` could not write a pin
- [ ] **A service's home is not snapshotted and gets no snapper configuration of its own.** It
      holds generated units, the rootless image store, the per-user podman secret database and
      build staging: none of it precious, and the secret database holds credentials in the clear.
      A snapshot list for a service shows its state volumes and nothing else
- [ ] Admin units and drop-ins live in `/etc/containers/systemd/users/<uid>/`, root-owned, and
      `weedr` reconciles the directory without ever reading or rewriting a file inside it. That
      path is podman's rootless quadlet search path and it is uid-scoped;
      `/usr/lib/systemd/user/` is not a search path and is not uid-scoped
- [ ] Every declared state volume becomes a btrfs subvolume owned by the service user with its
      own snapper configuration named `<service>-<volume>`. A service may declare several, and
      none of them is refused for being the second
- [ ] **Every state volume's snapper configuration sets `EMPTY_PRE_POST_CLEANUP=no`**, at creation
      and again on every `soil storage` apply. guarden only ever creates `single` snapshots and
      never a pre/post pair, so switching the empty-pair cleaner off costs nothing. How that
      cleaner treats the cleanup tag and the `important` mark is not something this ticket can
      establish, and nothing in the design depends on the answer
- [ ] A `bulk` volume becomes a btrfs subvolume owned by the service user and gets **no**
      snapper configuration. A name in both lists is refused, naming it
- [ ] **A bulk volume is a subvolume on every path, and the fork is a path.** `weedr service fork`
      creates an empty subvolume for each bulk volume owned by the target user, with no snapper
      configuration — never an empty directory, and never a clone of a live volume. The
      `.volume` unit has to resolve to the same kind of thing on the create path and the fork
      path, or a mounted bulk volume is a mount of something else afterwards
- [ ] A `bulk` volume may be mounted at **any path inside the container**, including one nested
      under another mount: a development hub whose repository checkouts live at
      `/home/herdr/repos` binds a bulk volume there while the home itself is bound at
      `/home/herdr`. The host path is always derived, never written by a manifest
- [ ] `overrides.toml` carries `[retention] keep_last` and `[retention] free_limit`, seeded from
      the track, plus `[groups] add` and `[mounts] allow`. `keep_last` is the volume ladder's
      daily bucket maximum and nothing else: it is not a mark count and it does not change
      `NUMBER_LIMIT_IMPORTANT`
- [ ] Supplementary groups named in `[groups] add` are reconciled: a group that exists is added,
      one that does not is reported and skipped, and no group is ever created — the groups a
      service may need belong to the system and the distribution, not to guarden. This is how a
      hardware-transcoding service reaches `/dev/dri` without the renderer knowing about video
- [ ] No config subvolume is ever created, for any track, including a gitops-created production
      service
- [ ] `weedr service remove` stops units, deletes the one directory under
      `/var/lib/guarden/services/`, calls `userdel`, and asks first on a track with
      `gated = true`
- [ ] `weedr service remove` **does not delete data.** State and bulk volumes are moved, not
      removed, to `/var/lib/guarden/removed/<service>/<time>/<volume>/` — a rename, so
      their snapshots come with them and a volume can be moved back
- [ ] **`weedr service remove <name>/<ref>` removes one instance and leaves its siblings alone**,
      and `weedr service remove <name>` on an instance track is **refused while any instance
      exists, naming them**. A ref naming no instance is refused. The instance form stops that
      instance's units, deletes its directory, releases its `seed` and frees its publications
- [ ] `weedr service list` reports anything sitting in the removed directory
- [ ] **The registry carries a `[generated]` table** — `[generated] "<KEY>" = "<timestamp>"` —
      for every value guarden minted rather than a human planted. Once a value is minted into
      the podman secret store it is indistinguishable from a planted one, so that table is the
      only record that it was not planted. A track with `gated = true` gets no generated value
- [ ] **`weedr service purge` is the only path in guarden that destroys data, and it is a verb
      rather than a flag**, so no sudoers rule granting `remove` can also grant destruction. It
      deletes the volumes
      instead of moving them, requires a terminal, names every volume it is
      about to destroy before it does, and **is refused for an instance**, because an instance's
      volumes are the service's data and purging one would destroy it
- [ ] A second `ingest` or `add` of a converged service exits 0, prints `converged`, and
      produces no calls in the log
- [ ] Every state file is written with the spec §3.5 protocol and the call log shows the
      temporary file created in the target directory and renamed
- [ ] Nothing root-owned exists anywhere under a service's home, and **nothing is ever copied
      from `/etc/guarden` into one**: a home belongs to the service user, and a service user can
      unlink anything in it. Admin units go to
      `/etc/containers/systemd/users/<uid>/<unit>.container.d/`, which podman merges into the
      source file before generating
- [ ] `weedr` reconciles only the existence of that directory on add and remove, and never
      reads, parses, copies or rewrites anything inside it: the service user owns that
      tree completely, which is what makes a regenerated unit harmless
- [ ] `weedr service list` prints uid, track, publications with their allocated ports, granted
      ports with pending marked, volumes with snapshot counts and effective retention, the
      deployed sha, the snapper configuration names, instances, the generated values, and the two
      host invariants guarden depends on and cannot enforce: IPv6 re-enabled, and
      `net.ipv4.ip_unprivileged_port_start` is not `1024`, which `soil sysctl` sets and owns. Both are
      reported and neither is corrected. `--json` emits the same as machine-readable output
- [ ] `/etc/guarden/guarden.toml` is read but never rewritten by any verb on this ticket. There
      are **two** writers of the file in the system, both under the `modules` lock and both
      through the write protocol and touching disjoint keys: `weedr module add` appends to
      `[modules] enabled` and rewrites nothing else, and `soil install` writes the measured
      `ingress.alias` from its probe
- [ ] Verified at the CLI seam with the fast harness
