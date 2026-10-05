#!/usr/bin/env bash
# The `[zram]` knob's own refusals and arithmetic, tested directly.
#
# spec 11 permits exactly one exception to "no test imports a program's
# internals" — the manifest and registry parsers, because their failures are
# invisible from outside until something is silently dropped. The `[zram]` table
# is a parser in that sense: a value guarden cannot read is one it would have to
# guess at, and the guess goes into a file the kernel acts on.
#
# The seam here is the command line, as it is everywhere else; the assertions
# live in the .py beside this file.
#
# machine: shared
# the module sets `GUARDEN_PREFIX` to its own `mkdtemp` before the import and
# writes the only file it reads (`proc/meminfo`) inside it. No host state: no
# device is created, no sysctl is written, and `soil` is never run.

. "$(dirname "$0")/lib.sh"

run python3 "$GUARDEN_ROOT/tests/t170-zram-parsers.py"
assert_exit 0
assert_stdout_empty
assert_stderr_empty
