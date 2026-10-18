#!/usr/bin/env bash
# The declared edges, and the containers the manifest names (ticket 40, spec 4,
# 7.3).
#
# `needs` is validated against the **registry** and names another guarden service;
# `routes` and `widgets` are validated against **the containers the unit source
# defines**. The two answers come from different places on purpose: a consumer
# cannot read a provider's tree, so the provider's `provides:` lives in a file the
# mutator wrote, and every disagreement therefore has one input and one exit code.
#
# machine: shared
# `guarden_prefix` stages the host, and every registry row, every staged
# manifest and every rendered unit is under `$GUARDEN_PREFIX` or
# `$GUARDEN_FIXTURES`. The unit source is hand-written quadlet, so no
# converter and no fetch is involved.

. "$(dirname "$0")/lib.sh"

guarden_prefix
stage_config guarden-measured.toml

registry=$GUARDEN_PREFIX/var/lib/guarden/registry
seed "$registry/postgres-staging.toml" \
    'service = "postgres-staging"' 'workload = "postgres"' 'project = "postgres"' \
    'environment = "staging"' 'uid = 1099' 'created = "2026-09-30T09:00:00Z"' \
    '[provides]' 'kinds = [ "db" ]'

# A provider that exists and offers something else: a cache, not a database.
seed "$registry/redis-staging.toml" \
    'service = "redis-staging"' 'workload = "redis"' 'project = "redis"' \
    'environment = "staging"' 'uid = 1098' 'created = "2026-09-30T09:00:00Z"' \
    '[provides]' 'kinds = [ "cache" ]'

seed "$registry/myapp-staging.toml" \
    'service = "myapp-staging"' 'workload = "myapp"' 'project = "myapp"' \
    'environment = "staging"' 'uid = 1101' 'created = "2026-09-30T09:00:00Z"' \
    '[publication]' 'web = 20114' \
    '[edges."postgres-staging:5432:db"]' 'port = 5432' 'as = "db"' 'auth = "database"' \
    'publications = [ 20007 ]'

project=$GUARDEN_FIXTURES/project
seed "$project/.guarden/service.yml" "project: myapp" "units: .guarden/quadlet/" \
    "state:" "  - data" "needs:" "  - service: postgres-staging" "    as: db" \
    "    port: 5432" "    auth: database"
seed "$project/.guarden/quadlet/web.container" "[Container]" \
    "Image=docker.io/library/nginx:1.27" "Volume=data:/var/lib/app"

render=$GUARDEN_FIXTURES/render
run loom render "$project" --service myapp-staging --out "$render"
assert_exit 0
assert_stderr_empty

# There is no name map and no /etc/hosts. For each edge the renderer writes
# `AddHost=<provider>:<alias>` into *every* unit of the consumer, and the name is
# the provider's own service name, with no suffix and no alias.
assert_file_has "$render/units/web.container" "AddHost=postgres-staging:10.0.2.2"
assert_file_has "$render/units/guarden.env" "DB_HOST=postgres-staging"
assert_file_has "$render/units/guarden.env" "DB_PORT=20007"
# The provider's service name must not appear in the real /etc/hosts.
if grep -qw postgres-staging /etc/hosts 2>/dev/null; then
    _fail "postgres-staging appears in /etc/hosts"
fi

# The start order is in the system manager, because a unit in one service's user
# manager cannot require a unit in another's. `loom` emits the edges and the
# mutator installs the file.
assert_file_has "$render/system/guarden-order.target" "Wants=postgres-staging.target"
assert_file_has "$render/system/guarden-order.target" "After=postgres-staging.target"
assert_file_has "$render/units/web.container.d/10-guarden-order.conf" \
    "Wants=guarden-order.target"
assert_file_lacks "$render/system/guarden-order.target" "Requires="

# A self-edge has no consumer and is nearly always a copy-paste.
seed "$project/.guarden/service.yml" "project: myapp" "units: .guarden/quadlet/" \
    "state:" "  - data" "needs:" "  - service: myapp-staging" "    as: db" \
    "    port: 5432" "    auth: database"
