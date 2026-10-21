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

# The edge is installed, because the edge is what dials a preview: the accept
# set this suite asserts is the edge's own uid being granted the instance's
# publication, and a host with no edge has no edge uid to grant. The module is
# already in the fixture's `[modules] enabled`, so this is the act that
# creates the edge's service and its account.
run weedr module add gate-traefik
assert_exit 0

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
# `units.install` writes an instance's quadlet files the tree's own mode —
# `0700` to the service user, like every other file under the tree (spec §2.1)
# — so this file is the same mode whether the install wrote it or
# `_make_tree`'s walk last touched it (ticket 320).
assert_mode "$instance_quadlet/web.container" 700

# The second instance is the whole point of the block below: one service, two
# refs, two renders, and neither render may erase the other's.
run weedr service ingest routed-preview/plain --from poke routed@9f2c1ab
assert_exit 0
assert_stderr_empty

# The FIRST instance's file after the SECOND instance's create: unchanged. The
# walk that owns the tree and the install that writes a unit state one mode
# (spec §2.1), so no operation can re-mode a file another one wrote. Before
# ticket 320 this read `0640` here and `0700` after the walk, and the next
# redeploy of the first instance flipped it back — the mode was whichever
# writer ran last.
assert_mode "$instance_quadlet/web.container" 700

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

# --- the instance's OWN edge router -------------------------------------------
# **Two instances of one service are two routers, and that is what makes both of
# them routable.** A preview service's route host is the SERVICE's own
# (`record.route_hosts` is per service), so before the fix every instance
# produced the same router key and the same `Host()` rule — and a YAML map holds
# one definition per key, so only ONE instance was served at the edge.
#
# The assertion is on the RULE, not on the key: the key is an implementation
# detail (`<service>-<label>-<suffix>`) and the rule is the thing the edge
# matches on. An instance's rule carries its ref as a path prefix, because the
# ref IS a path (`feature/x` is two segments and `/feature/x` is the path that
# reaches it) — and a slot's rule is byte-for-byte what it was before, so a
# service with no instance renders exactly as it did.
edge_file="/var/lib/guarden/edge/dynamic/routed-preview.yml"
# **The routers are written by `roots sync`, not by the deploy.** The edge
# reads its routes from a file provider over `/var/lib/guarden/edge/dynamic`,
# and the file is written when the routes are SYNced — a route change the edge
# reads without a restart. So the suite syncs the roots before it reads the
# file, or the file is absent and the assertion below is about nothing.
#
# **The file must be there.** A conditional assertion is a vacuous one: the
# first run of this suite found the file absent at the path it guessed, the
# `if [ -f ]` branch took the "absent" arm and the suite went green having
# asserted nothing. So the file's existence is asserted, not assumed, and the
# rules are read out of it.
run roots sync
assert_not_rejected
assert_file_exists "$edge_file"
echo "MEASURE: the edge router file: $edge_file"
# Both instances' rules are present, each with its own ref.
assert_file_has "$edge_file" 'PathPrefix(`/feature/x`)'
assert_file_has "$edge_file" 'PathPrefix(`/plain`)'
# And the HOST rule is there for each: the rule is the conjunction.
assert_file_has "$edge_file" 'Host('
echo "MEASURE: the instance routers: $(grep -c 'PathPrefix' "$edge_file")"
[ "$(grep -c 'PathPrefix' "$edge_file")" -ge 2 ] \
    || _fail "the edge file carries fewer than two instance routers, so one instance is not routable"
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
assert_mode "$instance_quadlet_b/web.container" 700
# And the property the mode exists for: the service user — the uid podman's
# generator runs as — reads the declaration.
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

