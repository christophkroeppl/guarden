# 298 — a malformed --template argument answers exit 1 where spec 1.2 requires exit 2

Blockers: none. Found 2026-10-19 by an adversarial review of develop 10f7457
(verified: service.py:363 HOST_NOT_AS_ASSUMED).

## What happens
`require_template` raises HOST_NOT_AS_ASSUMED (exit 1) for `--template ../x` /
`--template BAD`, although spec 1.2 defines exit 2 as "the input was rejected", while
the same-shaped `add --from /tmp` correctly yields 2 (service.py:139-146, pinned by
t250-verb-split.sh:43). docs/sysadmin.md:267 ("what is missing is on the host and not
in the argument") is untrue for that branch — a template NAME is argument, not host.

## What to build
Move the malformed-name rejection to exit 2 (keep the genuinely-missing-installed-set
case at 1 if the spec's host/input split demands it — read spec 1.2 and state the
split), red-first, update the sysadmin sentence.

## The split, on spec 1.2's one line

spec 1.2 draws one line — "The dividing line is input against host. A manifest and a
unit source are input; the filesystem, the installed services and the remote are the
host" — and its table writes `2` for "a name that breaks a rule", adding "Nothing else
writes `2`". Its `needs:` row answers `1` for a provider that does not exist, because
that answer came from the host's registry. The four cases one function answers split on
that line, and which side of it a case falls on is what the code is:

| case | code | why |
|---|---|---|
| a value that breaks the name rule (`../x`, `BAD`) | `2` | the input is at fault, and it is `2` whatever the host holds — the same answer the same-shaped `add --from /tmp` gives |
| no name where a set offered a choice (an empty `--template`, an empty line at the prompt) | `2` | the input named nothing |
| a well-formed name the set does not hold | `1` | the answer came from the host's filesystem — the same reason spec 1.2's `needs:` row answers `1` |
| no name and an empty set | `1` | nothing could be chosen |

## What was built

Three commits, all merged into develop before this card was requeued — `2ee40fe` (the
`code` split in `require_template`), `c6b07e0` (an explicitly empty `--template`
reaches `require_template` as an answer rather than falling through to the chooser) and
`25b2318` (the docstring quotes `names.NAME_RE` instead of restating it). What was
missing when this card was picked up was the **evidence**, and a stale claim in the
document the ticket names.

## The evidence, measured on this branch

A claim about a run rides on the sha it ran on, and the merged commit's quoted RED was
measured on the 2026-10-19 tree — before ticket 330 moved the service templates into the
shipped tree. **The world the quoted stderr describes no longer exists**: it reads
`… holds none`, and the machine prints the set it holds. So the runs below were measured
on this branch, in a real LXD VM, under `GUARDEN_LXC_RUNNER=guarden-run-t298w`.

**What the claim rides on.** This branch's merge base is `38ad235`. The tree the four
runs read is `8fdf48f` (`38ad235` plus the three commits named above); in the GREEN runs
the only path modified in the working tree was this ticket file, which no suite reads,
and in the RED runs `src/guarden/service.py` and `src/guarden/weedr.py` carried the
revert described below. The branch is 31 commits behind `develop`: the card forbids
merging and nothing here merges. The source of the fix (`2ee40fe`, `c6b07e0`) is an
ancestor of develop **and** of this HEAD, so the branch's `src/` carries the fix; it
differs from develop's only where develop has moved on elsewhere. The evidence below is
therefore a claim about `8fdf48f`'s tree, and a green on develop after the merge is a
separate measurement — not this one.

The suite is `tests/t250-verb-split.sh` — the one that already pins `add --from /tmp` at
`2`, so the two refusals are compared by the same suite and on the same machine.

### The GREEN, verbatim, with the fix

The tree is HEAD apart from this ticket file (`git status --short` shows only
`M docs/tickets/298-template-argument-exit-code.md`):

```
$ GUARDEN_LXC_RUNNER=guarden-run-t298w tests/lxc.sh run t250-verb-split --no-cache
ok   t250-verb-split.sh
1 suites: 1 ran, 0 inherited, 0 failures, 1 machines cut
note: --no-cache: all 1 suites ran and every result was recorded
rc=0
```

### The RED, verbatim, with the source reverted to pre-t298

**The revert is of the SOURCE and the tests are kept.** The two files go back to their
pre-t298 form as uncommitted changes, and `tests/lxc.sh` pushes the working tree —
`_reset` ends in `_push "$RUNNER" "$REPO" "$VM_REPO"`, a tar of the checkout — so the
machine runs exactly that source.

`git apply -R --3way` is **not** the revert this tree takes, and an earlier draft of this
section was wrong to say it was clean. `service.py` has moved since `2ee40fe`
(`25b2318` reworded the docstring), so the reverse hunk conflicts and `--3way` leaves
conflict markers. The pre-t298 function is restored from the commit before the fix
instead, and checked byte-for-byte:

```
$ git show 2ee40fe^:src/guarden/service.py | sed -n '/^def require_template/,/^def refuse_existing/p' > /tmp/pre_func.txt
$ sed -n '/^def require_template/,/^def refuse_existing/p' src/guarden/service.py > /tmp/now_func.txt
$ diff -q /tmp/pre_func.txt /tmp/now_func.txt
(no output; the two files are identical)
```

and `weedr.py`'s line is `c6b07e0^`'s:

```
template = service.require_template(args.template or _choose_template()).name
```

`git diff --stat HEAD -- src/` with that revert in the tree:

```
 src/guarden/service.py | 28 +++++-----------------------
 src/guarden/weedr.py   |  8 +-------
 2 files changed, 6 insertions(+), 30 deletions(-)
```

The run:

```
$ GUARDEN_LXC_RUNNER=guarden-run-t298w tests/lxc.sh run t250-verb-split --no-cache
error: expected exit 2, got 1
  stderr: error: the template '../x' is not a template name; available templates: postgres, vaultwarden
error: failed at line 138: return 1 (exit 1)
FAIL t250-verb-split.sh
error: t250-verb-split.sh exited 1; the suite stopped on an assertion, and its own line is above
1 suites: 1 ran, 0 inherited, 1 failures, 1 machines cut
note: --no-cache: all 1 suites ran and every result was recorded
rc=1
```

Line 138 is `assert_exit 2` under `run weedr service create rejectedapp-staging
--template ../x`. **The diagnostic names the defect and not a neighbour**: the exit code
is asserted first, and the stderr it reports is the verb's own refusal on the malformed
name — not a missing file and not a later assertion. The set the stderr names
(`postgres`, `vaultwarden`) is the one the suite's own `soil install --apply` put on the
machine; that is what the RED prints, and it is what the old quote's `holds none` no
longer describes.

### The GREEN again, with the source restored

`git checkout HEAD -- src/guarden/service.py src/guarden/weedr.py`, and the same command:

```
$ GUARDEN_LXC_RUNNER=guarden-run-t298w tests/lxc.sh run t250-verb-split --no-cache
ok   t250-verb-split.sh
1 suites: 1 ran, 0 inherited, 0 failures, 1 machines cut
note: --no-cache: all 1 suites ran and every result was recorded
rc=0
```

### The RED again, with the source reverted

The same revert, applied a second time and measured on a second fresh machine. This is
the control for two things: the suite is not vacuous, and the green above is an
observation rather than a record — `--no-cache` never inherits:

```
$ GUARDEN_LXC_RUNNER=guarden-run-t298w tests/lxc.sh run t250-verb-split --no-cache
error: expected exit 2, got 1
  stderr: error: the template '../x' is not a template name; available templates: postgres, vaultwarden
error: failed at line 138: return 1 (exit 1)
FAIL t250-verb-split.sh
error: t250-verb-split.sh exited 1; the suite stopped on an assertion, and its own line is above
1 suites: 1 ran, 0 inherited, 1 failures, 1 machines cut
note: --no-cache: all 1 suites ran and every result was recorded
rc=1
```

**A revert of the whole file is NOT available here, and that is why the revert is
surgical.** `2ee40fe` and `c6b07e0` are merged into develop, so the pre-t298 tree of
`service.py` and `weedr.py` is many commits behind the current one — `git checkout
2ee40fe^ -- src/guarden/service.py` would revert every change made since, not just the
t298 change. The revert is the pre-t298 body of the one function and the one expression,
applied to the current files.

## What was deliberately NOT changed

- **The exit code of the genuinely-missing-set case.** A well-formed name the installed
  set does not hold is still `1`, and so is an empty set with no flag at all. That is
  spec 1.2's `needs:` row and the ticket's own instruction ("keep the genuinely-missing-
  installed-set case at 1").
- **The refusal's wording.** The line the verb prints is the line the merged commits
  print; only the CODE moved. A diagnostic that names the thing it is about is not
  reworded for tidiness.
- **`docs/spec.md`.** The spec already draws the line this ticket applies — §1.2's
  "The dividing line is input against host" and its table's "a name that breaks a rule"
  row. The code was wrong, not the spec.
- **The templates themselves, and `t260-examples.sh`.** Ticket 330 placed them and
  t260 asserts the installed set; both are correct.
- **The verb surface.** No flag was added, removed or widened, and no verb changed its
  name. The exit code of a refusal is the whole of the change.

## The stale claim this card found

`docs/sysadmin.md:387` said "**No set ships.** … that tree has no `services/`
subdirectory, so on a host that has just been installed `create` is refused before
anything else is asked of it". That has been false since ticket 330 (`851920a`,
2026-10-19) moved the templates into `src/guarden/templates/services/` and the install
phase copies the tree with `cp -r -T` (`hostprep.py:2006`). `810e667` wrote the
paragraph when it was true. `851920a` rewrote the paragraph *below* it — "two copyable
ones … install them with `cp -r examples/services/…`" became "The two service templates
ship with the program" — and left "No set ships" standing a few lines above, so from
that commit the document contradicted itself. `84ae393` then merged a branch's older
copy of `docs/sysadmin.md` over develop's: the result carries the stale paragraph and
does not carry the corrected one at all (`git show 84ae393:docs/sysadmin.md` greps
"**No set ships.**" and greps no "service templates ship").

**Two committed messages describe this slightly differently, and are not amended.**
`57045dd` and `8fdf48f` say `851920a` "replaced" the paragraph and that the re-application
left the old paragraph "beside the new one". The measurement above says otherwise:
`851920a` left this paragraph standing (it corrected a different one further down), and
`84ae393` dropped the corrected one rather than duplicating it. The document is wrong
either way and the fix is the same; a committed message is history, and history is not
rewritten here — the correction is this paragraph.

**The same claim was in a SECOND document, and the same merge undid that too.**
`examples/README.md` said "**no template set ships with guarden**" and told the
operator to install the set by hand:

```
cd /usr/local/src/guarden
install -d -m 0755 /usr/lib/guarden/templates/services
cp -r examples/services/postgres /usr/lib/guarden/templates/services/
```

Both halves are wrong: the set ships, and `examples/services/` was **deleted** by
`851920a` itself, so the `cp` names a path that is not in the repository any more. An
operator following that README gets `cp: cannot stat 'examples/services/postgres': No
such file or directory`. Fixed in `8fdf48f`.

This is the reason AGENTS.md says "One canonical statement per rule … When you change
a rule, grep for it": the claim was stated in two documents, one merge reverted both,
and only the doc the ticket happened to name (`docs/sysadmin.md`) was looked at.

Fixed in `57045dd` (the runbook) and `8fdf48f` (the examples README), with the stderr
in the runbook corrected to the line the machine prints.

**A second stale claim, in the suite's own comment**, was fixed in `d326438`: the block
above the `../x` run said "No template is installed at this point in the suite", and the
suite runs `soil install --apply` at its top. The RED is what showed it — the machine
printed `available templates: postgres, vaultwarden`. The same commit deleted a
duplicated comment block (`0336448` inserted a second copy of a paragraph and orphaned
the first).

## Found, not fixed

- **`docs/sysadmin.md` still carries the two exit-1 example refusals** (`holds none`),
  which are true of a host whose templates were taken away but are no longer the state
  a fresh host is in. `57045dd` reframes them ("The set is empty only on a host whose
  templates were taken away") rather than deleting them, because `t260-examples.sh`
  proves that state by removing the installed set. A reader who runs the two commands
  on a fresh host sees a *different* refusal, and the document does not say so in
  those two lines — it says so in the sentence above them. **This is a readability
  question, not a false claim**, and it is left rather than rewritten a second time.

- **`docs/spec.md` §5.3's `create` row** (`spec.md:1314-1315`) names the flag and the
  verb but says nothing about the exit code of a malformed `--template`. §1.2's table
  already carries the rule, and the spec is the contract — but a reader of §5.3 alone
  does not learn it. Not changed: the spec's exit-code table is §1.2's, and adding a
  row to §5.3 would state the same rule twice (AGENTS.md: "One canonical statement per
  rule").
