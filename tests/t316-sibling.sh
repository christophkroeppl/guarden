#!/usr/bin/env bash
# A sibling container named inside one unit source resolves, and a container of
# that source which the manifest does not declare under `siblings:` is still
# refused (ticket 316, ADR-0023, spec 7.3).
#
# Ticket 285 refused this, and the refusal was right about the mechanism and
# wrong about the conclusion: the alias is the host's loopback, where each
# container answers on its allocated PUBLICATION and never on the container port
# the value dials — so `http://api:3000` reaches a port nothing binds. The
# mechanism that makes it work is the one an edge already uses, with the port
# added: `AddHost=<sibling>:<alias>` names the sibling, and the sibling's
# publication — its own allocation, in the same record — is the port it answers
# on. The renderer writes both, and the repository composes its own URL from
# them.
#
# **The boundary this suite pins.** A name inside ONE unit source resolves, and
# it resolves only when the manifest declared the container it names under
# `siblings:`. A container of the source that is NOT declared is still refused,
# and the diagnostic names the declaration that fixes it. The repository's own
# `AddHost=` and `extra_hosts` are still refused, because the key is the
# renderer's.
#
# **A name that is not a container of this source is not refused, and this is
# the correction ADR-0023 records:** 285's loop ran over the source's own
# container keys, so a value naming an external host was never inspected.
# Guarden neither knows nor resolves such a name, and policing it would be a
# check that fires on the repository's own business.
#
# machine: shared
# `guarden_prefix` stages the host, and every staged manifest, registry row and
# rendered unit is under `$GUARDEN_PREFIX` or `$GUARDEN_FIXTURES`. The unit
# source is hand-written quadlet, so no converter is driven and nothing is
# fetched.

. "$(dirname "$0")/lib.sh"

guarden_prefix
stage_config guarden-measured.toml

registry=$GUARDEN_PREFIX/var/lib/guarden/registry
seed "$registry/myapp-staging.toml" \
    'service = "myapp-staging"' 'workload = "myapp"' 'project = "myapp"' \
    'environment = "staging"' 'uid = 1103' 'created = "2026-10-19T08:00:00Z"' \
    '[publication]' 'api = 20021' 'nuxt = 20022'

project=$GUARDEN_FIXTURES/project
seed "$project/.guarden/service.yml" "project: myapp" "units: .guarden/quadlet" \
    "siblings:" "  - container: api" "    port: 3000"
seed "$project/.guarden/quadlet/api.container" "[Container]" \
    "Image=docker.io/library/alpine:3.20"
seed "$project/.guarden/quadlet/nuxt.container" "[Container]" \
    "Image=docker.io/library/alpine:3.20" "Environment=API_URL=http://api:3000"

render=$GUARDEN_FIXTURES/render

# --- the sibling name resolves -------------------------------------------------
#
# The refusal is GONE for a name inside the source, and what replaced it is a
# name the consumer can resolve: the sibling's own name and the alias, which is
# the address the host is reachable on from inside a container.
run loom render "$project" --service myapp-staging --out "$render"
assert_exit 0
assert_stderr_empty
assert_file_has "$render/units/nuxt.container" "AddHost=api:10.0.2.2"
assert_file_has "$render/units/api.container" "AddHost=api:10.0.2.2"

# **The port is the PUBLICATION and not the container's own port.** The value in
# the repository says 3000, which is the port inside the api container; what the
# consumer may dial is the loopback publication guarden allocated for it. The
# environment file is where the two meet, and it is the same file the edges'
# variables live in.
assert_file_has "$render/units/guarden.env" "API_HOST=api"
assert_file_has "$render/units/guarden.env" "API_PORT=20021"

# The publication is allocated per container, and the sibling's is its own —
# not the consumer's, and not the container port the manifest named.
assert_file_lacks "$render/units/guarden.env" "API_PORT=3000"

# **The name is scoped to the source.** A sibling name is never a service name
# and never reaches another service's units, so two sources each naming a
# container `api` cannot collide.
assert_file_lacks "$render/units/nuxt.container" "AddHost=myapp-staging:"

# --- the boundary: a container of the source that is NOT declared ------------
#
# The refusal survives for a container of THIS source that the manifest did
# not declare under `siblings:`. Guarden cannot allocate a publication for a
# container whose port it was never told, so the name would still be dead —
# and the diagnostic carries the remedy. The manifest is re-seeded WITHOUT the
# `siblings:` block, which is what makes this the undeclared case.
seed "$project/.guarden/service.yml" "project: myapp" "units: .guarden/quadlet"
seed "$project/.guarden/quadlet/nuxt.container" "[Container]" \
    "Image=docker.io/library/alpine:3.20" "Environment=API_URL=http://api:3000"
run loom check "$project"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "api"
assert_stderr_has "siblings:"

# A name that is NOT a container of this source is not guarden's business: an
# external host is the repository's own, and a value naming one is a fact
# about the repository rather than a dead name inside a unit source.
seed "$project/.guarden/quadlet/nuxt.container" "[Container]" \
    "Image=docker.io/library/alpine:3.20" "Environment=API_URL=http://elsewhere:3000"
run loom check "$project"
assert_exit 0
assert_stderr_empty

# --- the repository's own AddHost= is still refused ---------------------------
#
# The key is the renderer's (spec 6.3) and the renderer writes the sibling
# names itself. A repository writing one would have it dropped, so the
# repository would believe in an address guarden does not carry — and the
# `siblings:` block is re-seeded so the refusal is THIS one and not the
# undeclared-sibling one.
seed "$project/.guarden/service.yml" "project: myapp" "units: .guarden/quadlet" \
    "siblings:" "  - container: api" "    port: 3000"
