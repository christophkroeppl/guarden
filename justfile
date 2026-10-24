# guarden development tasks.
# Replaces the Makefile. `just` with no argument lists the recipes.

set shell := ["bash", "-euo", "pipefail", "-c"]

# list the recipes
default:
    @just --list

# run the test suite (minutes) — the harness of record, and the only one
#
# This runs the suite inside a throwaway LXD VM against the real tools: real
# useradd with real /etc/subuid arithmetic, real iptables, real btrfs
# subvolumes, real snapper, real systemd. Nothing is faked, and `fixtures/bin` is
# never on PATH: there is no fast tier, because the "fast" tier was on PATH
# inside this VM for 29 of 34 suites and its failures were facts about the fake
# rather than about guarden (ADR-0014). See tests/lxc.sh.
# The first run builds a golden VM, converts its root to btrfs (two reboots)
# and snapshots it; after that a run is a copy and a boot. Each suite declares
# in its own file whether it needs a machine of its own — `# machine: shared`
# or `# machine: fresh` — and a suite that says nothing gets one. A suite you
# are working on is `just test-one <file>`; the whole run is for the end.
#
# A suite whose tree and golden are unchanged is **inherited** rather than run,
# and prints `inherit t30-create.sh (green from the cache; not observed this
# run)` — never a line that could be read as a pass. Nothing expires: a result
# stays valid while the thing it was a function of does, and a rebuilt golden
# invalidates all of them.
test:
    tests/lxc.sh run

# run one test file in the VM: just test-one t30-create
test-one pattern:
    tests/lxc.sh run {{pattern}}

# cut a fresh machine per test file, whatever any suite declares. This is what
# `just test` did before the suites said anything, and it is the state a suite
# that writes a real /etc/guarden, a real user or a real btrfs subvolume is
# assumed to be in.
test-fresh:
    tests/lxc.sh run "" --fresh

# cut one machine for the whole run, whatever any suite declares. Only sound
# while every suite relocates guarden's own paths with GUARDEN_PREFIX, and it
# is the run that shows it when it stops being true.
test-shared:
    tests/lxc.sh run "" --shared

# run the suites in the opposite order, on machines of their own. Sharing is a
# claim and this is how it is asked about: the same suites, both orders, green.
test-reverse:
    tests/lxc.sh run "" --reverse

# run every suite and record the result, inheriting nothing. This is what a
# release gate uses: an inherited green is a real green, but it is not one this
# run observed, and a gate that reads one as an observation has verified nothing.
# The results are still recorded, so the next `just test` can inherit them.
test-gate:
    tests/lxc.sh run "" --no-cache

# throw the recorded results away, keeping the golden. The cache lives outside
# the repository and is disposable; this is the whole of removing it.
test-cache-clear:
    rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}/guarden/suite-results"
    @echo "cleared the suite cache"

# build the golden VM without running anything against it
provision:
    tests/lxc.sh provision

# throw away the golden VM
deprovision:
    tests/lxc.sh destroy

# check the runtime dependencies `soil` installs, and that no program reaches
# past the standard library and those two. The interpreter is the checkout's own
# venv when it has one, so a developer without the distribution's packages still
# gets a real answer.
check:
    @if [ -x .venv/bin/python ]; then .venv/bin/python tools/check-deps; else python3 tools/check-deps; fi

# lint the programs
lint:
    @if command -v ruff >/dev/null; then ruff check src tools/check-deps tests; else echo "ruff not installed"; fi

# resolve the root .env.schema, the tracked half of the varlock contract.
# varlock is not a declared dependency — `just check` exists to prove nothing
# reaches past the standard library and the two distribution packages — so this
# reports rather than fails when it is absent, as `lint` does for ruff.
# This recipe resolves and prints; `just unit` is the one that asserts about the
# schema (tests/test_env_schema.py), because an assertion is a test and this is
# a reader's convenience.
env:
    @if command -v varlock >/dev/null; then varlock load -p .env.schema; else echo "varlock not installed"; fi

# run the lint and the tests
ci: lint unit test

# The Python unit tests: the ones a VM suite cannot express because they
# assert on a FUNCTION's answer rather than on a host's state.
#
# **They ran under nothing until this recipe existed.** `tests/test_*.py` was
# three files and no recipe ran any of them, so a unit test that failed was a
# unit test nobody would ever see fail — which is the same defect as a suite
# that asserts nothing, wearing a different hat. The adversarial review named
# it: the sudoers rule's content was pinned only by a unit test that no recipe
# ran.
#
# **The checkout is the other subject no machine can see** (ADR-0025): the root
# `.env.schema`'s tracked-ness is a fact about this repository's `.git`, which
# a cut does not carry, so `tests/test_env_schema.py` is a unit test and this is
# the recipe that runs it. It executes no guarden program and writes nothing.
#
# The interpreter is the checkout's own venv when it has one, for the reason
# `check` gives: a developer without the distribution's packages still gets a
# real answer.
unit:
    @if [ -x .venv/bin/python ]; then PYTHONPATH=src .venv/bin/python -m unittest discover -s tests -p 'test_*.py' -v; else PYTHONPATH=src python3 -m unittest discover -s tests -p 'test_*.py' -v; fi

# throw the machine away and run the golden VM (minutes, manual)
golden-vm:
    tools/golden-vm

# build a source tarball (*.tar.gz) of guarden
package-tarball:
    packaging/build-tarball.sh

# build a Debian package (.deb) of guarden
package-deb:
    packaging/build-deb.sh

# build both packages
package: package-tarball package-deb

# build packages for CI
ci-package: package-tarball package-deb
