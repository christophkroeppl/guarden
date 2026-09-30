#!/usr/bin/env bash
# The declared volumes and the `.volume` units (ticket 40, spec 4, 6.3).
#
# **A mounted named volume in neither `state:` nor `bulk:` is refused, naming the
# volume.** It would land in the service's rootless image store, where nothing
# snapshots it, nothing lists it, and removing the service discards it. That is
# the most expensive mistake a manifest can make, and the manifest is not allowed
# to make it.
#
# A `.volume` unit is emitted for every declared volume, `state` and `bulk`
# alike, because a container must be able to mount either — the difference
# between the two is whether a snapper configuration exists, not whether a
# container can reach the data.

. "$(dirname "$0")/lib.sh"

guarden_prefix
stage_config guarden-measured.toml

registry=$GUARDEN_PREFIX/var/lib/guarden/registry
stage_service() {
    seed "$registry/$1.toml" \
        "service = \"$1\"" "workload = \"myapp\"" "project = \"myapp\"" \
        "environment = \"preview\"" "uid = 1101" "created = \"2026-09-30T09:00:00Z\"" \
        '[instances."feature\\x2dlogin"]' 'ref = "feature/login"' \
        'created = "2026-09-30T09:00:00Z"'
}
stage_service myapp-preview

project=$GUARDEN_FIXTURES/project
seed "$project/.guarden/service.yml" "project: myapp" "units: .guarden/quadlet/" \
    "state:" "  - data" "bulk:" "  - chainstate"
seed "$project/.guarden/quadlet/web.container" "[Container]" \
    "Image=docker.io/library/nginx:1.27" "Volume=data:/var/lib/app" \
    "Volume=chainstate:/data"

render=$GUARDEN_FIXTURES/render
run loom render "$project" --service myapp-preview --out "$render"
assert_exit 0
assert_stderr_empty

# A `.volume` unit per declared volume, and a `state` one is bound to
# /var/lib/guarden/services/<name>/state/<vol> with a `bulk` one beside it. The
# path is derived; a manifest never writes one.
assert_file_has "$render/units/data.volume" "VolumeName=myapp-preview-data.volume"
assert_file_has "$render/units/data.volume" \
    "$GUARDEN_PREFIX/var/lib/guarden/services/myapp-preview/state/data"
assert_file_has "$render/units/chainstate.volume" "VolumeName=myapp-preview-chainstate.volume"
assert_file_has "$render/units/chainstate.volume" \
    "$GUARDEN_PREFIX/var/lib/guarden/services/myapp-preview/bulk/chainstate"

# The container mounts the volume unit by name rather than the path, which is
# what makes quadlet start the `.volume` unit before the container.
assert_file_has "$render/units/web.container" "Volume=myapp-preview-data.volume:/var/lib/app"
assert_file_has "$render/units/web.container" "Volume=myapp-preview-chainstate.volume:/data"

# An instance's volumes are its own, under instances/<escaped-ref>/, which is a
# sibling of the service's and never a child of it: btrfs does not recurse into
# nested subvolumes when it snapshots, so a subvolume inside a snapshotted one
# would be excluded from every snapshot ever taken.
instance=$GUARDEN_FIXTURES/instance
run loom render "$project" --service myapp-preview --instance 'feature\x2dlogin' --out "$instance"
assert_exit 0
assert_file_has "$instance/units/data.volume" \
    "$GUARDEN_PREFIX/var/lib/guarden/services/myapp-preview/instances/feature\\x2dlogin/state/data"
assert_file_has "$instance/units/chainstate.volume" \
    "$GUARDEN_PREFIX/var/lib/guarden/services/myapp-preview/instances/feature\\x2dlogin/bulk/chainstate"

# The expensive mistake. The container mounts a named volume the manifest never
# declared, so the volume is refused by name rather than quietly installed, and
# the out directory it was pointed at is not created: a refused render writes
# nothing at all, which is what makes "it refuses to render what it cannot
# resolve" mean something.
refused=$GUARDEN_FIXTURES/refused-render
seed "$project/.guarden/quadlet/web.container" "[Container]" \
    "Image=docker.io/library/nginx:1.27" "Volume=data:/var/lib/app" \
    "Volume=chainstate:/data" "Volume=scratch:/scratch"
run loom render "$project" --service myapp-preview --out "$refused"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "scratch"
assert_stderr_has "state:"
assert_stderr_has "bulk:"
assert_file_missing "$refused"

# The other direction: a volume the manifest declares and the unit source does
# not mount is a declaration that does nothing, and a subvolume nobody mounts is
# not what the manifest said.
seed "$project/.guarden/quadlet/web.container" "[Container]" \
    "Image=docker.io/library/nginx:1.27" "Volume=data:/var/lib/app"
run loom render "$project" --service myapp-preview --out "$render"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "chainstate"

# The same rule on the Compose path, where the volume arrives as a short-form
# `volumes:` entry and podlet turns it into a `Volume=` line of its own.
compose=$GUARDEN_FIXTURES/compose
seed "$compose/.guarden/service.yml" "project: myapp" "units: compose.yaml" \
    "state:" "  - data" "bulk:" "  - chainstate"
seed "$compose/compose.yaml" "services:" "  web:" \
    "    image: docker.io/library/nginx:1.27" "    volumes:" \
    "      - data:/var/lib/app" "      - chainstate:/data" "      - scratch:/scratch"
run loom render "$compose" --service myapp-preview --out "$render"
assert_exit 2
assert_stderr_has "scratch"
