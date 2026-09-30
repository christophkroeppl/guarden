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

# A checkout with no root and no distribution packages still needs pyyaml and
# jinja2, which are the *host's* dependencies (`soil packages` installs the
# distribution's python3-yaml and python3-jinja2, and nothing is fetched at
# deploy time). A local .venv supplies them for the harness; it is not on PATH
# for any host, and if it is absent the programs still answer --help, because
# neither import is at module scope.
if [ -d "$GUARDEN_ROOT/.venv/bin" ]; then
    PATH="$GUARDEN_ROOT/.venv/bin:$PATH"
    export PATH
fi

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
    # A pristine copy, because a helper that reads the captured output — `assert_json`
    # most of all — replaces it, and the next assertion about the same run needs
    # the document the program actually printed.
    cp "$GUARDEN_STDOUT" "$GUARDEN_FIXTURES/last-stdout"
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

# scratch_host: point soil at a directory of its own, and hand back the path.
#
# soil's paths are the absolute ones in spec 2, and the fast harness cannot
# write to the host it runs on. GUARDEN_PREFIX is the program's test seam for
# exactly that, and every test in this file needs a fresh one.
scratch_host() {
    GUARDEN_HOST=$(mktemp -d)
    export GUARDEN_PREFIX="$GUARDEN_HOST"
    host() {
        printf '%s\n' "$GUARDEN_HOST/$1"
    }
}

# seed <path> <line>...: write a file the host is pretending to already have.
seed() {
    local target=$1
    shift
    mkdir -p "$(dirname "$target")"
    printf '%s\n' "$@" >"$target"
}

# say <path> <line>: append one line, for a host file a test is building up.
say() {
    printf '%s\n' "$2" >>"$1"
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

# assert_not_rejected: exit 0 (done or already true) or 1 (the host is not in
# the assumed state), never 2. 2 would mean the input was rejected, and a verb
# that exists cannot reject its own name.
assert_not_rejected() {
    case "$GUARDEN_EXIT" in
        0|1) return 0 ;;
        *) _fail "expected exit 0 or 1, got $GUARDEN_EXIT" ;;
    esac
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

# A ferm rule is a line that starts with "[ ", so the count of rules is the count
# of such lines and the absence of a rule is not the absence of the word.
assert_no_firewall_rule() {
    if grep -qE '^\[ ' "$1"; then
        _fail "$1 carries a firewall rule and should not"
    fi
}

assert_rule_count() {
    local count
    count=$(grep -cE '^\[ ' "$1")
    [ "$count" = "$2" ] || _fail "$1 carries $count rules, expected $2"
}

