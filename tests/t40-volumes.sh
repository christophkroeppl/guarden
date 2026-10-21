#!/usr/bin/env bash
# The declared volumes, and the `Volume=` line each one becomes (ticket 40,
# spec 4, 6.3).
#
# **A mounted named volume in neither `state:` nor `bulk:` is refused, naming the
# volume.** It would land in the service's rootless image store, where nothing
# snapshots it, nothing lists it, and removing the service discards it. That is
# the most expensive mistake a manifest can make, and the manifest is not allowed
# to make it.
#
# A declared volume is mounted by its own host path and there is no `.volume`
# unit: the mutator makes the subvolume before the unit is installed, so the
# `Volume=` line names the path it made — and a `state` volume's data lives one
# level down in its payload (ADR-0020), so its line names the payload. The
# difference between the two kinds is whether a snapper configuration exists,
# not whether a container can reach the data.
#
# machine: shared
# `guarden_prefix` stages the host; every registry row, staged manifest and
# rendered `.volume` unit is under `$GUARDEN_PREFIX` or `$GUARDEN_FIXTURES`.
# The paths this file asserts are the *rendered strings*, not directories
# that exist, so no subvolume is created and `btrfs` is never called.
# `install_pinned_converter` reaches real apt and the machine's apt timers;
# see the note in t40-manifest.sh, which is the same leak in the same four
# suites.

. "$(dirname "$0")/lib.sh"

guarden_prefix
stage_config guarden-measured.toml

# The last block of this file renders a Compose source, and the converter is what
# turns one into units — installed by the phase that owns the fetch, at the pinned
# path, and a program rather than a file that merely exists.
install_pinned_converter

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

assert_file_has "$render/units/web.container" \
    "Volume=$GUARDEN_PREFIX/var/lib/guarden/services/myapp-preview/state/data/data:/var/lib/app"
assert_file_has "$render/units/web.container" \
    "Volume=$GUARDEN_PREFIX/var/lib/guarden/services/myapp-preview/bulk/chainstate:/data"
assert_file_missing "$render/units/data.volume"
assert_file_missing "$render/units/chainstate.volume"

# An instance's volumes are its own, under instances/<escaped-ref>/, which is a
# sibling of the service's and never a child of it: btrfs does not recurse into
# nested subvolumes when it snapshots, so a subvolume inside a snapshotted one
# would be excluded from every snapshot ever taken.
instance=$GUARDEN_FIXTURES/instance
run loom render "$project" --service myapp-preview --instance 'feature\x2dlogin' --out "$instance"
assert_exit 0
assert_file_has "$instance/units/web.container" \
    "Volume=$GUARDEN_PREFIX/var/lib/guarden/services/myapp-preview/instances/feature\\x2dlogin/state/data/data:/var/lib/app"
assert_file_has "$instance/units/web.container" \
    "Volume=$GUARDEN_PREFIX/var/lib/guarden/services/myapp-preview/instances/feature\\x2dlogin/bulk/chainstate:/data"

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

# ---------------------------------------------------------------------------
# a subvolume is the service's own, and only the service's own
# ---------------------------------------------------------------------------

# `Mount=` is quadlet's long form -- `type=bind,source=<path>,destination=<path>` --
# and it was in neither REFUSED_DIRECTIVES nor GUARDEN_OWNED_ORDER while
# `_mounts_of_unit` read only `Volume=`. So a repository could write
# `Mount=type=bind,source=/,destination=/host` and nothing looked at it. It is
# refused by name now, which is stricter than letting the mount guard see it.
seed "$project/.guarden/quadlet/web.container" "[Container]" \
    "Image=docker.io/library/nginx:1.27" \
    "Volume=data:/var/lib/app" "Volume=chainstate:/data" \
    "Mount=type=bind,source=/,destination=/host"
run loom render "$project" --service myapp-preview --out "$refused"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "Mount="
assert_stderr_has "does not get it"

# The other half, and the one that is easy to get backwards: the guard permits the
# service's OWN volume tree, because that is where a subvolume lives, and nothing
# else. Another service's tree is not this service's own, so it is refused -- which
# is what makes the allowance safe rather than a widening.
#
# `Volume=` is the key that reaches the mount guard at all. `Mount=` is in
# REFUSED_DIRECTIVES, so a repository's `Mount=` is refused by name before the guard
# is consulted -- stricter, not weaker, and the assertion above is that it is
# refused at all rather than silently honoured.
seed "$project/.guarden/quadlet/web.container" "[Container]" \
    "Image=docker.io/library/nginx:1.27" \
    "Volume=data:/var/lib/app" "Volume=chainstate:/data" \
    "Volume=$GUARDEN_PREFIX/var/lib/guarden/services/myapp-production/state/data:/stolen"
run loom render "$project" --service myapp-preview --out "$refused"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "myapp-production"
# The refusal names the path as "not the service's own volume", which was false
# while that tree was in neither the allowance nor the check.
assert_stderr_has "not the service's own volume"
