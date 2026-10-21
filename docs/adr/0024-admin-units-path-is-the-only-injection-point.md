# The admin path is the injection point, and there is no staging copy of it

Ticket 306 found two incompatible stories in six documents and one missing
implementation between them. `docs/spec.md` (§2) said admin units live in
`/etc/guarden/services/<name>/units.d/` "until the mutator installs them into
`/etc/containers/systemd/users/<uid>/`", and no code had ever read or written
`units.d` — there was no constant for it, no mode-table row, and no caller.
In the same breath the spec's mode table had no row for the promised path,
ADR-0019's three-file model had already replaced the design the promise
belonged to, `service.py` claimed nothing inside the admin path was read, and
README.md claimed "nothing in guarden reads or rewrites it" — which was false,
because `render._dropins` reads the admin path and merges what it finds into
the rendered unit.

The decision: **the admin path is the injection point, and there is no staging
copy of it anywhere.** The `units.d` path is not implemented, because it must
not be.

## Status

accepted (2026-10-21) — implemented in `fix/t306-work`, amending ADR-0019's
model rather than superseding it.

## The decision

**The admin's own configuration reaches a unit by exactly one path:
`/etc/containers/systemd/users/<uid>/<unit>.container.d/`, read by the
renderer.** There is no second path and no staging copy.

The alternative — implementing the `units.d` → admin-path copy the spec
promised — was refused, and the reason is ADR-0019's own.

**A file has exactly one writer, and an injection point has exactly one
reader.** ADR-0019's model is three files with three writers and no file with
two of them: the base unit (the renderer), `50-guarden-keepid.conf` (the
mutator), `90-admin.conf` (the admin). A `units.d` staging copy would add a
fourth file — a copy of the admin's own file, in a second directory, with a
second writer (whoever wrote the staging copy) and a second reader (the
mutator, copying it into the admin path). Every property ADR-0019's model
buys would then hold twice, with the copies able to disagree:

- **Which copy wins?** The admin path's `90-admin.conf` is the admin's file
  and is never written by guarden. A staged copy of the same file is a
  different file with the same content and no rule saying which one the
  generator reads — and the generator reads exactly one of them, the one in
  the admin path.
- **What does "the admin's file is never deleted" mean?** Today it is exact:
  guarden takes the file it wrote and leaves the admin's where it is
  (`service._drop_admin_units`). With a staged copy there are two admin
  files, and a removal would have to decide what to do with the staged one —
  delete it and lose the admin's configuration, keep it and leave a file
  behind that names a service that no longer exists.
- **Which one is the record?** The admin's file is explicitly not the record
  (the registry holds guarden's pair, and the admin's file does not become
  one). Two files with the same content and only one of them "not the record"
  is a distinction without a difference.

**The admin path is already the injection point, and it is the one the
generator reads.** That is measured, not asserted: a drop-in in the uid-scoped
system path IS picked up for a base unit in the home (`probe-quadlet-dropins.md`
row 8), and `t353-dropin-overrides.sh` proves it end to end on a real
rootless podman — the admin's `90-admin.conf` overrides guarden's pin in the
generated unit, and the container's own `uid_map` says so.

**And the renderer reads it too, which is the half the old spec forgot.**
`render._dropins` reads every `*.conf` in the unit's drop-in directory and
merges it into the unit before generation, so an operator's `[Service]`
`MemoryMax=` lands in the rendered unit (`t40-render.sh` asserts it). That
merge is what makes a cap survive a regeneration, and it is why README.md's
"nothing in guarden reads or rewrites it" was false and had to be corrected.

## What the spec said, and why it was wrong

The promise was not a typo. `docs/spec.md` was rewritten in `fda5a4f` around
a model where a service's admin units were staged in a root-owned directory
and the mutator installed them into the search path — a reasonable shape for
a design where the mutator owned the whole unit. ADR-0019 (2026-10-18/19)
changed it: the admin's file became the admin's own, written directly where
the generator reads it, and the mutator's file became a drop-in beside it.
The `units.d` sentence was left behind by that change, and every document
that repeated it inherited the vestige.

**The mode table is what caught it.** §2.1 says every row is "a row an
implementer must be able to point at", and the promised path had no row —
because there was no code to point at. That is the check that would have
caught this before the review did, and the spec's own rule is why the ticket
is a gap in the documents rather than a missing feature.

## What it costs

- **An operator who followed the old spec has a directory nothing reads.**
  `/etc/guarden/services/<name>/units.d/` is not created by any program and
  is not read by any program. A unit placed there has no effect. The spec
  and the runbook now say where the admin's file goes — the admin path, named
  per unit — and a suite asserts that the staging path is not created, so the
  old shape cannot come back by accident.
- **The admin's file is a systemd drop-in, and that is its vocabulary.** It
  is `[Container]`/`[Service]` keys, merged alphabetically by filename, and
  the last value of a scalar key is the one in force. It is not a guarden
  manifest key, and nothing in guarden's schema accepts it. An operator
  coming from the old spec expected a unit; the file is a drop-in, and the
  runbook says so with an example.

## What this ADR does NOT change

- **ADR-0019's three-file model.** It stands exactly as it is: the base unit
  carries no `UserNS=` line, the mutator writes exactly one file in the admin
  path, and the admin's `90-admin.conf` beside it is never written and never
  deleted by guarden.
- **The admin path's modes.** `0755` on the way down, `0644` on the file
  guarden writes, the admin's file at the admin's own choice — the rows
  §2.1 states, and `t353` asserts.
- **The instance's own drop-in directory**, which is named for the entry
  stem and is the instance's to own.
- **The refusal of a repository's own `Userns=`/`UserNS=`**, and the admin
  file's bypass of it — an admin's own file is not repository input.
