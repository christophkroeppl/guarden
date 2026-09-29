# guarden development tasks.
# Replaces the Makefile. `just` with no argument lists the recipes.

set shell := ["bash", "-euo", "pipefail", "-c"]

# list the recipes
default:
    @just --list

# run the fast harness (seconds)
test:
    tests/run.sh

# check the runtime dependencies `soil` installs
check:
    @python3 -c "import yaml, jinja2" && echo "runtime deps ok"
    @command -v podlet >/dev/null && echo "podlet ok" || echo "podlet MISSING (install before use)"

# lint the programs
lint:
    @command -v shellcheck >/dev/null && shellcheck -x soil/soil weedr/weedr loom/loom roots/roots twig/twig furrow/furrow hose/hose stakes/stakes || echo "shellcheck not installed"
    @command -v ruff >/dev/null && ruff check . || echo "ruff not installed"

# run the lint and the tests
ci: lint test

# throw the machine away and run the golden VM (minutes, manual)
golden-vm:
    tools/golden-vm
