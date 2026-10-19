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
#   * every helper under `tests/` is in every key because it exists, so a new
#     helper moves the key and no suite is inherited against the old one;
#   * a file's execute bit is in the key, because a tool is run and not read;
#   * the developer's `.venv` is not a suite input, so it is neither in the key
#     nor on the machine;
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

# --- every helper under tests/ is in the key, because it exists ------------

# **The read set names the four helpers it knows and stops there.** That is
# the enumeration that lost ticket 309 one file class wide: a
# `tests/newhelper.sh` satisfied no list, was in no read set, and failed
# nothing — so a suite could be inherited against a helper nobody re-ran.
#
# The closure is a NEGATED glob, not a longer list: everything under `tests/`
# that the runner does not select. The runner selects exactly
# `tests/t[0-9]*.sh`, so the negation is every helper, and a helper is
# covered because it exists rather than because someone remembered it.
#
# Every helper the tree has is in the read set, and no suite but this one.
# The list below is the tree's own files with **the runner's own selection**
# removed — the runner selects `$REPO/tests/t[0-9]*.sh`, and the predicate in
# `suitecache.py` is the same one, so the test and the tool cannot disagree
# about what a suite is.
python3 "$CACHE_TOOL" readset "$SUITE" >"$GUARDEN_FIXTURES/readset.list"
while read -r helper; do
    name=${helper#"$GUARDEN_ROOT"/}
    grep -qxF "$name" "$GUARDEN_FIXTURES/readset.list" \
        || _fail "$name is a helper under tests/ and is not in the read set"
done <<<"$(find "$GUARDEN_ROOT/tests" -type f ! -name '*.pyc' | sort | grep -vE '/t[0-9][^/]*\.sh$')"

# The negation is exact: a suite is a suite because the runner says so, and
# the runner's own selection is the predicate. The other suite is a suite, so
# it is not in this suite's read set — which is what keeps two suites two
# read sets rather than one.
if grep -qxF "tests/t30-list.sh" "$GUARDEN_FIXTURES/readset.list"; then
    _fail "the other suite is in this suite's read set, so two suites are one read set"
fi

# A helper is in the read set of EVERY suite, which is the property that
# closes the hole: a new helper joins every suite's read set, so a bug fixed
# in it moves every key and no suite is inherited against the old helper.
python3 "$CACHE_TOOL" readset "$OTHER_SUITE" >"$GUARDEN_FIXTURES/other-readset.list"
grep -qxF "tests/lib.sh" "$GUARDEN_FIXTURES/other-readset.list" \
    || _fail "a helper is not in the other suite's read set either"

# --- a new helper moves the key, and two suites stay two digests ------------

# The executable rule that keeps the hole closed: a helper that is a real file
# under `tests/` is covered because it exists. The change is made on a copy,
# so it cannot leak into the tree the suites run against.
HELPER_COPY=$GUARDEN_FIXTURES/helper-copy
mkdir -p "$HELPER_COPY/tests"
cp "$GUARDEN_ROOT/tests/$SUITE_NAME" "$HELPER_COPY/tests/$SUITE_NAME"

helper_tree_key() {
    GUARDEN_LXC_ROOT="$HELPER_COPY" python3 "$CACHE_TOOL" key "$GOLDEN" \
        "$HELPER_COPY/tests/$SUITE_NAME" "$1" "$2"
}

# The key of the copy without the helper, and the key of the same copy with
# it. The helper is a file that exists and nothing else, so the difference
# between the two keys is the helper.
WITHOUT_HELPER=$(helper_tree_key declared runner-1)
printf '#!/bin/sh\n# a helper that did not exist when the key was written\nexit 0\n' \
    >"$HELPER_COPY/tests/anewhelper.sh"
WITH_HELPER=$(helper_tree_key declared runner-1)
[ "$WITHOUT_HELPER" != "$WITH_HELPER" ] \
    || _fail "a new helper under tests/ did not move the key"

# And the helper is in the read set of the copy, which is the reason the key
# moved: the assertion is about the set, not only about a digest.
GUARDEN_LXC_ROOT="$HELPER_COPY" python3 "$CACHE_TOOL" readset \
    "$HELPER_COPY/tests/$SUITE_NAME" >"$GUARDEN_FIXTURES/helper-readset.list"
grep -qxF "tests/anewhelper.sh" "$GUARDEN_FIXTURES/helper-readset.list" \
    || _fail "the new helper is not in the read set of the copy"

# **Two suites are still two digests.** This is the trap the negation has to
# avoid: a plain glob of `tests/*.sh` would put every suite in every key and
# make one digest for two suites, which is the bug the previous author hit.
# The two read sets differ in exactly one file — each suite's own — and that
# is what keeps them two.
cp "$GUARDEN_ROOT/tests/t30-list.sh" "$HELPER_COPY/tests/t30-list.sh"
GUARDEN_LXC_ROOT="$HELPER_COPY" python3 "$CACHE_TOOL" tree \
    "$HELPER_COPY/tests/$SUITE_NAME" >"$GUARDEN_FIXTURES/helper-tree-one"
GUARDEN_LXC_ROOT="$HELPER_COPY" python3 "$CACHE_TOOL" tree \
    "$HELPER_COPY/tests/t30-list.sh" >"$GUARDEN_FIXTURES/helper-tree-two"
if [ "$(cat "$GUARDEN_FIXTURES/helper-tree-one")" = "$(cat "$GUARDEN_FIXTURES/helper-tree-two")" ]; then
    _fail "two suites produced one tree digest over a tree that has a new helper"
fi

# --- the execute bit is in the key ------------------------------------------

# The tools under `tools/` are exec'd rather than read — `tool` runs them by
# path — so the same bytes without the execute bit is a different result:
# "Permission denied" where the suite expected an answer. A committed
# `100755` to `100644` would move no key at all, and every suite that calls
# the tool would inherit a green observed against a working tool.
TOOLS_COPY=$GUARDEN_FIXTURES/tools-copy
mkdir -p "$TOOLS_COPY/tools" "$TOOLS_COPY/tests"
cp "$GUARDEN_ROOT/tools/golden-vm" "$TOOLS_COPY/tools/golden-vm"
cp "$GUARDEN_ROOT/tests/$SUITE_NAME" "$TOOLS_COPY/tests/$SUITE_NAME"
chmod +x "$TOOLS_COPY/tools/golden-vm"

tools_tree_key() {
    GUARDEN_LXC_ROOT="$TOOLS_COPY" python3 "$CACHE_TOOL" key "$GOLDEN" \
        "$TOOLS_COPY/tests/$SUITE_NAME" "$1" "$2"
}

EXECUTABLE=$(tools_tree_key declared runner-1)
chmod -x "$TOOLS_COPY/tools/golden-vm"
NOT_EXECUTABLE=$(tools_tree_key declared runner-1)
[ "$EXECUTABLE" != "$NOT_EXECUTABLE" ] \
    || _fail "the execute bit of a tool is not in the key"

# The bytes are the same in both, so the difference is the mode and nothing
# else: restoring the bit restores the key exactly.
chmod +x "$TOOLS_COPY/tools/golden-vm"
[ "$EXECUTABLE" = "$(tools_tree_key declared runner-1)" ] \
    || _fail "restoring the execute bit did not restore the key"

# --- the developer's .venv is not a suite input ----------------------------

# A developer's `.venv` supplies the interpreter and the two libraries, and
# the runner's push tars the whole checkout, so it travels into the guest and
# `lib.sh` puts it on PATH. A `pip install` inside it changes what a suite
# runs against without moving any key.
#
# It is not in the key, and the reason is that it is not a suite input: the
# push leaves it behind, so the machine ran against the guest's own
# `python3-yaml` and `python3-jinja2`, not against the developer's.
VENV_COPY=$GUARDEN_FIXTURES/venv-copy
mkdir -p "$VENV_COPY/.venv/bin" "$VENV_COPY/tests"
cp "$GUARDEN_ROOT/tests/$SUITE_NAME" "$VENV_COPY/tests/$SUITE_NAME"
printf '#!/bin/sh\nexit 0\n' >"$VENV_COPY/.venv/bin/python3"

venv_tree_key() {
    GUARDEN_LXC_ROOT="$VENV_COPY" python3 "$CACHE_TOOL" key "$GOLDEN" \
        "$VENV_COPY/tests/$SUITE_NAME" "$1" "$2"
}

NO_VENV=$(venv_tree_key declared runner-1)
printf '# a different library in the venv\n' >>"$VENV_COPY/.venv/bin/python3"
WITH_VENV=$(venv_tree_key declared runner-1)
[ "$NO_VENV" = "$WITH_VENV" ] \
    || _fail "a change in the developer's .venv moved the key, so a pip install invalidates every cached green"

# And the venv is not in the read set either, which is the same claim.
GUARDEN_LXC_ROOT="$VENV_COPY" python3 "$CACHE_TOOL" readset \
    "$VENV_COPY/tests/$SUITE_NAME" >"$GUARDEN_FIXTURES/venv-readset.list"
if grep -qF '.venv' "$GUARDEN_FIXTURES/venv-readset.list"; then
    _fail "the developer's .venv is in the read set, so a pip install invalidates every cached green"
fi

# **And the machine does not have one either.** The key not carrying the venv
# is only half the claim: what the suite actually ran against is the machine's
# own `python3-yaml` and `python3-jinja2`, and the only way to know that is
# to look at the machine. The checkout in the guest is the tree the runner
# pushed, so a `.venv` there would be the developer's, on PATH, supplying the
# interpreter and the two libraries the renderer needs.
assert_file_missing "$GUARDEN_ROOT/.venv"

# And the machine's own libraries are what a program would import there.
run python3 -c 'import yaml, jinja2'
assert_exit 0

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

# **Relocation does not change the key, and that is asserted here rather than
# claimed in a comment.** The copy above holds only part of the read set, so
# its key is a DIFFERENT key from the harness's — the copy is a subset, and a
# subset hashes differently. What must not depend on the root is the answer
# for the same bytes, so the whole read set is copied into a second root and
# the two keys are compared.
#
# The copy names the same suite file, so the key is a function of the suite's
# name and the bytes rather than of where the tree was found. That is what
# lets the harness key against its own checkout and this suite against a
# scratch one and get the same answer, which is the whole reason the override
# exists.
RELOCATED=$GUARDEN_FIXTURES/relocated
mkdir -p "$RELOCATED"
while read -r name; do
    mkdir -p "$RELOCATED/$(dirname "$name")"
    cp --preserve=mode "$GUARDEN_ROOT/$name" "$RELOCATED/$name"
done <"$GUARDEN_FIXTURES/readset.list"
RELOCATED_KEY=$(GUARDEN_LXC_ROOT="$RELOCATED" python3 "$CACHE_TOOL" key "$GOLDEN" \
    "$RELOCATED/tests/$SUITE_NAME" declared runner-1)
[ "$RELOCATED_KEY" = "$(key "$GOLDEN" "$SUITE" declared runner-1)" ] \
    || _fail "the same bytes in a second root answered a different key, so the key depends on where the tree was found"

# --- what the key covers, and what it costs ---------------------------------

# The read set is the key's claim about the tree, so it is asserted as content
# rather than inferred from a digest: the package as a whole (ticket 309), the
# module definitions whose templates render the units, the runner's own shell
# helpers — a suite runs `tests/aptlock.sh` and `tests/failure_messages.sh`
# beside `lib.sh`, and every other file under `tests/` is a helper too, so
# they are carried by the negated glob rather than named one by one (a plain
# glob of `tests/*.sh` would put every other suite in every key) — the
# example services a suite installs as they are, and the tracked
# `.env.schema`.
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
#
# **The bound is on the FILE COUNT, not on a wall clock.** A wall-clock bound
# on a shared machine is a flake wearing a bound's clothes, and a generous one
# (5000ms against a measured ~150ms) cannot catch the regression it names: a
# key that grew 30x would still pass it. The count is what actually holds the
# property — the key is a fixed set of files, so a set that grew is a set
# that grew for a reason, and the reason is a file class that was added
# rather than a file that was longer.
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

# The count is bounded, and the bound is the tree's own: every file under
# `tests/` that is not a suite, plus the covered trees. A key that covers
# more than the tree has is a key that reads something the tree does not
# hold.
TREE_FILES=$(find "$GUARDEN_ROOT/src/guarden" "$GUARDEN_ROOT/fixtures" \
    "$GUARDEN_ROOT/modules" "$GUARDEN_ROOT/packages" "$GUARDEN_ROOT/tools" \
    "$GUARDEN_ROOT/examples" -type f ! -path '*__pycache__*' ! -name '*.pyc' | wc -l)
HELPER_FILES=$(find "$GUARDEN_ROOT/tests" -type f ! -name '*.pyc' | grep -cvE '/t[0-9][^/]*\.sh$')
EXPECTED=$((TREE_FILES + HELPER_FILES + 3))
[ "$READSET_FILES" -le "$EXPECTED" ] \
    || _fail "the key covers $READSET_FILES files and the tree holds $EXPECTED, so it reads something the tree does not"

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