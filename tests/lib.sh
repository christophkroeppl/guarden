# tests/lib.sh — the harness's shared helpers.
#
# Append to this file only when a helper is genuinely shared, and never
# restructure it: every later ticket's tests are written against what is here.
#
# The seam is the command line (spec 11), so every helper here either runs one
# command or asserts on what running it produced: the exit code, the diagnostic
# lines, and the files that appeared or vanished. No helper imports a program,
# and no test may.
#
# `run` drives a guarden program and `tool` drives a repo tool. Both capture
# stdout, stderr and the exit code, so an assertion never has to re-run the
# command.
#
# **There is no stand-in on `PATH` and there is no call log** (ADR-0014, spec
# §11). A helper here that needs the machine's answer reads the machine: the
# "real-host state" section at the bottom is what replaced the call-log
# assertions, because a call log records an intent and these record an outcome.
#
# `set -e` is on so that a failed assertion ends the test file where it failed
# rather than being outvoted by the assertions after it.
#
# `set -E` (errtrace) makes the ERR trap fire inside function bodies. Without it,
# a failure in `run` or `_capture` ends the suite silently because the trap never
# runs there — exactly the symptom ticket 262 describes.
set -Eeuo pipefail

# A suite that dies on a command rather than on an assertion has said nothing at
# all, and the line it died on is the whole of what is missing. `set -e` is what
# stops a suite at its first failure rather than being outvoted by the assertions
# after it, and this is what turns its silence into a report: the same reason
# `tests/lxc.sh` gives a suite a wall clock.
#
# It does not fire inside a condition, so a helper that tests a command with `||`
# or `if` is not reported twice.
trap 'printf "error: failed at line %s: %s (exit %s)\n" "$LINENO" "$BASH_COMMAND" "$?" >&2' ERR