# assert_file_lacks <path> <text>: a key that must be absent, which is how
# "the gate table is omitted rather than written as a verdict" is checked.
assert_file_lacks() {
    [ -e "$1" ] || return 0
    if grep -qF -- "$2" "$1"; then
        _fail "$1 names $2 and should not"
    fi
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

# assert_called_count <n> <text>: how many calls name the text. Used for the
# claims that are about absence -- no service user, no second group -- where a
# single matching call would not be enough to fail.
assert_called_count() {
    local count
    if [ ! -f "$GUARDEN_CALLS" ]; then
        count=0
    else
        count=$(grep -cF -- "$2" "$GUARDEN_CALLS")
    fi
    [ "$count" = "$1" ] || _fail "expected $1 calls naming $2, got $count"
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

# --- the mutator's host, staged -----------------------------------------------
#
# `GUARDEN_PREFIX` relocates every path the programs use, and the fast harness
# needs it because /etc/guarden, /var/lib/guarden, /etc/snapper and /etc/passwd
# are not a test's to write. See guarden/paths.py for why a single prefix is a
# poor candidate for widening authority.

# guarden_prefix: stage a host and point the programs at it. The `guarden` group
# and a root passwd entry are staged because they are load-bearing rather than
# tidiness: the registry and every overrides.toml are root:guarden and the
# unprivileged programs read them through the group.
guarden_prefix() {
    GUARDEN_HOST=${1:-$GUARDEN_FIXTURES/host}
    mkdir -p "$GUARDEN_HOST/etc/guarden/services" "$GUARDEN_HOST/etc/snapper/configs"
    mkdir -p "$GUARDEN_HOST/var/lib/guarden/services" "$GUARDEN_HOST/var/lib/guarden/registry"
    mkdir -p "$GUARDEN_HOST/var/lib/guarden/removed" "$GUARDEN_HOST/var/lib/guarden/staging"
    mkdir -p "$GUARDEN_HOST/var/lib/guarden/shared" "$GUARDEN_HOST/run/guarden/locks"
    mkdir -p "$GUARDEN_HOST/etc/containers/systemd/users" "$GUARDEN_HOST/proc/sys/net/ipv4"
    mkdir -p "$GUARDEN_HOST/proc/sys/net/ipv6/conf/all" "$GUARDEN_HOST/etc/snapper/configs"
    printf '%s\n' 'root:x:0:0:root:/root:/bin/bash' >"$GUARDEN_HOST/etc/passwd"
    printf '%s\n' 'guarden:x:1000:' 'edge:x:1001:' >"$GUARDEN_HOST/etc/group"
    : >"$GUARDEN_HOST/etc/subuid"
    : >"$GUARDEN_HOST/etc/subgid"
    printf '%s\n' '1' >"$GUARDEN_HOST/proc/sys/net/ipv6/conf/all/disable_ipv6"
    printf '%s\n' '1024' >"$GUARDEN_HOST/proc/sys/net/ipv4/ip_unprivileged_port_start"
    chmod 0750 "$GUARDEN_HOST/var/lib/guarden/registry"
    export GUARDEN_PREFIX="$GUARDEN_HOST"
}

# stage_config <fixture>: the environment table under test.
stage_config() {
    cp "$GUARDEN_ROOT/fixtures/$1" "$GUARDEN_PREFIX/etc/guarden/guarden.toml"
}

# stage_poke <project> <sha>: a poke's staged tree, where guarden itself puts it.
stage_poke() {
    mkdir -p "$GUARDEN_PREFIX/var/lib/guarden/staging/$1/$2"
    cp -r "$GUARDEN_ROOT/fixtures/projects/$1/." "$GUARDEN_PREFIX/var/lib/guarden/staging/$1/$2/"
}

# assert_mode and assert_owner: the mode table in spec 2.1 is a set of claims a
# test has to be able to point at, and `stat` is how it is pointed at. The owner
# is the golden VM's to prove — the fast harness runs unprivileged, so `chown` is
# skipped rather than faked.
assert_mode() {
    local actual
    actual=$(stat -c %a "$1")
    if [ "$actual" != "${2#0}" ]; then
        _fail "$1 is mode $actual, not $2"
    fi
}

assert_owner() {
    local actual
    actual=$(stat -c %U:%G "$1")
    if [ "$actual" != "$2" ]; then
        _fail "$1 is owned by $actual, not $2"
    fi
}

# assert_json <dotted.path> <expected>: one field out of the captured stdout.
#
# The document is copied aside first, because the capture overwrites it. Assert
# the run's exit code before calling this: it replaces GUARDEN_STDOUT with the
# field's value.
assert_json() {
    local path=$1 expected=$2 found
    cp "$GUARDEN_FIXTURES/last-stdout" "$GUARDEN_FIXTURES/target.json"
    if python3 "$GUARDEN_ROOT/tests/jsonfield.py" "$path" <"$GUARDEN_FIXTURES/target.json" \
        >"$GUARDEN_STDOUT" 2>"$GUARDEN_STDERR"; then
        GUARDEN_EXIT=0
    else
        GUARDEN_EXIT=1
    fi
    found=$(cat "$GUARDEN_STDOUT")
    if [ "$found" != "$expected" ]; then
        _fail "$path is $found, expected $expected"
    fi
}

# assert_json_missing <dotted.path>: a field that must not be there, which is
# how "the field set is closed" is checked rather than assumed.
assert_json_missing() {
    local path=$1
    cp "$GUARDEN_FIXTURES/last-stdout" "$GUARDEN_FIXTURES/target.json"
    if python3 "$GUARDEN_ROOT/tests/jsonfield.py" "$path" <"$GUARDEN_FIXTURES/target.json" \
        >/dev/null 2>&1; then
        _fail "$path is a field of this document, and should not be"
    fi
}
