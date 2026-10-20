# 333 — the orphaned `fix-instance-r3` worktree: one live bug, one live suite, and a lot of churn

Blockers: none. Found 2026-10-20 by the ticket audit while planning the open-ticket
fleet, and confirmed by measurement on the tree.

## What happened

`git worktree list` showed a worktree at `fix-instance-r3` in **detached HEAD** at
`1ba63a3d`, with **no branch, no remote and no tag** containing that commit. Its
work existed nowhere else: a detached HEAD is a ref that `git gc` is entitled to
collect, and a `git worktree remove` would have taken it with it.

The work was **9 commits on top of `e8659af`**, and develop has moved **97 commits**
past that base since.

## The measurement, commit by commit

`git cherry develop 1ba63a3d` says 7 of the 9 are not in develop by patch-id. But
a patch-id says a commit is not in develop; it does not say its *work* is missing.
The per-patch measurement — does develop's current version of the file already
carry the lines the commit added? — separates the two:

| commit | subject | verdict |
|---|---|---|
| `163be27` | fix(roots): a preview keeps the basic-auth middleware | **ALREADY IN DEVELOP** (23/23 lines) |
| `34cbaed` | fix(roots): an instance's edge router is its own | **ALREADY IN DEVELOP** (47/47 lines) |
| `f9153c4` | test(instances): the red-first assertions for the four P1s | **ALREADY IN DEVELOP** (58/58, 34/34, 42/42 across three files) |
| `55285a8` | fix(weedr): a removal renders the set only when there is one | **ALREADY IN DEVELOP**, re-implemented inline: `develop:src/guarden/weedr.py:492-493` carries the same predicate (`not firewall.unit_installed() and not firewall.SERVICES_CONF.exists()`) with the same reasoning in its docstring. The orphan's version extracted it into `_host_holds_a_set`; develop kept it inline. |
| `f115f67e` | fix(units): a service's own quadlet tree is the service's | **NOT PRESENT — a live bug** (see below) |
| `bdf62b2` | test(previews): a preview that is DIALLED | **NOT PRESENT — a live suite** (see below) |
| `1ba63a3` | test(deploy): the pin is the start step, and the link to 313 says so | **NOT PRESENT** — but its content is the spec/ticket wording that `e24d59d` and `3f24b5e` carry |
| `e24d59d` | docs(tickets): 320 is one number, and 264's decision is the spec's | **SUPERSEDED** — a renumbering. develop's 320 is `320-instance-unit-mode-race.md` and develop's 321 is `321-build-inherits-the-callers-environment.md`. The orphan's numbering is from a world where those numbers were free. Merging it would **renumber develop's live tickets back**. |
| `3f24b5e` | docs(spec): the delta's sentences that named a mechanism that does not exist | **NOT PRESENT** — but see the caveat: this is a spec-text change against a spec that has since moved 97 commits |

## The live bug: `f115f67e`

The orphan's commit fixes a real, still-present defect. `develop:src/guarden/service.py`
`_make_tree` creates the service's own quadlet directory and, for an instance, the
instance's home:

```python
directories += [
    paths.instance_home(name, escaped_ref),
    ...
]
```

It does **not** create the instance's own **quadlet** directory
(`paths.instance_home(...) / paths.QUADLET`). That directory is therefore created
by the first `units.install`, through `conf.write_file`'s `path.parent.mkdir` — so
it is **root-owned with the mutator's umask** (0755, typically) **inside a `0700`
home**. Two things are false at once: the spec's "nothing root-owned lives inside a
service's home", and the service's ability to write its own unit directory. The
mode also depends on who invoked the mutator.

The orphan's fix is two lines in `src/guarden/units.py` — a `_own_directory(path,
owner)` helper called for the unit's directory and for the search-path mirror's —
plus the one line in `service.py`'s `directories` list. It also creates the
`<unit>.container.d` drop-in directory with the service's own user and the tree's
`0700`.

## The live suite: `bdf62b2`

`tests/t442-preview-dial.sh` and `tests/t442-preview-dial.py` do not exist in
develop. The suite fetches a **preview instance** end to end, and the gap it fills
is named in its own header: the other suites each cover one link of the chain
(the edge dials the instance's own publication; the firewall grants the edge's
uid on that port; the route is `Host(...) && PathPrefix(/<ref>)`; the middleware
is carried to the edge), and *"a link that is only covered on its own is a link
nothing proves works together."* The `.py` helper parses the edge's rendered file
with **pyyaml** — the same YAML layer the file goes through before the edge sees
it — because the text alone cannot catch two instances of one preview producing
the SAME router key (a YAML map holds one definition per key, so one router was
served and the other dropped).

## What to build

**Nothing is merged wholesale.** The branch is 97 commits behind and carries a
ticket renumbering that would collide with develop's live tickets.

The two pieces of real work are landed on their own branches, cut from develop:

1. **The `f115f67e` fix**, red-first: a suite that creates an instance and reads
   the mode and the owner of the instance's own quadlet directory, and asserts
   they are the service user's and `0700`. It goes red on develop today.
2. **The `t442` suite**, as a new file under `tests/`, adjusted to develop's
   current fixtures and numbering. It is a whole-product test, so it needs the
   edge's module and a running preview — read `tests/t440-instance-start.sh` and
   `tests/t50-slice.sh` for the shape, and check whether develop's current
   fixture set still carries the pieces it needs.

The ticket renumbering (`e24d59d`) and the spec-text change (`3f24b5e`) are
**dropped, not merged**: the first would renumber develop's live tickets, and the
second was written against a spec that has moved 97 commits — its sentences need
re-deriving against the spec as it is now, not replaying.

## The immediate step, already taken

The branch `fix/instance-r3-orphan` now holds `1ba63a3d`, so the commits are
reachable by name and no `git gc` can collect them. The detached worktree itself
is left in place until the two pieces above are landed; after that it and the
branch can go.

## The test that would have caught it

A suite that creates an instance and reads back the mode and the owner of the
instance's own quadlet directory. It is **not vacuous**: it reads a real
filesystem state that develop gets wrong today — the directory exists, and it is
root-owned with a umask-dependent mode.

## A note on the audit that found it

The audit that found this read `git cherry` and read the two-dot diff, and both
said "7 commits not in develop" and "84 files changed". Neither of those is the
work. The work is the per-patch question — *does develop's file today already
carry these lines* — and it is the only one of the three that separates "a fix
that is missing" from "a fix that was re-implemented by another route".
