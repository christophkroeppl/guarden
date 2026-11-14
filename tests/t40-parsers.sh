#!/usr/bin/env bash
# The unit-source and secret-schema parsers, tested directly: the one exception
# the seam allows, for the parsers whose failures are invisible from outside
# until a container starts without a key it needed (spec 11).
#
# The assertions live in the .py beside this file; the seam here is the command
# line, as it is everywhere else.
#
# machine: shared
# the module sets `GUARDEN_PREFIX` to its own `mkdtemp` before the import,
# and its assertions read documents it wrote. No host state.

. "$(dirname "$0")/lib.sh"

run python3 "$GUARDEN_ROOT/tests/t40-parsers.py"
assert_exit 0
assert_stdout_empty
assert_stderr_empty