run loom render "$project" --service myapp-staging --out "$render"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "myapp-staging"
assert_stderr_has "self-edge"

# A service this host has never heard of. `loom` never guesses, and the answer
# came from the host, so it is exit 1 rather than 2 (spec 1.2).
seed "$project/.guarden/service.yml" "project: myapp" "units: .guarden/quadlet/" \
    "state:" "  - data" "needs:" "  - service: nowhere-staging" "    as: db" \
    "    port: 5432" "    auth: database"
run loom render "$project" --service myapp-staging --out "$render"
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "nowhere-staging"

# The provider exists and does not offer the kind. Both kinds and both services
# are named, because "the edge is wrong" is not an answer a person can act on.
seed "$project/.guarden/service.yml" "project: myapp" "units: .guarden/quadlet/" \
    "state:" "  - data" "needs:" "  - service: redis-staging" "    as: db" \
    "    port: 6379" "    auth: database"
run loom render "$project" --service myapp-staging --out "$render"
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "redis-staging"
assert_stderr_has "myapp-staging"
assert_stderr_has "db"

# `as:` is the prefix of the generated variables, so it has to be unique and it
# has to be a name. And there is no default auth: every edge states one.
seed "$project/.guarden/service.yml" "project: myapp" "units: .guarden/quadlet/" \
    "state:" "  - data" "needs:" "  - service: postgres-staging" "    as: db" \
    "    port: 5432" "    auth: database" "  - service: redis-staging" "    as: db" \
    "    port: 6379" "    auth: none"
run loom render "$project" --service myapp-staging --out "$render"
assert_exit 2
assert_stderr_has "as: db"

seed "$project/.guarden/service.yml" "project: myapp" "units: .guarden/quadlet/" \
    "state:" "  - data" "needs:" "  - service: postgres-staging" "    as: db" \
    "    port: 5432"
run loom render "$project" --service myapp-staging --out "$render"
assert_exit 2
assert_stderr_has "no default"

# The edge is declared, so the publication it dials is an allocation and an
# allocation is in the registry. Without one the renderer says so rather than
# inventing a loopback port.
seed "$project/.guarden/service.yml" "project: myapp" "units: .guarden/quadlet/" \
    "state:" "  - data" "needs:" "  - service: postgres-staging" "    as: db" \
    "    port: 5432" "    auth: database"
seed "$registry/myapp-staging.toml" \
    'service = "myapp-staging"' 'workload = "myapp"' 'project = "myapp"' \
    'environment = "staging"' 'uid = 1101' 'created = "2026-09-30T09:00:00Z"' \
    '[publication]' 'web = 20114' \
    '[edges."postgres-staging:5432:db"]' 'port = 5432' 'as = "db"' 'auth = "database"'
run loom render "$project" --service myapp-staging --out "$render"
assert_exit 1
assert_stderr_has "publication"

# `ingress.alias` is written by `soil install` from the pinned set, and an edge
# with no alias would render host entries that resolve to nothing. Empty is the
# host not being in the state the render assumed, so it is exit 1.
seed "$registry/myapp-staging.toml" \
    'service = "myapp-staging"' 'workload = "myapp"' 'project = "myapp"' \
    'environment = "staging"' 'uid = 1101' 'created = "2026-09-30T09:00:00Z"' \
    '[publication]' 'web = 20114' \
    '[edges."postgres-staging:5432:db"]' 'port = 5432' 'as = "db"' 'auth = "database"' \
    'publications = [ 20007 ]'
stage_config guarden.toml
run loom render "$project" --service myapp-staging --out "$render"
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "ingress.alias"
stage_config guarden-measured.toml

# A container the unit source does not define is exit 2 in both directions: the
# manifest and the unit source are both input (spec 1.2).
seed "$project/.guarden/service.yml" "project: myapp" "units: .guarden/quadlet/" \
    "state:" "  - data" "routes:" "  - container: api" "    port: 3000" "    host: api"
