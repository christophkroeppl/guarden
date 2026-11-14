#!/usr/bin/env bash
# tests/run_plan.sh — what a run decides before it cuts anything: which suites
# the pattern selects, which machine each one is on, and the run's mode.
#
# (ticket 266. The failure lines live in `tests/failure_messages.sh` for the
# same reason this file exists: a suite runs *inside* the machine the runner
# cut, where `lxc` does not exist, and `tests/lxc.sh` executes its verb
# dispatch at the bottom of the file — so a suite cannot source the runner:
# sourcing it would run a run. The decision used to be inline in `cmd_run`,
# where nothing outside the runner could reach it, which is the residue ticket
# 266 names: "the arithmetic that gives a failing suite its machine group".)
#
# No dispatch and no side effects: every input is a parameter, and the answer
# goes into the caller's `PLAN_*` variables rather than onto stdout, because a
# caller runs this in its own shell and a plan read through a command
# substitution would be a refusal that only reached the subshell. A suite that
# wants it captured runs it in one anyway.
#
# It is decided **before** the machine is cut, which is a change of order and
# not of answer: the declaration in a suite is input, the cut is the host, and
# this repository's diagnostics rule rejects input before it touches the host.
# Decided up front it also obeys the rule the old position stated but did not
# yet have: the plan is a function of the selection and the tree, never of what
# the run has done so far — the cache must not be able to move a suite from one
# machine group to another, or two runs of the same suites would disagree about
# the machine a green was observed on.

# A suite says whether it needs a machine of its own, in the suite itself:
#
#     # machine: shared
#     # machine: fresh
#
# The declaration is in the file rather than in a list in the runner for the
# reason the ticket gives — it travels with the suite, and a suite that forgets
# it is the safe answer rather than a silent inheritor of another suite's system
# users.
#
# **An absent declaration is `fresh`, and that is the whole of the safety
# argument.** `sed -n 's/^# machine: //p'` reads one line, the value is checked
# against the two words, and anything else is refused by name rather than
# treated as a near miss. A typo that read as "share" would put a suite that
# writes real `/etc/guarden`, real users and real btrfs subvolumes on a machine
# another suite already changed, and the run would be green about a host nobody
# set up.
#
# `sed -n` with one substitution rather than `grep` because the first match is
# the answer: a second declaration in the same suite is a contradiction rather
# than a refinement, and reading the last one would let a file carry both
# answers and depend on which line came last.
_declaration_of() {
    sed -n 's/^# machine: //p' "$1" | head -n 1
}

# _refuse_declaration <name> <declared>: the refusal, printed exactly as `die`
# in `tests/lxc.sh` prints one and exiting the way `die` exits, because a suite
# sourcing this file has no `die` and the two callers must produce the same
# bytes for the same wrong input.
_refuse_declaration() {
    printf 'error: %s\n' "$1 declares '# machine: $2'; it is 'fresh' or 'shared', and a suite that says neither gets a machine of its own" >&2
    exit 1
}

# _run_mode <fresh> <shared> <reverse>: the mode is part of the cache key, and
# it carries two things a run decides.
#
# **The policy**, because `--shared` and `--fresh` put a suite on a machine
# another suite changed, and a green observed that way is a claim about a
# different machine than a green observed on one of its own.
#
# **The order**, because a shared suite's machine carries the history of
# whatever shared suites ran on it before, and `just test-reverse` runs the
# same suites in the opposite order. Without the order in the key, a green
# observed in a reversed run would answer for the forward run's machine — the
# one contamination claim this repository cares most about not making, because
# `--reverse` exists to ask exactly that question.
#
# Six combinations exist and the flags that make a seventh are refused by the
# runner before a plan is asked for; the case below refuses it anyway, because
# a seam whose input it does not check answers about a mode that is not a mode.
_run_mode() {
    case "$1:$2:$3" in
        1:0:0) printf 'fresh\n' ;;
        1:0:1) printf 'fresh-reversed\n' ;;
        0:1:0) printf 'shared\n' ;;
        0:1:1) printf 'shared-reversed\n' ;;
        0:0:0) printf 'declared\n' ;;
        0:0:1) printf 'declared-reversed\n' ;;
        *)
            printf 'error: %s:%s:%s is not a run mode; the six are the fresh, shared and declared flags, each with and without --reverse\n' \
                "$1" "$2" "$3" >&2
            exit 1
            ;;
    esac
}

