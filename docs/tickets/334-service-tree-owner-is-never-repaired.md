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

`tests/t334-tree-repair.sh` — one new suite, and `tests/registrykey.py` — one
new helper that plants an instance key in a registry.

The suite creates an instance, breaks the tree the way an older guarden left
it (root-owned, `0755`, at every level of the chain the installer made), and
then asks a **converged** create — the same source again — to repair it. The
assertion is `stat` on a real machine.

### The RED, verbatim, before the fix

The source reverted to develop's `6617f72` and the tests kept:

```
$ GUARDEN_LXC_RUNNER=guarden-run-t334w timeout 1800 tests/lxc.sh run t334-tree-repair --no-cache
sha: ed87491e7049ffaf0813e59356125577dad5b186 (SOURCE REVERTED to develop 6617f72, tests kept)
error: /var/lib/guarden/services/routed-preview/home/feature\x2fx/.config/containers/systemd is mode 755, not 700
error: failed at line 526: return 1 (exit 1)
FAIL t334-tree-repair.sh
error: t334-tree-repair.sh exited 1; the suite stopped on an assertion, and its own line is above
1 suites: 1 ran, 0 inherited, 1 failures, 1 machines cut
note: --no-cache: all 1 suites ran and every result was recorded
```

### The GREEN, verbatim, with the fix

```
$ GUARDEN_LXC_RUNNER=guarden-run-t334w timeout 1800 tests/lxc.sh run t334-tree-repair --no-cache
sha: ed87491e7049ffaf0813e59356125577dad5b186
ok   t334-tree-repair.sh
1 suites: 1 ran, 0 inherited, 0 failures, 1 machines cut
note: --no-cache: all 1 suites ran and every result was recorded
```

### The RED again, with the source reverted

**The suite is not vacuous, and the revert is of the SOURCE and not of the
test.** The source files are put back to develop's `6617f72` and the tree is
left otherwise alone:

```
git checkout 6617f72 -- src/guarden/paths.py src/guarden/service.py \
    src/guarden/units.py src/guarden/weedr.py
```

and the suite goes RED again with the same diagnostic — the block above is
that run. The source is then restored with `git checkout HEAD --` on the same
four files, and the suite is green again.

**The mode assertion comes FIRST, and that is a thing that was got wrong and
fixed.** The suite asserted the repair's report line ("the repair says what
it repaired") before it asserted the mode, and the reverted run stopped on
`stdout does not name repaired` — a diagnostic about a missing report line
where the tree was still root-owned and `0755`. The measurement has to name
the DEFECT, and the defect is the mode and the owner.

### The suites that had to stay green

The repair is about modes, and the modes are a question other suites pin:

| suite | what it pins | result |
|---|---|---|
| `t333-instance-quadlet-owner` | the instance's own quadlet directory, `0700` and the service's own | ok |
| `t250-verb-split` | a unit file is `0640` under the service uid | ok |
| `t260-examples` | a template's copy lands `0640` under the service uid | ok |
| `t440-instance-start` | the instance's unit file is `0640` after the walk | ok |
| `t30-create` | a converged ingest says `converged` and changes nothing | ok |
| `t380-store-walk` | the walk leaves podman's store and snapper's subtree alone | ok |
| `t432-add-applies-an-edit` | `add` converges, and an edit re-deploys | ok |
| `t433-shared-record-idempotency` | a converged deploy converges and changes nothing | ok |
| `t500-container-files` | a container writes into the service's own tree | ok |
| `t501-service-user-files` | a service user cannot reach another service's tree | ok |
| `t10-no-fakes`, `t10-help` | no stand-in for a system tool; the verb surface | ok |

## The adversarial review, and what it found

A second model read the change against the tree and found five real defects.
Four were closed in `27505a1` and the fifth was a measurement that measured
nothing. They are recorded here because **a decision with no stated reasoning
is a decision the next reader has to re-derive** — and so is a fix whose holes
are not written down.

1. **The repair was never said.** `weedr._emit` returned on
   `outcome.converged` BEFORE the loop that prints `outcome.notes`, so the
   repair's lines never reached stdout, and decision 2's "the repair reports
   what it changed" was not implemented at all. The notes are now printed
   before the verdict: the verdict is the verb's answer and a caller reads
   the last line as the answer.

