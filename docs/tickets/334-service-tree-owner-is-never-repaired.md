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

## The test that would have caught it

A suite that creates an instance, gives its quadlet directory back to root
with the pre-fix mode, and then asks a second install to fix it — which is
what `tests/t333-instance-quadlet-owner.sh`'s second-install block already
does, and it goes red today because the re-ingest is `converged` and walks
nothing. That block is the measurement of this ticket's defect; what it needs
is a product decision about what repairs a tree and when.
