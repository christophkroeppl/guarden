#!/usr/bin/env bash
# A cached suite did not run, and this file holds that line (ticket 210).
#
# A cache inherits a result. The only thing that makes inheriting honest is that
# the thing inherited is a **pass**, observed on **this** golden against **this**
# tree — so every way that can go wrong is asserted here rather than assumed:
#
#   * a failure is not recorded, so it can never be inherited;
#   * a record answers only for the golden it was observed on, and the golden's
#     identity is machine-provided, so a rebuilt golden invalidates everything;
#   * a suite that ran on a shared machine is not inherited on a fresh one, and
#     the group it shared and the order the run went in are part of the key;
#   * one changed file invalidates what read it, leaves the rest alone, and an
#     edited suite is never inherited;
#   * a change anywhere in `src/guarden/**` — the package the harness runs —
#     invalidates every key, and a change under `docs/` invalidates none
#     (ticket 309);
#   * a cached suite's line cannot be read as a pass;
#   * `--no-cache` consults nothing;
#   * the cache is outside the repository, and nothing expires.
#
# What this file drives is `tests/suitecache.py`, the helper the harness keys
# with. It is driven as a program, on a real machine, through its command line:
# no internal is imported, so the assertions are about the interface the
# harness actually uses.
#
# machine: shared
# it reads files, computes digests, and writes a cache directory under
# GUARDEN_LXC_CACHE. Nothing here converges a host or starts a machine, so it
# shares a machine with the other suites that only read.
#
# **No file this suite runs against is changed.** Where a change is needed to see
# a digest move, a copy of the tree is built and the copy is changed — the reason
# is in the block that does it, and it is about a suite that is SIGKILLed.

. "$(dirname "$0")/lib.sh"

CACHE="$GUARDEN_FIXTURES/cache"
export GUARDEN_LXC_CACHE="$CACHE"
CACHE_TOOL="$GUARDEN_ROOT/tests/suitecache.py"

