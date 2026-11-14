#!/usr/bin/env bash
# Config file injection, rendered (ticket 289, spec 4 and 6.3).
#
# A manifest's `config_files:` names a repository template and an absolute path
# inside the container. `loom` renders the template with the service's edge
# variables and writes the bytes under `config/<target>` in the render, and the
# mutator installs them into the service home at the target's own path — so the
# home is a mirror of the container's filesystem at the paths the service needs
# configured, and the unit source's own bind mount, `<home>/<target>:<target>`,
# delivers it. No Containerfile writes it and no operator copies it by hand.
#
# machine: shared
# `guarden_prefix` stages the host, and every registry row, rendered unit and
# checked host path is under `$GUARDEN_PREFIX` or `$GUARDEN_FIXTURES`. The unit
# source is hand-written quadlet, so no converter is driven and no fetch
# happens; `loom` runs unprivileged and writes only into `--out`.

. "$(dirname "$0")/lib.sh"

guarden_prefix
stage_config guarden-measured.toml

# The provider every edge below names. Its `provides:` is read from its registry
# and not from its manifest, because a consumer cannot read a provider's tree
# and `loom` runs as `guarden` (spec 4).
seed "$GUARDEN_PREFIX/var/lib/guarden/registry/postgres-production.toml" \
    'service = "postgres-production"' 'workload = "postgres"' 'project = "postgres"' \
    'environment = "production"' 'uid = 1099' 'created = "2026-09-30T09:00:00Z"' \
    '[provides]' 'kinds = [ "db" ]'
# The consumer's own registry carries the edge's allocated publication, which is
# where `<AS>_PORT` comes from — the renderer reads it and never guesses a
# loopback port (spec 6.3).
seed "$GUARDEN_PREFIX/var/lib/guarden/registry/app-production.toml" \
    'service = "app-production"' 'workload = "app"' 'project = "app"' \
    'environment = "production"' 'uid = 1101' 'created = "2026-09-30T09:00:00Z"' \
    '[publication]' 'web = 20114' \
    '[edges."postgres-production:5432:db"]' 'port = 5432' 'as = "db"' 'auth = "database"' \
    'publications = [ 20007 ]'

project=$GUARDEN_FIXTURES/project
seed "$project/.guarden/service.yml" "project: app" "units: .guarden/quadlet/" \
    "needs:" "  - service: postgres-production" "    as: db" "    port: 5432" "    auth: database" \
    "config_files:" "  - source: templates/odoo.conf.j2" "    target: /etc/odoo/odoo.conf"
# The bind mount is the repository's own declaration and it is unchanged by this
# feature: the path under the service's own tree is what `loom` allows without
# an admin grant (spec 6.3), and the rendered file is what makes it non-empty.
seed "$project/.guarden/quadlet/web.container" "[Unit]" "Description=the web container" \
    "" "[Container]" "Image=docker.io/library/nginx:1.27" \
    "Volume=$GUARDEN_PREFIX/var/lib/guarden/services/app-production/home/etc/odoo:/etc/odoo"
seed "$project/templates/odoo.conf.j2" "[options]" "db_host = {{ DB_HOST }}" \
    "db_port = {{ DB_PORT }}" "base_url = https://app.{{ domain }}"

render=$GUARDEN_FIXTURES/render
run loom render "$project" --service app-production --out "$render"
assert_exit 0
assert_stderr_empty

# Keyed by the target and not by the source: the home mirrors the container's
# filesystem, so the mount the repository wrote reads the same on every track.
config=$render/config/etc/odoo/odoo.conf
assert_file_exists "$config"
assert_file_has "$config" "db_host = postgres-production"
assert_file_has "$config" "db_port = 20007"
assert_file_has "$config" "base_url = https://app.example.com"
assert_file_lacks "$config" "{{"
# The config file is the renderer's output and not a line in the unit: the unit
# source's own `Volume=` is what carries it, and a second copy in the unit would
# be a second place for the path to be wrong.
assert_file_lacks "$render/units/web.container" "odoo.conf"
assert_stdout_has "config/etc/odoo/odoo.conf"

