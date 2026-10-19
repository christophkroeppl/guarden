#!/usr/bin/env bash
# What a render actually produces (ticket 40, spec 6.3, 3.1, 6.10, 7.1, 7.3).
#
# The render is a pure function of the manifest, the registry, the overrides and
# the configuration: the same four produce the same bytes on every run. These are
# the claims that are about the bytes — the network backend, the weights, the
# credential requests, the substitution, the templates, and the fact that `check`
# writes nothing at all.
#
# machine: shared
# `guarden_prefix` stages the host and every registry row, admin drop-in,
# rendered unit and template set is under `$GUARDEN_PREFIX` or
# `$GUARDEN_FIXTURES`. The unit source is hand-written quadlet, so no
# converter is driven and no fetch happens; `loom` runs unprivileged and
# writes only into `--out`. A Compose source carrying several `environment:`
# keys is `tests/t300-environment.sh`'s subject, because that case needs the
# converter this suite deliberately does not drive.

. "$(dirname "$0")/lib.sh"

guarden_prefix
stage_config guarden-measured.toml

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
seed "$registry/app-staging.toml" \
    'service = "app-staging"' 'workload = "app"' 'project = "app"' \
    'environment = "staging"' 'uid = 1102' 'created = "2026-09-30T09:00:00Z"' \
    '[publication]' 'web = 20116' \
    '[edges."postgres-production:5432:db"]' 'port = 5432' 'as = "db"' 'auth = "database"' \
    'publications = [ 20007 ]'

project=$GUARDEN_FIXTURES/project
seed "$project/.guarden/service.yml" "project: app" "units: .guarden/quadlet/" \
    "state:" "  - data" "schema: .guarden/.env.schema" "needs:" \
    "  - service: postgres-production" "    as: db" "    port: 5432" "    auth: database"
seed "$project/.guarden/quadlet/web.container" "[Unit]" "Description=the web container" \
    "" "[Container]" "Image=docker.io/library/nginx:1.27" \
    "Environment=APP_HOST=\${domain}" "Environment=APP_MODE=production" \
    "Volume=data:/var/lib/app"
seed "$project/.guarden/quadlet/worker.container" "[Container]" \
    "Image=docker.io/library/alpine:3.20" "Environment=WORKER=yes"
seed "$project/.guarden/.env.schema" "// @defaultSensitive=false" "// @defaultRequired=true" \
    "" "// APP_SECRET" "//   @required" "//   @sensitive" "" "// SESSION_KEY" \
    "//   @sensitive" "//   @type env"

render=$GUARDEN_FIXTURES/render
run loom render "$project" --service app-production --out "$render"
assert_exit 0
assert_stderr_empty
unit=$render/units/web.container

# The renderer owns the network backend, and writes it from the [network] table
# and nowhere else — so a `pasta_options` entry in containers.conf cannot reach
# a guarden container. The pinned set is what the table states, and the whole set
# is what the unit carries.
assert_file_has "$unit" "Network=pasta:--map-gw,--ipv4-only,-a,10.0.2.100,-n,24,-g,10.0.2.2"
assert_file_has "$unit" "Image=docker.io/library/nginx:1.27"
assert_file_has "$unit" "Environment=APP_MODE=production"

# The options join with commas, podman's separator: podman cuts the value at the
# first colon and then splits on commas, so a colon-joined pair would arrive as
# one mangled option and podman would append its default `--no-map-gw` — the host
# mapping off, which is the one thing this table exists to keep on. The table
# drives the bytes, so changing a pinned value changes the rendered one.
sed -i 's/^pasta_options = .*/pasta_options = [ "--map-gw", "--ipv4-only", "-a", "10.0.2.101", "-n", "24", "-g", "10.0.2.2" ]/' \
    "$GUARDEN_PREFIX/etc/guarden/guarden.toml"
run loom render "$project" --service app-production --out "$render"
assert_exit 0
assert_file_has "$unit" "Network=pasta:--map-gw,--ipv4-only,-a,10.0.2.101,-n,24,-g,10.0.2.2"
stage_config guarden-measured.toml
run loom render "$project" --service app-production --out "$render"
assert_exit 0

