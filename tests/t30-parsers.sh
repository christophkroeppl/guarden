#!/usr/bin/env bash
# The one test seam's stated exception, run (spec 11): the manifest and registry
# parsers are tested directly, because a key they drop is a key nobody hears
# about until it has silently cost a service its configuration.
#
# The assertions live in the .py beside this file; the seam here is the command
# line, as it is everywhere else.
#
# machine: shared
# the module sets `GUARDEN_PREFIX` to its own `mkdtemp` before the import,
# and its assertions read documents it wrote. No host state.

. "$(dirname "$0")/lib.sh"

run python3 "$GUARDEN_ROOT/tests/t30-parsers.py"
assert_exit 0
assert_stdout_empty
assert_stderr_empty