# `check` accepts a `config_files:` manifest whose template names an edge
# variable. It has no registry and therefore no edge variables, so its
# environment is lenient — the undefined names render empty rather than refusing
# — and `render` is the verb that proves the template renders against the host.
# It also accepts the bind mount of the service's own home: `check` has no
# service, so it allows the service tree as a whole and `render` narrows it to
# one service's own.
cp -r "$project" "$GUARDEN_FIXTURES/project-before"
run loom check "$project"
assert_exit 0
assert_stdout_has "renderable"
run diff -r "$GUARDEN_FIXTURES/project-before" "$project"
assert_exit 0

seed "$project/.guarden/service.yml" "project: app" "units: .guarden/quadlet/" \
    "config_files:" "  - source: templates/odoo.conf.j2" "    target: /etc/odoo/odoo.conf" \
    "    dest: /etc/odoo"
run loom check "$project"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "dest"

# `source` is a path inside the repository. An absolute one or one with a `..`
# component would name a file the repository does not own.
seed "$project/.guarden/service.yml" "project: app" "units: .guarden/quadlet/" \
    "config_files:" "  - source: /etc/odoo/odoo.conf.j2" "    target: /etc/odoo/odoo.conf"
run loom check "$project"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "source"

seed "$project/.guarden/service.yml" "project: app" "units: .guarden/quadlet/" \
    "config_files:" "  - source: ../outside/odoo.conf.j2" "    target: /etc/odoo/odoo.conf"
run loom check "$project"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has ".."

# `target` is an absolute path inside the container. A relative one names no
# path the home can hold, and a `//` or a trailing slash is not a path either.
seed "$project/.guarden/service.yml" "project: app" "units: .guarden/quadlet/" \
    "config_files:" "  - source: templates/odoo.conf.j2" "    target: etc/odoo/odoo.conf"
run loom check "$project"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "target"

seed "$project/.guarden/service.yml" "project: app" "units: .guarden/quadlet/" \
    "config_files:" "  - source: templates/odoo.conf.j2" "    target: /etc//odoo/odoo.conf"
run loom check "$project"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "target"

# Two entries naming one target would be two writes to one file.
seed "$project/.guarden/service.yml" "project: app" "units: .guarden/quadlet/" \
    "config_files:" "  - source: templates/odoo.conf.j2" "    target: /etc/odoo/odoo.conf" \
    "  - source: templates/other.j2" "    target: /etc/odoo/odoo.conf"
run loom check "$project"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "twice"

# A source that is not in the repository is refused by name, and it is the
# renderer's question because the tree is the repository's.
seed "$project/.guarden/service.yml" "project: app" "units: .guarden/quadlet/" \
    "config_files:" "  - source: templates/absent.j2" "    target: /etc/odoo/odoo.conf"
run loom check "$project"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "absent.j2"
assert_stderr_has "does not exist"

# A template that does not parse is refused with the file named, rather than
# reaching the home as a file that is not a config file. A fresh `--out` is used
# because a render that refuses writes nothing at all: `build` raises before
# `write`, and the mutator is what empties the directory before it renders.
seed "$project/templates/broken.j2" "[options]" "db_host = {{ DB_HOST "
seed "$project/.guarden/service.yml" "project: app" "units: .guarden/quadlet/" \
    "config_files:" "  - source: templates/broken.j2" "    target: /etc/odoo/odoo.conf"
broken=$GUARDEN_FIXTURES/render-broken
run loom render "$project" --service app-production --out "$broken"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "broken.j2"
assert_file_missing "$broken/config/etc/odoo/odoo.conf"

# The narrowing is `render`'s and not `check`'s: a mount into ANOTHER service's
# home is refused there, because `render` knows which service it is rendering
# for and `check` does not. The manifest is restored first, because the refusals
# above leave the one that was being refused in place.
seed "$project/.guarden/service.yml" "project: app" "units: .guarden/quadlet/" \
    "config_files:" "  - source: templates/odoo.conf.j2" "    target: /etc/odoo/odoo.conf"
seed "$project/.guarden/quadlet/web.container" "[Unit]" "Description=the web container" \
    "" "[Container]" "Image=docker.io/library/nginx:1.27" \
    "Volume=$GUARDEN_PREFIX/var/lib/guarden/services/other-production/home/etc/odoo:/etc/odoo"
run loom check "$project"
assert_exit 0
run loom render "$project" --service app-production --out "$render"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "other-production"

# `loom` writes only into `--out`: the config file is the renderer's output and
# not something it drops into a service home, which it cannot write to at all.
assert_file_missing "$GUARDEN_PREFIX/var/lib/guarden/services/app-production/home/etc/odoo/odoo.conf"