seed "$project/.guarden/quadlet/nuxt.container" "[Container]" \
    "Image=docker.io/library/alpine:3.20" "AddHost=api:10.0.0.1"
run loom check "$project"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "api"
assert_stderr_has "renderer's"

# And a name that only looks like the sibling's is not a reference: the
# authority after `//` runs until the next delimiter of a hostname, so
# `apiary` is a different host and a value mentioning one is text. Refusing it
# would be a check that fires on its own shadow. The `siblings:` block is
# re-seeded, so the file is otherwise renderable and the value is the only
# thing that could fire.
seed "$project/.guarden/service.yml" "project: myapp" "units: .guarden/quadlet" \
    "siblings:" "  - container: api" "    port: 3000"
seed "$project/.guarden/quadlet/nuxt.container" "[Container]" \
    "Image=docker.io/library/alpine:3.20" "Environment=API_DOCS=https://apiary.example.com/docs"
run loom check "$project"
assert_exit 0
assert_stderr_empty

# --- the manifest's half ------------------------------------------------------
#
# The port is the container's own port, and the manifest says so: `siblings:`
# names a container of THIS service and the port it serves. The translation to
# the publication is guarden's, and it is the only thing the renderer does with
# the entry.
seed "$project/.guarden/service.yml" "project: myapp" "units: .guarden/quadlet" \
    "siblings:" "  - container: api" "    port: 3000"
seed "$project/.guarden/quadlet/nuxt.container" "[Container]" \
    "Image=docker.io/library/alpine:3.20" "Environment=API_URL=http://api:3000"
run loom render "$project" --service myapp-staging --out "$render"
assert_exit 0
assert_file_has "$render/units/guarden.env" "API_PORT=20021"

# A sibling that names a container this service does not have is refused: the
# manifest and the unit source are both input, and the entry names a container
# that does not exist. The unit source is re-seeded too, because the manifest
# is not the only half of this case — the value still dials `api`, and the
# undeclared-sibling refusal would fire on it first.
seed "$project/.guarden/service.yml" "project: myapp" "units: .guarden/quadlet" \
    "siblings:" "  - container: nowhere" "    port: 3000"
seed "$project/.guarden/quadlet/nuxt.container" "[Container]" \
    "Image=docker.io/library/alpine:3.20"
run loom check "$project"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "nowhere"

# A container naming ITSELF in a value is refused: it is the copy-paste, and
# there is nothing to translate, because it is the one being addressed. The
# manifest declaring the container under `siblings:` is NOT that — the block
# names the containers of this source that others may dial, and a container
# that is both the dialer and the dialled is a fact about the topology.
seed "$project/.guarden/service.yml" "project: myapp" "units: .guarden/quadlet" \
    "siblings:" "  - container: api" "    port: 3000"
seed "$project/.guarden/quadlet/nuxt.container" "[Container]" \
    "Image=docker.io/library/alpine:3.20" "Environment=API_URL=http://nuxt:3000"
run loom check "$project"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "nuxt"

# Two containers whose names give the SAME variable are refused, and this is
# not the same check as the one above: `my-api` and `my_api` are two
# containers and one variable, because a variable name cannot carry a dash.
# The environment file would carry MY_API_HOST twice and the second row would
# win — a silent failure with no diagnostic anywhere. The unit source is
# re-seeded, because the self-reference from the case above would fire first.
seed "$project/.guarden/quadlet/my-api.container" "[Container]" \
    "Image=docker.io/library/alpine:3.20"
seed "$project/.guarden/quadlet/my_api.container" "[Container]" \
    "Image=docker.io/library/alpine:3.20"
seed "$project/.guarden/quadlet/nuxt.container" "[Container]" \
    "Image=docker.io/library/alpine:3.20"
seed "$project/.guarden/service.yml" "project: myapp" "units: .guarden/quadlet" \
    "siblings:" "  - container: my-api" "    port: 3000" "  - container: my_api" "    port: 3001"
run loom check "$project"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "MY_API"

# A container declared twice under `siblings:` is refused too: the generated
# variables would be written twice with two different ports. The unit source is
# re-seeded for the same reason as the case above.
seed "$project/.guarden/quadlet/nuxt.container" "[Container]" \
    "Image=docker.io/library/alpine:3.20"
seed "$project/.guarden/service.yml" "project: myapp" "units: .guarden/quadlet" \
    "siblings:" "  - container: api" "    port: 3000" "  - container: api" "    port: 3001"
run loom check "$project"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "declared twice"

# --- a service with no siblings renders as it always did ---------------------
#
# The absence of the block is the absence of the mechanism, not a refusal, and
# the rendered unit carries no sibling entry at all. The unit source here has
# ONE container, so there is no sibling of it to name and the value naming
# `api` is a name outside the source — the repository's own business.
seed "$project/.guarden/service.yml" "project: myapp" "units: .guarden/quadlet"
rm -f "$project/.guarden/quadlet/api.container"
rm -f "$project/.guarden/quadlet/nuxt.container"
rm -f "$project/.guarden/quadlet/my-api.container"
rm -f "$project/.guarden/quadlet/my_api.container"
seed "$project/.guarden/quadlet/web.container" "[Container]" \
    "Image=docker.io/library/alpine:3.20" "Environment=API_URL=http://api:3000"
run loom check "$project"
assert_exit 0
assert_stderr_empty

echo "ok   t316-sibling.sh"
