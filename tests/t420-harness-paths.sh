#!/usr/bin/env bash
# The runner's machine-facing paths, driven where a machine allows (ticket 266).
#
# `tests/t10-failure-messages.sh` pins the runner's failure text by presence,
# and presence cannot see structure. This file EXECUTES the rest of what a
# suite can reach from inside a machine:
#
#   * `tests/lxc.sh` as a child process, on every path that stops before a
#     machine is cut — the usage arm, an unknown flag, the two flags that are
#     opposites, a checkout missing each of its two diagnostic files, a suite
#     whose `# machine:` line is refused, and the pool guard a run reaches
#     once its plan is good and no daemon answers;
#   * `tests/run_plan.sh` on its own — the pattern selection, the host-only
#     list, the declaration arithmetic that gives every suite its machine
#     group, and the run's mode: ticket 266's named residue ("the arithmetic
#     that gives a failing suite its machine group"), which used to be inline
#     in `cmd_run` where nothing could drive it.
#
# Nothing here nests a cut, and that is measured rather than assumed — see the
# first check. What stays uncovered, and the reason for each, is stated at the
# end of the file rather than left implicit.
#
# machine: shared
# read-only: it writes under GUARDEN_FIXTURES only, and every child it runs is
# refused before it can cut, copy or delete a machine (see /bin/false below).

. "$(dirname "$(readlink -f "$0")")/lib.sh"

runner=$GUARDEN_ROOT/tests/lxc.sh
plan_sh=$GUARDEN_ROOT/tests/run_plan.sh

[ -f "$runner" ] || _fail "the runner source is not in the machine at $runner"
[ -r "$plan_sh" ] || _fail "$plan_sh is not in the machine; a run cannot decide a plan without it"

# The scope of this file, measured rather than assumed: nothing here can cut a
# machine, because this guest has no LXD. Both facts are asked of the guest as
# state — the runner's own client is not at the path the runner would use, and
# neither of the two daemon sockets LXD installs exists — and not as a command
# name, which is what the first version of this check asserted: it reddened
# the suite on `command -v lxc` alone, and a name on a guest's PATH says
# nothing about whether a daemon answers, in either direction. If either check
# below goes red, a suite could reach a working daemon, "nothing here nests"
# is false, and this file's argument has to be made again.
if [ -x /snap/bin/lxc ]; then
    _fail "/snap/bin/lxc is present in this guest; the runner's own client is here and t420's scope statement must be re-argued"
fi
for socket in /var/snap/lxd/common/lxd/unix.socket /var/lib/lxd/unix.socket; do
    if [ -e "$socket" ]; then
        _fail "an LXD daemon socket exists in this guest at $socket; a suite could cut a machine and t420's scope statement is false"
    fi
done

# Every child runs the runner with `GUARDEN_LXC` at a path that exists and
# fails: /bin/false is not a stand-in for LXD — nothing here claims a command
# succeeded — it is what makes a cut impossible. With every `lxc` call failing,
# a run can reach its guards but cannot copy, start or delete anything, and
# `lxc_child` refuses any other value below so that no invocation of this file
# can drift onto a daemon that works.
false_lxc=/bin/false
[ -x "$false_lxc" ] || _fail "$false_lxc is missing; every child here needs an executable that cannot cut a machine"

# --- helpers -----------------------------------------------------------------

# plan <tests-dir> <pattern> <fresh> <shared> <reverse>: the decision, taken
# the way the runner takes it — `mode`, then `overridden`, then one line per
# selected suite (`name`, machine, want-fresh) in run order. Driven in a child
# because `_plan` refuses a bad declaration by exiting, and an exit inside a
# command substitution would be a refusal only the subshell ever saw.
plan_script='
. "$1" || exit 1
rc=0
_plan "$2" "$3" "$4" "$5" "$6" || rc=$?
if [ "$rc" -ne 0 ]; then exit "$rc"; fi
printf "mode\t%s\n" "$PLAN_MODE"
printf "overridden\t%s\n" "$PLAN_OVERRIDDEN"
i=0
while [ "$i" -lt "${#PLAN_FILES[@]}" ]; do
    printf "%s\t%s\t%s\n" "${PLAN_FILES[$i]##*/}" "${PLAN_GROUPS[$i]}" "${PLAN_FRESH[$i]}"
    i=$((i + 1))
done
'
plan() {
    run bash -c "$plan_script" plan "$plan_sh" "$@"
}

