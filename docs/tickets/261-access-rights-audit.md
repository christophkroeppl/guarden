# 261: access rights audit — tighten every file guarden writes

**What to build:** A systematic audit of every file and directory guarden creates, converging each to the tightest mode that still lets the documented readers work. The current state after ticket 260 is:

- `00-ssh.conf` (if it exists) is `0600` — root only
- Everything else under `/etc/guarden/**` is heading toward `0640` (was `0644`)
- `/etc/guarden/projects.toml`, `projects.d/`, `allow-gated-drop` are `0444` so `hose` can read the ref allowlist
- `/etc/guarden/creds/` is `0700` root
- `/etc/ssh/authorized_keys.d/hose` is `0644` root

**Blocked by:** 260 (stub resolver under the deny)

**Status:** backlog

- [ ] Enumerate every path guarden writes in `hostprep.py`, `conf.py`, `firewall.py`, `hosttool.py`, and the mutator verbs
- [ ] For each, state the reader(s) and the tightest mode that serves them
- [ ] Update `MODE_CONFIG`/`MODE_DIR`/`MODE_DIR_GROUP` constants and every `write_file` call to match
- [ ] Add a regression test that fails if any guarden file is world-readable (`0644` or `0755` on files) unless explicitly listed as a carve-out
- [ ] Document the carve-outs in `spec.md §2.1` with the same table that exists today

**Carve-outs to record:**
1. `projects.toml` / `projects.d/` / `allow-gated-drop` — `0444` for `hose`
2. `stakes/` — `0770` for `stakes` (runs as `guarden`)
3. `queue/` — `0770` for `furrow` (runs as `guarden`)
4. `shared/dashboard/` — `0755` for the dashboard service (not in either group)
5. `00-ssh.conf` — `0600` root (if/when created)

**Notes:**
- `UNIT_MODE = 0o644` in `units.py` is for **systemd unit files** which systemd may read as a non-root user in some paths; that is a separate decision and not in scope for this ticket
- A full audit of every file guarden writes has not been done — this ticket tracks doing it
- The change from `0644` to `0640` in `hosttool.py:40` (`MODE_CONFIG`) is the first step; this ticket finishes the job
## Follow-on found by the full gate: t130-paths, and what it says about the group ordering

`a9d18bc` routed `guarden.toml`'s three writers through
`conf.write_file(..., (0, users.group_id(PROGRAM_GROUP)))`. `t130-paths.sh` fails
with

```
error: /tmp/.../usr/lib/guarden/bin/soil did not appear
error: failed at line 254: return 1 (exit 1)
```

Line 254 is `assert_file_exists` in `tests/lib.sh`, not a line in the suite. The
directories `bin/ lib/ modules/ templates/` are all created and all **empty**, so
install built the tree and populated none of it.

Running it by hand names the real failure, and it is a traceback rather than a
diagnostic:

```
guarden.errors.GuardenError: the guarden group does not exist in
/tmp/inst/etc/group; `soil install` creates it
```

**The ordering is correct and is not the bug.** `install_items` puts "the guarden
group exists" first (hostprep.py:1978) and the three `group_id` callers run at
2003, 2119 and 2127 — after it. So a real install creates the group before
anything asks for its gid.

What is true is narrower and worth stating: **`group_id` raises rather than
returning, on any path where the group does not yet exist.** That is the right
behaviour for a program that runs after install, and the wrong behaviour for a
function a test can call against a tree where install has not run. The suite
stages a scratch host and calls the items in a context where the group is
absent, so it gets the raise.

Two readings, and the difference matters:

- **The test is wrong** — it asserts the tree is populated without arranging for
  the group, and the fix is to have the suite ensure the account first, which
  `ensure_accounts` in `tests/lib.sh` already does for other suites.
- **The code is too strict** — an item that writes `root:guarden` should be able
  to say "the group is not there yet" rather than raise, so a converge that
  creates the group in the same run can still write its files.

The second is the better shape for a converge, and it is also what
`a9d18bc` should have done rather than assuming the group is always present.
Not fixed here: it needs the reading chosen first, and the suite failure is a
symptom of the decision rather than the thing to patch.

### Narrowed further: `group_id` reads a staged `/etc/group` that install never writes

`paths.py:43` is `GROUP = ETC / "group"` and `ETC = PREFIX / "etc"`, so it honours
`GUARDEN_PREFIX`. That is right for reading a staged tree and wrong for asking
the kernel a question.

`install_items` creates the group with `h.run_or_die("groupadd", "--system",
PROGRAM_GROUP)` — which writes the **real** `/etc/group`. But `group_id` reads
`$GUARDEN_PREFIX/etc/group`. Under a scratch prefix:

```
$ GUARDEN_PREFIX=/tmp/i4 soil install --apply
guarden.errors.GuardenError: the guarden group does not exist in
/tmp/i4/etc/group; `soil install` creates it
```

The group exists on the host the whole time — `getent group guarden` answers
`guarden:x:986:` — and install created it there. `group_id` is looking in the
staged tree for a file that nothing in install ever writes, because `groupadd`
cannot be staged.

**So the two are asking different questions.** `groupadd` answers "does this
host have the group", which `getent` answers truthfully. `group_id` asks "does
the staged tree name it", which nothing maintains.

The fix is to make `group_id` ask the host — `grp.getgrnam(name).gr_gid` — rather
than parsing `$GUARDEN_PREFIX/etc/group`. A gid is a property of the system, not
of the tree a test stages; reading it out of a file copy is what makes the two
disagree. The file exists to be *read* by programs that need the mapping, and
using it as the source of truth for a live lookup is the inversion.

That is a small change with a real blast radius — `group_id` is used by every
`root:guarden` write `a9d18bc` introduced — so it wants the suites that assert
ownership run against it before it lands, not after.
