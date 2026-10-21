#!/usr/bin/env bash
# A cache key must name a tree, and a record must live under a key that does.
#
# (ticket 309)
#
# A suite's result is cached, and an inherited result is never an observed one
# (spec 11). The whole of that promise rests on the key: it names the tree the
# result was observed against, and the record is filed under it. A key that
# names nothing breaks the promise from the other side — the record is
# inherited by a run whose tree it never ran.
#
# **The empty key is the one that names every tree at once.** `tests/lxc.sh`
# computes a suite's key with `key=$(python3 ... key ...)`, and a computation
# that fails leaves the variable EMPTY. The helper takes the key as an argument,
# so the empty string was a legal place to file a green — the same place for
# every suite and every tree — and a later run inherited it. That is ticket
# 309's own shape: a green inherited over code nothing re-ran, reached through
# a different door.
#
# Two refusals close it, and this file proves both:
#
#   * the helper refuses a key that is not a digest, so no record is written
#     under one and none is read back under one;
#   * the runner checks the status of the computation, so a key it did not
#     compute is neither consulted nor recorded under.
#
# machine: shared
# it reads files, computes digests and writes under GUARDEN_FIXTURES. Nothing
# here converges a host or starts a machine, so it shares a machine with the
# other suites that only read.

. "$(dirname "$0")/lib.sh"

CACHE="$GUARDEN_FIXTURES/cache"
export GUARDEN_LXC_CACHE="$CACHE"
CACHE_TOOL="$GUARDEN_ROOT/tests/suitecache.py"

SUITE_NAME=t211-cache-key-integrity.sh

# cache <args...>: the helper, as the harness calls it, so every assertion here
# reads the same captured output and exit code as any other suite's.
cache() {
    run_installed python3 "$CACHE_TOOL" "$@"
}

# golden <created>: the identity the harness reads out of `lxc info`, and its
# digest. The timestamp is what makes a rebuilt golden a different golden.
golden() {
    printf 'instance=guarden-golden\npool=guarden-btrfs\nsnapshot=base\ncreated=%s\n' "$1" \
        | python3 "$CACHE_TOOL" golden
}

GOLDEN=$(golden '2026-10-05 11:20:33 UTC')

# --- a key that names no result is refused ----------------------------------

# The empty key is the one a failed computation produces, and the one that
# names every tree at once. It must not be a place a green can live.
#
# It is a REFUSAL (2) and not a miss (1): a key that is not a digest is a
# rejected input, not a tree that happens to have changed — and the two must not
# read the same, because one of them means "run the suite" and the other means
# "something is wrong with the key". Exit 2 is this repository's code for a
# rejected input.
cache put "$GOLDEN" "" "$SUITE_NAME" declared runner-1 0
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "digest"

# Nothing was written. A refusal that wrote the record and *then* complained
# would pass the assertion above and fail this one — and the file it would have
# written is the record every later run inherits.
assert_file_missing "$CACHE/$GOLDEN/.json"

# And the empty key is not a hit either: a refusal to record is worth nothing
# if the next run reads the record anyway.
cache get "$GOLDEN" "" "$SUITE_NAME"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "digest"

# A key that is not a digest at all names no tree either, and is refused the
# same way.
cache put "$GOLDEN" "not-a-digest" "$SUITE_NAME" declared runner-1 0
assert_exit 2
assert_one_diagnostic "error:"
assert_file_missing "$CACHE/$GOLDEN/not-a-digest.json"

cache get "$GOLDEN" "not-a-digest" "$SUITE_NAME"
assert_exit 2
assert_one_diagnostic "error:"

# **A key shaped like a path is refused too, and nothing is written outside
# the cache.** The record's path is built from the key, so a key carrying a
# separator writes outside the cache root — and the cache root is the one place
# this mechanism is allowed to write.
cache put "$GOLDEN" "../escape" "$SUITE_NAME" declared runner-1 0
assert_exit 2
assert_one_diagnostic "error:"
assert_file_missing "$CACHE/escape.json"

cache get "$GOLDEN" "../escape" "$SUITE_NAME"
assert_exit 2
assert_one_diagnostic "error:"

# `why` names the record a human is asking about, so a key that names none is a
# refusal rather than a report about nothing.
cache why "$GOLDEN" ""
assert_exit 2
assert_one_diagnostic "error:"

# **The refusal is a refusal and not a wall.** A digest is still a key: the
# helper is not simply saying no to everything. Without this, a `check_key`
# that refused every string would pass every assertion above and break the
# cache entirely — which is the way a test of a refusal goes vacuous.
DIGEST=$(printf 'a%.0s' {1..64})
cache put "$GOLDEN" "$DIGEST" "$SUITE_NAME" declared runner-1 0
assert_exit 0
cache get "$GOLDEN" "$DIGEST" "$SUITE_NAME"
assert_exit 0

# --- the runner refuses a key it did not compute ----------------------------

# The helper refusing a malformed key is the load-bearing half: with it, a
# failed computation cannot be recorded under and cannot be inherited from.
#
# The other half is the runner, because a helper that refused the empty key
# would otherwise turn a failed computation into a dead run: `put` would
# refuse, the runner would `die`, and every suite after this one would go
# unrun. The right answer is that the suite RUNS and nothing is recorded for
# it, which is what "an inherited green is not an observed one" means when
# there is no key to record under.
#
# **The runner's own source is pinned here rather than its behaviour.** The
# runner cannot be driven from inside a machine — `lxc` does not exist there,
# and a failed key computation is not something a suite can cause — so the
# assertion is on the text it runs, the way `t210` pins the venv exclusion in
# the same file. What must hold is that the computation's status is checked and
# that neither call site uses a key it has not checked.
runner=$GUARDEN_ROOT/tests/lxc.sh
[ -f "$runner" ] || _fail "the runner source is not in the machine at $runner"

# A bare `key=$(...)` with nothing after it is the shape the hole has: the
# variable is empty and the run carries on. The negative search is the one that
# names the defect; the positive one is the guard that replaced it.
if grep -nE '^[[:space:]]*(local[[:space:]]+)?key=\$\(python3 ' "$runner"; then
    _fail "the runner computes the key in a bare assignment, so a failed computation leaves the empty key in use"
fi
grep -qE 'if ! key=\$\(python3 ' "$runner" \
    || _fail "the runner does not check the status of the key computation, so a failed computation leaves the empty key in use"

# The record is not written under a key that was never checked, and no record
# is read under one either. The guard is looked for in the lines before each
# call, so the assertion is about the property rather than about one spelling
# of it.
grep -B3 'CACHE_TOOL" put ' "$runner" | grep -qE '\[ -n "\$key" \]' \
    || _fail "the runner records a result under a key it did not check for"
grep -B3 'CACHE_TOOL" get ' "$runner" | grep -qE '\[ -n "\$key" \]' \
    || _fail "the runner consults the cache under a key it did not check for"

echo "t211-cache-key-integrity: ok"