run loom render "$project" --service myapp-staging --out "$render"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "api"
assert_stderr_has ".guarden/quadlet"

seed "$project/.guarden/service.yml" "project: myapp" "units: .guarden/quadlet/" \
    "state:" "  - data" "widgets:" "  - container: api" "    file: .guarden/widgets/api.yml"
run loom render "$project" --service myapp-staging --out "$render"
assert_exit 2
assert_stderr_has "widgets"

# A route's `host:` is a label, not a domain, and the pattern is closed because a
# wildcard was the shape that would have been dangerous.
seed "$project/.guarden/service.yml" "project: myapp" "units: .guarden/quadlet/" \
    "state:" "  - data" "routes:" "  - container: web" "    port: 3000" \
    '    host: "*.example.com"'
run loom render "$project" --service myapp-staging --out "$render"
assert_exit 2
assert_stderr_has "host_prefix"

# A widget file the manifest names and the repository does not ship.
seed "$project/.guarden/service.yml" "project: myapp" "units: .guarden/quadlet/" \
    "state:" "  - data" "widgets:" "  - container: web" \
    "    file: .guarden/widgets/absent.yml"
run loom render "$project" --service myapp-staging --out "$render"
assert_exit 2
assert_stderr_has "absent.yml"

seed "$registry/postgres-pinned.toml" \
    'service = "postgres-pinned"' 'workload = "postgres"' 'project = "postgres"' \
    'environment = "staging"' 'uid = 1102' 'created = "2026-09-30T09:00:00Z"' \
    '[provides]' 'kinds = [ "db" ]' '[publication]' 'db = 20008'
seed "$registry/myapp-pinned.toml" \
    'service = "myapp-pinned"' 'workload = "myapp"' 'project = "myapp"' \
    'environment = "staging"' 'uid = 1103' 'created = "2026-09-30T09:00:00Z"' \
    '[publication]' 'web = 20117' \
    '[edges."postgres-pinned:5432:db"]' 'port = 5432' 'as = "db"' 'auth = "database"' \
    'publications = [ 20008 ]'

# The record is keyed by the provider **the mutator resolved when it installed
# the edge** — a `[providers]` row or an earlier pin in force at that moment —
# and the pin is read on every render (spec 3.1), so a pin written after the
# install moves the name without moving the record. The render must still find
# the allocation the mutator wrote for this `needs:` entry: `as:` is unique per
# manifest, so the entry carrying this edge's port and `as` under any provider
# name is this edge's record and nothing else's. A port the box holds is read; a
# port it would have to invent is still refused.
seed "$registry/myapp-latepin.toml" \
    'service = "myapp-latepin"' 'workload = "myapp"' 'project = "myapp"' \
    'environment = "staging"' 'uid = 1106' 'created = "2026-09-30T09:00:00Z"' \
    '[publication]' 'web = 20121' \
    '[edges."postgres-staging:5432:db"]' 'port = 5432' 'as = "db"' 'auth = "database"' \
    'publications = [ 20007 ]'
seed "$project/.guarden/service.yml" "project: myapp" "units: .guarden/quadlet/" \
    "state:" "  - data" "needs:" "  - service: postgres" "    as: db" \
    "    port: 5432" "    auth: database"
seed "$GUARDEN_PREFIX/etc/guarden/overrides.toml" \
    "[edge_overrides]" 'postgres = "postgres-pinned"'
run loom render "$project" --service myapp-latepin --out "$render"
assert_exit 0
assert_file_has "$render/units/guarden.env" "DB_HOST=postgres-pinned"
assert_file_has "$render/units/guarden.env" "DB_PORT=20007"
assert_file_has "$render/units/web.container" "AddHost=postgres-pinned:10.0.2.2"
assert_file_lacks "$render/units/guarden.env" "DB_HOST=postgres-staging"

