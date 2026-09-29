# 70: state, snapshots, forks, rollbacks, pins

**What to build:** Snapshots are taken while a service runs, forks are copy-on-write clones,
rollbacks are the same operation pointed the other way, and pins are derived from the service
registries rather than recorded by anything. Retention stays snapper's: guarden marks the
snapshots that must survive and runs no delete loop.

**Blocked by:** 30 (weedr), 20 (soil — the cleanup timer and its lock)

**Status:** ready-for-agent

- [ ] `weedr service snapshot` creates one **routine** snapper snapshot per state volume,
      tagged `timeline`, with a timestamped description, records the newest number in the
      registry, and does not stop the service, lock, or wait
- [ ] The two kinds of snapshot are distinguished by tag and nothing else: `weedr service
      snapshot` makes a `timeline`-tagged one governed by the ladder, and a fork source or an
      operator's snapshot is `number`-tagged and governed by the marks. There is no flag that
      chooses, and a routine snapshot is never marked
- [ ] **A routine snapshot lives by the volume's ladder** — `TIMELINE_LIMIT_*`, with `keep_last`
      as the daily bucket's maximum. A daily cadence fills the daily bucket and snapper ages
      those snapshots up into the weekly, monthly and quarterly buckets, so one nightly timer
      produces a bounded, spread-out history rather than a flat window of the newest few
- [ ] **A fork takes a `number`-tagged snapshot, precisely so the mark can protect it.** A fork
      source is not a routine snapshot and does not go in the ladder; the marks, and only the
      marks, are what keep a fork base alive
- [ ] **A service may declare as many `state` volumes as it needs.** Every one is a subvolume
      with its own snapper configuration, and one snapshot covers all of them. There is no
      one-volume limit and no refusal of a second entry
- [ ] **btrfs has no atomic multi-subvolume snapshot primitive**, checked against the kernel's
      ioctl surface, so the volumes in one snapshot are each consistent and may be microseconds
      apart from each other. The command does not claim otherwise and neither does its output.
      What the skew costs depends on the pair: a configuration volume beside a two-terabyte
      media library tolerates it without noticing, and two volumes that must agree byte-for-byte
      do not — that is a property of the service, and it says so in its own documentation
- [ ] A `bulk` volume is skipped by every snapshot, carries no snapper configuration, is never in
      `stakes list`, is never a fork or rollback source, **and is created as an empty subvolume by
      a fork**. It is a subvolume on every path, the fork included: a fork creates an empty
      btrfs subvolume owned by the target user, never an empty directory and never a clone of a
      live volume. It is named in the output as skipped rather than passing silently. A copy as
      of an instant is not reproducible afterwards, and a fork that quietly
      produced different data on two targets would be worse than an empty one. That is the right
      declaration for chain state and for anything else that is regenerable or too large to
      snapshot
- [ ] A `bulk` volume still gets a `.volume` unit, because a container must be able to mount it
- [ ] A snapshot id is `<service>:<volume>@<number>` and nothing else, on the command line, in the
      pin file and in every diagnostic. `other-app-production-pgdata-41` is ambiguous and is never
      emitted
- [ ] Every state volume's snapper configuration is written with `EMPTY_PRE_POST_CLEANUP=no`, and
      `soil storage` converges it on every configuration it finds. guarden only ever creates
      `single` snapshots and never a pre/post pair, so switching the empty-pair cleaner off costs
      nothing. How that cleaner treats the cleanup tag and the `important` mark is not something
      this ticket can establish, and nothing here depends on the answer
- [ ] `weedr service snapshot --all` does every service that has a state volume and lists what
      it skipped. A nightly timer calls it: **one timer for the host, not one per service**,
      because a per-service timer is a unit to install, a timer to re-arm and something to
      forget to remove
- [ ] The snapshot of a running data directory is atomic **per volume**; the ticket 15 result on
      the golden VM is the evidence
- [ ] `weedr service fork <target> --from <source>[@<number>]` stops the target, moves its
      subvolumes aside, clones, clears the read-only flag, sets ownership, records the `seed`,
      and starts the target
- [ ] **A snapshot is addressed as a complete set of per-volume numbers, and the set is validated
      before anything is changed.** Every state volume the service declares must have that
      number; a partial set is refused with exit `1`, naming the volumes with no snapshot, and the
      target is left untouched. A clone assembled from some volumes at one instant and the rest at
      another is worse than a failed fork
- [ ] **A snapshot is protected for the duration of a clone and released only after the clone
      succeeds**, by creating its pin file — not by taking a lock, and not by a
      counter. The reconciler therefore cannot unmark the source underneath the fork and
      snapper's cleanup cannot run against it. A failed clone releases the pin and leaves nothing
      pinned forever
- [ ] **A fork or a rollback that cannot find the snapshot on every state volume changes
      nothing** — no subvolume moved, no ownership changed, and the target is still running
- [ ] Fork and rollback operate on `state` volumes only and **say which volumes they skipped**,
      which is the bulk ones
- [ ] The clone is copy-on-write: no space is consumed for unmodified data, and the source
      snapshot is never written to
- [ ] A failed fork restores the previous subvolumes, starts the target, and exits 1, leaving
      nothing half-swapped
- [ ] The btrfs-progs version is checked and reported, not worked around
- [ ] `weedr service rollback <name[/ref]> --to <number>` stops, swaps, starts; it is refused on a track
      with `gated = true` outright, with no override flag, and refused entirely — changing nothing — if the
      snapshot is missing from any state volume
- [ ] Lineage is derived from the track's `fork_from` field and never from its name: the shipped
      rows are `production` (empty), `staging` (`fork_from = "production"`) and `preview`
      (`fork_from = "staging"`), and a fourth track forks because a row says so rather than
      because guarden recognises the word. `--from` overrides; a `fork_from` naming a track that
      does not exist, or the track's own name, is exit `2`; a manifest key for lineage is refused
      by name
