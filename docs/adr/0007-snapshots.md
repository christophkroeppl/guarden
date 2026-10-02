# Snapper prunes, guarden writes the marks

Pruning is snapper's job and stays snapper's job. guarden never runs a delete loop, never
computes a candidate set, and never calls `snapper delete`. What guarden owns is the *mark*:
when a snapshot is still wanted, it is marked in snapper's own metadata, and snapper's
`number` cleaner counts marked snapshots against its budget and keeps them.

Two kinds of snapshot are governed by two different mechanisms, and keeping them apart is what
makes the policy comprehensible. A **routine** snapshot — the nightly one — is tagged `timeline`
and lives or dies by the volume's **ladder**, its per-bucket retention schedule, aged upward by
snapper as snapshots get older. An **on-demand** snapshot — a fork source, or an operator's
"before the risky change" — is tagged `number`, and is what the mark below governs. So a
volume's routine history is a bounded, spread-out shape, and the handful of snapshots a fork can
be taken from are the ones worth protecting. With one counter governing both, neither is
tunable.

A mark is written with the only interface snapper offers for it:

```
snapper -c <service>-<volume> modify --cleanup-algorithm number \
    --userdata "important=yes, guarden=<referencing-service>" <number>
```

Both halves matter. `important=yes` is read only by the `number` cleaner, and a snapshot is
only a candidate for that cleaner if its cleanup tag is `number`; setting one without the
other does nothing. `guarden=` is our own provenance key, so a human reading `snapper list`
sees which service is holding a snapshot, and so a mark written by something else is
distinguishable from one of ours.

**A mark is a priority with a budget, not a promise.** `NUMBER_LIMIT_IMPORTANT` is a min-max
range. The unconditional pass keeps up to the maximum. The free-space pressure pass, which
runs when the filesystem is below `FREE_LIMIT`, keeps up to the *minimum* — and the minimum is
usually zero. So under genuine disk pressure, marked snapshots are reaped, oldest first. This
is accepted deliberately: it only happens when the disk is nearly full, which is itself the
signal worth having, and a preview that cannot be re-forked from a three-week-old snapshot
means the disk is filling rather than that something is broken. The floor is a number the
operator chooses, and the shipped default keeps eight marked snapshots under pressure —
enough for every fork base on the box, few enough that the pressure valve still has something
to give.

## The reconciler, and the race it exists to close

A root oneshot, `weedr pin sync`, reads the pin directory and the service registries,
recomputes the desired mark for every snapshot, and calls `snapper modify` only where reality
differs from the intent. It adds before it removes, it is idempotent, and if its state cannot
be read it stops rather than clearing anything.

It exists as a separate root action from `stakes` on purpose. `stakes` owns files and queries
and runs unprivileged; writing snapper's metadata needs root; and a program that runs as two
different users on a schedule is how a privilege boundary quietly stops being one. `stakes`
pins, `weedr pin sync` bridges.

The reason it has its own lock is the real hazard. **snapper takes no lock that
`snapper modify` participates in.** Its per-config lock lives in the daemon, is advisory, is
released when a client disconnects, and is not checked by the method behind `modify` at all.
Its cleaner takes one reference to the snapshot list and reuses it across all three passes.
So a mark written while a cleanup is running is silently lost, with no error anywhere. Two
consequences, both implemented:

- guarden disables the distribution's packaged snapper cleanup timer and installs its own
  oneshot, and **both it and the reconciler take `/run/guarden/locks/snapshots.lock`**. There
  is then exactly one writer of a mark at a time, and one deleter, and they cannot overlap.
- `NUMBER_MIN_AGE` is set so that a brand-new snapshot cannot be reaped before the reconciler
  has had a chance to see it.

`EMPTY_PRE_POST_CLEANUP` is `no` on every state volume's configuration, and the reason is the one
that can be confirmed: guarden only ever creates `single` snapshots and never a pre/post pair, so
switching the empty-pair cleaner off costs nothing. How that cleaner treats the cleanup tag and
the `important` mark is not something this document can establish from the available sources, and
nothing here depends on the answer.

Snapshot state is read with `snapper --machine-readable json --config <config> list` (spec §8.2,
which carries the three measured facts about the option's position, the document's shape and the
`0` entry that is not a snapshot). JSON renders `userdata` as a real object, so `important` is a
key; CSV renders the whole map as one comma-joined quoted field, so a CSV consumer ends up
matching a substring of a quoted blob. Writes never use `--no-dbus`: without the daemon there is
no inter-process coordination at all.

