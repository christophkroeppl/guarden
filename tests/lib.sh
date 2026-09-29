# tests/lib.sh — the fast harness's shared helpers.
#
# Append to this file only when a helper is genuinely shared, and never
# restructure it: every later ticket's tests are written against what is here.
#
# The seam is the command line (spec 11), so every helper here either runs one
# command or asserts on what running it produced: the exit code, the diagnostic
# lines, the files that appeared or vanished, and the call log. No helper
# imports a program, and no test may.
#
# `run` drives a guarden program, `fake` drives one of the fakes in
# fixtures/bin, and `tool` drives a repo tool. All three capture stdout, stderr
# and the exit code, so an assertion never has to re-run the command.
#
# `set -e` is on so that a failed assertion ends the test file where it failed
# rather than being outvoted by the assertions after it.

set -euo pipefail

GUARDEN_ROOT=${GUARDEN_ROOT:-$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")}
GUARDEN_FIXTURES=${GUARDEN_FIXTURES:-$(mktemp -d)}

# fixtures/bin is first on PATH, so every fake wins over a real tool of the same
# name, and PYTHONPATH is the source tree so the programs run from a checkout
# with nothing installed.
export GUARDEN_FIXTURES
export PATH="$GUARDEN_ROOT/fixtures/bin:$PATH"
export PYTHONPATH="$GUARDEN_ROOT/src"

GUARDEN_STDOUT="$GUARDEN_FIXTURES/stdout"
GUARDEN_STDERR="$GUARDEN_FIXTURES/stderr"
GUARDEN_CALLS="$GUARDEN_FIXTURES/calls.log"

GUARDEN_EXIT=0

_mkdir_guaranteen() {
    mkdir -p "$GUARDEN_FIXTURES"
}

# _capture <command...>: run one command, keep what it said and what it returned.
_capture() {
    _mkdir_guaranteen
    local rc=0
    if "$@" >"$GUARDEN_STDOUT" 2>"$GUARDEN_STDERR"; then
        rc=0
    else
        rc=$?
    fi
    GUARDEN_EXIT=$rc
}

GUARDEN_PROGRAMS="soil weedr loom roots twig furrow hose stakes"

# run <command> [args...]: run one command and capture what it said and returned.
#
# One of guarden's eight programs is run from the working tree as a module,
# which is the same `main` the console script calls. The working tree wins over
# an installed console script, because a test that ran a stale installed copy
# would report on code nobody just edited; set GUARDEN_TEST_INSTALLED=1 to drive
# the shipped entry points instead. Any other command runs as itself.
run() {
    local program=$1
    shift
    if [ "${GUARDEN_TEST_INSTALLED:-0}" = 1 ] && command -v "$program" >/dev/null 2>&1; then
        _capture "$program" "$@"
    elif [[ " $GUARDEN_PROGRAMS " == *" $program "* ]]; then
        _capture python3 -m "guarden.$program" "$@"
    else
        _capture "$program" "$@"
    fi
}

# fake <name> [args...]: run one of the fakes in fixtures/bin.
fake() {
    _capture "$GUARDEN_ROOT/fixtures/bin/$1" "${@:2}"
}

# tool <name> [args...]: run a repo tool.
tool() {
    _capture "$GUARDEN_ROOT/tools/$1" "${@:2}"
}

_fail() {
    printf 'error: %s\n' "$*" >&2
    return 1
}

assert_exit() {
    [ "$GUARDEN_EXIT" = "$1" ] || _fail "expected exit $1, got $GUARDEN_EXIT"
}

assert_stdout_has() {
    grep -qF -- "$1" "$GUARDEN_STDOUT" || _fail "stdout does not name $1"
}

assert_stdout_lacks() {
    if grep -qF -- "$1" "$GUARDEN_STDOUT"; then
        _fail "stdout names $1 and should not"
    fi
}

assert_stderr_has() {
    grep -qF -- "$1" "$GUARDEN_STDERR" || _fail "stderr does not name $1"
}

assert_stderr_lacks() {
    if grep -qF -- "$1" "$GUARDEN_STDERR"; then
        _fail "stderr names $1 and should not"
    fi
}

assert_stdout_empty() {
    if [ -s "$GUARDEN_STDOUT" ]; then
        _fail "stdout is not empty"
    fi
}

assert_stderr_empty() {
    if [ -s "$GUARDEN_STDERR" ]; then
        _fail "stderr is not empty: $(cat "$GUARDEN_STDERR")"
    fi
}

# assert_makes_no_calls <program> [args...]: runs the program and asserts the
# call log did not grow. Counted, not merely absent, so the assertion holds in a
# file where earlier tests have already made calls.
assert_makes_no_calls() {
    local before=0 after=0
    if [ -f "$GUARDEN_CALLS" ]; then
        before=$(wc -l <"$GUARDEN_CALLS")
    fi
    run "$@"
    if [ -f "$GUARDEN_CALLS" ]; then
        after=$(wc -l <"$GUARDEN_CALLS")
    fi
    [ "$before" = "$after" ] || _fail "$* called a tool it has no body to call"
}

# assert_one_diagnostic <prefix>: a diagnostic is one line, prefixed, and names
# the thing it is about (AGENTS.md). Two lines is a defect on its own.
assert_one_diagnostic() {
    local prefix=$1
    local lines
    lines=$(wc -l <"$GUARDEN_STDERR")
    [ "$lines" = 1 ] || _fail "expected one diagnostic line, got $lines"
    grep -qE "^$prefix " "$GUARDEN_STDERR" || _fail "the diagnostic is not prefixed $prefix"
}

assert_stdout_lines() {
    local lines
    lines=$(wc -l <"$GUARDEN_STDOUT")
    [ "$lines" = "$1" ] || _fail "expected $1 lines on stdout, got $lines"
}

assert_file_exists() {
    [ -e "$1" ] || _fail "$1 did not appear"
}

assert_file_missing() {
    if [ -e "$1" ]; then
        _fail "$1 is still there"
    fi
}

assert_file_has() {
    grep -qF -- "$2" "$1" || _fail "$1 does not name $2"
}

assert_executable() {
    [ -x "$1" ] || _fail "$1 is not executable"
}

# assert_fake <name>: the fake is where the spec says it is, PATH resolves to it
# rather than to a real tool of the same name, and it records its own call.
assert_fake() {
    local name=$1
    local path="$GUARDEN_ROOT/fixtures/bin/$name"
    assert_file_exists "$path"
    assert_executable "$path"
    run env sh -c "command -v $name"
    assert_exit 0
    assert_stdout_has "fixtures/bin/$name"
    fake "$name" --version
    assert_exit 0
    assert_called "$name --version"
}

assert_called() {
    [ -f "$GUARDEN_CALLS" ] || _fail "nothing was called"
    grep -qF -- "$1" "$GUARDEN_CALLS" || _fail "no call names $1"
}

assert_not_called() {
    if [ -f "$GUARDEN_CALLS" ] && grep -qF -- "$1" "$GUARDEN_CALLS"; then
        _fail "a call names $1 and should not"
    fi
}

assert_no_calls() {
    if [ -f "$GUARDEN_CALLS" ]; then
        _fail "something was called and should not have been"
    fi
}

# assert_verbs <program> <expected...>: the verbs --help lists are the verbs the
# spec lists, and nothing else. assert_subcommands is the same assertion one
# level down, for `weedr service` and the rest.
assert_verbs() {
    _assert_verb_set "$1" "${@:2}"
}

assert_subcommands() {
    _assert_verb_set "$1 $2" "${@:3}"
}

_assert_verb_set() {
    local path=$1
    shift
    local found expected
    found=$(_verbs_of "$path")
    expected=$(printf '%s\n' "$@" | sort | tr '\n' ' ')
    [ "$found" = "$expected" ] || _fail "$path lists [$found], expected [$expected]"
}

_verbs_of() {
    local path=$1
    set -- $path
    run "$@" --help
    [ "$GUARDEN_EXIT" = 0 ] || _fail "$path --help exited $GUARDEN_EXIT"
    grep -o '{[^}]*}' "$GUARDEN_STDOUT" |
        head -n 1 |
        tr -d '{}' |
        tr ',' '\n' |
        sed 's/ (.*//' |
        tr -d ' ' |
        grep -v '^$' |
        sort |
        tr '\n' ' '
}

# assert_only_alias_rm <program> [group...]: the only parenthesised token in any
# help is `(rm)`. Any second alias, on any verb, would render as its own
# parenthesised token, so this is the whole of "no other verb has one".
assert_only_alias_rm() {
    run "$@" --help
    [ "$GUARDEN_EXIT" = 0 ] || _fail "$* --help exited $GUARDEN_EXIT"
    local token
    while read -r token; do
        [ -n "$token" ] || continue
        [ "$token" = "(rm)" ] || _fail "$* --help shows the alias $token; only remove has one"
    done < <(grep -oE '\([A-Za-z][A-Za-z-]*\)' "$GUARDEN_STDOUT" | sort -u)
}
