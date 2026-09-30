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
# past the standard library and those two
check:
    tools/check-deps

# lint the programs
lint:
    @if command -v ruff >/dev/null; then ruff check src tools/check-deps tests; else echo "ruff not installed"; fi

# run the lint and the tests
ci: lint test

# throw the machine away and run the golden VM (minutes, manual)
golden-vm:
    tools/golden-vm