# Without the pin, `postgres-staging` is the provider: no `[providers]` table is
# staged on this host, so the name as written is the answer.
seed "$project/.guarden/service.yml" "project: myapp" "units: .guarden/quadlet/" \
    "state:" "  - data" "needs:" "  - service: postgres-staging" "    as: db" \
    "    port: 5432" "    auth: database"
run loom render "$project" --service myapp-staging --out "$render"
assert_exit 0
assert_file_has "$render/units/guarden.env" "DB_HOST=postgres-staging"
assert_file_has "$render/units/web.container" "AddHost=postgres-staging:10.0.2.2"
assert_file_has "$render/system/guarden-order.target" "Wants=postgres-staging.target"

# The pin is written, and the **same manifest** renders the pinned provider on
# the next render. No re-ingest and no re-deploy: a pin that needed one would
# not be a pin, and the renderer reading the file is what makes it effective.
seed "$GUARDEN_PREFIX/etc/guarden/overrides.toml" \
    "[edge_overrides]" 'postgres-staging = "postgres-pinned"'
run loom render "$project" --service myapp-staging --out "$render"
assert_exit 0
assert_file_has "$render/units/guarden.env" "DB_HOST=postgres-pinned"
assert_file_has "$render/units/web.container" "AddHost=postgres-pinned:10.0.2.2"
assert_file_has "$render/system/guarden-order.target" "Wants=postgres-pinned.target"
assert_file_lacks "$render/units/guarden.env" "DB_HOST=postgres-staging"

# The pin is keyed by the LOGICAL name the manifest writes, so a manifest that
# names `postgres` (the logical name `[providers]` exists for) is pinned too,
# and a manifest that already names a full service name is not — there is no
# logical name left to match.
seed "$project/.guarden/service.yml" "project: myapp" "units: .guarden/quadlet/" \
    "state:" "  - data" "needs:" "  - service: postgres" "    as: db" \
    "    port: 5432" "    auth: database"
seed "$registry/myapp-logical.toml" \
    'service = "myapp-logical"' 'workload = "myapp"' 'project = "myapp"' \
    'environment = "staging"' 'uid = 1104' 'created = "2026-09-30T09:00:00Z"' \
    '[publication]' 'web = 20118' \
    '[edges."postgres-pinned:5432:db"]' 'port = 5432' 'as = "db"' 'auth = "database"' \
    'publications = [ 20008 ]'
seed "$GUARDEN_PREFIX/etc/guarden/overrides.toml" \
    "[edge_overrides]" 'postgres = "postgres-pinned"'
run loom render "$project" --service myapp-logical --out "$render"
assert_exit 0
assert_file_has "$render/units/guarden.env" "DB_HOST=postgres-pinned"
assert_file_has "$render/system/guarden-order.target" "Wants=postgres-pinned.target"

# A pin for a logical name no manifest declares changes nothing, and the pin is
# per host rather than per track: the production consumer reads the same file.
seed "$registry/myapp-prod-pinned.toml" \
    'service = "myapp-prod-pinned"' 'workload = "myapp"' 'project = "myapp"' \
    'environment = "production"' 'uid = 1105' 'created = "2026-09-30T09:00:00Z"' \
    '[publication]' 'web = 20119' \
    '[edges."postgres-pinned:5432:db"]' 'port = 5432' 'as = "db"' 'auth = "database"' \
    'publications = [ 20008 ]'
run loom render "$project" --service myapp-prod-pinned --out "$render"
assert_exit 0
assert_file_has "$render/units/guarden.env" "DB_HOST=postgres-pinned"
assert_file_lacks "$render/units/guarden.env" "postgres-production"

# A pin whose value is not a service name is refused rather than rendered: a
# silently ignored pin is one an operator believes is in effect, and the
# diagnostic names the file.
seed "$GUARDEN_PREFIX/etc/guarden/overrides.toml" \
    "[edge_overrides]" 'postgres-staging = "Not a name"'
run loom render "$project" --service myapp-staging --out "$render"
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "overrides.toml"
assert_stderr_has "Not a name"
assert_file_missing "$render"