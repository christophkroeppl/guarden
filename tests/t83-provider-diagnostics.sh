#!/usr/bin/env bash
# The diagnostic names the provider the operator has to act on (ticket 290).
#
# A `needs:` entry may name a LOGICAL provider, and the host resolves it per
# track through `[providers]` in `guarden.toml`. When the resolution goes wrong
# — the provider does not exist, or it does not offer the kind the consumer
# wants — the diagnostic has to name the CONCRETE name, because that is the
# service the operator has to fix. A diagnostic that names only the logical
# name sends the operator looking for a service called `postgres`, which is not
# a service on this host at all.
#
# machine: shared
# `guarden_prefix` stages the host, and every registry row, every staged
# manifest and every rendered unit is under `$GUARDEN_PREFIX` or
# `$GUARDEN_FIXTURES`. The unit source is hand-written quadlet, so no
# converter and no fetch is involved.

. "$(dirname "$0")/lib.sh"

guarden_prefix
stage_config guarden-provider-diag.toml

registry=$GUARDEN_PREFIX/var/lib/guarden/registry

# The provider the `[providers]` table names for staging: it exists, and it
# offers a cache rather than a database.
seed "$registry/postgres-staging.toml" \
    'service = "postgres-staging"' 'workload = "postgres"' 'project = "postgres"' \
    'environment = "staging"' 'uid = 1099' 'created = "2026-09-30T09:00:00Z"' \
    '[provides]' 'kinds = [ "cache" ]'

seed "$registry/myapp-staging.toml" \
    'service = "myapp-staging"' 'workload = "myapp"' 'project = "myapp"' \
    'environment = "staging"' 'uid = 1101' 'created = "2026-09-30T09:00:00Z"' \
    '[publication]' 'web = 20114'

project=$GUARDEN_FIXTURES/project
seed "$project/.guarden/quadlet/web.container" "[Container]" \
    "Image=docker.io/library/nginx:1.27" "Volume=data:/var/lib/app"

render=$GUARDEN_FIXTURES/render

# The manifest names the LOGICAL name, and the host resolves it to
# `postgres-staging`. The provider does not offer the `db` kind, so the render
# refuses — and the diagnostic has to name the concrete provider, because
# `postgres` is not a service on this host.
seed "$project/.guarden/service.yml" "project: myapp" "units: .guarden/quadlet/" \
    "state:" "  - data" "needs:" "  - service: postgres" "    as: db" \
    "    port: 5432" "    auth: database"
rm -rf "$render"
run loom render "$project" --service myapp-staging --out "$render"
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "postgres-staging"
assert_stderr_has "myapp-staging"
assert_stderr_has "db"
assert_file_missing "$render"

# The provider the logical name resolves to does not exist at all. The
# diagnostic names the concrete name for the same reason: `absent` is not a
# service this host has, and the operator looking for it will not find it.
seed "$project/.guarden/service.yml" "project: myapp" "units: .guarden/quadlet/" \
    "state:" "  - data" "needs:" "  - service: absent" "    as: db" \
    "    port: 5432" "    auth: database"
rm -rf "$render"
run loom render "$project" --service myapp-staging --out "$render"
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "absent-staging"
assert_stderr_has "myapp-staging"
assert_file_missing "$render"

# The MUTATOR's two refusals name the concrete provider as well. A poke whose
# manifest names the logical `postgres` is resolved by the mutator against the
# consumer's own track, and the refusal it produces has to name the service
# the operator has to fix.
#
# The provider does not offer the kind. The mutator consults the registry
# before it creates anything, so the refusal comes from `edges.check`.
ghost=$GUARDEN_PREFIX/var/lib/guarden/staging/ghost/9f2c1ab
mkdir -p "$ghost/.guarden/quadlet"
seed "$ghost/.guarden/service.yml" "project: ghost" "units: .guarden/quadlet/" \
    "state:" "  - data" "needs:" "  - service: postgres" "    as: db" \
    "    port: 5432" "    auth: database"
seed "$ghost/.guarden/quadlet/web.container" "[Container]" \
    "Image=docker.io/library/nginx:1.27"
run weedr service ingest ghost-staging --from poke ghost@9f2c1ab
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "postgres-staging"
assert_stderr_has "ghost-staging"
assert_stderr_has "db"
assert_stderr_has "cache"

# The provider the logical name resolves to does not exist. This one is a
# WARNING, not a refusal: a poke creates services in dependency order and a
# manifest may name one a later deploy brings into being, so the edge is
# recorded with no publication and `loom` is what refuses it.
nowhere=$GUARDEN_PREFIX/var/lib/guarden/staging/nowhere/9f2c1ab
mkdir -p "$nowhere/.guarden/quadlet"
seed "$nowhere/.guarden/service.yml" "project: nowhere" "units: .guarden/quadlet/" \
    "state:" "  - data" "needs:" "  - service: absent" "    as: db" \
    "    port: 5432" "    auth: database"
seed "$nowhere/.guarden/quadlet/web.container" "[Container]" \
    "Image=docker.io/library/nginx:1.27"
run weedr service ingest nowhere-staging --from poke nowhere@9f2c1ab
assert_exit 0
assert_stderr_has "absent-staging"
assert_stderr_has "nowhere-staging"
