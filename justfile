# guarden development tasks.
# Replaces the Makefile. `just` with no argument lists the recipes.

set shell := ["bash", "-euo", "pipefail", "-c"]

# list the recipes
default:
    @just --list

# run the fast harness (seconds)
test:
    tests/run.sh

# check the runtime dependencies `soil` installs, and that no program reaches
# past the standard library and those two. The interpreter is the checkout's own
# venv when it has one, so a developer without the distribution's packages still
# gets a real answer.
check:
    @if [ -x .venv/bin/python ]; then .venv/bin/python tools/check-deps; else python3 tools/check-deps; fi

# lint the programs
lint:
    @if command -v ruff >/dev/null; then ruff check src tools/check-deps tests; else echo "ruff not installed"; fi

# run the lint and the tests
ci: lint test

# throw the machine away and run the golden VM (minutes, manual)
golden-vm:
    tools/golden-vm
