#!/usr/bin/env bash
# The refusal names the provider the operator has to act on — the RENDERER's
# half (ticket 290).
#
# A `needs:` entry may name a LOGICAL provider, and the host resolves it per
# track through `[providers]` in `guarden.toml`. When the resolution goes wrong
# — the provider does not exist, it does not offer the kind the consumer wants,
# it resolves to the consumer itself, or its entry carries no allocation for
# the edge — the refusal has to name the CONCRETE name, because that is the
# service the operator has to fix. A refusal that named only the logical name
# would send the operator looking for a service called `postgres`, which is not
# a service on this host at all.
#
# The MUTATOR's refusals are the same rule on the other side of the same
# resolution, and they need a real host, so they live in
# `t84-provider-diagnostics-mutator.sh`.
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
# refuses — and the refusal has to name the concrete provider, because
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
# refusal names the concrete name for the same reason: `absent` is not a
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

# The logical name resolves to the consumer itself, which is a self-edge. The
# manifest wrote `myself` and the host resolved it to `myapp-staging`; the
# refusal names the concrete name, because `myself` is not a service and the
# operator has to look at the service that declared the edge.
seed "$project/.guarden/service.yml" "project: myapp" "units: .guarden/quadlet/" \
    "state:" "  - data" "needs:" "  - service: myself" "    as: db" \
    "    port: 5432" "    auth: database"
rm -rf "$render"
run loom render "$project" --service myapp-staging --out "$render"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "myapp-staging"
assert_stderr_has "self-edge"
assert_file_missing "$render"

# The provider exists and offers the kind, and the consumer's registry entry
# carries no allocation for the edge: the host has not been asked yet. The
# refusal names the concrete provider, because that is the entry whose
# `publications` list is missing and `dbsrc` is not a service.
seed "$registry/dbprov-staging.toml" \
    'service = "dbprov-staging"' 'workload = "dbprov"' 'project = "dbprov"' \
    'environment = "staging"' 'uid = 1102' 'created = "2026-09-30T09:00:00Z"' \
    '[provides]' 'kinds = [ "db" ]'
seed "$project/.guarden/service.yml" "project: myapp" "units: .guarden/quadlet/" \
    "state:" "  - data" "needs:" "  - service: dbsrc" "    as: db" \
    "    port: 5432" "    auth: database"
rm -rf "$render"
run loom render "$project" --service myapp-staging --out "$render"
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "dbprov-staging"
assert_stderr_has "dbsrc"
assert_stderr_has "allocated publication"
assert_stderr_has "myapp-staging"
assert_file_missing "$render"
