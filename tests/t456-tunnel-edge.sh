#!/usr/bin/env bash
# `needs:` over the tunnel hostname — the RENDERER's half (ticket 307f T2, spec 4,
# 7.3).
#
# A `needs:` entry naming a service on ANOTHER host is reached through that
# host's cloudflared ingress, at the route hostname it publishes. The name is a
# fact about the other machine and nothing here can derive it, so the entry
# states it (`hostname:`) and `via: tunnel` says how to dial it: port 443, no
# `AddHost=` entry, no publication, no ordering edge, and a credential request
# named by the entry's `auth:`.
#
# `T1` — the same-host pasta edge — is asserted here too, byte for byte: the
# render of a manifest without `via:` has to be exactly what it was before the
# transport existed, so the rows of `guarden.env` are compared against a file
# rather than probed line by line.
#
# The mutator's half (what `weedr service ingest` records, the refusal for a
# producer recorded `loopback`, the firewall, and the container that resolves the
# name) needs a real host and lives in `t457-tunnel-edge-host.sh`. This suite
# stages the host and drives `loom` alone.
#
# machine: shared
# `guarden_prefix` stages the host: every registry row, every staged manifest
# and every rendered unit is under `$GUARDEN_PREFIX` or `$GUARDEN_FIXTURES`, and
# the unit source is hand-written quadlet, so no converter and no fetch is
# involved.

. "$(dirname "$0")/lib.sh"

guarden_prefix
stage_config guarden-measured.toml

registry=$GUARDEN_PREFIX/var/lib/guarden/registry
seed "$registry/myapp-staging.toml" \
    'service = "myapp-staging"' 'workload = "myapp"' 'project = "myapp"' \
    'environment = "staging"' 'uid = 1101' 'created = "2026-09-30T09:00:00Z"' \
    '[edges."orders:443:api"]' 'port = 443' 'as = "api"' 'auth = "secret"' \
    'via = "tunnel"' 'hostname = "orders.tunnel.example.net"'

project=$GUARDEN_FIXTURES/project
seed "$project/.guarden/service.yml" "project: myapp" "units: .guarden/quadlet/" \
    "state:" "  - data" "needs:" "  - service: orders" "    as: api" \
    "    auth: secret" "    via: tunnel" "    hostname: orders.tunnel.example.net"
seed "$project/.guarden/quadlet/web.container" "[Container]" \
    "Image=docker.io/library/nginx:1.27" "Volume=data:/var/lib/app"

render=$GUARDEN_FIXTURES/render
run loom render "$project" --service myapp-staging --out "$render"
assert_exit 0
assert_stderr_empty

# The hostname the entry stated, and 443 — not a publication, because there is
# no publication on this side of the edge at all.
assert_file_has "$render/units/guarden.env" "API_HOST=orders.tunnel.example.net"
assert_file_has "$render/units/guarden.env" "API_PORT=443"

# **And the unit LOADS it.** The two assertions above are about the file's
# contents, and a file no unit references is a file the container never reads.
# The edge allocates no publication, so it is not in the published set that
# decides whether a unit carries `EnvironmentFile=` — measured before this
# assertion existed: the render wrote both rows here and `web.container` carried
# no `EnvironmentFile=` at all, so the container started with neither variable
# and the transport delivered nothing while this suite passed.
assert_file_has "$render/units/web.container" "EnvironmentFile="
assert_file_has "$render/units/web.container" "guarden.env"

# The credential the `auth:` names is a REQUEST the unit makes, and the value is
# the operator's: a vendor's Access service token is minted by the vendor, so
# guarden names the key and never writes a value.
assert_file_has "$render/units/web.container" "Secret=API_SECRET,type=mount"

# Nothing local is written for the edge: no name map entry, no ordering edge, no
# publication. A name that reached `AddHost=` would resolve to this host's own
# loopback alias and dial a service that is not here.
assert_file_lacks "$render/units/web.container" "AddHost="
assert_file_exists "$render/system/guarden-order.target"
assert_file_lacks "$render/system/guarden-order.target" "orders"
assert_file_lacks "$render/units/web.container" "PublishPort="

# --- T1: a `needs:` entry without `via:` is untouched ------------------------
#
# The same consumer, with the pasta edge it had before the transport existed.
# The rows are compared against a file, so a value that moved in either
# direction is a diff rather than a line nobody thought to assert.
seed "$project/.guarden/service.yml" "project: myapp" "units: .guarden/quadlet/" \
    "state:" "  - data" "needs:" "  - service: postgres-staging" "    as: db" \
    "    port: 5432" "    auth: none"