SUITE=$GUARDEN_ROOT/tests/t30-create.sh
OTHER_SUITE=$GUARDEN_ROOT/tests/t30-list.sh
SUITE_NAME=${SUITE##*/}

# cache <args...>: the helper, as the harness calls it, so every assertion here
# reads the same captured output and exit code as any other suite's.
cache() {
    run_installed python3 "$CACHE_TOOL" "$@"
}

# key <golden> <suite> <mode> <group>: the harness's key. A pipe rather than
# `cache`, because a key is a value the next command takes as an argument rather
# than something to assert about.
key() {
    python3 "$CACHE_TOOL" key "$1" "$2" "$3" "$4"
}

# golden <created>: the identity the harness reads out of `lxc info`, and its
# digest. A rebuilt golden differs only in the last field, which is what makes a
# rebuild a different golden rather than the same one.
golden() {
    printf 'instance=guarden-golden\npool=guarden-btrfs\nsnapshot=base\ncreated=%s\n' "$1" \
        | python3 "$CACHE_TOOL" golden
}

# is_digest: a sha256 and nothing else. A digest that is empty, or that carries
# an error message, would make every key comparison in this file vacuously true.
is_digest() {
    grep -qE '^[0-9a-f]{64}$' "$GUARDEN_STDOUT" \
        || _fail "not a sha256: $(cat "$GUARDEN_STDOUT")"
}

# --- the identity is machine-provided, or it is refused ---------------------

# A golden with no creation time cannot be told from itself, so a rebuild would
# inherit results from a machine that no longer exists. This is the ticket's
# first requirement, and it is refused rather than defaulted.
cache golden <<'EOF'
instance=guarden-golden
pool=guarden-btrfs
snapshot=base
created=
EOF
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "created"

# A field LXD did not report is a refusal, not a default: an identity that is
# half-filled is not an identity.
cache golden <<'EOF'
pool=guarden-btrfs
snapshot=base
created=2026-10-05 11:20:33 UTC
EOF
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "instance"

# A creation time that is not a timestamp is unreadable rather than normalised.
cache golden <<'EOF'
instance=guarden-golden
pool=guarden-btrfs
snapshot=base
created=yesterday
EOF
assert_exit 1
assert_stderr_has "creation time"

cache golden <<'EOF'
instance=guarden-golden
pool=guarden-btrfs
snapshot=base
created=2026-10-05 11:20:33 UTC
EOF
assert_exit 0
is_digest
GOLDEN=$(cat "$GUARDEN_STDOUT")

REBUILT=$(golden '2026-10-06 09:00:00 UTC')
[ "$REBUILT" != "$GOLDEN" ] || _fail "a rebuilt golden produced the same identity"

# --- a failure is not recorded ----------------------------------------------

KEY=$(key "$GOLDEN" "$SUITE" declared runner-1)

# The helper is given the suite's own exit code, and it refuses anything but a
# pass. A cache with a verb for recording a failure would cache the flakiness
# the ticket is written against: the three non-determinisms this repository paid
# for would each be inherited forever instead of being fixed.
cache put "$GOLDEN" "$KEY" "$SUITE_NAME" declared runner-1 1
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "only an observed pass is recorded"

# Nothing was written, so there is nothing to inherit. This is checked rather
# than inferred from the refusal: a helper that wrote the record and *then*
# complained would pass the assertion above and fail this one.
cache get "$GOLDEN" "$KEY" "$SUITE_NAME"
assert_exit 1

# A pass is recorded, and the record says it was observed rather than assumed.
cache put "$GOLDEN" "$KEY" "$SUITE_NAME" declared runner-1 0
assert_exit 0
cache get "$GOLDEN" "$KEY" "$SUITE_NAME"
assert_exit 0
cache why "$GOLDEN" "$KEY"
assert_exit 0
assert_stdout_has '"outcome": "green"'
assert_stdout_has "$KEY"

# --- the record answers for that golden and no other ------------------------

# The same key under another golden is a miss. The digest is in the directory
# name, so this is a file that does not exist — and the record's own copy of the
# golden is checked as well, which is the case of a record that was moved.
cache get "$REBUILT" "$KEY" "$SUITE_NAME"
assert_exit 1

mkdir -p "$CACHE/$REBUILT"
cp "$CACHE/$GOLDEN/$KEY.json" "$CACHE/$REBUILT/$KEY.json"
cache get "$REBUILT" "$KEY" "$SUITE_NAME"
assert_exit 1

# A record whose outcome is anything but green is not a hit, whatever else
# agrees about it.
seed "$CACHE/$GOLDEN/bogus.json" \
    "{\"golden\":\"$GOLDEN\",\"key\":\"bogus\",\"outcome\":\"red\",\"suite\":\"$SUITE_NAME\"}"
cache get "$GOLDEN" bogus "$SUITE_NAME"
assert_exit 1

# A record that is not readable is a miss, not a crash and not a hit.
seed "$CACHE/$GOLDEN/broken.json" 'not json'
cache get "$GOLDEN" broken "$SUITE_NAME"
assert_exit 1

# Pruning drops another golden's records and says how many went.
# `prune <golden>` keeps <golden> and drops every OTHER, which is the only
# direction that makes sense: a run wants to forget what it cannot inherit from.
# The block passed the rebuilt golden and then expected the in-use one's record to
# survive — the opposite of what it had just asked for.
cache prune "$GOLDEN"
assert_exit 0
cache get "$REBUILT" "$KEY" "$SUITE_NAME"
assert_exit 1
cache get "$GOLDEN" "$KEY" "$SUITE_NAME"
assert_exit 0
cache prune "$GOLDEN"
assert_exit 0
cache get "$GOLDEN" "$KEY" "$SUITE_NAME"
assert_exit 0

# --- the machine a suite ran on is part of the key --------------------------

# `--fresh` and `--shared` are different claims about the machine, and a green
# observed under one is not evidence under the other.
FRESH_KEY=$(key "$GOLDEN" "$SUITE" fresh runner-1)
SHARED_KEY=$(key "$GOLDEN" "$SUITE" shared runner-1)
[ "$FRESH_KEY" != "$SHARED_KEY" ] || _fail "the mode is not part of the key"

cache put "$GOLDEN" "$FRESH_KEY" "$SUITE_NAME" fresh runner-1 0
assert_exit 0
cache get "$GOLDEN" "$FRESH_KEY" "$SUITE_NAME"
assert_exit 0
cache get "$GOLDEN" "$SHARED_KEY" "$SUITE_NAME"
assert_exit 1

# And the group: a shared suite's result is only meaningful beside the exact
# machine it shared, so the same suite in a different group is a different claim.
GROUP_ONE=$(key "$GOLDEN" "$SUITE" shared 3)
GROUP_TWO=$(key "$GOLDEN" "$SUITE" shared 4)
[ "$GROUP_ONE" != "$GROUP_TWO" ] || _fail "the shared group is not part of the key"
cache put "$GOLDEN" "$GROUP_ONE" "$SUITE_NAME" shared 3 0
assert_exit 0
cache get "$GOLDEN" "$GROUP_TWO" "$SUITE_NAME"
assert_exit 1

# And the order, because a shared machine carries the history of whatever ran
# on it before. `just test-reverse` runs the same suites in the opposite order,
# and a green from a reversed run must not answer for the forward run's machine
# — `--reverse` exists to ask whether sharing contaminates, so inheriting across
# it would stop the question being asked.
FORWARD=$(key "$GOLDEN" "$SUITE" declared runner-1)
REVERSED=$(key "$GOLDEN" "$SUITE" declared-reversed runner-1)
[ "$FORWARD" != "$REVERSED" ] || _fail "the run order is not part of the key"
cache put "$GOLDEN" "$REVERSED" "$SUITE_NAME" declared-reversed runner-1 0
assert_exit 0
cache get "$GOLDEN" "$REVERSED" "$SUITE_NAME"
assert_exit 0
# Each record answers for its OWN key and names it, so a reversed green cannot be
# read back as the forward run's result.
cache why "$GOLDEN" "$REVERSED"
assert_exit 0
assert_stdout_has "\"key\": \"$REVERSED\""
assert_stdout_lacks "\"key\": \"$FORWARD\""

# The suite name is in the key and in the record, so a record is never another
# suite's. Checked with a key of its own: overwriting the shared group's record
# would destroy the assertion two lines above.
OTHER_KEY=$(key "$GOLDEN" "$OTHER_SUITE" shared 3)
cache put "$GOLDEN" "$OTHER_KEY" "${OTHER_SUITE##*/}" shared 3 0
assert_exit 0
cache get "$GOLDEN" "$OTHER_KEY" "${OTHER_SUITE##*/}"
assert_exit 0
# The same key read as the first suite is a miss, so a record cannot answer for
# a suite it was not observed on even when the key line is shared.
cache get "$GOLDEN" "$OTHER_KEY" "$SUITE_NAME"
assert_exit 1
# And the first suite's own record is untouched by any of that.
cache get "$GOLDEN" "$GROUP_ONE" "$SUITE_NAME"
assert_exit 0

# --- the key is a function of the tree the suite reads ----------------------

# The read set is over-approximated, and its shape is the claim: a suite must
# carry the shared helper, the fixture inputs and **the whole of the package the
# harness runs out of** (ticket 309).
#
# The narrowing this section used to assert — `src/guarden` cut down to the
# closure of the modules the suite names, walked with `ast` — is what ticket 309
# is written against. It answers "which modules does this text name, resolved
# through `import`", and a suite's result is not a function of that: the harness
# runs programs out of the package, `tools/` names programs on a suite's behalf,
# and a module the walk never reaches from a seed is a green nobody re-checked.
# A src-only change that moved no key is a stale pass, which is the worst thing
# this cache can produce. Which file moves the key and which does not is
# asserted where the files are changed, below.
cache readset "$SUITE"
assert_exit 0
assert_stdout_has "tests/lib.sh"
assert_stdout_has "tests/t30-create.sh"
assert_stdout_has "pyproject.toml"
assert_stdout_has "fixtures/guarden.toml"
assert_stdout_has "src/guarden/templates/quadlet-container.j2"

# The same tree twice is one digest, and two suites with different read sets are
# two. A digest that moved on its own would inherit nothing, and one that never
# moved would inherit everything.
cache tree "$SUITE"
assert_exit 0
is_digest
TREE=$(cat "$GUARDEN_STDOUT")
cache tree "$SUITE"
assert_exit 0
[ "$TREE" = "$(cat "$GUARDEN_STDOUT")" ] || _fail "the same tree produced two digests"
cache tree "$OTHER_SUITE"
assert_exit 0
[ "$TREE" != "$(cat "$GUARDEN_STDOUT")" ] || _fail "two suites produced one tree digest"

# --- one changed file invalidates what read it ------------------------------

# The digest is a function of the bytes, so a change to a file in the read set
# moves the key and the record recorded against the old key is a miss. This is
# the property the whole ticket rests on: a changed suite is run, never
# inherited.
#
# **It is proved on a copy of the tree, never on the one the suites run against.**
# `GUARDEN_LXC_ROOT` points the helper at a scratch tree holding just the files a
# read set names, and the change is made there. Changing the live tree and putting
# it back afterwards is a test that leaks when it fails: the harness kills a
# suite that overruns with SIGKILL, no trap runs, the next suite on this shared
# machine reads a tree one test left modified, and the failure is reported
# against a program that did nothing wrong. A scratch tree cannot leak.
#
# Only the files a read set needs are copied, and they are copied as they are, so
# the digests here are the digests of the real tree's bytes.
TREE_COPY=$GUARDEN_FIXTURES/tree
mkdir -p "$TREE_COPY/src/guarden" "$TREE_COPY/tests" "$TREE_COPY/fixtures" "$TREE_COPY/tools"
cp "$GUARDEN_ROOT/tests/lib.sh" "$TREE_COPY/tests/lib.sh"
cp "$GUARDEN_ROOT/tests/$SUITE_NAME" "$TREE_COPY/tests/$SUITE_NAME"
cp "$GUARDEN_ROOT/fixtures/guarden.toml" "$TREE_COPY/fixtures/guarden.toml"
cp "$GUARDEN_ROOT/tools/golden-vm" "$TREE_COPY/tools/golden-vm"
cp "$GUARDEN_ROOT/pyproject.toml" "$TREE_COPY/pyproject.toml"
# The package is copied whole rather than file by file: a seed whose module is
# missing from the copy makes `read_set` fall back to the whole copy of the
# package, and a copy that fell back would answer the assertion below for the
# wrong reason instead of showing what the read set resolved.
cp -R "$GUARDEN_ROOT/src/guarden/." "$TREE_COPY/src/guarden/"

tree_key() {
    GUARDEN_LXC_ROOT="$TREE_COPY" python3 "$CACHE_TOOL" key "$GOLDEN" "$TREE_COPY/tests/$SUITE_NAME" "$1" "$2"
}

BEFORE=$(tree_key declared runner-1)

# The same unchanged tree answers the same key on a second invocation. The key
# is a hash of names relative to the tree and the bytes under them — nothing
# else — and a key that moved on its own would invalidate every suite on every
# run, so nothing could ever be inherited and the cache would be worth nothing.
[ "$BEFORE" = "$(tree_key declared runner-1)" ] \
    || _fail "the same unchanged tree produced two different keys"

cache put "$GOLDEN" "$BEFORE" "$SUITE_NAME" declared runner-1 0
assert_exit 0

# A file every suite reads: the key moves and the record is a miss.
printf '\n# a change a suite reads\n' >>"$TREE_COPY/tests/lib.sh"
[ "$BEFORE" != "$(tree_key declared runner-1)" ] \
    || _fail "a change to tests/lib.sh did not move the key"
AFTER=$(tree_key declared runner-1)
cache get "$GOLDEN" "$AFTER" "$SUITE_NAME"
assert_exit 1

# Putting it back restores the key exactly, so the recorded result is a hit
# again — the cache follows the bytes and nothing else.
cp "$GUARDEN_ROOT/tests/lib.sh" "$TREE_COPY/tests/lib.sh"
[ "$BEFORE" = "$(tree_key declared runner-1)" ] \
    || _fail "restoring tests/lib.sh did not restore the key"
cache get "$GOLDEN" "$BEFORE" "$SUITE_NAME"
assert_exit 0

# A timestamp is not a change. The key is read from bytes, and one read from
# mtimes would move on every checkout, every copy and every `tar` into a cut —
# nothing could ever be inherited, and the cache would inherit nothing while
# looking like it was working.
touch "$TREE_COPY/tests/lib.sh"
[ "$BEFORE" = "$(tree_key declared runner-1)" ] \
    || _fail "touching a file without changing it moved the key"

# **The package, which is the ticket (309).** `loom.py` is the file the old read
# set could leave out: this suite's closure resolves `weedr` and the modules it
# imports and never reaches `loom`, so a change to it left every recorded green
# standing over code no suite had re-run. Every suite's result is a function of
# the package the harness runs, so the whole of it is in the key — and the key
# moves, the record recorded against the old key is a miss, and the suite runs.
printf '\n# a change in the package\n' >>"$TREE_COPY/src/guarden/loom.py"
[ "$BEFORE" != "$(tree_key declared runner-1)" ] \
    || _fail "a change to src/guarden/loom.py did not move the key"
SRC_AFTER=$(tree_key declared runner-1)
cache get "$GOLDEN" "$SRC_AFTER" "$SUITE_NAME"
assert_exit 1

# Putting it back restores the key exactly, so the recorded result is a hit
# again — the cache follows the bytes of the package and nothing else.
cp "$GUARDEN_ROOT/src/guarden/loom.py" "$TREE_COPY/src/guarden/loom.py"
[ "$BEFORE" = "$(tree_key declared runner-1)" ] \
    || _fail "restoring src/guarden/loom.py did not restore the key"
cache get "$GOLDEN" "$BEFORE" "$SUITE_NAME"
assert_exit 0

# And a file no read set carries leaves the key alone. Without this half the
# mechanism would be sound but useless: a key that moved on any change anywhere
# would invalidate every suite on every edit, and a run would inherit nothing.
#
# `docs/` is where that line sits, and it is deliberate: the ticket asks for a
# docs-only change to move nothing, so the key covers what a suite executes and
# not what it quotes. `src/guarden/loom.py` was the file that used to sit in this
# position as the example — asserting that it was outside every read set was
# asserting the bug; it is in every key now, and the example is `docs/` again.
mkdir -p "$TREE_COPY/docs"
printf '# the specification\n' >"$TREE_COPY/docs/spec.md"
printf '\n# a change outside every read set\n' >>"$TREE_COPY/docs/spec.md"
[ "$BEFORE" = "$(tree_key declared runner-1)" ] \
    || _fail "a change to a file no read set carries moved the key"

# And the suite's own file: a change to the suite is the change that matters most
# of all, and a key that did not move would let an edited suite be inherited.
printf '\n# the suite changed\n' >>"$TREE_COPY/tests/$SUITE_NAME"
[ "$BEFORE" != "$(tree_key declared runner-1)" ] \
    || _fail "a change to the suite itself did not move the key"

# The copy names the same suite file, so the key is a function of the suite's
# name and the bytes rather than of where the tree was found. That is what lets
# the harness key against its own checkout and this suite against a scratch one
# and get the same answer, which is the whole reason the override exists.

# --- what the key covers, and what it costs ---------------------------------

# The read set is the key's claim about the tree, so it is asserted as content
# rather than inferred from a digest: the package as a whole (ticket 309), the
# module definitions whose templates render the units, the runner's own shell
# helpers — a suite runs `tests/aptlock.sh` and `tests/failure_messages.sh`
# beside `lib.sh`, so `tests/*.sh` is carried like `tests/*.py` already was —
# the example services a suite installs as they are, and the tracked
# `.env.schema` a suite resolves.
cache readset "$SUITE"
assert_exit 0
assert_stdout_has "src/guarden/loom.py"
assert_stdout_has "src/guarden/render.py"
assert_stdout_has "src/guarden/weedr.py"
assert_stdout_has "modules/gate-traefik"
assert_stdout_has "examples/services"
assert_stdout_has "tests/aptlock.sh"
grep -qFx '.env.schema' "$GUARDEN_STDOUT" \
    || _fail "the root .env.schema is not in the read set"

# And every name in it is relative to the tree, so the same bytes key the same
# way wherever the checkout sits — no absolute path can enter the hash, which is
# what lets the harness key against its own checkout and a scratch copy against
# another root and get one answer.
! grep -qE '^/' "$GUARDEN_STDOUT" || _fail "the read set carries an absolute path"

# Covering the package means hashing it, so the cost is measured rather than
# assumed: how many files the key covers, and how long a digest over them takes
# on this machine — interpreter start included, which is most of it.
python3 "$CACHE_TOOL" readset "$SUITE" >"$GUARDEN_FIXTURES/readset.list"
READSET_FILES=$(grep -c . "$GUARDEN_FIXTURES/readset.list")
START_NS=$(date +%s%N)
cache tree "$SUITE"
assert_exit 0
is_digest
END_NS=$(date +%s%N)
TREE_MS=$(( (END_NS - START_NS) / 1000000 ))
printf 'note: the key covers %s files; its digest was built in %s ms\n' \
    "$READSET_FILES" "$TREE_MS"
[ "$TREE_MS" -lt 5000 ] || _fail "a key digest took ${TREE_MS}ms, so the key is no longer cheap enough to build per suite"

# --- a cached suite's line cannot be read as a pass -------------------------

# This is the requirement that makes the rest safe. Three properties, asserted
# separately because each could hold while the line still read as a pass to
# someone skimming the tail of a run.
cache line pass "$SUITE_NAME"
assert_exit 0
assert_stdout_has "ok   $SUITE_NAME"
assert_stdout_lacks "inherit"

cache line fail "$SUITE_NAME"
assert_exit 0
assert_stdout_has "FAIL $SUITE_NAME"
# Not the word a pass line is made of. Checked with its padding, because the
# suite's own name contains no `ok` today and a substring search would pass for
# the wrong reason the day a suite was named something like `t40-broken.sh`.
assert_stdout_lacks "ok   "

cache line inherited "$SUITE_NAME"
assert_exit 0
assert_stdout_has "inherit $SUITE_NAME"
assert_stdout_has "green from the cache"
assert_stdout_has "not observed this run"
# Not one of the words a green line carries.
assert_stdout_lacks "ok   "
assert_stdout_lacks "PASS"
assert_stdout_lacks "PASSED"

# A verdict that is not one of the three is refused rather than printed, so a
# caller cannot invent a line that reads as anything at all.
cache line green "$SUITE_NAME"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "is not a verdict"

# --- the summary says how many ran and how many were inherited --------------

LEDGER=$GUARDEN_FIXTURES/ledger

seed "$LEDGER" "pass	t30-create.sh" "pass	t30-list.sh" "inherit	t70-fork.sh"
cache report --ledger "$LEDGER" --golden "$GOLDEN" --cuts 2
assert_exit 0
assert_stdout_has "3 suites"
assert_stdout_has "2 ran"
assert_stdout_has "1 inherited"
assert_stdout_has "0 failures"

# The most dangerous line in the mechanism is the one where nothing ran. A
# summary that said "3 suites" there, with no word about inheriting, would be a
# claim of verification that did not happen.
seed "$LEDGER" "inherit	t30-create.sh" "inherit	t30-list.sh" "inherit	t70-fork.sh"
cache report --ledger "$LEDGER" --golden "$GOLDEN" --cuts 0
assert_exit 0
assert_stdout_has "0 ran"
assert_stdout_has "3 inherited"
assert_stdout_has "verified nothing"

# A run that inherited some of them says which, and says the rest are the only
# observations it made.
seed "$LEDGER" "pass	t30-create.sh" "inherit	t30-list.sh" "inherit	t70-fork.sh"
cache report --ledger "$LEDGER" --golden "$GOLDEN" --cuts 1
assert_exit 0
assert_stdout_has "2 of 3 suites were inherited"
assert_stdout_has "the 1 that ran are the only results this run observed"
assert_stdout_has "--no-cache"

# A ledger that is not there is a report that cannot be written, and it says so
# rather than printing a count of nothing.
cache report --ledger "$GUARDEN_FIXTURES/absent-ledger" --golden "$GOLDEN"
assert_exit 1
assert_one_diagnostic "error:"

# `--no-cache` is the gate's answer, and its summary says the run observed
# everything — the claim a release gate is entitled to make and a cached run is
# not.
seed "$LEDGER" "pass	t30-create.sh" "pass	t30-list.sh" "pass	t70-fork.sh"
cache report --ledger "$LEDGER" --golden "$GOLDEN" --cuts 3 --no-cache
assert_exit 0
assert_stdout_has "--no-cache: all 3 suites ran"
assert_stdout_has "0 inherited"
assert_stdout_lacks "verified nothing"

# --- the cache is outside the repository and is disposable -----------------

# A cache inside the checkout is a claim about the host sitting in a tree meant
# to be read by other people, so the helper refuses the path rather than
# writing there.
GUARDEN_LXC_CACHE="$GUARDEN_ROOT/.suite-cache" cache prune "$GOLDEN"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "inside the repository"
assert_file_missing "$GUARDEN_ROOT/.suite-cache"

# --- there is no expiry -----------------------------------------------------

# Nothing consults a clock to decide whether a result is still good. The check
# is that a record written earlier in this suite is still a hit, with no
# argument that could have expired it: the only inputs are the golden's
# identity and the tree's bytes.
cache get "$GOLDEN" "$KEY" "$SUITE_NAME"
assert_exit 0
assert_file_exists "$CACHE/$GOLDEN/$KEY.json"

echo "t210-cache-suite-results: ok"