# `${domain}` is the only substitution, taken from host.domain. A host
# environment variable does not reach a rendered unit, because a unit that
# depended on when it was rendered would not be byte-identical across runs.
assert_file_has "$unit" "Environment=APP_HOST=example.com"
assert_file_lacks "$unit" "\${"
assert_file_lacks "$unit" "app-production} "

# The track's weight reaches the box through the generated units, and a manifest
# cannot state one: `weight:` is refused by name, in t40-manifest.sh. production
# is 1000 and staging is 100, so the same project rendered on two tracks is two
# different units and neither of them is the repository's to choose.
assert_file_has "$unit" "CPUWeight=1000"
assert_file_has "$unit" "IOWeight=1000"
staged=$GUARDEN_FIXTURES/staged
run loom render "$project" --service app-staging --out "$staged"
assert_exit 0
assert_stderr_empty
assert_file_has "$staged/units/web.container" "CPUWeight=100"
assert_file_has "$staged/units/web.container" "IOWeight=100"

# A credential *request* and never a value. Podman resolves the key from the
# service's own secret store and presents it at /run/secrets/<KEY>; a key whose
# application needs a variable gets type=env.
assert_file_has "$unit" "Secret=APP_SECRET,type=mount"
assert_file_has "$unit" "Secret=SESSION_KEY,type=env"
# ... and for a `database` edge, the role's own password in the consumer's store,
# named as the uppercased `as:` prefix plus _PASSWORD.
assert_file_has "$unit" "Secret=DB_PASSWORD,type=mount"
# **`type=file` is not a podman type (ticket 276), so its absence is asserted.**
# podman 5.7 answers `type file is invalid: parsing secret` and the unit fails at
# start — every service with a database or a secret edge — while three suites at
# once pinned the wrong literal as expected output. `mount` is the directive
# that presents the key at /run/secrets/<KEY>, which is what the renderer's own
# docstring has always said it does.
assert_file_lacks "$unit" ",type=file"

# **There is no LoadCredentialEncrypted=, and the absence is asserted.** These
# units run in the service user's user manager, which cannot read the 0600 root
# system host key; the credential materialiser decrypts once, root-side, and by
# the time the renderer runs the value is already a podman secret.
assert_file_lacks "$unit" "LoadCredentialEncrypted"
assert_file_lacks "$render/units/guarden.env" "LoadCredentialEncrypted"
assert_file_lacks "$render/shared/schema.toml" "EXAMPLE"
assert_file_has "$render/shared/schema.toml" "APP_SECRET"
assert_file_has "$render/shared/schema.toml" 'injection = "env"'

# The admin's drop-in is merged into the source before generation, and its
# [Service] keys land in the generated scope: quadlet's own [Container] table has
# only Memory=, so the systemd keys are the only way to express a soft and a hard
# limit together.
seed "$GUARDEN_PREFIX/etc/containers/systemd/users/1101/web.container.d/10-cap.conf" \
    "[Service]" "MemoryMax=512M" "MemoryHigh=384M" "Restart=on-failure"
seed "$GUARDEN_PREFIX/etc/containers/systemd/users/1101/web.container.d/20-tuned.conf" \
    "[Container]" "Environment=TUNED=yes"
run loom render "$project" --service app-production --out "$render"
assert_exit 0
assert_file_has "$unit" "MemoryMax=512M"
assert_file_has "$unit" "MemoryHigh=384M"
assert_file_has "$unit" "Restart=on-failure"
assert_file_has "$unit" "Environment=TUNED=yes"
# The source's own [Service] keys survive, and a drop-in that is not there for a
# container changes nothing for it.
seed "$project/.guarden/quadlet/web.container" "[Unit]" "Description=the web container" \
    "" "[Container]" "Image=docker.io/library/nginx:1.27" \
    "Environment=APP_HOST=\${domain}" "Environment=APP_MODE=production" \
    "Volume=data:/var/lib/app" "" "[Service]" "Restart=always"