seed "$registry/postgres-staging.toml" \
    'service = "postgres-staging"' 'workload = "postgres"' 'project = "postgres"' \
    'environment = "staging"' 'uid = 1099' 'created = "2026-09-30T09:00:00Z"' \
    '[provides]' 'kinds = [ "db" ]'
seed "$registry/myapp-staging.toml" \
    'service = "myapp-staging"' 'workload = "myapp"' 'project = "myapp"' \
    'environment = "staging"' 'uid = 1101' 'created = "2026-09-30T09:00:00Z"' \
    '[edges."postgres-staging:5432:db"]' 'port = 5432' 'as = "db"' 'auth = "none"' \
    'publications = [ 20007 ]'

run loom render "$project" --service myapp-staging --out "$render"
assert_exit 0
assert_stderr_empty
grep -vE '^[[:space:]]*#' "$render/units/guarden.env" >"$GUARDEN_FIXTURES/rows"
seed "$GUARDEN_FIXTURES/expected" "DB_HOST=postgres-staging" "DB_PORT=20007"
run diff -u "$GUARDEN_FIXTURES/expected" "$GUARDEN_FIXTURES/rows"
assert_exit 0
assert_file_has "$render/units/web.container" "AddHost=postgres-staging:10.0.2.2"
assert_file_has "$render/system/guarden-order.target" "Wants=postgres-staging.target"

# --- the manifest's own vocabulary ------------------------------------------
#
# `hostname:` is `via: tunnel`'s key: a pasta edge's name is the provider's
# service name and the renderer writes it, so a repository writing one would
# believe in a host entry guarden never emits.
seed "$project/.guarden/service.yml" "project: myapp" "units: .guarden/quadlet/" \
    "state:" "  - data" "needs:" "  - service: orders" "    as: api" \
    "    port: 443" "    auth: secret" "    hostname: orders.tunnel.example.net"
run loom check "$project"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "hostname"

# A tunnel edge with no hostname names nothing to dial.
seed "$project/.guarden/service.yml" "project: myapp" "units: .guarden/quadlet/" \
    "state:" "  - data" "needs:" "  - service: orders" "    as: api" \
    "    auth: secret" "    via: tunnel"
run loom check "$project"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "hostname"

# A tunnel route answers https on 443, and the number is not the repository's.
seed "$project/.guarden/service.yml" "project: myapp" "units: .guarden/quadlet/" \
    "state:" "  - data" "needs:" "  - service: orders" "    as: api" \
    "    port: 8080" "    auth: secret" "    via: tunnel" \
    "    hostname: orders.tunnel.example.net"
run loom check "$project"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "443"

# A `database` edge creates its role inside the provider, and the mutator that
# would create it is not on the other host.
seed "$project/.guarden/service.yml" "project: myapp" "units: .guarden/quadlet/" \
    "state:" "  - data" "needs:" "  - service: orders" "    as: db" \
    "    auth: database" "    via: tunnel" "    hostname: orders.tunnel.example.net"
run loom check "$project"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "auth: database"

# An unknown transport is refused by name, not silently treated as pasta.
seed "$project/.guarden/service.yml" "project: myapp" "units: .guarden/quadlet/" \
    "state:" "  - data" "needs:" "  - service: orders" "    as: api" \
    "    auth: secret" "    via: cloudflare" \
    "    hostname: orders.tunnel.example.net"
run loom check "$project"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "cloudflare"

# --- the record is the authority ---------------------------------------------
#
# A tunnel edge whose registry entry records no hostname has not been installed:
# the mutator records the name when it installs the edge, and a renderer that
# invented one would be the only holder of a name nobody serves.
seed "$project/.guarden/service.yml" "project: myapp" "units: .guarden/quadlet/" \
    "state:" "  - data" "needs:" "  - service: orders" "    as: api" \
    "    auth: secret" "    via: tunnel" "    hostname: orders.tunnel.example.net"
seed "$registry/myapp-staging.toml" \
    'service = "myapp-staging"' 'workload = "myapp"' 'project = "myapp"' \
    'environment = "staging"' 'uid = 1101' 'created = "2026-09-30T09:00:00Z"' \
    '[edges."orders:443:api"]' 'port = 443' 'as = "api"' 'auth = "secret"' \
    'via = "tunnel"'
run loom render "$project" --service myapp-staging --out "$render"
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "no hostname"

echo "ok t456-tunnel-edge.sh"