GUARDEN_ROOT=${GUARDEN_ROOT:-$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")}
GUARDEN_FIXTURES=${GUARDEN_FIXTURES:-$(mktemp -d)}

# GUARDEN_FIXTURES is a scratch directory and nothing more: it is not a
# directory of stand-ins, and the tests that use it are staging a file a program
# then reads or writes.
#
# PYTHONPATH is the source tree so the programs run from a checkout with nothing
# installed. Nothing else goes on PATH ahead of the machine: a stand-in that
# wins over a real tool is a tool that lies, and this repository has paid for
# that twice. tests/t10-no-fakes.sh holds that line.
export GUARDEN_FIXTURES
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

GUARDEN_EXIT=0

_mkdir_guaranteen() {
    mkdir -p "$GUARDEN_FIXTURES"
}

# _capture <command...>: run one command, keep what it said and what it returned.
#
# `|| rc=$?` rather than `if ... then ... else rc=$?; fi`: a command killed by a
# signal does not return an exit status, so the `if` guard never runs and `set -e`
# ends the script on the spot — before any assertion can print. That is why a
# failure here is silent: no `error:` line, no captured output, just a stop.
_capture() {
    _mkdir_guaranteen
    local rc=0
    # A subshell isolates signals: if the command is killed by SIGPIPE (curl
    # getting its connection closed early), the subshell dies but the parent
    # shell survives to record the exit code and captured output.
    ("$@" >"$GUARDEN_STDOUT" 2>"$GUARDEN_STDERR") || rc=$?
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
    # NOT $GUARDEN_EXIT. A suite that runs a verb expected to fail -- `run
    # weedr service build` then `assert_exit 1` -- dies here under `set -e`
    # before the assertion that was written to handle it. Measured: removing
    # this line is what keeps t10-help green. The status is read by assert_exit,
    # which is the right consumer; `run` reports only whether it ran.
}

# run_in <dir> <program> [args...]: run a command from a directory the target user
# can enter.
#
# A service-user command is refused by the harness, not by guarden: `run` executes
# from the suite's own GUARDEN_ROOT, which is a 0700 root tree, and podman chdirs
# there before it reads anything — so `runuser -u svc -- podman …` fails with
# "cannot chdir … Permission denied" before podman has done any work. `runuser`
# also rewrites HOME and PWD, so a `cd` inside a subshell is not enough either.
run_in() {
    local dir=$1
    shift
    _capture env -C "$dir" "$@"
}

# scratch_host: point soil at a directory of its own, and hand back the path.
#
# soil's paths are the absolute ones in spec 2, and the VM is a throwaway one
# that a test may write to. GUARDEN_PREFIX is the program's test seam, and a
# suite that needs a host of its own makes a fresh one.
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

# tool <name> [args...]: run a repo tool.
tool() {
    _capture "$GUARDEN_ROOT/tools/$1" "${@:2}"
}

# run_installed <path> [args...]: run something at a path that is not one of
# guarden's own programs — the pinned `podlet` under `/usr/lib/guarden/bin`, an
# installed unit, a repository's script.
#
# Not `run`: that dispatches by program *name* through the wrapper and passes only
# the first argument through, so `run "$path" --version` runs the binary as a
# command named after itself and the wrapper answers "unknown run mode". This is
# the same capture, with the arguments intact.
run_installed() {
    _capture "$@"
}

_fail() {
    printf 'error: %s\n' "$*" >&2
    return 1
}

# The exit code alone is rarely the whole of what a program said, and a suite that
# stops on the code leaves the diagnostic inside a temporary the next run
# overwrites. So the failure names what the program wrote, which is the one thing
# the person reading the failure needs and cannot get any other way.
assert_exit() {
    if [ "$GUARDEN_EXIT" = "$1" ]; then
        return 0
    fi
    printf 'error: expected exit %s, got %s\n' "$1" "$GUARDEN_EXIT" >&2
    if [ -s "$GUARDEN_STDERR" ]; then
        sed 's/^/  stderr: /' "$GUARDEN_STDERR" >&2
    fi
    return 1
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

# text_has <captured text> <literal>: whether an already-captured text names it.
#
# **This is the shape a suite must use instead of `printf '%s' "$text" | grep
# -q`.** `grep -q` exits at its first match, so the producer is still writing
# when the reader closes the pipe; it takes SIGPIPE, `pipefail` turns the
# pipeline into 141, and the caller reads "no match" for text that is right
# there. A here-string has no producer to signal.
#
# **0 and 1 are the only answers.** Anything else is `grep` failing to decide —
# a death by signal included — and it fails the suite rather than answering "no
# match". The pass arm of a negative assertion is exactly 1, so "I could not
# read it" must never land there: that is the direction in which this shape is
# silent.
text_has() {
    local rc=0
    grep -qF -- "$2" <<<"$1" || rc=$?
    case $rc in
        0 | 1) return "$rc" ;;
        *)
            _fail "grep exited $rc deciding whether the captured text names $2"
            return 1
            ;;
    esac
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

# assert_dir_exists <dir>: the directory is there. The pair to
# `assert_file_exists` for a directory a program creates — the payload
# directory inside a `state` volume is one (ADR-0020), and "the file exists"
# would answer a different question than "the directory is there".
assert_dir_exists() {
    [ -d "$1" ] || _fail "$1 is not a directory"
}

assert_file_missing() {
    if [ -e "$1" ]; then
        _fail "$1 is still there"
    fi
}

assert_file_has() {
    grep -qF -- "$2" "$1" || _fail "$1 does not name $2"
}

# assert_dir_empty <dir>: the directory exists and holds nothing.
#
# The pair to `assert_file_exists` for a generator's output: a systemd generator
# directory that is present but empty says the generator ran and produced nothing,
# which is a different fact from one that was never created, and only one of them
# is a defect.
assert_dir_empty() {
    [ -d "$1" ] || _fail "$1 does not exist"
    local entries
    entries=$(ls -A "$1" 2>/dev/null | wc -l)
    [ "$entries" = 0 ] || _fail "$1 holds $entries entries and should hold none"
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
    # `grep -c` exits 1 when it counts ZERO, and a rules-less file is a real
    # state (a host with no service yet) rather than an error — so the count is
    # taken with the status ignored, and the comparison below is what decides.
    # Same shape as `assert_file_lacks`: an empty result is not a failure of
    # the helper, it is the answer.
    count=$(grep -vE '^[[:space:]]*(#|$)' "$1" | grep -cE '^[[:space:]]+(jump|proto|mod|ip|if|daddr|iif) ' || true)
    [ "$count" = "$2" ] || _fail "$1 carries $count rules, expected $2"
}

# assert_file_lacks <path> <text>: a key that must be absent, which is how
# "the gate table is omitted rather than written as a verdict" is checked.
# Comments are excluded: a unit explaining why it lacks a directive names it.
#
# **The producer is captured, and the reason is a measurement.** The filter was
# a pipeline into `grep -q`, and `grep -q` exits at its first match — so the
# producer got SIGPIPE while it was still writing, `pipefail` turned that into
# exit 141, and the pipeline's status was the SIGPIPE rather than the match.
# The consequence was silent and total: **the assertion could not fail on a
# file bigger than one pipe buffer.** Measured on this tree's own
# `docs/sysadmin.md` (86,716 bytes, 1,497 filtered lines): the string was
# present at byte 1,156 and the helper reported it absent. A negative
# assertion that cannot fail is not a weak assertion, it is no assertion at
# all, and it was silent about that.
#
# **And `grep -v` exits 1 when it filters EVERYTHING out.** A file that is all
# comments — a rendered firewall file with no rules in it yet, which is exactly
# what a host with no grants and no services has — leaves the filter with
# nothing to print, so `grep -vE` exits 1, the assignment takes that status,
# and under `set -e` the whole SUITE dies on a file it was only inspecting.
# Measured: `t160-grants.sh` failed at this line with
# `error: failed at line 311: grep -vE … (exit 1)` and named no assertion at
# all, because the assertion never ran. **An empty filter is not an error and
# it is not a match**, so exit 1 is tolerated below and exit >1 is not.
#
# `-a` into a scratch file: a binary's `grep -v` answer is stderr-only, so a
# captured filter passes vacuously; exit 2 means it could not be searched.
assert_file_lacks() {
    [ -e "$1" ] || return 0
    [ -f "$1" ] || _fail "$1 is not a regular file, so it cannot be searched for $2"
    local filtered status=0
    filtered=$(mktemp)
    grep -a -vE '^[[:space:]]*(#|;)' -- "$1" >"$filtered" || status=$?
    if [ "$status" -gt 1 ]; then
        rm -f "$filtered"
        _fail "$1 could not be searched for $2 (grep exit $status)"
    fi
    if grep -aqF -- "$2" "$filtered"; then
        rm -f "$filtered"
        _fail "$1 names $2 and should not"
    fi
    rm -f "$filtered"
}

assert_executable() {
    [ -x "$1" ] || _fail "$1 is not executable"
}

# assert_elf <path>: the file is an ELF object, which is what separates a program
# from an archive that was installed under a program's name.
#
# The executable bit does not: an XZ file named `podlet` and made 0755 is
# present, is executable, and is not a program, and that is the state a fetch
# without an unpack step leaves behind. Four bytes at offset 0 is the whole
# distinction, so it is read with `od` rather than guessed at from a `file` that
# a minimal image may not carry.
assert_elf() {
    local magic
    magic=$(od -An -N4 -tx1 -- "$1" 2>/dev/null || true)
    [ "$magic" != "" ] || _fail "$1 is not there, so it is not an ELF object"
    magic=${magic//[[:space:]]/}
    [ "$magic" = "7f454c46" ] || _fail "$1 starts with 0x$magic, which is not an ELF header"
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

# **The first `{verb list}` block is taken by capture, not by `grep -o | head`.**
# `head -n 1` exits after its first line, so `grep -o` is still writing when the
# pipe closes, takes SIGPIPE, and `pipefail` makes the whole assignment exit
# 141 — a false red that ends the suite on a help output that is perfectly
# readable. Captured first, the first block is a parameter expansion, and every
# reader left in the pipeline reads to the end of its input. A help that names
# no block fails here: an unreadable help is not a program with no verbs.
_verbs_of() {
    local path=$1
    set -- $path
    run "$@" --help
    [ "$GUARDEN_EXIT" = 0 ] || _fail "$path --help exited $GUARDEN_EXIT"
    local blocks first
    blocks=$(grep -o '{[^}]*}' "$GUARDEN_STDOUT" || true)
    first=${blocks%%$'\n'*}
    [ -n "$first" ] || {
        _fail "$path --help names no {verb list}"
        return 1
    }
    printf '%s\n' "$first" |
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
    # `|| true` because `grep -oE` exits 1 when it matches nothing, and the ERR
    # trap fires for it — measured, and the location is the part worth writing
    # down: the trap runs **inside the process substitution's own subshell**
    # (`BASHPID` differs from the parent's), because `set -E` makes ERR inherited
    # there. The suite still passed, since the substitution's status is discarded
    # — so a GREEN run printed `error: failed at line 363: sort -u (exit 1)` once
    # per call, thirteen times, which reads as thirteen failures.
    #
    # `|| true` is what stops it: a command followed by `||` is not the final
    # command in the list, so neither `set -e` nor the ERR trap fires for it.
    # Measured both ways — with the `|| true` there is no trap line, without it
    # there is. The assertion is unchanged: no parenthesised token means no
    # violation, which is what an empty input to the loop already expressed.
    while read -r token; do
        [ -n "$token" ] || continue
        [ "$token" = "(rm)" ] || _fail "$* --help shows the alias $token; only remove has one"
    done < <(grep -oE '\([A-Za-z][A-Za-z-]*\)' "$GUARDEN_STDOUT" | sort -u || true)
}

# --- the mutator's host, staged -----------------------------------------------
#
# `GUARDEN_PREFIX` relocates every path the programs use, and a suite that must
# not touch the VM's own /etc/guarden, /var/lib/guarden or /etc/snapper stages
# one instead. It does not relocate the host's *identity* databases, because it
# cannot: `useradd` writes the machine's /etc/passwd and a program reading
# `$GUARDEN_PREFIX/etc/passwd` is reading another database than the one it was
# promised. See guarden/paths.py for why a single prefix is a poor candidate for
# widening authority.

# guarden_prefix: stage a host and point the programs at it. A staged host is
# guarden's own tree and nothing else: `/etc/guarden`, `/var/lib/guarden`,
# `/etc/snapper`, `/etc/containers/systemd/users`, and the two sysctl values a
# host invariant is checked against.
#
# **No identity is staged, and that is the rule rather than an omission.** There is
# no `/etc/passwd`, `/etc/group`, `/etc/subuid` or `/etc/subgid` here, because a real
# `useradd` writes the machine's four and a program that reads `$GUARDEN_PREFIX/etc/passwd`
# is reading a different database from the one it just asked to be written to. A suite
# that stages those files *and* lets a real tool create a service user asserts against two
# databases and is about neither: `weedr service ingest` created `qapp-production` on the
# machine, read back the staged file, found nothing, and reported "qapp-production was
# created but is not in <staged>/etc/passwd" — which is a true sentence about two
# databases rather than a fact about a service.
#
# So a suite that needs real identity — a real `useradd`, a real uid, a real
# `/etc/subuid` range — sets `GUARDEN_PREFIX=/` and drives the machine's own tools, the
# way `t20-*`, `t30-*`, `t40-untrusted`, `t70-*` and `t130-*` do (ticket 35: "a suite
# that needed a staged host gets a real one"). A suite that stages one has no `useradd`
# in its path, so it is not testing identity and does not get a pretend database to make
# it look as though it were. `guarden/paths.py` is why one prefix is a poor candidate for
# widening authority.
guarden_prefix() {
    GUARDEN_HOST=${1:-$GUARDEN_FIXTURES/host}
    mkdir -p "$GUARDEN_HOST/etc/guarden/services" "$GUARDEN_HOST/etc/snapper/configs"
    mkdir -p "$GUARDEN_HOST/var/lib/guarden/services" "$GUARDEN_HOST/var/lib/guarden/registry"
    mkdir -p "$GUARDEN_HOST/var/lib/guarden/removed" "$GUARDEN_HOST/var/lib/guarden/staging"
    mkdir -p "$GUARDEN_HOST/var/lib/guarden/shared" "$GUARDEN_HOST/run/guarden/locks"
    mkdir -p "$GUARDEN_HOST/etc/containers/systemd/users" "$GUARDEN_HOST/proc/sys/net/ipv4"
    mkdir -p "$GUARDEN_HOST/proc/sys/net/ipv6/conf/all" "$GUARDEN_HOST/etc/snapper/configs"
    printf '%s\n' '1' >"$GUARDEN_HOST/proc/sys/net/ipv6/conf/all/disable_ipv6"
    printf '%s\n' '1024' >"$GUARDEN_HOST/proc/sys/net/ipv4/ip_unprivileged_port_start"
    chmod 0750 "$GUARDEN_HOST/var/lib/guarden/registry"
    export GUARDEN_PREFIX="$GUARDEN_HOST"
}

# stage_config <fixture>: the environment table under test.
stage_config() {
    cp "$GUARDEN_ROOT/fixtures/$1" "$GUARDEN_PREFIX/etc/guarden/guarden.toml"
    getent group guarden >/dev/null 2>&1 || groupadd --system guarden
    chmod 0640 "$GUARDEN_PREFIX/etc/guarden/guarden.toml"
    chown root:guarden "$GUARDEN_PREFIX/etc/guarden/guarden.toml"
}

# ensure_accounts: the guarden and operator accounts every suite that installs or
# renders needs. One helper rather than the nine copies this had, because a suite
# that creates only the GROUP dies on `KeyError: 'guarden'` (the renderer reads the
# user's uid) and one that omits the account entirely dies on the firewall refusing
# to render: "there is no 'operator' account, and it is the uid the edge's API accept
# set names". useradd exits 9 when the GROUP exists and -g was not given, so the
# group is created first — that mistake was in three suites at once.
ensure_accounts() {
    getent group guarden >/dev/null 2>&1 || groupadd --system guarden
    id -u guarden >/dev/null 2>&1 || useradd --system --no-create-home \
        --shell /usr/sbin/nologin --gid guarden guarden
    getent group operator >/dev/null 2>&1 || groupadd --system operator
    id -u operator >/dev/null 2>&1 || useradd --create-home --gid operator --shell /bin/bash operator
}

# stage_poke <project> <sha>: a poke's staged tree, where guarden itself puts it.
stage_poke() {
    mkdir -p "$GUARDEN_PREFIX/var/lib/guarden/staging/$1/$2"
    cp -r "$GUARDEN_ROOT/fixtures/projects/$1/." "$GUARDEN_PREFIX/var/lib/guarden/staging/$1/$2/"
}

# install_pinned_converter: the pinned podlet release, installed into this suite's
# staged host by the phase that owns the fetch.
#
# A suite that feeds a `compose.yaml` to the renderer needs a converter, and the
# renderer resolves it at the pinned path under `GUARDEN_PREFIX` rather than on
# PATH — the fetch is digest-verified, and a PATH lookup would run whatever a
# repository put first on the renderer's path (spec 6.3, ADR-0012). There is no
# second way to get one: no stand-in and nothing on `PATH` (ADR-0014), no
# hand-copied binary, and no flag that skips the digest. So this seeds the record
# this repository ships and runs `soil packages --apply`, which fetches, compares
# the artefact's digest before it unpacks anything, and installs the one member
# named `podlet`.
#
# The phase is asked for the converter and not for a converged host, so the exit
# is 0 or 1 and only a 2 would be a refusal: a package that would not install is
# drift on a throwaway machine, and the item this suite needs is not that one. The
# ELF header and the answer are asserted because "the file exists" is the state the
# pin exists to prevent; `t20-podlet.sh` is where that claim is the whole subject.
install_pinned_converter() {
    install -D -m 0644 "$GUARDEN_ROOT/src/guarden/templates/podlet.release" \
        "$GUARDEN_PREFIX/etc/guarden/podlet.release"
    run soil packages --apply
    assert_not_rejected
    assert_elf "$GUARDEN_PREFIX/usr/lib/guarden/bin/podlet"
    run_installed "$GUARDEN_PREFIX/usr/lib/guarden/bin/podlet" --version
    assert_exit 0
    assert_stdout_has "podlet"
}

# assert_mode and assert_owner: the mode table in spec 2.1 is a set of claims a
# test has to be able to point at, and `stat` is how it is pointed at. The VM
# runs as root, so `chown` is a real one and the owner is a real fact.
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

assert_link() {
    local found
    found=$(readlink "$1")
    if [ "$found" != "$2" ]; then
        _fail "$1 points at $found, not $2"
    fi
}

# ---- real-host state -------------------------------------------------------
#
# These assert what the machine actually holds. They replace the call-log
# helpers, which could only ask a fake what it had been asked to do: a call log
# records an intent, and these record an outcome. Every one of them runs inside
# the LXD VM against the real tool.

# assert_passwd <name> / assert_no_passwd <name>: a system account.
assert_passwd() {
    getent passwd "$1" >/dev/null 2>&1 || _fail "no passwd entry for $1"
}
assert_no_passwd() {
    if getent passwd "$1" >/dev/null 2>&1; then
        _fail "passwd entry for $1 exists: $(getent passwd "$1")"
    fi
}

# assert_passwd_field <name> <field> <expected>: 1-indexed colon field.
assert_passwd_field() {
    local actual
    actual=$(getent passwd "$1" | cut -d: -f"$2")
    if [ "$actual" != "$3" ]; then
        _fail "passwd field $2 of $1 is '$actual', not '$3'"
    fi
}

assert_group() {
    getent group "$1" >/dev/null 2>&1 || _fail "no group entry for $1"
}
assert_no_group() {
    if getent group "$1" >/dev/null 2>&1; then
        _fail "group entry for $1 exists"
    fi
}

# assert_subid <file> <user> <start> <count>: the delegated range is the fact,
# not the flag that was supposed to produce it.
assert_subid() {
    local line
    line=$(grep "^$2:" "$1" 2>/dev/null | tail -1)
    if [ "$line" != "$2:$3:$4" ]; then
        _fail "$1 has no line '$2:$3:$4' (found: ${line:-none})"
    fi
}

# assert_no_subid <file> <user>
assert_no_subid() {
    if grep -q "^$2:" "$1" 2>/dev/null; then
        _fail "$1 still carries a range for $2: $(grep "^$2:" "$1")"
    fi
}

# assert_subvolume <path> / assert_no_subvolume <path>
assert_subvolume() {
    btrfs subvolume show "$1" >/dev/null 2>&1 \
        || _fail "$1 is not a btrfs subvolume"
}
assert_no_subvolume() {
    if btrfs subvolume show "$1" >/dev/null 2>&1; then
        _fail "$1 is a btrfs subvolume and should not be"
    fi
}

# assert_property <path> <key> <value>: `btrfs property get` is how the box
# reports a subvolume's own properties, and `ro` is the one a clone has to have
# cleared. btrfs does not make a snapshot read-only (docs/notes item O measured
# it), so asking is a real question with a real answer.
#
# The answer is `<key>=<value>` — `btrfs property get <path> ro` prints `ro=false`
# and not `false` — so the key is part of what is compared. Comparing the bare
# value asked a question the tool does not answer, and it failed on a machine that
# had done the right thing.
assert_property() {
    local actual
    actual=$(btrfs property get "$1" "$2" 2>/dev/null || true)
    if [ "$actual" != "$2=$3" ]; then
        _fail "$1 has $2='${actual:-unreadable}', not '$2=$3'"
    fi
}

# assert_unit_not_active <user> <unit>: the user manager's own answer. A unit
# that is not running is the outcome of a stop whatever order the stop and the
# start were issued in, so this is the form of "the units were stopped before the
# volumes moved" that a machine can report.
#
# A deleted user answers `unknown`, which is also not running, and that is
# correct rather than convenient: a unit belonging to a user the machine has never
# heard of cannot be running.
assert_unit_not_active() {
    local state
    state=$(systemctl --user --machine "$1@" is-active "$2" 2>/dev/null || true)
    [ "$state" != active ] || _fail "$2 is $state in $1's user manager"
}

# assert_snapper_config <config> <key> <value>
assert_snapper_config() {
    local actual
    actual=$(snapper -c "$1" get-config 2>/dev/null | awk -F'|' -v k="$2" '
        $1 ~ "^[[:space:]]*"k"[[:space:]]*$" {gsub(/[[:space:]]/,"",$2); print $2}')
    if [ "$actual" != "$3" ]; then
        _fail "snapper config $1: $2 is '$actual', not '$3'"
    fi
}

assert_no_snapper_config() {
    if snapper -c "$1" get-config >/dev/null 2>&1; then
        _fail "snapper configuration $1 exists and should not"
    fi
}

# assert_dpkg <pkg> / assert_no_dpkg <pkg>: what a converge actually installed.
assert_dpkg() {
    local state
    state=$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null || true)
    [ "$state" = installed ] || _fail "package $1 is '${state:-absent}', not installed"
}
assert_no_dpkg() {
    if [ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null || true)" = installed ]; then
        _fail "package $1 is installed and should not be"
    fi
}

# ---- the value is the answer, the exit code is the tool's convention ---------
#
# Every helper below asks a real system tool a question whose **answer is the
# stdout**, and the answer and the exit code disagree by design: `systemctl
# is-enabled` prints `disabled` and exits **1**, prints `static` and exits 0, and
# exits **4** for a unit that is not there; `dpkg-query -W` exits 1 for a package
# that is not installed, which is exactly the case `assert_dpkg` exists to report.
# So the substitution carries `|| true` and the *value* is compared.
#
# It is not a style choice. A suite runs `set -e`, and a command substitution
# whose command exits non-zero fails the assignment — and because the tool's own
# diagnostics are redirected into the substitution, the ERR trap fires inside the
# subshell where they are discarded, so the suite **dies with no message at all**.
# That is how `tests/t20-storage.sh` came to fail on a green assertion: the suite
# reached `assert_not_enabled snapper-cleanup.timer`, the assertion *passed*, and
# the shell died on the exit code of the very command that answered it.

# assert_enabled <unit> / assert_not_enabled <unit>
assert_enabled() {
    local state
    state=$(systemctl is-enabled "$1" 2>/dev/null || true)
    [ "$state" = enabled ] || _fail "unit $1 is '$state', not enabled"
}
assert_not_enabled() {
    local state
    state=$(systemctl is-enabled "$1" 2>/dev/null || true)
    case "$state" in
        enabled | enabled-runtime) _fail "unit $1 is $state and should not be" ;;
    esac
}
assert_active() {
    local state
    state=$(systemctl is-active "$1" 2>/dev/null || true)
    [ "$state" = active ] || _fail "unit $1 is '$state', not active"
}
assert_inactive() {
    local state
    state=$(systemctl is-active "$1" 2>/dev/null || true)
    [ "$state" != active ] || _fail "unit $1 is active and should not be"
}

# assert_linger <user>: loginctl, which only a real systemd answers.
assert_linger() {
    local state
    state=$(loginctl show-user "$1" -p Linger --value 2>/dev/null || true)
    [ "$state" = yes ] || _fail "linger for $1 is '$state', not yes"
}
assert_no_linger() {
    local state
    state=$(loginctl show-user "$1" -p Linger --value 2>/dev/null || true)
    [ "$state" != yes ] || _fail "linger for $1 is enabled and should not be"
}

# assert_supplementary_group <user> <group> / assert_no_supplementary_group
#
# **The group list is captured, and the match is a here-string.** `id -nG | tr |
# grep -qx` is the SIGPIPE shape: `grep -qx` exits at the first match, `id` is
# still writing when the pipe closes, and `pipefail` makes the pipeline 141
# instead of the answer. For the positive assertion that is a false red; for the
# negative one it is a **silent pass on the membership it exists to refuse**,
# because "the pipeline died" and "the group is absent" are the same exit status
# to an `if`. Captured first, there is no producer left to signal.
#
# **A group list that cannot be read is a failure, never an absence.** `id -nG`
# exiting non-zero — no such user, or a death by signal — prints and returns
# non-zero, which is the direction that matters here: an unreadable list is the
# one state in which the negative assertion knows nothing, so it must not answer
# "not a member". The `return` is not `_fail`'s alone on purpose: a caller that
# runs the helper inside an `if` or a `||` list has disabled `set -e` for it,
# and there it would otherwise fall through to the answer.
assert_supplementary_group() {
    local groups
    groups=$(id -nG "$1" | tr ' ' '\n') || {
        _fail "the group list of $1 could not be read"
        return 1
    }
    grep -qxF -- "$2" <<<"$groups" \
        || _fail "$1 is not a member of $2 (members: $(id -nG "$1"))"
}
assert_no_supplementary_group() {
    local groups
    groups=$(id -nG "$1" | tr ' ' '\n') || {
        _fail "the group list of $1 could not be read"
        return 1
    }
    if grep -qxF -- "$2" <<<"$groups"; then
        _fail "$1 is a member of $2 and should not be"
    fi
}

# hide_sysctl <path>: make a knob unreadable, so "could not read" is proven.
#
# The staged prefix holds a plain file, so removing it is safe. Under a real root
# it is a live sysfs knob, and unlinking it is not a thing to attempt as root:
# the stand-in could do it because the file was never a knob.
#
# A bind mount of a **directory** is what makes the read fail. A bind of
# /dev/null does not: reading it returns the empty string rather than raising,
# and an empty value is not "1" either, so the caller would report the knob as
# re-enabled instead of unreadable — a different diagnostic, and the wrong one.
# Reading a directory raises IsADirectoryError, which is an OSError, which is
# the branch this is here to reach.
#
# **The empty directory is bound over the directory that holds the knob, not over
# the knob.** Both other shapes are refused by this kernel, and one of them is
# refused in a way that looks like a pass:
#
# - a new entry inside a knob's own directory: `/proc/sys/net/ipv6/conf/all` is
#   `0555` and does not take one — `mkdir` there answers `No such file or
#   directory`, and the directory a bind mount needs never comes into being;
# - a directory bound onto the knob file itself: `mount: <knob>: mount point is
#   not a directory` — the source and the mountpoint must agree in kind.
#
# So the empty directory comes from the suite's own scratch and is bound over
# `dirname <knob>`; `cat <knob>` then answers `No such file or directory`, which
# is the ENOENT `weedr service list` reports as "could not read".
hide_sysctl() {
    if [ -n "${GUARDEN_PREFIX:-}" ] && [[ "$1" == "$GUARDEN_PREFIX"/* ]]; then
        rm -f "$1"
        return 0
    fi
    local dir knob_dir
    knob_dir=$(dirname "$1")
    dir=$(mktemp -d)
    if mount --bind "$dir" "$knob_dir" 2>/dev/null; then
        rmdir "$dir" 2>/dev/null || true
        return 0
    fi
    rmdir "$dir" 2>/dev/null || true
    return 1
}

# unhide_sysctl <path>: undo hide_sysctl, for the same path it was given.
unhide_sysctl() {
    umount "$(dirname "$1")" 2>/dev/null || true
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

# assert_immutable <path> / assert_mutable <path>: `chattr +i` is a filesystem
# attribute, so `lsattr` is what reports one. This is the whole replacement for
# reading `chattr +i <path>` out of a call log: the log recorded the intent, and
# the attribute is the outcome.
#
# The `i` flag is one character in `lsattr`'s output among others, so the first
# field is split and matched exactly rather than grepped for a substring — a
# substring test would read a neighbouring flag as the immutable one.
assert_immutable() {
    local flags
    flags=$(lsattr -d "$1" 2>/dev/null | awk '{print $1}')
    case "$flags" in
        *i*) return 0 ;;
    esac
    _fail "$1 is not immutable (lsattr: ${flags:-unreadable})"
}

assert_mutable() {
    local flags
    flags=$(lsattr -d "$1" 2>/dev/null | awk '{print $1}')
    case "$flags" in
        *i*) _fail "$1 is immutable and should not be" ;;
        *) return 0 ;;
    esac
}

# ---- snapshot state, read the way spec 8.2 says to read it --------------------
#
# `snapper --machine-readable json -c <config> list` renders a snapshot's
# `userdata` as an **object**, so `important` and `guarden` are keys of it. These
# are the replacements for the call-log assertions that asked a stand-in what it
# had been asked to write: a mark is asserted by reading the mark off the
# snapshot, and an unmark by reading its absence. Nothing here parses CSV, because
# the CSV rendering joins the whole map into one comma-joined quoted field and a
# consumer of it ends up string-matching a value it was told was structured.
#
# `--machine-readable` is a **global** option on snapper 0.10.6 and goes before
# the command. This helper and `guarden/snapper.py` are the only two readers in
# the tree, and they were written the same wrong way for the same reason: the
# retired `snapper` stand-in accepted the flag after `list` because the code used
# it, and answered a flat list because the code expected one. The real tool
# refuses the flag in that position and answers an object keyed by the
# configuration's name, so `tests/snapfield.py` is where both are handled.
#
# Every one of these takes the configuration's own name. A service with two
# state volumes has a different number in each, so the name is never derived
# from a service name and a volume name in a test.

# _snapentry <config>: the JSON document for one configuration, kept in a file
# so the assertions below read one list rather than re-asking `snapper` for it.
# Every caller refreshes it: a configuration's snapshot list changes under these
# tests on purpose, and a cached copy from before a `snapper create` would be a
# lie rather than a cache.
_snapentry() {
    mkdir -p "$GUARDEN_FIXTURES"
    if ! snapper --machine-readable json -c "$1" list \
        >"$GUARDEN_FIXTURES/snapper-$1.json" 2>/dev/null; then
        : >"$GUARDEN_FIXTURES/snapper-$1.json"
        return 1
    fi
    return 0
}

# _snapfield <config> <number> <field>: the value, or an empty string when the
# snapshot does not carry it. A missing field is an answer — "the mark is not
# there" — and a missing *snapshot* is a different claim, handled by
# assert_no_snapshot.
_snapfield() {
    _snapentry "$1" || true
    python3 "$GUARDEN_ROOT/tests/snapfield.py" "$1" "$2" "$3" \
        <"$GUARDEN_FIXTURES/snapper-$1.json" 2>/dev/null || true
}

# assert_snapshot_marked <config> <number> <yes|no>: `important` read as a key
# of the userdata object.
#
# **`yes` is exact and `no` means *not marked*, and those are not the same
# question.** `yes` is the value snapper's number cleaner counts, so it has to be
# the literal key. `no` is the absence of that value: the key unset, or set to
# `no`. The two are different on disk and the same to every consumer — the
# cleaner tests for `yes` and nothing else — and the distinction is the machine's:
#
#   - A snapshot `weedr service snapshot` took carries **no userdata at all**.
#     The mutator writes the cleanup tag and the description and stops, so snapper
#     renders `userdata: null` and `important` is unset rather than `no`. The
#     snapshot is unmarked, and it is unmarked by never having been marked.
#   - A snapshot `weedr pin sync` unmarked carries `important=no`, because the
#     reconciler's `modify` wrote it (`snapper unmark` in `guarden/snapper.py`).
#
# A helper that demanded the literal `no` in both places was asserting a value
# snapper only writes when something asks for it, and it read as a defect in the
# mutator. `no` also checks the snapshot is there at all: "unmarked" said of a
# number snapper never issued would be vacuously true, and the whole point of the
# assertion is that a snapshot which **is** wanted carries no mark.
assert_snapshot_marked() {
    local found number
    if [ "$3" = no ]; then
        number=$(_snapfield "$1" "$2" number)
        if [ -z "$number" ]; then
            _fail "configuration $1 has no snapshot numbered $2, so 'unmarked' would say nothing"
        fi
        found=$(_snapfield "$1" "$2" important)
        if [ "$found" = yes ]; then
            _fail "snapshot $1:$2 is marked important=yes and should not be"
        fi
        return 0
    fi
    found=$(_snapfield "$1" "$2" important)
    if [ "$found" != "$3" ]; then
        _fail "snapshot $1:$2 has important='${found:-unset}', not '$3'"
    fi
}

# assert_snapshot_userdata <config> <number> <key> <expected>: the provenance
# key, `guarden=`, which is what says which service wants a snapshot.
assert_snapshot_userdata() {
    local found
    found=$(_snapfield "$1" "$2" "$3")
    if [ "$found" != "$4" ]; then
        _fail "snapshot $1:$2 has $3='${found:-unset}', not '$4'"
    fi
}

# assert_snapshot_lacks_userdata <config> <number> <key>: no such key at all.
assert_snapshot_lacks_userdata() {
    local found
    found=$(_snapfield "$1" "$2" "$3")
    if [ -n "$found" ]; then
        _fail "snapshot $1:$2 has $3='$found' and should not"
    fi
}

# assert_snapshot_tag <config> <number> <cleanup-algorithm>: which of the two
# kinds of snapshot this is. A routine one is `timeline` and lives by the ladder;
# an on-demand one is `number` and is what the marks protect.
assert_snapshot_tag() {
    local found
    found=$(_snapfield "$1" "$2" cleanup)
    if [ "$found" != "$3" ]; then
        _fail "snapshot $1:$2 is tagged $found, not $3"
    fi
}

# assert_snapshot_count <config> <n>: how many snapshots the configuration
# holds, which is what "a routine snapshot was taken" and "no bulk volume was
# snapshotted" both reduce to.
assert_snapshot_count() {
    local found
    found=$(_snapfield "$1" - count)
    if [ "$found" != "$2" ]; then
        _fail "configuration $1 holds ${found:-?} snapshots, not $2"
    fi
}

# assert_newest_snapshot <config> <number>: the newest number snapper issued,
# which is what a fork clones and what the registry records.
assert_newest_snapshot() {
    local found
    found=$(_snapfield "$1" - newest)
    if [ "$found" != "$2" ]; then
        _fail "the newest snapshot in $1 is ${found:-none}, not $2"
    fi
}

# assert_no_snapshot <config> <number>: a number snapper has not issued. A
# record naming one is exactly as unfindable as a flag nobody wrote down.
assert_no_snapshot() {
    _snapentry "$1" || true
    if python3 "$GUARDEN_ROOT/tests/snapfield.py" "$1" "$2" number \
        <"$GUARDEN_FIXTURES/snapper-$1.json" >/dev/null 2>&1; then
        _fail "snapshot $1:$2 exists and should not"
    fi
}

# The pinned converter's release record, at the path `soil packages` reads. A
# suite that renders needs podlet, and podlet's fetch is refused without this
# file — one template in the checkout is the whole of it, so every suite that
# installs it stages the same bytes rather than each carrying a copy.
stage_podlet_release() {
    mkdir -p "${GUARDEN_PREFIX:-}/etc/guarden"
    install -D -m 0644 "$GUARDEN_ROOT/src/guarden/templates/podlet.release" \
        "${GUARDEN_PREFIX:-}/etc/guarden/podlet.release"
}

# The accounts every suite needs, created once at source time rather than by each
# suite that renders or installs. `units.render_units` reads the guarden user's uid
# out of /etc/passwd and the firewall refuses to render without an operator uid for
# the edge's API accept set, so a suite that runs a guarden program and has not
# created them dies on a KeyError that names neither the cause nor the fix. 38
# suites had their own copy of this; one call here is the whole of it.
ensure_accounts

# wait_settled <unit>: block until a unit is neither activating nor deactivating.
# guarden-firewall.service is Type=oneshot with RemainAfterExit=yes, and its
# ExecStop runs `ferm -F`, which blocks while it flushes the chains. A restart
# therefore spends real time in deactivating, and an assertion that reads the
# state the instant the call returns sees 'deactivating' rather than 'active'.
# That is a race in the caller, not a fault in the unit.
wait_settled() {
    local unit="$1" state i
    for i in $(seq 1 300); do
        state=$(systemctl show -p ActiveState --value "$unit" 2>/dev/null || true)
        case "$state" in
            activating | deactivating | reloading) ;;
            *) return 0 ;;
        esac
        sleep 0.1
    done
    _fail "unit $unit is still '$state' after 30s"
}

# apt_waits <args...>: apt-get on a machine whose background services may hold
# the dpkg lock. `apt-get` does not queue for a lock it cannot take -- it exits
# 100 with the lock's name -- and a cut machine can meet a boot-time
# `unattended-upgrades` between the reach of a drift report and the call; one
# did, in `t130-packages.sh`, on 2026-10-12. While another process holds the
# frontend lock this waits for it -- the runner waits for the same lock at boot
# with the same probe, though it reads two locks and does not trust fuser's exit
# alone, which in-guest as root collapses to "free" -- and a failure with the
# lock free is re-run once and its code returned: that is apt's own answer to
# the command.
# The waiting is bounded -- thirty sleeps of two seconds and a final attempt,
# past the runner's measured boot window -- and an upgrade run still in flight
# past that fails the suite, which is the honest report. Twelve seconds was the
# first bound and it was too short: a boot-time `unattended-upgrades` has a
# whole machine's package set to walk, and it reddened `t130-packages` twice in
# one day (rc 100 out of this helper's last call) before the bound was raised.
# `fuser` comes from `psmisc` via `ubuntu-standard`; without it the probe fails
# open and the command simply runs.
apt_waits() {
    local attempt
    for attempt in $(seq 1 30); do
        if apt-get "$@"; then
            return 0
        fi
        fuser -s /var/lib/dpkg/lock-frontend || {
            apt-get "$@"
            return $?
        }
        sleep 2
    done
    apt-get "$@"
}