# lxc_child <repo> <args...>: the runner as a child, with its `lxc` pinned to
# /bin/false. The two checks are the whole safety of this file: they run before
# every invocation, so a child can only ever be handed an executable that fails.
lxc_child() {
    local repo=$1
    shift
    # The pin, and the only value this helper can ever hand the runner: an
    # executable that exists (so the runner's own load guard passes) and fails
    # every call it is given (so no path through the runner can cut, copy or
    # delete a machine).
    [ -x "$false_lxc" ] || _fail "GUARDEN_LXC would not be an executable at $false_lxc"
    [ "$false_lxc" = /bin/false ] || _fail "this suite pins GUARDEN_LXC to /bin/false and it is $false_lxc"
    run env GUARDEN_LXC="$false_lxc" GUARDEN_LXC_POOL_SOURCE="$GUARDEN_FIXTURES/pool" \
        bash "$repo/tests/lxc.sh" "$@"
}

# scratch_repo <name> <test-file>...: a checkout holding just the named test
# files, so a run can be driven against a runner missing one of them without
# touching the tree every suite runs against.
scratch_repo() {
    local dir=$GUARDEN_FIXTURES/$1 f
    shift
    mkdir -p "$dir/tests"
    for f in "$@"; do
        cp "$GUARDEN_ROOT/tests/$f" "$dir/tests/"
    done
    printf '%s\n' "$dir"
}

# --- tests/run_plan.sh is a seam, the way failure_messages.sh is --------------

# Sourcing it runs nothing: no dispatch, no cut, no output. That is the whole
# reason the decision lives in its own file — sourcing `tests/lxc.sh` instead
# would run a run (checked below, on the runner itself).
run bash -c '. "$1"; echo ok' plan "$plan_sh"
assert_exit 0
assert_stdout_has ok
assert_stdout_lines 1

run bash -c '. "$1"
for f in _plan _declaration_of _run_mode; do
    command -v "$f" >/dev/null || exit 1
done' plan "$plan_sh"
assert_exit 0

# And the contrast it exists for: the runner itself executes its dispatch when
# it is sourced, so nothing that lives there can be driven by a suite. The run
# it starts dies at the pool guard — no daemon answers /bin/false — which is
# also the first proof that a child cannot get past provisioning.
run env GUARDEN_LXC="$false_lxc" GUARDEN_LXC_POOL_SOURCE="$GUARDEN_FIXTURES/pool" \
    bash -c '. "$1" run t-nothing-matches-this-pattern' plan "$runner"
assert_exit 1
assert_stderr_has "cannot create the btrfs pool"
assert_stdout_empty

# --- the declaration reader ---------------------------------------------------

seed "$GUARDEN_FIXTURES/two/two.sh" '# machine: fresh' '# machine: shared'
run bash -c '. "$1"; _declaration_of "$2"' plan "$plan_sh" "$GUARDEN_FIXTURES/two/two.sh"
assert_exit 0
# First match, not last: two declarations in one suite are a contradiction, not
# a refinement (docs/tickets/190), and reading the last one would let a file
# carry both answers.
got=$(cat "$GUARDEN_STDOUT")
[ "$got" = fresh ] || _fail "the first declaration of a twice-declared suite is [$got], not [fresh]"

seed "$GUARDEN_FIXTURES/two/silent.sh" '# a suite that says nothing'
run bash -c '. "$1"; _declaration_of "$2"' plan "$plan_sh" "$GUARDEN_FIXTURES/two/silent.sh"
assert_exit 0
assert_stdout_empty

# --- the machine-group arithmetic --------------------------------------------

plan_dir=$GUARDEN_FIXTURES/plan
mkdir -p "$plan_dir"
seed "$plan_dir/t1-shared.sh" '# machine: shared'
seed "$plan_dir/t2-fresh.sh" '# machine: fresh'
seed "$plan_dir/t3-silent.sh" '# a suite that says nothing gets a machine of its own'
seed "$plan_dir/t4-shared.sh" '# machine: shared'
# `t[0-9]` is the selection's shape: a file that does not start with a digit
# after the t is not a suite, whatever it declares.
seed "$plan_dir/two-declarations.sh" '# machine: fresh'

# Declared mode: each `shared` suite takes the next group, each `fresh` suite
# (or one that says nothing) takes the next slot.
expect=$(printf 'mode\tdeclared\noverridden\t0\nt1-shared.sh\tshared-0\t0\nt2-fresh.sh\tfresh-1\t1\nt3-silent.sh\tfresh-2\t1\nt4-shared.sh\tshared-1\t0')
plan "$plan_dir" "" 0 0 0
assert_exit 0
got=$(cat "$GUARDEN_STDOUT")
[ "$got" = "$expect" ] || _fail "declared plan is [$got], expected [$expect]"
assert_stdout_lacks two-declarations.sh

