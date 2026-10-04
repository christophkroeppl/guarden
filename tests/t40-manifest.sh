#!/usr/bin/env bash
# The manifest and the unit source: what is refused before anything is rendered
# (ticket 40, spec 4).
#
# A project ships either `compose.yaml` at the root or `.guarden/quadlet/`,
# exactly one. Both present is ambiguous and neither is incomplete, and both are
# refused naming both accepted locations rather than picking one: a renderer that
# quietly preferred one would make the repository's real behaviour depend on
# which file happened to exist.
#
# machine: shared
# `guarden_prefix` stages the host, and `install_pinned_converter` installs
# the converter into that staged prefix at
# `$GUARDEN_PREFIX/usr/lib/guarden/bin/podlet`, so every file this suite
# reads or writes is under `$GUARDEN_PREFIX` or `$GUARDEN_FIXTURES`. **It is
# not staged that far: `install_pinned_converter` runs a real `soil packages
# --apply`, and apt and `systemctl disable` are not prefixed.** Those two
# reach the machine every time this suite runs, which is the leak the ticket
# asks to be preserved rather than widened, and it is why the same four
# suites that call it are order-insensitive today: they all ask for the same
# convergent state and none of them asserts an absence a converged machine
# no longer has. What this suite asserts is entirely about the manifest and
# the refusal, so a converged apt set costs it nothing.

. "$(dirname "$0")/lib.sh"

guarden_prefix
stage_config guarden-measured.toml

# This file's unit source is `compose.yaml`, so the renderer needs the pinned
# converter to answer anything about it — including whether the manifest beside it
# is renderable. The converter is installed by the phase that owns the fetch, at
# the pinned path, and is a program; `t20-podlet.sh` is where that is the subject.
install_pinned_converter

project=$GUARDEN_FIXTURES/project
seed "$project/.guarden/service.yml" "project: myapp" "units: compose.yaml"
seed "$project/compose.yaml" "services:" "  web:" "    image: docker.io/library/nginx:1.27"

run loom check "$project"
assert_exit 0
assert_stderr_empty

# Both present. The diagnostic names both locations, because "one of these two"
# is not an answer somebody can act on.
seed "$project/.guarden/quadlet/web.container" "[Container]" "Image=docker.io/library/alpine:3.20"
run loom check "$project"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "compose.yaml"
assert_stderr_has ".guarden/quadlet"
rm -r "$project/.guarden/quadlet"

# Neither present: the same two locations, named the same way.
mkdir -p "$GUARDEN_FIXTURES/bare/.guarden"
seed "$GUARDEN_FIXTURES/bare/.guarden/service.yml" "project: bare"
run loom check "$GUARDEN_FIXTURES/bare"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "compose.yaml"
assert_stderr_has ".guarden/quadlet"

# `units:` names one of the two, and the repository has to agree with it.
seed "$project/.guarden/service.yml" "project: myapp" "units: docker-compose.yml"
run loom check "$project"
assert_exit 2
assert_stderr_has "units:"

seed "$project/.guarden/service.yml" "project: myapp" "units: compose.yaml"

# An unknown top-level key is refused, with the file named.
seed "$project/.guarden/service.yml" "project: myapp" "units: compose.yaml" "replicas: 2"
run loom check "$project"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "replicas"
assert_stderr_has "service.yml"

# `environment:` is refused specifically: it is the key a developer reaches for
# and the answer is never in the repository.
seed "$project/.guarden/service.yml" "project: myapp" "units: compose.yaml" "environment: production"
run loom check "$project"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "environment"
assert_stderr_has "the host decides the environment"
assert_stderr_has "guarden.toml"

# A manifest may not state a weight, a cap or a priority: those are the track's
# and the operator's, and a repository that could state them would be a second
# place for them to be wrong.
seed "$project/.guarden/service.yml" "project: myapp" "units: compose.yaml" "weight: 1000"
run loom check "$project"
assert_exit 2
assert_stderr_has "weight"
assert_stderr_has "guarden.toml"

# The closed key set covers the keys *inside* a block. A typo there used to be
# silently dropped, and a manifest asking for `authentification: true` got a
# route with no auth on it and no diagnostic saying so.
seed "$project/.guarden/service.yml" "project: myapp" "units: compose.yaml" \
  "routes:" "  - container: web" "    port: 3000" "    host: web" "    authentification: true"
run loom check "$project"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "authentification"

# A `service:` key where a `container:` belongs is the one mistake the block
# structure exists to make impossible, so it gets its own message.
seed "$project/.guarden/service.yml" "project: myapp" "units: compose.yaml" \
  "routes:" "  - service: other-production" "    port: 3000" "    host: web"
run loom check "$project"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "routes"
assert_stderr_has "service:"

seed "$project/.guarden/service.yml" "project: myapp" "units: compose.yaml" \
  "widgets:" "  - service: other-production" "    file: .guarden/widgets/web.yml"
run loom check "$project"
assert_exit 2
assert_stderr_has "widgets"

# Repository YAML is read with `safe_load` and nothing else. The default loader
# constructs arbitrary python objects, and the mutator must never run anything
# over repository input; a loader that can is a loader that runs code.
canary=$GUARDEN_FIXTURES/constructed
seed "$project/.guarden/service.yml" "project: !!python/object/apply:os.system [\"touch $canary\"]"
run loom check "$project"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "service.yml"
assert_file_missing "$canary"

# The same for the Compose file, which is the same kind of stranger's document.
seed "$project/.guarden/service.yml" "project: myapp" "units: compose.yaml"
seed "$project/compose.yaml" "services:" "  web: !!python/object/apply:os.system [\"touch $canary\"]"
run loom check "$project"
assert_exit 2
assert_file_missing "$canary"
