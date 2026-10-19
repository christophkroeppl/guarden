#!/usr/bin/env bash
# ticket 302, with ticket 295 behind it: `weedr service start <name>/<ref>` —
# the last step of every `furrow deploy <svc>/<ref>` and the one no suite ran.
#
# A preview instance is created the way the deploy path creates it (`weedr
# service ingest <name>/<ref>`, which `furrow deploy` runs at `ensure` and again
# at `install`) and started the way the deploy's last step starts it. Before
# ticket 295 the mutator never passed the instance's escaped ref to
# `units.install`, so the render landed in the service's shared quadlet
# directory, `units_of(<name>, <escaped-ref>)` was empty, and this start
# answered 1 — which is why every `furrow deploy <svc>/<ref>` failed at its last
# step while the 75 green suites said nothing about it.
#
# What is asserted is state: the exit code of the start, a unit file in the
# instance's own directory, the shared slot holding none of it, the route slice
# carrying the ref raw (the form `roots` escapes for itself), and the unit
# running. No call log and no stand-in.
#
# Two instances of ONE service, because the second one is what the review's
# findings bite on: before their fixes every instance's shared slices were
# installed into `shared/<service>/`, so the second ingest overwrote the
# first's route slice, and `ContainerName=<service>-<container>` was computed
# without the instance, so both instances asked podman for one container name
# (the second `podman run` is refused with the name already in use).
#
# machine: fresh

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GUARDEN_PREFIX=/

ensure_accounts
stage_config guarden.toml
stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_not_rejected
# The firewall phase is the one that installs `guarden-firewall.service`,
# and it is what loads what the mutator renders: without it the render
# below writes `50-services.conf` and warns that nothing loaded it.
run soil firewall --apply
assert_not_rejected

# One route and no `needs:`, so nothing here is about the edge: the preview
# track is `kind = "instance"` in the shipped table and ungated, so the gate
# has nothing to withhold and the start reaches systemd.
stage_poke routed 9f2c1ab

escaped='feature\x2fx'
second='plain'
instance_quadlet="/var/lib/guarden/services/routed-preview/home/$escaped/.config/containers/systemd"
instance_quadlet_b="/var/lib/guarden/services/routed-preview/home/$second/.config/containers/systemd"
slot_quadlet="/var/lib/guarden/services/routed-preview/home/.config/containers/systemd"
slice_a="/var/lib/guarden/shared/routed-preview/instances/$escaped/routes.toml"
slice_b="/var/lib/guarden/shared/routed-preview/instances/$second/routes.toml"

# --- two instances, created the way the deploy path creates them ------------------

run weedr service ingest routed-preview/feature/x --from poke routed@9f2c1ab
assert_exit 0
assert_stderr_empty
assert_file_exists /var/lib/guarden/registry/routed-preview.toml
# `units.install` writes an instance's quadlet files UNIT_MODE (0640) as the
# service uid, and this is where that is true: the SECOND instance's create
# walks the whole service tree (`_make_tree`, `0700` to the tree, spec §2.1)
# and re-modes this file, so a mode asserted later would be asserting whichever
# write ran last (ticket 320).
assert_mode "$instance_quadlet/web.container" 640

# The second instance is the whole point of the block below: one service, two
# refs, two renders, and neither render may erase the other's.
run weedr service ingest routed-preview/plain --from poke routed@9f2c1ab
assert_exit 0
assert_stderr_empty

# --- neither instance's route slice clobbers the other's ----------------------
# Before the fix `units.install` copied every instance's `out/shared/` into
# `shared/routed-preview/` — ticket 295's "fold in 264:87's wrong SHARED slice
# path, units.py writes every slice to SHARED/<service>" — so the second
# ingest's routes.toml replaced the first's and instance A's routes existed
# nowhere. Each instance's slices are its own (spec 2), and the raw ref is what
# the slice carries: `roots.render_tunnel` escapes it itself on the way into
# cloudflared's `ingress.path` (spec 5.2).
assert_file_exists "$slice_a"
assert_file_has "$slice_a" 'ref = "feature/x"'
assert_file_exists "$slice_b"
assert_file_has "$slice_b" 'ref = "plain"'
# The service's own routes.toml is the slot's file: on an instance track no
# render writes it, and it is exactly the file every instance used to clobber.
assert_file_missing /var/lib/guarden/shared/routed-preview/routes.toml

