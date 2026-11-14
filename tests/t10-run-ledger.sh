#!/usr/bin/env bash
# The run's ledger, and the summary computed from it (ticket 328).
#
# A gate's summary — "N suites: X ran, Y inherited, Z failures" — is the claim
# that everything passed, and it is computed from the run's own ledger rather
# than from counters a caller could set. On the 2026-10-21 gate that ledger's
# directory was pruned mid-run: every append failed, the per-suite lines still
# printed, and the run reached its end holding a record that could not be read.
# **A run that cannot read its own record must not speak for itself**, and the
# summary is exactly the thing that would be believed.
#
# The runner cannot be driven from here — a suite runs inside the machine, where
# `lxc` does not exist — so this file has the two halves the harness allows it:
#
#   * the summary, driven as a program. `tests/suitecache.py report` is handed a
#     ledger this file writes, empties and deletes, and must refuse anything but
#     one line per suite the run selected. The count is the run's selection and
#     never the file's, so a ledger that lost its lines cannot be summarised as
#     a smaller run that passed.
#   * the runner's own text, pinned: where the ledger lives, that every write to
#     it is fatal, and that the summary is printed only when the tool succeeded.
#
# **The boundary, stated so it is not mistaken for more**: the second half is
# presence and adjacency checks on the runner's text, and a residue remains that
# only executing the runner could close — an edit that keeps every literal (an
# `exit 0` inserted before the run's exit test) is invisible to a text pin. No
# in-machine suite can execute a host process, which is the same boundary
# `tests/t10-failure-messages.sh` states (ticket 266).
#
# machine: shared
# it reads the checkout and writes only under GUARDEN_FIXTURES; it converges
# nothing and cuts nothing, so it shares a machine with the other read-only
# suites.

. "$(dirname "$0")/lib.sh"

CACHE_TOOL="$GUARDEN_ROOT/tests/suitecache.py"
LEDGER=$GUARDEN_FIXTURES/ledger
GOLDEN=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef

# cache <args...>: the summary tool, called the way the runner calls it, so
# every assertion here reads what the runner would read.
cache() {
    run_installed python3 "$CACHE_TOOL" "$@"
}

# --- a summary is computed only from the whole run's record -----------------
#
# The defect the ticket measured, in the summary's own terms: the file holds one
# suite of the three the run selected. A summary computed from it is a claim
# about work that is not in the record, and the count that separates the two is
# the run's own selection — which is why `report` is given it.
seed "$LEDGER" $'pass\tt30-create.sh'
cache report --ledger "$LEDGER" --selected 3 --golden "$GOLDEN" --cuts 2
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "$LEDGER"
assert_stderr_has "holds 1 suite line(s)"
assert_stderr_has "selected 3"
# Nothing on stdout: the summary is the thing that would be believed, so a run
# that cannot certify itself prints none at all.
assert_stdout_empty

# A ledger holding none of the run's lines is the worst case, because the
# summary it produces reads as a run with nothing to report rather than as a
# lost record.
: >"$LEDGER"
cache report --ledger "$LEDGER" --selected 3 --golden "$GOLDEN" --cuts 0
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "holds 0 suite line(s)"
assert_stdout_empty

# More lines than the run selected is another run's record — or this one's,
# written twice — and it cannot certify this run either.
seed "$LEDGER" $'pass\ta.sh' $'pass\tb.sh' $'pass\tc.sh' $'pass\td.sh'
cache report --ledger "$LEDGER" --selected 3 --golden "$GOLDEN" --cuts 2
assert_exit 1
assert_stderr_has "holds 4 suite line(s)"
assert_stdout_empty

# The measured failure, reproduced: the ledger's own directory is removed
# partway through the run. The file is gone with it, and what comes back names
# the ledger rather than a count of nothing.
GONE=$GUARDEN_FIXTURES/gone
seed "$GONE/ledger" $'pass\ta.sh' $'pass\tb.sh'
rm -rf "$GONE"
cache report --ledger "$GONE/ledger" --selected 2 --golden "$GOLDEN" --cuts 2
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "cannot read the run's ledger"
assert_stderr_has "$GONE/ledger"
assert_stdout_empty

