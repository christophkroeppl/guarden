#!/usr/bin/env bash
# A stand-in does not come back, and this is where that is held.
#
# (ticket 35, ADR-0014, spec §11)
#
# **`fixtures/` is retired and there is no second tier.** `tests/lib.sh` used to
# export `PATH="$GUARDEN_ROOT/fixtures/bin:$PATH"` unconditionally, and the LXD
# runner never removed it, so the tier that was supposed to be evidence about a
# machine was, on 2026-10-01, a statement about a stand-in in 29 of the 34
# suites. This file is the assertion that the condition cannot come back, and it
# is an assertion about **this** environment: it reads the `PATH` of the process
# running it and asks the shell to resolve commands with it.
#
# What it deliberately does not do is read another process's environment. A test
# that inspected the `PATH` of a suite it did not run would be asserting about
# the runner, not about the box, and the two are not the same thing — which is
# the mistake that let the prepend stand for as long as it did.
#
# machine: shared
# it reads files, this process's own `PATH`, and one `soil packages --list`.
# `--list` is the phase's read-only form: it resolves the family and prints
# the row, and reaches neither `apt-get` nor a fetch.

. "$(dirname "$0")/lib.sh"

# The directory is gone, not merely off PATH. Both halves matter and they fail
# differently: a `fixtures/bin` that exists but is not on PATH is a stand-in
# waiting for the one suite that forgets to pin its own PATH, and a `fixtures/bin`
# that is on PATH but does not exist is a `command -v` that answers nothing.
assert_file_missing "$GUARDEN_ROOT/fixtures/bin"
assert_file_missing "$GUARDEN_ROOT/fixtures/lib"
assert_file_missing "$GUARDEN_ROOT/fixtures/lib"

# Every entry on this process's PATH is read and checked. The whole list rather
# than a named tool, because a stand-in is only ever a problem when something
# resolves to it, and a list of tool names would have to be maintained to stay
# ahead of one being added.
IFS=':' read -r -a _entries <<<"$PATH"
[ "${#_entries[@]}" -gt 0 ] || _fail "PATH is empty, so this file would pass vacuously"

for entry in "${_entries[@]}"; do
    [ -n "$entry" ] || continue
    case "$entry" in
        "$GUARDEN_ROOT"/*)
            case "$entry" in
                "$GUARDEN_ROOT"/.venv | "$GUARDEN_ROOT"/.venv/*) continue ;;
            esac
            _fail "PATH carries $entry, which is inside the repository but is not .venv"
            ;;
    esac
done

# And the resolution itself: a command on PATH must not be a file under
# `fixtures/`, whichever entry it came from. This is the same question asked
# through the shell's own lookup, so it holds for a stand-in reached by a
# symlink, a relative entry or a directory that is not the one named above.
# The eight programs plus the tools a converge reaches for, because those are
# the names a stand-in would have shadowed.
for command in soil weedr loom roots twig furrow hose stakes \
    snapper btrfs getent useradd groupadd userdel loginctl \
    systemctl dpkg-query apt-get curl install chown stat chattr git podlet; do
    resolved=$(command -v "$command" 2>/dev/null || true)
    [ -n "$resolved" ] || continue
    case "$resolved" in
        "$GUARDEN_ROOT"/fixtures/*)
            _fail "$command resolves to $resolved, which is a stand-in under fixtures/"
            ;;
    esac
done

# The one entry allowed to precede the machine's own PATH is the checkout's own
# interpreter, and it is a venv rather than a stand-in: it holds pyyaml and
# jinja2, which are the host's dependencies and are installed as distribution
# packages on a converged host. **It is not asserted to exist.** `lib.sh` treats a
# checkout without one as a normal checkout — the two imports are not at module
# scope, so `--help` still answers — and the guest's copy arrives with the tree
# only if the host had one, so asserting it here tested the developer rather than
# the harness.

# `tool` still works, because the repo tools are real programs in `tools/` and are
# driven by path rather than by PATH. The fake tier's disappearance took `fake`
# with it; this is the shape that replaced it.
tool golden-vm --help
assert_exit 0
assert_stdout_has "usage: golden-vm"

# And the render path, which is the one program whose output this repository
# treats as authoritative: it reads `packages/packages.toml` and nothing else, so
# it is the strongest possible answer to "is anything in this repository standing
# in for a real tool".
run soil packages --list
assert_exit 0
assert_stdout_has "python3-yaml"