- [ ] `stakes pin/unpin/list/query` operate on one file per snapshot id, idempotently, with no
      lock and no shared aggregate file
- [ ] **Retention is snapper's. guarden runs no delete loop of its own.** snapper's own cleanup
      algorithms prune, on the `number`, `timeline` and `space` algorithms the distribution
      ships
- [ ] **A root reconciler — `weedr pin sync`, a separate root action from `stakes` on purpose,
      because `stakes` runs unprivileged and writing snapper's metadata does not —
      recomputes the desired marks and writes them with `snapper modify`**:
      `userdata important=yes` and the `number` cleanup tag. Both halves are required —
      `important` is read only by the `number` cleaner, and a snapshot is a candidate for that
      cleaner only when its cleanup tag is `number`. Its inputs are the service registries' `seed`
      values and the pin files, both read without a lock
- [ ] **Snapshot state is read with `snapper list --machine-readable json`, using the `number`,
      `cleanup`, `date`, `userdata` and `description` fields.** JSON renders `userdata` as a real
      object, so `important` is a key; CSV renders the whole map as one comma-joined quoted
      field, so a CSV consumer ends up string-matching. Nothing in guarden parses CSV
- [ ] **No write passes `--no-dbus`.** Without the snapperd daemon there is no inter-process
      coordination at all, so a mark written that way can be lost with no error anywhere
- [ ] The reconciler **adds before it removes**, and **stops rather than clearing anything when
      its state is unreadable** — a missing or unparsable registry directory leaves every
      existing mark in place rather than releasing it
- [ ] **`NUMBER_MIN_AGE` is set on every configuration, converged by `soil storage`**, so a
      brand-new snapshot is not a cleanup candidate before the reconciler has seen it — ticket 20
- [ ] The reconciler is idempotent: a second run with no change makes no `snapper modify` call
- [ ] **A pin is a priority with a budget, not a promise.** `NUMBER_LIMIT_IMPORTANT` is a
      min-max range and the free-space pass uses the minimum, so under genuine disk pressure a
      marked snapshot can be reaped, oldest first. This is accepted and is not treated as a defect;
      the operational reading is that a snapshot that cannot be forked from means the disk is
      filling. The floor is the low end of that range, one number in the state volume's snapper
      configuration owned by `soil` and set by no manifest; the shipped default keeps eight marked
      snapshots under pressure
- [ ] **`chattr +i` on a snapshot's subvolume is available as an opt-in escalation, and it is a
      deny rather than a keep-N.** The btrfs delete ioctl returns `EPERM` for an immutable victim
      and no `NUMBER_LIMIT`, `FREE_LIMIT` or `SPACE_LIMIT` overrides it; btrfs does not inherit
      immutability, so a fork from an immutable snapshot still works. The cost is exact:
      snapper's cleaner deletes candidates in a loop with no per-item error handling, so the first
      candidate it cannot delete **aborts that configuration's entire cleanup for that run**, so
      while that snapshot is a candidate the configuration stops auto-pruning. It is opt-in, it is
      recorded with its reason, and unsetting it with `chattr -i` restores normal pruning. A test
      asserts that unsetting it lets cleanup prune again
- [ ] The reconciler takes `/run/guarden/locks/snapshots.lock` for the whole run, and so does
      the cleanup oneshot, so the two never overlap. snapper takes no lock that `snapper modify`
      participates in — the per-config lock lives in the daemon, is advisory, and is released
      when a client disconnects — and its cleaner takes one reference to the snapshot list and
      reuses it across all three passes, so a mark written during a running cleanup is silently
      lost. One guarden lock around both closes it. `snapper list` holds that configuration lock
      for its whole duration, so the reconciler does not list in a loop
- [ ] `soil storage` disables the distribution's packaged snapper cleanup timer and installs
      guarden's own oneshot instead, because a packaging timer running on its own schedule is the
      same overlap by another name — ticket 20
- [ ] Removing a service removes its `seed` reference; another service that names the same
      snapshot still protects it
- [ ] `keep_last` in `overrides.toml` is **the ladder's daily bucket maximum** and nothing else.
      It does not mark snapshots, and it does not raise the floor of `NUMBER_LIMIT_IMPORTANT` —
      that floor is one number `soil` owns. It defaults to the track's `keep_last`, which ships
      as `0` for staging and preview and `7` for production, and `weedr service list` shows both.
      The ladder's own values are ranges, so the free-space pass keeps only their minimum and no
      retention promise is absolute
- [ ] `stakes list --json` reports **the pin files it owns and, for each, which services name it
      as a seed** — its own files and the registries, both readable. It cannot report per-volume
      figures: `stakes` runs as `guarden` and a service's tree is `0700` to that service, so it
      does not read a service's snapshots and does not pretend to
- [ ] `weedr service list --json` reports, per state volume: total snapshots, marked snapshots,
      oldest, newest, and the effective `NUMBER_LIMIT` and `NUMBER_LIMIT_IMPORTANT` read back
      with `snapper get-config`, not by parsing `/etc/snapper/configs/<name>` and not from the
      configuration guarden believes it wrote. This is a root read and it is the command
      monitoring polls; the division is deliberate and is stated in the runbook and the spec so
      an unprivileged job does not get an empty result and conclude the disk is fine
- [ ] Every snapshot list behind those counts is read with `--machine-readable json`, and
      `important` is read as a key in the `userdata` object
- [ ] On the golden VM, a clone of a live database starts, recovers, and the data is present
- [ ] Verified at the CLI seam with the fast harness