2. **The installer would have followed a link out of the tree.** `own_directory`
   converged an EXISTING leaf, and `conf.set_owner` and `os.chmod` both follow
   a link by default. The service owns its home, so the service can plant a
   link there — and one that replaced `home/.config` with a link to `/etc`
   would have made a root-run install `chown` and `0700` `/etc/containers`,
   which is root-owned `0755` and read by every uid's podman generator
   (spec 2.1). `own_directory` is back to touching only what it creates, and
   the repair of an existing directory is `repair_unit_dirs`' — a separate
   call, on a converged create, where every path is resolved and checked
   against the home before anything is chowned.

3. **A registry key naming `..` walked out of the home.** `_chain_up` used a
   lexical `relative_to`, which accepts `..`, so a key would have walked the
   chain up to `/var/lib/guarden` itself — which holds `registry/` and
   `creds/`. The chain is built from the RESOLVED leaf, and a leaf that does
   not resolve inside the home yields nothing at all.

4. **The repair and the installer disagreed about the owner.** The repair
   asked the passwd database for the service user's PRIMARY gid; the
   installer asked `users.group_id(service)` for the service's own GROUP
   gid — a different number on a host where `useradd` made a group with
   another gid. The two chowned the same directory different ways on
   alternate deploys, so **every converged deploy "repaired" again**, and
   spec 5.3's "changes nothing" was false. The installer now asks the same
   database, so there is ONE answer. And a service user the host no longer
   has is a **refusal naming the service**, not a gid invented from the uid:
   a gid is a property of the system, and a number nobody assigned is not one.

5. **The containment block measured nothing.** Renaming the registry's only
   instance key made `_converged` return False, so the create took the other
   branch and the repair never ran — the assertion was about a code path
   that was not taken. The key is now **added beside the real one**, so the
   deploy stays converged AND the repair has a hostile path to walk.

**What the review did NOT find**, read and checked rather than assumed: the
repair does not break ticket 320's `0640`-against-`0700` question (the repair
touches directories only, and the files are left alone); it does not break
`t333`'s assertions (the same two properties, and the t333 suite is green);
and it does not touch a directory belonging to a different service (every path
is resolved and checked against the service's own home before it is touched).

**The golden hides finding 4**, and that is worth knowing: `tests/lib.sh`
creates a same-named group for the service user, which makes the two gids
identical on the test machine. The defect is real on a host where `useradd`
does not make one, and no suite on this golden would have seen it.

## A sixth finding, found by running it rather than by reading it

**The helper that plants the key wrote a document that was not TOML.** The
review's finding 5 was closed by planting the hostile key with a helper that
parses the registry and writes it back — and the helper wrote it with its own
TOML writer, which quoted the key but did not ESCAPE the backslash inside
that quoting. The document it produced was not TOML at all:

```
error: /var/lib/guarden/registry/routed-preview.toml is not valid TOML: Unescaped '\' in a string (at line 14, column 22)
```

So the mutator refused to read its own registry, the deploy never reached
the repair, and the containment block measured nothing — the review's finding
5, unfixed, in a new shape. The diagnostic named the registry and not the
suite that had planted the key, which is what a defect in a test helper
looks like from the outside.

**The helper now hands the parsed document back to `conf.toml_dumps`** — the
code that writes every registry guarden has ever written. It knows the two
things a second writer gets wrong: a key that is not a bare key has to be
QUOTED, and the backslash in an escaped ref has to be ESCAPED inside that
quoting. **A second writer is a second thing to keep agreeing, and this one
did not agree.** The helper also reads the document back with a parser before
it says it planted the key, so a writer that produces something the parser
refuses is caught by the helper and not by the mutator on the next line.

**This is the third time a thing that had to be MEASURED was wrong when it
was only READ** — the review's finding 5 was the same shape, and the fix for
finding 5 was wrong in the same way. The lesson is in the code, not in the
story: a test helper that writes a file the program will read is a piece of
the program, and the only way to know it is right is to let the program read
it.
