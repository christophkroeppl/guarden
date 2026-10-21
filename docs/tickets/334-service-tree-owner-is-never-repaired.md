# 334 — a service's tree is never repaired, so a host upgraded in place keeps a root-owned quadlet directory

Blockers: none. Found 2026-10-20 while landing ticket 333's fix, by a second
reading of the change against the tree it lands on.

## What happens

Ticket 333 fixes the CREATION path: an instance's own quadlet directory is now
made by `_make_tree`'s walk, so it is `0700` and owned by the service user
rather than root-owned with the mutator's umask. The installer owns the
drop-in directory it creates for the same reason (`units.own_directory`).

**None of that repairs a tree that was made wrong by an older version.** A
host that ran guarden before the fix carries an instance's quadlet directory
that is `root:root 0755`, and:

- **`units.own_directory` leaves an existing directory alone.** It creates the
  levels it has to and does not re-own what is already there — deliberately,
  because the walk that owns a service's tree is `_make_tree`'s and a second
  statement of the same mode in the installer would be two places to keep
  agreeing.
- **`_make_tree`'s walk does reach it, but only when the install is not
  `converged`.** `service.create` returns at the convergence check
  (`src/guarden/service.py`, `_converged`) before `_make_tree` is called, so
  re-ingesting the same source changes nothing and walks nothing.
- **`weedr service start` and `_edge_units` call `units.install` with no
  `_make_tree` at all**, so neither repairs the tree either.

So the defect 333 closes is closed for a tree made AFTER the fix, and a host
that already has the wrong tree keeps it until something happens to walk it
with a changed source.

## Why it is a separate ticket and not part of 333's fix

333's subject is the creation path, and a repair policy is a decision with a
surface of its own:

- **What is repaired?** The instance's quadlet directory, the drop-in
  directories, the whole tree? The whole tree has podman's store and snapper's
  subtree in it, and the walk already knows to leave those alone.
- **Whose mode wins?** An admin who widened a directory under the home — the
  spec says nothing about it, and `0700` is the tree's rule, so the tree's
  rule probably does — but a repair that fights an operator's deliberate
  widening is a repair operators turn off.
- **When does it run?** On every install? On a start? A verb that repairs a
  tree is a verb that changes the host, and `spec 1.2` wants the exit codes
  to say so.

None of that is settled by the code, and 333's fix does not need it to be
right: it makes the NEW tree correct, which is the defect 333 measured.

## The measurement — and a correction to the ticket as it stood

**This ticket said that `tests/t333-instance-quadlet-owner.sh`'s second-install
block "IS the measurement of this ticket's defect" and that it "goes RED
today". Both halves are wrong, and the measurement that replaced them is the
whole of what was learned by doing it.**

The t333 second-install block re-ingests the instance **from a DIFFERENT
source** — a second staging tree with a different unit source, so the source
hash differs. A deploy from a different source is **not converged**, so
`service.create` does not return at `_converged`; it falls through to
`_make_tree`'s walk, and the walk owns the whole tree including the instance's
quadlet directory. **So that block is GREEN today** (measured: `ok
t333-instance-quadlet-owner.sh`, 1 suite, 0 failures), and it measures the
NOT-converged path — which 333's fix already closed.

The defect is on the **converged** path, and that is what this ticket's own
suite measures: a create of the **SAME** source, which converges, and which
therefore returns before anything walks the tree.

```
$ GUARDEN_LXC_RUNNER=guarden-run-t334w tests/lxc.sh run t333-instance-quadlet-owner
ok   t333-instance-quadlet-owner.sh
1 suites: 1 ran, 0 inherited, 0 failures, 1 machines cut
```

## The three decisions

### 1. What is repaired: the UNIT DIRECTORIES — the service's own and every instance's

**The unit directories and the levels above them**, plus the drop-in
directories under them.

**Why not the whole tree.** The directories an older guarden made wrong are the
ones the **INSTALLER** made: the quadlet directory, the levels above it, and
the drop-in directory under it — all of them by `conf.write_file`'s
`path.parent.mkdir`, so root-owned with the mutator's umask. Every other
directory in the tree was made by `_make_tree`'s walk, which owns it, and the
walk runs on every create that is not converged. A repair that walked the
whole tree would be a second statement of the tree's rule in a second place,
and the two would drift — which is the drift that produced this ticket.

**Why the levels above the leaf are included.** `mkdir(parents=True)` creates
the leaf AND the levels above it, and every level it makes carries the
mutator's umask and root's ownership. A repair that owned the leaf and left
`home/.config` and `home/.config/containers` root-owned inside a `0700` home
would be the defect it exists to prevent, one level up.

