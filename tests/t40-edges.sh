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
    '[edges."postgres-staging:5432"]' 'port = 5432' 'as = "db"' 'auth = "database"' \
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
assert_file_has "$render/units/web.container" "AddHost=postgres-staging:192.0.2.1"
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
    '[edges."postgres-staging:5432"]' 'port = 5432' 'as = "db"' 'auth = "database"'
run loom render "$project" --service myapp-staging --out "$render"
assert_exit 1
assert_stderr_has "publication"

# `ingress.alias` is empty until `soil install` measures it, and an edge with no
# alias would render host entries that resolve to nothing. Empty is the host not
# being in the state the render assumed, so it is exit 1.
seed "$registry/myapp-staging.toml" \
    'service = "myapp-staging"' 'workload = "myapp"' 'project = "myapp"' \
    'environment = "staging"' 'uid = 1101' 'created = "2026-09-30T09:00:00Z"' \
    '[publication]' 'web = 20114' \
    '[edges."postgres-staging:5432"]' 'port = 5432' 'as = "db"' 'auth = "database"' \
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
