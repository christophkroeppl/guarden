#!/usr/bin/env bash
# The root `.env.schema` resolves, carries no value, and is tracked.
#
# The schema is the tracked half of the varlock contract: names, types and
# example values, never a value, so it is safe in git and required to be there.
# This is this repo's copy of next's `.test/smoke.sh` assertion that every
# schema resolves, and it is the command-line seam like every other test here —
# `varlock` is run and its exit code and output are asserted. No program is
# imported and none is run: what is under test is a file and the tool that
# reads it.
#
# Two things make this test less obvious than it looks.
#
# `varlock` is not a declared dependency — `just check` exists to prove nothing
# reaches past the standard library and the two distribution packages, and
# adding one would break that — so it is on PATH or the varlock half is skipped
# with a `warning:`, the way `just lint` reports a missing `ruff`. The
# assertions that do not need it still run, so the test is never wholly
# vacuous: the tracking and no-value claims below are the ones that catch a
# real regression, and they are the claims a skipped varlock would leave
# unchecked.
#
# `.gitignore` matches `.env.*`, which matches `.env.schema` at the root as
# well, so "tracked" is a real assertion here and not a formality: without the
# negation the schema would resolve perfectly and never reach a clone. The
# harness once put a fake `git` first on PATH that exited 0 for everything
# (fixtures/bin, deleted with the fake tier — ticket 35, ADR-0014), so the real
# binary is still named outright — a stand-in of that shape would make these
# pass whatever the ignore rules say.

. "$(dirname "$0")/lib.sh"

# --- the schema is tracked ---------------------------------------------------

# Not ignored, so it can be committed. The real git, named outright.
run /usr/bin/git check-ignore -q .env.schema
assert_exit 1

# And visible to git as a tracked file rather than suppressed, which is the
# distinction a stand-in `git` returning 0 for everything would hide. `ls-files`
# rather than `status`: a committed file is tracked and correctly absent from
# status, so the status form asserted a pre-commit moment and then stopped
# meaning anything the moment the schema landed.
run /usr/bin/git ls-files --error-unmatch .env.schema
assert_exit 0
assert_stdout_has ".env.schema"

# The negation must not have cost the fixture repository its own schema: a
# root-anchored rule instead of the unanchored one would drop it silently, and
# nothing else in the harness would notice.
run /usr/bin/git check-ignore -q fixtures/projects/quadlet-app/.guarden/.env.schema
assert_exit 1

# --- the schema holds no value ----------------------------------------------

# The rule the whole file rests on: names, types and example values, never a
# value. An uncommented `KEY=<something>` line would be a value in git, and for
# a deployment tool that is the one thing this file must never be. Commented
# decorator lines are not values, so the assertion is on a declaration line
# rather than on the character "=" appearing anywhere.
run grep -nE '^[A-Za-z_][A-Za-z0-9_]*=.+' "$GUARDEN_ROOT/.env.schema"
assert_exit 1

# The sensitive marker is absent, and that is a finding rather than an
# oversight: a credential in this design is a systemd-encrypted blob under
# /etc/guarden/creds materialised into a per-user podman secret store, and
# nothing in guarden reads a secret from the environment.
run grep -qE '^# @sensitive' "$GUARDEN_ROOT/.env.schema"
assert_exit 1

# --- the schema resolves -----------------------------------------------------

if command -v varlock >/dev/null; then
    # `varlock` exits 0 on an empty directory as well as on a resolved one, so
    # the exit code alone would pass with no schema at all. `--agent` is the
    # redacted JSON form, so this stays safe against a checkout that has a real
    # `.env` beside the schema.
    #
    # `--agent` emits RESOLVED values, so a declared key with no value is
    # absent from its output entirely. Asserting a key name there tested the
    # machine's environment rather than the schema, and passed only because a
    # stray exported GUARDEN_PREFIX happened to be set. The declaration is
    # asserted below against the human form, which lists every declared key
    # with its value (`undefined` included), and against the audit.
    run varlock load --agent -p "$GUARDEN_ROOT"
    assert_exit 0

    # Both seams the programs read through the environment, and the harness's
    # own three. A key that resolves is a key that is declared.
    run varlock load -p "$GUARDEN_ROOT"
    assert_exit 0
    assert_stdout_has "GUARDEN_TEMPLATES"
    assert_stdout_has "GUARDEN_VM_TARGET"
    assert_stdout_has "GUARDEN_FIXTURES"
    assert_stdout_has "GUARDEN_TEST_INSTALLED"

    # Loadable as a single file as well as by directory, which is the form an
    # operator would use against one path.
    run varlock load --agent -p "$GUARDEN_ROOT/.env.schema"
    assert_exit 0

    # Schema and code agree. `varlock audit` is the drift check, and it is in
    # sync because each item carries `@auditIgnore` — audit scans JS
    # `process.env` and not Python `os.environ`, so against a Python codebase
    # it reports every key here as unused. `@auditIgnore` is load-bearing, not
    # decoration: removing it turns this into five false positives.
    run varlock audit -p "$GUARDEN_ROOT/.env.schema" "$GUARDEN_ROOT/src"
    assert_exit 0
else
    printf 'warning: varlock not installed; the schema was not resolved\n' >&2
fi