# `--fresh` cuts per file whatever any suite says, and counts the shared
# declarations it overrode — the count the run's closing note prints.
expect=$(printf 'mode\tfresh\noverridden\t2\nt1-shared.sh\tfresh-0\t1\nt2-fresh.sh\tfresh-1\t1\nt3-silent.sh\tfresh-2\t1\nt4-shared.sh\tfresh-3\t1')
plan "$plan_dir" "" 1 0 0
assert_exit 0
got=$(cat "$GUARDEN_STDOUT")
[ "$got" = "$expect" ] || _fail "fresh plan is [$got], expected [$expect]"

# `--shared` is one machine for the run and reads no declaration at all — the
# runner's own header says it ignores every declaration, and a suite with a
# typo'd one is not refused under it, because the refusal belongs to the two
# policies that act on the declaration.
expect=$(printf 'mode\tshared\noverridden\t0\nt1-shared.sh\t0\t0\nt2-fresh.sh\t0\t0\nt3-silent.sh\t0\t0\nt4-shared.sh\t0\t0')
plan "$plan_dir" "" 0 1 0
assert_exit 0
got=$(cat "$GUARDEN_STDOUT")
[ "$got" = "$expect" ] || _fail "shared plan is [$got], expected [$expect]"

# `--reverse` reverses the selection and carries each suite's machine with it,
# because the machine is a property of the suite's place in the sharing order.
expect=$(printf 'mode\tdeclared-reversed\noverridden\t0\nt4-shared.sh\tshared-1\t0\nt3-silent.sh\tfresh-2\t1\nt2-fresh.sh\tfresh-1\t1\nt1-shared.sh\tshared-0\t0')
plan "$plan_dir" "" 0 0 1
assert_exit 0
got=$(cat "$GUARDEN_STDOUT")
[ "$got" = "$expect" ] || _fail "reversed plan is [$got], expected [$expect]"

# The pattern is a substring of the file name, applied before the declaration
# is read — a suite the run did not select is not the run's business.
expect=$(printf 'mode\tdeclared\noverridden\t0\nt1-shared.sh\tshared-0\t0')
plan "$plan_dir" "t1" 0 0 0
assert_exit 0
got=$(cat "$GUARDEN_STDOUT")
[ "$got" = "$expect" ] || _fail "the t1 plan is [$got], expected [$expect]"

expect=$(printf 'mode\tdeclared\noverridden\t0\nt1-shared.sh\tshared-0\t0\nt4-shared.sh\tshared-1\t0')
plan "$plan_dir" "shared" 0 0 0
assert_exit 0
got=$(cat "$GUARDEN_STDOUT")
[ "$got" = "$expect" ] || _fail "the shared-named plan is [$got], expected [$expect]"

# Nothing matched: a plan of nothing, not an error — the run then reports that
# it verified nothing, which is `suitecache report`'s line (t210).
expect=$(printf 'mode\tdeclared\noverridden\t0')
plan "$plan_dir" "no-such-suite" 0 0 0
assert_exit 0
got=$(cat "$GUARDEN_STDOUT")
[ "$got" = "$expect" ] || _fail "an empty selection plans [$got], expected [$expect]"

# Against the live tree: this suite's own declaration is shared, and the
# pattern selects this suite and nothing else, so the plan is one line and it
# names the machine this run is on.
expect=$(printf 'mode\tdeclared\noverridden\t0\nt420-harness-paths.sh\tshared-0\t0')
plan "$GUARDEN_ROOT/tests" "t420-harness-paths" 0 0 0
assert_exit 0
got=$(cat "$GUARDEN_STDOUT")
[ "$got" = "$expect" ] || _fail "this suite's own plan is [$got], expected [$expect]"

# --- a bad declaration is refused, with the runner's own words ---------------

typo_dir=$GUARDEN_FIXTURES/typo
mkdir -p "$typo_dir"
seed "$typo_dir/t9-typo.sh" '# machine: share'

plan "$typo_dir" "" 0 0 0
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "t9-typo.sh declares '# machine: share'; it is 'fresh' or 'shared', and a suite that says neither gets a machine of its own"
assert_stdout_empty

# Under `--fresh` the declaration is read, so the same refusal fires.
plan "$typo_dir" "" 1 0 0
assert_exit 1
assert_stderr_has "t9-typo.sh declares '# machine: share'"

# --- the mode ----------------------------------------------------------------

expect_modes=$(printf '1 0 0 fresh\n1 0 1 fresh-reversed\n0 1 0 shared\n0 1 1 shared-reversed\n0 0 0 declared\n0 0 1 declared-reversed')
while read -r f s r want; do
    run bash -c '. "$1"; _run_mode "$2" "$3" "$4"' plan "$plan_sh" "$f" "$s" "$r"
    assert_exit 0
    assert_stdout_has "$want"