# _plan <tests-dir> <pattern> <fresh> <shared> <reverse>
#
# Answers, in the caller's scope:
#
#   PLAN_FILES       the selected suites, in run order
#   PLAN_GROUPS      the machine each one is on (`fresh-<slot>`,
#                    `shared-<group>`, or the literal `0` under `--shared`,
#                    where one machine is the whole run)
#   PLAN_FRESH       1 when the suite gets a machine of its own
#   PLAN_MODE        what `_run_mode` names
#   PLAN_OVERRIDDEN  how many `shared` declarations `--fresh` overrode
#
# The loop is one pass and the three decisions it makes are made in the order
# they can be refused: the pattern first (a suite the run did not select is not
# the run's business, so a bad declaration in it is never read), then the
# declaration. `--reverse` reverses the selection
# rather than the machine: sharing is a claim about one suite not contaminating
# the next, and only running the shared ones in both orders asks the question —
# the machine travels with the suite through the reversal, because it is a
# property of the suite's place in the sharing order.
_plan() {
    local tests_dir=$1 pat=$2 fresh=$3 shared=$4 reverse=$5
    local file name i group=0 slot=0 want_fresh machine declared
    local -a rev_files=() rev_groups=() rev_fresh=()
    PLAN_FILES=()
    PLAN_GROUPS=()
    PLAN_FRESH=()
    PLAN_MODE=''
    PLAN_OVERRIDDEN=0
    for file in "$tests_dir"/t[0-9]*.sh; do
        [ -f "$file" ] || continue
        name=${file##*/}
        if [ -n "$pat" ] && [[ "$name" != *"$pat"* ]]; then
            continue
        fi
        # `--shared` reads no declarations at all: it cuts one machine for the
        # whole run whatever any suite says, and the refusal below belongs to
        # the two policies that act on the declaration.
        if [ "$shared" = 1 ]; then
            want_fresh=0
            machine=0
        else
            declared=$(_declaration_of "$file")
            case "$declared" in
                '')
                    want_fresh=1
                    ;;
                fresh)
                    want_fresh=1
                    ;;
                shared)
                    want_fresh=0
                    ;;
                *)
                    _refuse_declaration "$name" "$declared"
                    ;;
            esac
            if [ "$fresh" = 1 ]; then
                want_fresh=1
                machine="fresh-$slot"
                if [ "$declared" = shared ]; then
                    PLAN_OVERRIDDEN=$((PLAN_OVERRIDDEN + 1))
                fi
            elif [ "$want_fresh" = 1 ]; then
                machine="fresh-$slot"
            else
                machine="shared-$group"
                group=$((group + 1))
            fi
        fi
        PLAN_FILES+=("$file")
        PLAN_GROUPS+=("$machine")
        PLAN_FRESH+=("$want_fresh")
        slot=$((slot + 1))
    done
    if [ "$reverse" = 1 ]; then
        for ((i = ${#PLAN_FILES[@]} - 1; i >= 0; i--)); do
            rev_files+=("${PLAN_FILES[$i]}")
            rev_groups+=("${PLAN_GROUPS[$i]}")
            rev_fresh+=("${PLAN_FRESH[$i]}")
        done
        PLAN_FILES=("${rev_files[@]}")
        PLAN_GROUPS=("${rev_groups[@]}")
        PLAN_FRESH=("${rev_fresh[@]}")
    fi
    # The status is checked on purpose: `_run_mode` refuses an impossible
    # combination by exiting, and a refusal raised inside a command
    # substitution returns only to this assignment — unchecked, the run would
    # carry on with an empty mode and a key built from nothing.
    PLAN_MODE=$(_run_mode "$fresh" "$shared" "$reverse") || exit $?
}
