#!/usr/bin/env bash
# The import discipline behind `just check` (spec 6.1, AGENTS.md).
#
# The runtime dependencies are the distribution's python3-yaml and
# python3-jinja2, installed by `soil packages`. There is no `pip install` at
# deploy time and no wheel is checked in, so a program that imported a third
# thing would be a program the host cannot install — and that is what keeps the
# install path portable to a distribution nobody has tried yet.
#
# The rule is checked against fixture files, so it holds on a host that has not
# run `soil packages` yet, and separately against the package itself.

. "$(dirname "$0")/lib.sh"

mkdir -p "$GUARDEN_FIXTURES/allowed" "$GUARDEN_FIXTURES/refused"

printf '%s\n' 'import json' 'import os' 'import sys' 'import yaml' 'import jinja2' 'from guarden import cli' >"$GUARDEN_FIXTURES/allowed/programs.py"
printf '%s\n' 'import json' 'import requests' >"$GUARDEN_FIXTURES/refused/settled.py"
printf '%s\n' 'from dataclasses import dataclass' 'import pip' >"$GUARDEN_FIXTURES/refused/installed.py"

tool check-deps --imports-only "$GUARDEN_FIXTURES/allowed"
assert_exit 0
assert_stdout_has "imports ok"

tool check-deps --imports-only "$GUARDEN_FIXTURES/refused"
assert_exit 1
assert_stderr_has "settled.py imports requests"
assert_stderr_has "installed.py imports pip"

# The package itself imports nothing outside the standard library, and the scan
# half is quiet: a host that has not run `soil packages` is not a scan finding.
# stderr is asserted before the exit code, because stderr is where the finding
# is and a bare "expected exit 0" would not say what was wrong.
tool check-deps --imports-only
assert_stderr_empty
assert_stdout_has "imports ok"
assert_exit 0

# And the check is not satisfiable by a file that fails to parse: a syntax error
# is a finding, not a skip.
printf '%s\n' 'import json' 'def (' >"$GUARDEN_FIXTURES/refused/broken.py"
tool check-deps --imports-only "$GUARDEN_FIXTURES/refused/broken.py"
assert_exit 1
assert_stderr_has "does not parse"