done <<<"$expect_modes"

# A seventh combination is refused rather than named, so a key can never be
# built from a mode that does not exist.
run bash -c '. "$1"; _run_mode 1 1 0' plan "$plan_sh"
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "is not a run mode"

# --- the runner, as a child, on every path that cannot cut -------------------

# The load guard: with no executable at the configured path the runner refuses
# before it dispatches anything, and the usage arm never runs.
run env GUARDEN_LXC="$GUARDEN_FIXTURES/no-such-lxc" bash "$runner" run t420-harness-paths --no-cache
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "$GUARDEN_FIXTURES/no-such-lxc not found; the LXD snap is not installed at that path"
assert_stderr_lacks "usage:"
assert_stdout_empty

# An unknown verb is usage and exit 2, whatever else is wrong with the checkout.
lxc_child "$GUARDEN_ROOT" nonsense-verb
assert_exit 2
assert_one_diagnostic "usage:"
assert_stderr_has "provision|run"
assert_stderr_has "shell|destroy|clean"
assert_stdout_empty

# An unknown flag, refused before the plan and before provisioning. The
# pattern is the run's first positional (`run [pat] [opts]`), so a flag has to
# follow one to be read as a flag at all — a token in the pattern's place is a
# pattern, and refusing it is not this path's business.
lxc_child "$GUARDEN_ROOT" run t420-harness-paths --bogus
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "unknown option for run: --bogus"
assert_stderr_lacks "btrfs pool"

# The two flags that are opposites — again after the pattern.
lxc_child "$GUARDEN_ROOT" run t420-harness-paths --fresh --shared
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "--fresh and --shared are opposites; pass one"
assert_stderr_lacks "btrfs pool"

# A checkout missing failure_messages.sh: the run is stopped by the file it
# cannot name a failure without, before a flag or a machine.
repo_no_messages=$(scratch_repo no-messages lxc.sh run_plan.sh aptlock.sh)
lxc_child "$repo_no_messages" run t-any
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "failure_messages.sh is unreadable; a run cannot name a failure without it"
assert_stderr_lacks "btrfs pool"

# A checkout missing run_plan.sh: `die` still lives in the runner, so the
# refusal is the runner's own, and the usage arm still answers — which is the
# property the tolerant source line exists for (the cleanup verbs must stay
# reachable in a broken checkout).
repo_no_plan=$(scratch_repo no-plan lxc.sh failure_messages.sh aptlock.sh)
lxc_child "$repo_no_plan" run t-any
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "run_plan.sh is unreadable; a run cannot decide a plan without it"
assert_stderr_lacks "btrfs pool"

lxc_child "$repo_no_plan" nonsense-verb
assert_exit 2
assert_one_diagnostic "usage:"

# A good plan, and the run reaches provisioning and stops at its first lxc
# call: with /bin/false the storage show fails, the pool cannot be created, and
# no machine can be cut. `--no-cache` parsed, or the message would be the
# unknown-option one.
repo_ok=$(scratch_repo ok lxc.sh run_plan.sh failure_messages.sh aptlock.sh)
seed "$repo_ok/tests/t1-ok.sh" '# machine: shared'
lxc_child "$repo_ok" run t1-ok --no-cache
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "cannot create the btrfs pool"
assert_stdout_empty

# The wiring that used to be unreachable: cmd_run asks for the plan, and a bad
# declaration in a selected suite stops the run **before** provisioning — the
# pool guard's message is what a run with a good plan reaches, and its absence
# here is the whole assertion.
seed "$repo_ok/tests/t9-typo.sh" '# machine: share'
lxc_child "$repo_ok" run t9-typo
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "t9-typo.sh declares '# machine: share'"
assert_stderr_lacks "btrfs pool"
assert_stdout_empty

# The same refusal across a whole selection: the pattern selects both suites,
# the good one plans, the typo stops the run — again with no cut attempted.
lxc_child "$repo_ok" run "" --no-cache
assert_exit 1
assert_stderr_has "t9-typo.sh declares '# machine: share'"
assert_stderr_lacks "btrfs pool"

# Every flag is parsed: each one alone takes the same route to the pool guard.
for flag in --fresh --shared --reverse --no-cache; do
    lxc_child "$repo_ok" run t1-ok "$flag"
    assert_exit 1
    grep -qF "cannot create the btrfs pool" "$GUARDEN_STDERR" \
        || _fail "$flag was not parsed: $(cat "$GUARDEN_STDERR")"