## References are derived, not recorded

A service's registry records `seed = { <volume> = <number> }` — the snapshot it was forked
from. Nothing maintains a count, a holder set, or a ledger. The reconciler is a projection of
state that has to exist anyway, which is why evicting one preview cannot release a snapshot
another preview is forked from, and why there is nothing to reconcile when a process dies
midway. The one writable projection is the mark.

`keep_last` in a service's overrides is the daily bucket's maximum, so it is the natural home
for a retention count: `keep_last = 7` on a production volume means seven daily snapshots, aged
upward by snapper into the weekly, monthly and quarterly buckets as they get older. That is a
bounded, spread-out history rather than a flat window of the newest few, and it is why a
production rollback history is kept without anyone marking anything.

It is a retention count and nothing else. It does not mark snapshots, and it does not raise the
floor of `NUMBER_LIMIT_IMPORTANT` — that floor is one number an operator chooses, and the ladder
does not compute it.

The ladder's ranges are ranges, so the free-space pass still keeps only their minimum, and no
retention promise in this design is absolute. The runbook says so rather than implying
otherwise, and the marked snapshots are the ones protected on top of that.

## Multi-volume services

btrfs has no atomic multi-subvolume snapshot primitive — the ioctl surface carries exactly one
destination name and one source per operation — so a service with two state volumes has two
consistent snapshots that may be microseconds apart. A configuration volume and a bulk media
library do not care; two volumes that must agree byte for byte should not be snapshotted
together, and should say so in their own documentation. Forks and rollbacks address a snapshot
as a complete set of per-volume numbers, validate that every declared state volume has its
number, and change nothing when one is missing.

## What is deliberately not the mechanism

- **Read-only is not a pin.** The cleaners never consult a snapshot's read-only flag or the
  subvolume's `ro` property, and every snapper btrfs snapshot is read-only by default, so it is
  not even a distinguishing property. A fork is unaffected, which is why the flag is used after
  a fork to confirm the clone's `ro` was actually cleared.
- **There is no cleanup hook.** snapper's plugin API has pre/post notifications for eight
  actions and no cleanup stage; a plugin's exit code cannot veto anything, and plugins may not
  call snapper. Any design that waits for a filter before a delete is waiting for something
  that does not exist.
- **There is no flag, lock, or "protected" concept in snapper.** A grep for one returns a C++
  access specifier.

## The escalation, for one case

`chattr +i` on a snapshot's subvolume is a genuinely stronger pin: the btrfs delete ioctl
checks the victim inode for immutability and returns `EPERM`, which no `NUMBER_LIMIT`,
`FREE_LIMIT` or `SPACE_LIMIT` can override. It survives a race with a running cleanup and
survives a manual `snapper cleanup all`, and btrfs does not inherit immutability into a new
subvolume, so a fork still works.

It is an escalation rather than the default because of one behaviour: snapper's cleaner
deletes candidates one at a time with no per-item error handling, so the first candidate it
cannot delete aborts that configuration's whole cleanup for that run. It is a deny, not a
keep-N. It therefore stops auto-pruning for that configuration, which is a decision an operator makes
per snapshot, records in the service's registry with its reason, and can see in the runbook.
Production rollback bases are the case worth spending it on.

## One dial, and who reports it

The retention knobs live in the state volume's snapper configuration and are never in a
manifest. `weedr pin sync` reads them back with `snapper get-config` and applies them.

**The per-volume figures are a root read, and they come from `weedr service list --json`, not
from `stakes`.** `stakes` runs as `guarden` and a service's tree is `0700` to that service, so it
cannot read a service's snapshots and does not pretend to: `stakes list --json` reports the pin
files it owns and, for each, which services name it as a seed — its own files and the registries,
both readable. Everything that needs a state volume comes from the other command: per state
volume the total, the marked, the oldest, the newest, and the effective `NUMBER_LIMIT` and
`NUMBER_LIMIT_IMPORTANT` read back with `snapper get-config`. That is the shape disk and
snapshot-count monitoring consumes, and the division is stated here so it is not a surprise in a
script that polls the unprivileged command and gets nothing.

Building that monitoring is backlog; the data it needs exists from the first day.
