#!/usr/bin/env bash
# 301 — the tree `_render_source` stages belongs to one invocation: a second
# `weedr service add` from the same source must not `rmtree` the tree the first
# run staged and has not finished with.
#
# The interleaving is driven, not raced. Run A is started and waited for until
# its staged tree exists, and then A itself is stopped with SIGSTOP — by pid, a
# child of this suite's own, so the stop cannot miss, the thaw cannot fail to
# find it again, and nothing about timing is guessed. A stands there holding a
# tree its `finally` has not removed, with whatever read of it is still to come
# (the rest of its staging, its `loom render`) owed to the thaw, and only then
# does run B stage from the same source — which is where the shared staging path
# answered with an `rmtree` on a tree another run held. Nothing is faked and
# nothing stands in for a tool: the freeze is the order, and what is asserted
# after B is what B's staging did to A's own tree.
#
# The freeze is deliberately on A's process and not on the `runuser`/`loom`
# chain under it: a chain is matched by pattern rather than known by pid, and a
# reader that could not be resumed would wedge this suite instead of proving
# anything. A stopped is enough — the tree is A's until A runs again, whoever
# else is reading it.
#
# machine: fresh

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GUARDEN_PREFIX=/

# Progress on stderr, prefixed and elapsed-timed: this suite drives a frozen
# process, and the runner's wall clock kills a suite with `SIGKILL` — which runs
# no trap and prints no line — so the stage it stopped in has to have been said
# out loud before that. `run` keeps a program's own output in its files, so
# nothing here reaches an assertion's stderr.
_t0=$(date +%s)
stage() {
    printf 't460 %ss: %s\n' "$(( $(date +%s) - _t0 ))" "$*" >&2
}

stage "preamble"
stage_config guarden.toml
stage_poke myapp 9f2c1ab

stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_not_rejected

# The source both runs add from: a real service, whose home is 0700 to itself,
# which is why its render inputs are staged for `loom` at all.
stage "ingest the source"
run weedr service ingest myapp-production --from poke myapp@9f2c1ab
assert_exit 0
assert_stderr_empty

stage_root=/var/lib/guarden/render-source/myapp-production

# A frozen run must not be left frozen by an assertion that fails: the freeze is
# the suite's own instrument, and the thaw is owed whichever way the run ends.
a_job=
thaw() {
    if [ -n "$a_job" ]; then
        kill -CONT "$a_job" 2>/dev/null || true
    fi
    return 0
}
trap thaw EXIT

# --- run A stages, and is frozen holding its tree -----------------------------

# Not `run`: A's capture has to outlive B's, and B uses the harness's own
# stdout/stderr files, so A keeps two of its own and they are folded in below
# once A has finished.
stage "run A: add raceone-staging --from myapp-production"
python3 -m guarden.weedr service add raceone-staging --from myapp-production \
    >"$GUARDEN_FIXTURES/a.out" 2>"$GUARDEN_FIXTURES/a.err" &
a_job=$!

stage "waiting for run A's staged tree"
a_tree=
for ((i = 0; i < 3000; i++)); do
    a_tree=$(find "$stage_root" -name compose.yaml -print -quit 2>/dev/null || true)
    if [ -n "$a_tree" ]; then
        break
    fi
    sleep 0.01
done
[ -n "$a_tree" ] || _fail "run A staged no compose.yaml under $stage_root: $(cat "$GUARDEN_FIXTURES/a.err")"

# The freeze itself: A, by its own pid, once its staged tree is on disk. A is
# stopped where it is — inside the `with _render_source(...)` that holds the
# tree — so the tree cannot be cleaned up, and everything A still owes it (its
# `loom render` if the freeze caught it before that) waits for the thaw.
stage "freezing run A"
kill -STOP "$a_job" 2>/dev/null \
    || _fail "run A ended before it could be frozen: $(cat "$GUARDEN_FIXTURES/a.err")"
stage "run A is stopped with its tree staged"

a_dir=$(dirname "$a_tree")
a_inode=$(stat -c %i "$a_tree")
# The suite's own witness inside A's tree: a second run staging over this path
# deletes it and does not recreate it, and an inode number alone could be handed
# straight back to the file that replaced it.
marker="$a_dir/.run-a-marker"
printf 'run A staged this tree\n' >"$marker"

# --- an entry whose name carries no answerable pid -----------------------------
#
# The reap names each tree after the pid that staged it and asks that pid
# whether it still answers. A stray entry whose "pid" is wider than a pid_t —
# the directory `2147483648-x`, one any root-side leftover can leave in the
# staging parent — is garbage, not a run: `os.kill` raises `OverflowError` at
# the C-int conversion, which is not an `OSError`, and an escape there would
# end run B with a traceback instead of the one diagnostic line the contract
# promises (spec 1.2) — and would keep ending every later staging run from
# this source the same way, until an operator cleaned the entry out by hand.
#
# So the entry is planted before B stages: B must take it and add as always,
# while A — alive, stopped or not — keeps its own tree.

stage "planting an entry whose name carries no pid"
mkdir -p "$stage_root/2147483648-x"

# --- run B stages from the same source while A holds its tree -----------------

stage "run B: add racetwo-staging --from myapp-production"
run weedr service add racetwo-staging --from myapp-production
assert_exit 0
assert_stderr_empty
assert_stdout_has "racetwo-staging"

stage "the stray entry was taken, A's tree was not"
assert_file_missing "$stage_root/2147483648-x"

stage "checking A's tree survived B"
assert_file_exists "$marker"
b_inode=$(stat -c %i "$a_tree" 2>/dev/null || printf 'gone')
[ "$a_inode" = "$b_inode" ] || _fail \
    "run B's staging replaced the tree run A is reading: $a_tree was inode $a_inode, is $b_inode"

# --- A finishes on the tree it staged -----------------------------------------

stage "thawing"
thaw
# `wait` has no deadline of its own, and a reader that never came back would
# hold the runner's wall clock silently until it did. The bound turns that into
# the one line the failure needs: which processes are still standing, and what
# run A said.
stage "waiting for run A to finish"
for ((i = 0; i < 600; i++)); do
    kill -0 "$a_job" 2>/dev/null || break
    sleep 0.1
done
if kill -0 "$a_job" 2>/dev/null; then
    ps -eo pid,ppid,stat,etime,cmd >&2 || true
    _fail "run A did not finish within 60s of the thaw: $(cat "$GUARDEN_FIXTURES/a.err")"
fi
a_rc=0
wait "$a_job" || a_rc=$?
a_job=
cp "$GUARDEN_FIXTURES/a.out" "$GUARDEN_STDOUT"
cp "$GUARDEN_FIXTURES/a.err" "$GUARDEN_STDERR"
GUARDEN_EXIT=$a_rc
stage "run A exited $a_rc"
assert_exit 0
assert_stderr_empty
assert_stdout_has "raceone-staging"

stage "both services listed"
run weedr service list
assert_exit 0
assert_stdout_has "raceone-staging"
assert_stdout_has "racetwo-staging"

# The staging area is per-invocation, so once both runs are done nothing of
# either tree is left behind: no run reads another run's tree, and no run needs
# a tree a later run would have to delete out from under someone.
stage "no staging tree left behind"
run find /var/lib/guarden/render-source -name compose.yaml
assert_exit 0
assert_stdout_empty
assert_dir_empty "$stage_root"
stage "done"
