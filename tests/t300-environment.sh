#!/usr/bin/env bash
# A Compose service's `environment:` map is several assignments (ticket 274,
# spec 6.3).
#
# **A multi-key `environment:` used to arrive as ONE variable, silently.** The
# converter joins the map with spaces, the renderer quoted that join because
# `Environment` was a quotable key, and quadlet passes a quoted value through as
# a single argv token: the container received one variable named `POSTGRES_USER`
# whose value held `guarden POSTGRES_PASSWORD=guarden-dev PGDATA=...`, and
# `POSTGRES_PASSWORD` and `PGDATA` did not exist. Nothing printed anywhere — the
# unit rendered, `weedr service start` said `started`, and postgres later
# complained about a data directory that was only wrong because its environment
# was (ticket 274).
#
# This file is its own suite because the case needs the pinned converter: the
# Compose source is what produces a joined group in the first place, and
# `install_pinned_converter` reaches real apt. `t40-parsers.py` asserts the same
# property from the other side — `format_line` refusing a wholly quoted
# `Environment=` — and needs no converter at all.
#
# machine: shared
# `guarden_prefix` stages the host; every registry row, staged manifest and
# rendered unit is under `$GUARDEN_PREFIX` or `$GUARDEN_FIXTURES`.

. "$(dirname "$0")/lib.sh"

guarden_prefix
stage_config guarden-measured.toml
install_pinned_converter

registry=$GUARDEN_PREFIX/var/lib/guarden/registry
seed "$registry/postgres-production.toml" \
    'service = "postgres-production"' 'workload = "postgres"' 'project = "postgres"' \
    'environment = "production"' 'uid = 1099' 'created = "2026-09-30T09:00:00Z"' \
    '[provides]' 'kinds = [ "db" ]'
seed "$registry/app-production.toml" \
    'service = "app-production"' 'workload = "app"' 'project = "app"' \
    'environment = "production"' 'uid = 1101' 'created = "2026-09-30T09:00:00Z"' \
    '[publication]' 'web = 20114' \
    '[edges."postgres-production:5432:db"]' 'port = 5432' 'as = "db"' 'auth = "database"' \
    'publications = [ 20007 ]'

project=$GUARDEN_FIXTURES/compose-env
seed "$project/.guarden/service.yml" "project: app" "units: compose.yaml" \
    "state:" "  - data" "schema: .guarden/.env.schema" "needs:" \
    "  - service: postgres-production" "    as: db" "    port: 5432" \
    "    auth: database"
seed "$project/.guarden/.env.schema" "// @defaultSensitive=false" \
    "// @defaultRequired=true" "" "// APP_SECRET" "//   @required" \
    "//   @sensitive" "" "// SESSION_KEY" "//   @sensitive" "//   @type env"
seed "$project/compose.yaml" "services:" "  web:" \
    "    image: docker.io/library/nginx:1.27" "    environment:" \
    "      POSTGRES_USER: guarden" "      POSTGRES_PASSWORD: guarden-dev" \
    "      PGDATA: /var/lib/postgresql/data/pgdata" "    volumes:" \
    "      - data:/var/lib/app"

render=$GUARDEN_FIXTURES/render
run loom render "$project" --service app-production --out "$render"
assert_exit 0
assert_stderr_empty
unit=$render/units/web.container
assert_file_exists "$unit"

# The three keys are three assignments and none of them is a quoted group
# holding the join: quadlet splits an unquoted `Environment=` value on
# whitespace into one `--env` per assignment, and hands a quoted one through as
# ONE token — measured in ticket 274 as
# `--env "POSTGRES_USER=guarden\x20POSTGRES_PASSWORD=..."`.
assert_file_lacks "$unit" "Environment=\""
assert_file_has "$unit" "POSTGRES_USER=guarden"
assert_file_has "$unit" "POSTGRES_PASSWORD=guarden-dev"
assert_file_has "$unit" "PGDATA=/var/lib/postgresql/data/pgdata"

# The credential request is emitted on the Compose path too, and it is podman's
# `mount` rather than the `type=file` podman 5.7 rejects (ticket 276).
assert_file_has "$unit" "Secret=APP_SECRET,type=mount"
assert_file_lacks "$unit" ",type=file"
