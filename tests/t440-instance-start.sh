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

# --- the instance, created the way the deploy path creates it -----------------

run weedr service ingest routed-preview/feature/x --from poke routed@9f2c1ab
assert_exit 0
assert_stderr_empty
assert_file_exists /var/lib/guarden/registry/routed-preview.toml

# --- the step no suite ever ran -------------------------------------------------
# Before the fix this answers 1: `routed-preview has no unit to start:
# .../home/feature\x2fx/.config/containers/systemd declares no container`.
run weedr service start routed-preview/feature/x
assert_exit 0
assert_stdout_has "started routed-preview"

# --- and where the render had to land for that to be true -----------------------
escaped='feature\x2fx'
instance_quadlet="/var/lib/guarden/services/routed-preview/home/$escaped/.config/containers/systemd"
assert_file_exists "$instance_quadlet/web.container"
assert_mode "$instance_quadlet/web.container" 640
# The shared slot is where the render used to land, and the service's own `web`
# is not there: an instance track deploys a ref every time. What the slot does
# hold is the one entry podman's generator reads — the unit plus the escaped
# ref — because the generator reads the home's own quadlet directory and
# nothing below it, and without that entry `systemctl start` answers
# "Unit web.service not found" (measured).
slot_quadlet="/var/lib/guarden/services/routed-preview/home/.config/containers/systemd"
assert_file_missing "$slot_quadlet/web.container"
assert_file_exists "$slot_quadlet/web-$escaped.container"

# The route slice carries the ref **raw**: `roots.render_tunnel` escapes it
# itself on the way into cloudflared's `ingress.path` (spec 5.2: the verb takes
# the ref raw and the escaping is internal), so the escaped form here would be
# escaped a second time downstream.
assert_file_has /var/lib/guarden/shared/routed-preview/routes.toml 'ref = "feature/x"'

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