**Why the files are NOT repaired.** A unit file's mode is **ticket 320's**
question: `units.install` writes `0640` and `_make_tree`'s walk writes `0700`,
two writers disagreeing, with `t250`, `t260` and `t440` pinning the `0640`
answer. A repair that re-moded the files would settle that question by side
effect, and this is not that ticket. The repair touches **directories only**.

**The unit directories are named by one rule.** `units.repair_unit_dirs` walks
the service's own quadlet directory and every instance's, from
`units.unit_dir` — the same function that decides where an install writes and
where a start looks. There is no second expression of "where a unit lives".

### 2. Whose mode wins: the TREE'S

`0700` to the service user (spec 2.1).

**The spec is silent on a deliberate widening, and this says which way it
goes.** The reason the tree's rule wins is that it is not a convenience: the
`0700` on a service's tree is the **isolation boundary**, and it is what stops
every service user reading every other service's state volumes straight off
the host filesystem (spec 2.1 says so in its own words). An operator who
widened a directory under the home has widened that boundary, and a repair
that did not put it back would leave the hole open.

**A repair that fights an operator's deliberate widening is a repair operators
turn off** — and that is answered by making the repair **report what it
changed**, not by making it permissive. The lines are NOTES on stdout, one
per directory, so an operator sees the widening being undone and can put it
somewhere guarden reads (a root-owned override) rather than fighting a loop
that resets it on every deploy.

**The comparison is read from the host, not assumed.** A directory that
already holds the rule is not touched at all, so a repair is a correction of
what is wrong and not a rewrite of what is right.

### 3. When it runs: on the CONVERGED create

**The create that reconciles a service** — `weedr service ingest` and `weedr
service add`, whatever their source.

**Why there and not on a start.** The create is the only thing that runs on
every deploy, and a converged deploy is exactly the one that walked nothing.
`weedr service start` runs when an operator asks for a container to run; a
repair there would change the host's modes as a side effect of asking for a
start, and it would do it on every start of a healthy service — which is the
churn the decision avoids.

**Why there and not at the end of the create.** The end of the create is where
the units are INSTALLED, and a converged deploy installs nothing, so a repair
placed there would never run on the deploy it is for. The repair runs where
the convergence check returns.

**What it costs.** A converged create is still a converge: it installs
nothing, re-renders nothing, and says `converged`. The repair is a mode
correction on directories, it is idempotent, and it changes no registry field
and no unit file.

**The exit code is `0`.** A repair is the verb doing what it says, so the
deploy is a success — spec 1.2's `0` is "the requested work happened, or the
requested state is already true", and the requested state (a converged
service) is true afterwards. The repair is reported on **stdout as a note**,
because a note is a result and a warning is a fault.

## What was deliberately NOT changed

- **`_make_tree`'s walk.** It owns the rest of the tree and it is not the
  writer that made a directory wrong.
- **The `0640` unit mode and the `0644` admin drop-in mode.** Spec 2.1's own
  table, and ticket 320's open question.
- **The admin's own `90-admin.conf`** in the uid-scoped search path. It is
  outside the service's home, and it is the human's file.
- **`weedr service start`.** A start is not a reconcile (see decision 3).
- **The registry.** The repair changes no field: the tree's rule is stated by
  spec 2.1 and derived from the host, and a record of "the tree was repaired"
  would be a fact about the past that the next repair would have to contradict.
- **`paths.TREE_MODE`.** The mode constant MOVED to `paths.py`: the rule is the
  tree's, the tree is walked by `service.py` and converged by `units.py`, and a
  second constant would be a second statement of it. `service.TREE_MODE` is
  now `paths.TREE_MODE`, so the name the suites cite still resolves.

## The test

`tests/t334-tree-repair.sh` — one new suite.

It creates an instance, breaks the tree the way an older guarden left it
(root-owned, `0755`, at every level of the chain the installer made), and then
asks a **converged** create — the same source again — to repair it. The
assertion is `stat` on a real machine.

```
# RED, before the fix:
error: /var/lib/guarden/services/routed-preview/home/feature\x2fx/.config/containers/systemd is mode 755, not 700
FAIL t334-tree-repair.sh

# GREEN, with the fix:
ok   t334-tree-repair.sh
1 suites: 1 ran, 0 inherited, 0 failures, 1 machines cut
```

**The suite is not vacuous**: with the source reverted (`git revert --no-commit`
of the fix commit, the test kept) it goes RED again with the same diagnostic.
