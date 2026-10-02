#!/usr/bin/env bash
# The mounts: what a rendered unit may name on the host, and who widens that
# (ticket 40, spec 6.3, 10).
#
# `[mounts] allow` in the root-owned `overrides.toml` is the only way a host path
# outside the service's own volumes and `/etc/guarden` becomes bindable, and an
# entry there is a grant in the same sense a port is. A repository cannot widen
# its own mounts, so the renderer never writes that file and never reads one the
# repository supplied.

. "$(dirname "$0")/lib.sh"

guarden_prefix
stage_config guarden-measured.toml

# Two of the three fixture projects this file renders ship a `compose.yaml`, so the
# property it asserts — that no rendered unit names a host path outside the
# service's own volumes — is a property of a converter's output as much as of the
# renderer's. The converter is installed by the phase that owns the fetch, at the
# pinned path, and is a program; `t20-podlet.sh` is where that is the subject.
install_pinned_converter

registry=$GUARDEN_PREFIX/var/lib/guarden/registry
overrides=$GUARDEN_PREFIX/etc/guarden/services

# The provider every consumer in this file declares an edge to. Its `provides:`
# is read from its registry and not from its manifest, because a consumer cannot
# read a provider's tree and `loom` runs as `guarden` (spec 4).
seed "$registry/postgres-staging.toml" \
    'service = "postgres-staging"' 'workload = "postgres"' 'project = "postgres"' \
    'environment = "staging"' 'uid = 1099' 'created = "2026-09-30T09:00:00Z"' \
    '[provides]' 'kinds = [ "db" ]'

stage_service() {
    seed "$registry/$1.toml" \
        "service = \"$1\"" "workload = \"myapp\"" "project = \"myapp\"" \
        "environment = \"staging\"" "uid = 1101" "created = \"2026-09-30T09:00:00Z\"" \
        '[publication]' 'web = 20114' 'node = 20115' \
        '[edges."postgres-staging"]' 'port = 5432' 'as = "db"' 'auth = "database"' \
        'publications = [ 20007 ]'
}
stage_service myapp-staging

# The property belongs to the renderer, so it is asserted once over every fixture
# project rather than per service. Each project is rendered as its own service on
# the staging track, and every host path any of them renders is checked against
# the service's own volumes, `/etc/guarden` and the admin's allow list.
for project in myapp quadlet-app hostnet; do
    service=$project-staging
    stage_service $service
    run loom render "$GUARDEN_ROOT/fixtures/projects/$project" --service $service \
        --out "$GUARDEN_FIXTURES/render-$project"
    assert_exit 0
done

seed "$overrides/myapp-staging/overrides.toml" '[mounts]' 'allow = [ "/dev/dri" ]'
allowed=$GUARDEN_PREFIX/var/lib/guarden/services:/etc/guarden:/dev/dri
run python3 "$GUARDEN_ROOT/tests/t40-hostpaths.py" "$allowed" \
    "$GUARDEN_FIXTURES/render-myapp" "$GUARDEN_FIXTURES/render-quadlet-app" \
    "$GUARDEN_FIXTURES/render-hostnet"
assert_exit 0
assert_stderr_empty

# The one host path a repository may add, and only because the admin put it in
# the file. A `groups.add` entry is how a transcoding service reaches /dev/dri
# without the renderer knowing anything about video (spec 3.3).
seed "$registry/myapp-staging.toml" \
    'service = "myapp-staging"' 'workload = "myapp"' 'project = "myapp"' \
    'environment = "staging"' 'uid = 1101' 'created = "2026-09-30T09:00:00Z"' \
    '[publication]' 'web = 20114' 'node = 20115' \
    '[edges."postgres-staging"]' 'port = 5432' 'as = "db"' 'auth = "database"' \
    'publications = [ 20007 ]'
seed "$GUARDEN_FIXTURES/dri/.guarden/service.yml" "project: myapp" "units: .guarden/quadlet/"
seed "$GUARDEN_FIXTURES/dri/.guarden/quadlet/web.container" "[Container]" \
    "Image=docker.io/library/nginx:1.27" "Volume=/dev/dri:/dev/dri"
run loom render "$GUARDEN_FIXTURES/dri" --service myapp-staging --out "$GUARDEN_FIXTURES/render-dri"
assert_exit 0
assert_file_has "$GUARDEN_FIXTURES/render-dri/units/web.container" "Volume=/dev/dri:/dev/dri"

# Take the grant away and the same unit is refused, naming the path: the allow
# list is the grant, and nothing else turns it on.
seed "$overrides/myapp-staging/overrides.toml" '[mounts]' 'allow = [ ]'
run loom render "$GUARDEN_FIXTURES/dri" --service myapp-staging --out "$GUARDEN_FIXTURES/render-dri"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "/dev/dri"

# A repository cannot widen its own mounts. The renderer does not write the
# admin's file, and the file it read is byte for byte the file it was given.
seed "$overrides/myapp-staging/overrides.toml" '[mounts]' 'allow = [ "/dev/dri" ]'
cp "$overrides/myapp-staging/overrides.toml" "$GUARDEN_FIXTURES/overrides.before"
run loom render "$GUARDEN_ROOT/fixtures/projects/myapp" --service myapp-staging \
    --out "$GUARDEN_FIXTURES/render-myapp"
assert_exit 0
assert_file_exists "$overrides/myapp-staging/overrides.toml"
run diff "$GUARDEN_FIXTURES/overrides.before" "$overrides/myapp-staging/overrides.toml"
assert_exit 0
# The mode and the owner of the admin's file are `weedr`'s to write, not the
# renderer's: the claim this test can make is the one that belongs to `loom`,
# which is that a render neither creates that file nor changes one it read. The
# mode itself is asserted where the file is written, in t30.
seed "$registry/plain-staging.toml" \
    'service = "plain-staging"' 'workload = "myapp"' 'project = "myapp"' \
    'environment = "staging"' 'uid = 1101' 'created = "2026-09-30T09:00:00Z"' \
    '[publication]' 'web = 20114'
run loom render "$GUARDEN_ROOT/fixtures/projects/hostnet" --service plain-staging \
    --out "$GUARDEN_FIXTURES/render-plain"
assert_exit 0
assert_file_missing "$overrides/plain-staging/overrides.toml"

# The renderer writes no firewall rule of its own: a grant is a translation the
# mutator renders into `30-services.conf`. Everything a render produced is under
# `--out`, in the three directories the mutator installs from, and the whole set
# is listed on stdout — which is where that claim is asserted, in t40-render.
assert_file_missing "$GUARDEN_PREFIX/etc/guarden/firewall/30-services.conf"