# --- the instance's publication is in the firewall accept set -----------------
# The start above proves the container runs. It does not prove anything can
# REACH it, and that is a different fact: an instance gets its own
# publication (`instance.publication`), its unit publishes it
# (`PublishPort=127.0.0.1:<instance pub>:<port>`) and the route target is
# `<service>:<instance pub>` — so the edge dials the INSTANCE's port, not the
# service's. The accept set is what lets it: `50-services.conf` carries one
# owner-matched accept per `(publication, uid)`, and the loopback deny below
# them carries no owner match, so a publication with no accept is a port
# nothing outside the box can reach.
#
# Before this fix `accept_lines` iterated only `record.publication` — the
# service's own map — so the instance's port had no accept at all: the preview
# was running and unreachable, and "two previews run at once" was true in
# podman and false in the product.
#
# The instance's publication is read from the registry, which is where it is
# persisted (spec 7.4) and the only place it can be read from — the number is
# allocated, never derived.
#
# The registry writes it as a sub-table of the instance's own table, and the
# instance's key is the ESCAPED ref, TOML-quoted — so the header on disk holds
# the escaped form with its backslash doubled by the TOML string quoting.
registry=/var/lib/guarden/registry/routed-preview.toml
# The instance's publication is read with a TOML parser, not with `sed`: the
# registry writes an instance's publications as an INLINE TABLE inside the
# instance's own table (`publication = { web = 20006 }`), and a grep for a
# flat sub-table never matches it. The key is the ESCAPED ref, which is what
# the registry is keyed by (spec 5.2).
run python3 "$GUARDEN_ROOT/tests/registryfield.py" "$registry" 'feature\x2fx' web
assert_exit 0
instance_pub=$(cat "$GUARDEN_STDOUT")
[ -n "$instance_pub" ] \
    || _fail "the instance feature\\x2fx holds no publication in the registry"
services=/etc/guarden/firewall/50-services.conf
assert_file_exists "$services"
# The service's own uid, and the edge's uid: the edge is what dials it, and it
# dials it as the edge's own uid. Both accepts are owner-matched and both sit
# above the single loopback deny.
assert_file_has "$services" \
    "mod owner uid-owner $(id -u routed-preview) daddr 127.0.0.1 proto tcp dport $instance_pub jump ACCEPT;"
# The edge's uid is the one that makes the preview reachable at all, so it is
# asserted by name rather than by count: the edge's own publication set is
# granted on every route publication the edge serves (ticket 293), and an
# instance's publication is a route publication like any other.
edge_uid=$(getent passwd traefik-production | cut -d: -f3)
[ -n "$edge_uid" ] \
    || _fail "the edge service traefik-production has no uid, so its accept cannot be named"
assert_file_has "$services" \
    "mod owner uid-owner $edge_uid daddr 127.0.0.1 proto tcp dport $instance_pub jump ACCEPT;"
# Above the deny: an accept under the single drop matches no packet while
# still appearing in the file, so the position is part of the claim.
accept_line=$(grep -nFm1 "dport $instance_pub jump ACCEPT;" "$services" | cut -d: -f1)
deny_line=$(grep -nF "daddr 127.0.0.0/8 jump DROP;" "$services" | tail -n 1 | cut -d: -f1)
if [ -z "$accept_line" ] || [ -z "$deny_line" ] || [ "$accept_line" -ge "$deny_line" ]; then
    _fail "the instance's accept for dport $instance_pub (line ${accept_line:-absent}) is not above the loopback deny (line ${deny_line:-absent})"
fi

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

# --- a bare start names no instance, and is refused ---------------------------
# The preview track is `kind = "instance"`, so a name with no `/<ref>` names
# the SLOT — and the slot of an instance track holds no unit of its own. Every
# render on that track is an instance's, and the slot's own quadlet directory
# holds only the entries the search path needs: one `<unit>-<escaped-ref>` per
# instance.
#
# Before the fix that directory was read as if it were the slot's own, so the
# "has no unit to start" guard passed, and the start then fanned out to every
# instance — plus, because keep-id re-renders the units before a start, a
# phantom `web.container` for a slot that has no render. A start that starts
# every preview and a unit nobody declared is not a start (review r2, F3).
#
# The refusal is exit 2 — the argument named something the track does not
# have — and it names the instances, so the operator is told which to name.
run weedr service start routed-preview
assert_exit 2
assert_stderr_has "kind = \"instance\""
assert_stderr_has "routed-preview/<ref>"
assert_stderr_has "feature/x"
assert_stdout_lacks "started routed-preview"

# And nothing was started by it: the slot's own unit is not there, and the two
# instances are exactly the ones the starts above named.
assert_file_missing "$slot_quadlet/web.container"
assert_file_exists "$slot_quadlet/web-$escaped.container"
assert_file_exists "$slot_quadlet/web-$second.container"