run loom render "$project" --service app-production --out "$render"
assert_exit 0
assert_file_has "$unit" "Restart=on-failure"

# An untagged image is a warning that does not stop the render.
seed "$project/.guarden/quadlet/web.container" "[Unit]" "Description=the web container" \
    "" "[Container]" "Image=docker.io/library/nginx" \
    "Volume=data:/var/lib/app"
run loom render "$project" --service app-production --out "$render"
assert_exit 0
assert_stderr_has "warning:"
assert_stderr_has "web"
assert_stderr_has "no tag"

# The same manifest, registry and overrides produce byte-identical output on every
# run, and a second render into the same directory leaves no stale file behind.
seed "$project/.guarden/quadlet/web.container" "[Unit]" "Description=the web container" \
    "" "[Container]" "Image=docker.io/library/nginx:1.27" \
    "Environment=APP_HOST=\${domain}" "Environment=APP_MODE=production" \
    "Volume=data:/var/lib/app"
run loom render "$project" --service app-production --out "$render"
assert_exit 0
run cp -r "$render" "$GUARDEN_FIXTURES/render-once"
run loom render "$project" --service app-production --out "$render"
assert_exit 0
run diff -r "$GUARDEN_FIXTURES/render-once" "$render"
assert_exit 0

# `loom check` validates and writes nothing: no out directory, and the project's
# own tree is untouched.
cp -r "$project" "$GUARDEN_FIXTURES/project-before"
run loom check "$project"
assert_exit 0
assert_stdout_has "renderable"
# The path asserted absent here is one `check` could only have written inside the
# project tree -- `do_check` takes no `--out` and never calls `write()` -- and the
# project tree is already covered by the diff below. `$GUARDEN_FIXTURES/checked`
# was asserted here before and passed whether or not the write-nothing logic was
# there, because nothing in the suite ever named that path. The claim is the
# diff: the tree is byte-identical after a `check`.
run diff -r "$GUARDEN_FIXTURES/project-before" "$project"
assert_exit 0

# Units are rendered from templates/ with jinja2 and not from a string built in
# the program, so a changed template changes the next render. GUARDEN_TEMPLATES is
# the seam, of the same kind as GUARDEN_PREFIX and no wider: it can only change
# the bytes a render produces.
mkdir -p "$GUARDEN_FIXTURES/templates"
cp -r "$GUARDEN_ROOT/src/guarden/templates/." "$GUARDEN_FIXTURES/templates/"
export GUARDEN_TEMPLATES=$GUARDEN_FIXTURES/templates
run loom render "$project" --service app-production --out "$render"
assert_exit 0
assert_file_has "$unit" "Rendered by loom"
# The claim is that a CHANGED template changes the next render, so the template
# has to change. Copying the stock tree and asserting the stock marker proved
# only that the default renders, and would have stayed green with the
# `GUARDEN_TEMPLATES` lookup deleted outright. Marking the seam and rendering
# again is what makes it a seam: the marker comes out of the copy, and the stock
# line does not.
printf '\n# GUARDEN_TEMPLATES marker: this line exists only in the copy\n' \
    >>"$GUARDEN_FIXTURES/templates/quadlet-container.j2"
out=$GUARDEN_FIXTURES/render-marked
run loom render "$project" --service app-production --out "$out"
assert_exit 0
assert_file_has "$out/units/web.container" "GUARDEN_TEMPLATES marker"
unset GUARDEN_TEMPLATES

# `loom` writes only into --out and the shared slices the mutator installs for
# `roots` and `twig`: the whole set is under those three directories and the
# whole set is listed.
assert_stdout_has "units/web.container"
assert_stdout_has "units/web.container.d/10-guarden-order.conf"
assert_stdout_has "units/guarden.env"
assert_stdout_has "system/guarden-order.target"
assert_stdout_has "shared/routes.toml"
assert_stdout_has "shared/schema.toml"
assert_file_missing "$GUARDEN_PREFIX/var/lib/guarden/shared/app-production"