# And a ledger that accounts for every selected suite is a summary, in the shape
# a gate is read for: the verdict, the work it observed, and the machines it
# cost. This is the control the four refusals above are measured against — a
# tool that refused everything would pass them all and certify nothing.
seed "$LEDGER" $'pass\tt30-create.sh' $'inherit\tt30-list.sh' $'pass\tt70-fork.sh'
cache report --ledger "$LEDGER" --selected 3 --golden "$GOLDEN" --cuts 2
assert_exit 0
assert_stdout_has "3 suites: 2 ran, 1 inherited, 0 failures, 2 machines cut"
assert_stdout_has "1 of 3 suites were inherited, not run"

# --- the runner keeps that record where the run owns it ---------------------
#
# The path half of the ticket, pinned because it cannot be executed from here.
# A ledger under `mktemp` resolves under `TMPDIR`, and on 2026-10-21 the host
# pruned that directory out from under a live gate. The run's state directory is
# the suite cache's sibling and is created by the run, so a fresh clone needs
# nothing and no pruner owns it.
runner=$GUARDEN_ROOT/tests/lxc.sh
[ -f "$runner" ] || _fail "the runner source is not in the machine at $runner"

under_tmp=$(grep -vE '^[[:space:]]*#' "$runner" | grep -cE '^[[:space:]]*ledger=.*mktemp' || true)
[ "$under_tmp" = 0 ] \
    || _fail "the run's ledger is created under mktemp again ($under_tmp site(s)); TMPDIR is the host's to prune and the record goes with it"

state=$(grep -vE '^[[:space:]]*#' "$runner" | grep -cE '^RUN_STATE=\$\{GUARDEN_LXC_RUN_STATE:-.*\}[[:space:]]*$' || true)
[ "$state" = 1 ] \
    || _fail "the runner no longer takes the run's state directory from GUARDEN_LXC_RUN_STATE; an uncorrectable path is the one thing this ticket cannot have"

path=$(grep -vE '^[[:space:]]*#' "$runner" | grep -cE '^[[:space:]]*ledger=\$RUN_STATE/\$RUNNER/ledger[[:space:]]*$' || true)
[ "$path" = 1 ] \
    || _fail "the run's ledger is not the harness-owned path keyed by the runner name ($path site(s)); two streams would tally each other's suites"

created=$(grep -vE '^[[:space:]]*#' "$runner" | grep -cE '^[[:space:]]*: >"\$ledger" \|\| die ' || true)
[ "$created" = 1 ] \
    || _fail "the run's ledger is not created up front, and a ledger that cannot be created is not fatal"

# **Every append is fatal.** This is what makes the failure arrive where it
# happened instead of at the end of a long run: a write that fails is a record
# that has already stopped being the run's, and continuing only produces a tally
# nobody can trust.
writes=$(grep -vE '^[[:space:]]*#' "$runner" | grep -c '>>"\$ledger"' || true)
[ "$writes" = 4 ] \
    || _fail "the runner writes the run's ledger $writes time(s); four is the measured set (inherit, the cut's failure, a pass, a suite's failure)"
fatal=$(grep -A1 -E '>>"\$ledger"[[:space:]]*\\$' "$runner" | grep -cE '^[[:space:]]*\|\| _ledger_lost ' || true)
[ "$fatal" = "$writes" ] \
    || _fail "$fatal of $writes ledger writes are fatal; a lost line that does not end the run is the 2026-10-21 failure"
lost=$(grep -A2 -E '^_ledger_lost\(\) \{' "$runner" | grep -c 'die ' || true)
[ "$lost" -ge 1 ] \
    || _fail "_ledger_lost does not stop the run, so a failed write only prints and the run sums nothing"

# **The summary is the run's verdict, so the count it is checked against is the
# run's own selection, and a refusal has to end the run.** Falling through after
# a refused summary was the other half of the measured failure: the exit test
# reads a counter in memory, so a run whose record could not be read exited 0.
selected=$(grep -vE '^[[:space:]]*#' "$runner" | grep -cF -- '--selected "$total"' || true)
[ "$selected" = 1 ] \
    || _fail "the runner does not hand the summary the run's own selection; a ledger that lost lines then reads as a smaller run that passed"
checked=$(grep -vE '^[[:space:]]*#' "$runner" | grep -cE 'report "\$\{report_args\[@\]\}" \|\| die ' || true)
[ "$checked" = 1 ] \
    || _fail "the runner's summary is not checked; a refused summary leaves the run to exit on its counter"