done

# The provision and shell verbs dispatch (both stop at the same guard; `shell`
# would exec the runner only after provisioning succeeds, which it cannot).
for verb in provision shell; do
    lxc_child "$repo_ok" "$verb"
    assert_exit 1
    grep -qF "cannot create the btrfs pool" "$GUARDEN_STDERR" \
        || _fail "$verb did not dispatch: $(cat "$GUARDEN_STDERR")"
done

# --- the guest wrapper's word, and the trap that reaps the machine -----------

# The wrapper writes `<name> <rc>` and the read-back cats it: one file, one
# format, three places. A split — the wrapper writing one path and the runner
# reading another — is the drift no presence pin on either line alone can see,
# and it turns every rc=1 into "the machine did not confirm".
marker=$(grep -vE '^[[:space:]]*#' "$runner" | grep -cF '/tmp/guarden-suite-status' || true)
[ "$marker" = 3 ] \
    || _fail "the runner's status word is touched on $marker non-comment lines; three is the set (the wrapper's rm, its write, the read-back)"

word=$(grep -vE '^[[:space:]]*#' "$runner" | grep -cF "printf '%s %s'" || true)
[ "$word" = 1 ] \
    || _fail "the guest wrapper's word format is on $word non-comment lines; one is the set"

# An interrupted run still reaps its machine: the teardown is on the trap, not
# on a line that has to be reached.
teardown=$(grep -vE '^[[:space:]]*#' "$runner" | grep -cF "trap '_teardown_runner' EXIT INT TERM" || true)
[ "$teardown" = 1 ] \
    || _fail "the runner's teardown trap is on $teardown non-comment lines; one is the set"

# And the runner really drives the seam this suite asserts about: the source
# line and the plan call. Both are also exercised above through cmd_run, so
# these two are about the call sites a behaviour change could silently drop.
sourced=$(grep -vE '^[[:space:]]*#' "$runner" | grep -cF '. "$REPO/tests/run_plan.sh"' || true)
[ "$sourced" = 1 ] || _fail "the runner sources run_plan.sh on $sourced non-comment lines; one is the set"
planned=$(grep -vE '^[[:space:]]*#' "$runner" | grep -cF '_plan "$REPO/tests"' || true)
[ "$planned" = 1 ] || _fail "the runner asks for the plan on $planned non-comment lines; one is the set"

# --- and the plan is part of every suite's read set --------------------------

# The decision moved out of lxc.sh, so it has to be in the universal read set
# with it: a change to machine assignment must invalidate cached greens the
# same way a change to the runner does.
run python3 "$GUARDEN_ROOT/tests/suitecache.py" readset "$GUARDEN_ROOT/tests/t420-harness-paths.sh"
assert_exit 0
assert_stdout_has "tests/run_plan.sh"
assert_stdout_has "tests/lxc.sh"

# --- what this file does NOT drive, and why ----------------------------------
#
# Nothing here nests a cut, because a guest has no `lxc` (asserted first) and
# a cut is the host's act. The paths that need a host process with a working
# daemon therefore stay uncovered, each for its own reason:
#
#   * `_reset`, `_push`, `_convert`, `_reboot` and `_run_suite`'s exec — the
#     whole cut/push/reset path. No daemon in the guest, by the assertion
#     above; pointing the runner at /bin/false cannot exercise a copy, only
#     prove that every one of its calls fails.
#   * The guest wrapper's own behaviour: `<name> <rc>` written and the suite's
#     code re-raised is produced by the `lxc exec` string, which no child of
#     this suite runs. What is asserted above is the property a change could
#     break silently — one file, one word format — and the rest of the
#     wrapper's contract is pinned in t10-failure-messages.sh.
#   * `_wait_cloud_init`'s fuser guard, its lock-file guard and its poll loop:
#     they shell out to `lxc exec`. Their messages are pinned by
#     t10-failure-messages.sh and their guest half — probe, evidence, the three
#     words — is driven by t370-apt-lock-wait.sh.
#   * `clean` and `destroy`: their whole job is deleting the golden and the
#     pool. `lxc_child` refuses any value of GUARDEN_LXC but /bin/false, under
#     which both verbs delete nothing and print only a list, so the one thing
#     they could prove here — that they dispatch — the usage line already
#     names. The gate's golden is not worth re-proving that.
#   * `_failure_message` (t10), the cache key, the ledger and the report
#     (t210), and the aptlock probe contract (t370) are already driven where
#     they live; this file does not re-drive them.
#   * Repository hygiene (t35-env-schema.sh) is a unit test under just unit, not a VM suite (ADR-0025).
echo "t420-harness-paths: ok"