# --- every instance's container has a name of its own -------------------------
# `ContainerName=<service>-<container>` was computed without `context.instance`,
# so two instances of one service asked podman for one name and the second
# container could never start. The suffix is the instance's registry key in
# hex: podman's container-name grammar allows `[A-Za-z0-9][A-Za-z0-9_.-]*`
# only, where systemd's `\xNN` key carries a backslash podman refuses, and hex
# of the key is valid and injective (spec 5.2).
hex_a=$(printf %s "$escaped" | od -An -tx1 | tr -d ' \n')
hex_b=$(printf %s "$second" | od -An -tx1 | tr -d ' \n')
assert_file_has "$instance_quadlet/web.container" "ContainerName=routed-preview-web-$hex_a"
assert_file_has "$instance_quadlet_b/web.container" "ContainerName=routed-preview-web-$hex_b"

# --- where the render had to land for a start to find it -----------------------
assert_file_exists "$instance_quadlet/web.container"
assert_file_exists "$instance_quadlet_b/web.container"
assert_mode "$instance_quadlet_b/web.container" 640
# Instance A's unit was 0640 after ITS install (asserted above) and the second
# instance's create re-moded it to 0700 with the rest of the tree (ticket 320).
# What must hold either way is the property the entry exists for: the service
# user — the uid podman's generator runs as — still reads the declaration.
run_in /tmp runuser -u routed-preview -- test -r "$instance_quadlet/web.container"
assert_exit 0
# The shared slot is where the render used to land, and the service's own `web`
# is not there: an instance track deploys a ref every time. What the slot does
# hold is the one entry podman's generator reads — the unit plus the escaped
# ref, one per instance — because the generator reads the home's own quadlet
# directory and nothing below it, and without that entry `systemctl start`
# answers "Unit web.service not found" (measured).
assert_file_missing "$slot_quadlet/web.container"
assert_file_exists "$slot_quadlet/web-$escaped.container"
assert_file_exists "$slot_quadlet/web-$second.container"

# --- the step no suite ever ran -------------------------------------------------
# Before the fix this answers 1: `routed-preview has no unit to start:
# .../home/feature\x2fx/.config/containers/systemd declares no container`.
run weedr service start routed-preview/feature/x
assert_exit 0
assert_stdout_has "started routed-preview"

# The unit the generator made from the entry above — `<unit>-<escaped-ref>`,
# the name the start translated to — and it running: a start that exits 0 while
# the container never comes up would be a start that proved nothing. Bounded,
# because a pull is the network's own pace.
active=''
for _ in $(seq 1 60); do
    active=$(systemctl --user --machine routed-preview@ is-active "web-$escaped.service" 2>/dev/null || true)
    if [ "$active" = active ]; then
        break
    fi
    sleep 1
done
[ "$active" = active ] || _fail "the instance's unit web-$escaped.service is '${active:-unreadable}', not active"

# ...and the same for the second instance, whose container name has to differ
# for it to be running at all.
run weedr service start routed-preview/plain
assert_exit 0
assert_stdout_has "started routed-preview"
active=''
for _ in $(seq 1 60); do
    active=$(systemctl --user --machine routed-preview@ is-active "web-$second.service" 2>/dev/null || true)
    if [ "$active" = active ]; then
        break
    fi
    sleep 1
done
[ "$active" = active ] || _fail "the second instance's unit web-$second.service is '${active:-unreadable}', not active"
