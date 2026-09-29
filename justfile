# guarden development tasks.
# Replaces the Makefile. `just` with no argument lists the recipes.
#
# The programs are Python console scripts (`soil = "guarden.soil:main"` and so on),
# so lint is ruff. There are no shell entry points to shellcheck.
#
# `just check` is for the host's runtime dependencies: the two distribution
# Python packages, plus the pinned podlet that `loom` drives and `soil packages`
# installs on the box.

set shell := ["bash", "-euo", "pipefail", "-c"]

# list the recipes
default:
    @just --list

# run the fast harness (seconds)
test:
    tests/run.sh

# check the runtime dependencies, which are distribution packages plus pinned podlet
check:
    @python3 -c "import yaml, jinja2"
    @echo "runtime deps ok (python3-yaml, python3-jinja2)"
    @command -v podlet >/dev/null && echo "podlet ok" || { echo "podlet MISSING: soil packages installs it"; exit 1; }

# lint the programs
lint:
    ruff check .
    ruff format --check .

# run the lint and the tests
ci: lint test

# throw the machine away and run the golden VM (minutes, manual)
golden-vm:
    tools/golden-vm
