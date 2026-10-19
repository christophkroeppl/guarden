#!/usr/bin/env bash
# t452-tunnel-default.sh — ticket 293: the default posture of a new service is
# the tunnel when the cloudflared module is installed and loopback-only when
# it is not, fail-closed in both directions, with no manifest asking for any
# of it. A track that states `expose` keeps deciding (root-owned, spec 3.3);
# a track that states nothing resolves from the module set; and a service
# created under one answer keeps it — the default moves, a running fleet does
# not — which is what `soil firewall --check` reports when it happens.
#
# The suite removes the fixture's explicit `expose` rows first: what is under
# test is the derived default, so the track has to say nothing at all.
#
# machine: fresh

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GUARDEN_PREFIX=/

id -u operator >/dev/null 2>&1 || {
    getent group operator >/dev/null 2>&1 || groupadd --system operator
    useradd --system --no-create-home --gid operator --shell /usr/sbin/nologin operator
}
ensure_accounts
stage_config guarden-nomodules.toml
# No track states an exposure: this host's answer is the module set and
# nothing else, which is the whole claim of the derived default.
sed -i '/^expose = "edge"$/d' "$GUARDEN_PREFIX/etc/guarden/guarden.toml"
stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_not_rejected
run weedr module add gate-traefik
assert_exit 0

destination_of() {
    sed -n 's/^destination = "\(.*\)"$/\1/p' "$1" | head -n 1
}

services=$GUARDEN_PREFIX/etc/guarden/firewall/50-services.conf

# 1. With no cloudflared module a new service is loopback-only: its slice says
# so, the edge does not render it, and the edge's uid holds no accept on its
# route publication — the owner does, because the service is still reachable
# from the box, which is what loopback-only means.
stage_poke routed 9f2c1ab
run weedr service ingest routed-staging --from poke routed@9f2c1ab
assert_exit 0
reg=$GUARDEN_PREFIX/var/lib/guarden/registry/routed-staging.toml
slice=$GUARDEN_PREFIX/var/lib/guarden/shared/routed-staging/routes.toml
publication=$(sed -n 's/^web = \([0-9]*\)$/\1/p' "$reg")
[ -n "$publication" ] || _fail "no publication was allocated for the routed service"
routed_uid=$(getent passwd routed-staging | cut -d: -f3)
edge_uid=$(getent passwd traefik-production | cut -d: -f3)
[ "$(destination_of "$slice")" = "loopback" ] \
    || _fail "without the cloudflared module a new service rendered destination $(destination_of "$slice"), not loopback"
assert_file_has "$services" \
    "mod owner uid-owner $routed_uid daddr 127.0.0.1 proto tcp dport $publication jump ACCEPT;"
[ "$(grep -cE "uid-owner $edge_uid daddr 127\.0\.0\.1 proto tcp dport $publication jump ACCEPT;" \
    "$services" || true)" = 0 ] \
    || _fail "the edge holds an accept on a loopback-only service's publication"

# 2. A track that says `tunnel` with no tunnel to carry it is fail-closed
# loopback, not a route rendered into a config nothing reads.
sed -i '/^name = "staging"$/,/^fork_from/ s/^keep_last = 0$/keep_last = 0\nexpose = "tunnel"/' \
    "$GUARDEN_PREFIX/etc/guarden/guarden.toml"
other=$GUARDEN_PREFIX/var/lib/guarden/staging/other/9f2c1ab
mkdir -p "$other/.guarden/quadlet"
seed "$other/.guarden/service.yml" "project: other" "units: .guarden/quadlet/" \
    "routes:" "  - container: web" "    port: 8080" "    host: api"
seed "$other/.guarden/quadlet/web.container" "[Container]" \
    "Image=docker.io/library/nginx:1.27"
run weedr service ingest other-staging --from poke other@9f2c1ab
assert_exit 0
otherslice=$GUARDEN_PREFIX/var/lib/guarden/shared/other-staging/routes.toml
[ "$(destination_of "$otherslice")" = "loopback" ] \
    || _fail "a track asking for a tunnel with no module rendered destination $(destination_of "$otherslice"), not the fail-closed loopback"

# 3. The recorded postures and the current config still agree, so the check is
# clean before anything moves — the drift line later has to be about the
# change and about nothing else.
run soil firewall --apply
assert_not_rejected
run soil firewall --check
assert_exit 0

# 4. With the tunnel installed, a service created afterwards goes behind it,
# with no manifest change and no host-facing bind: the slice says tunnel, the
# edge renders nothing for it, cloudflared's config carries its host, and the
# tunnel's uid is the one granted the publication.
sed -i '/^\[ingress\]$/a tunnel_domain = "tunnel.example.net"' \
    "$GUARDEN_PREFIX/etc/guarden/guarden.toml"
run weedr module add cloudflared
assert_exit 0
run weedr service ingest routed-production --from poke routed@9f2c1ab
assert_exit 0
prodreg=$GUARDEN_PREFIX/var/lib/guarden/registry/routed-production.toml
prodslice=$GUARDEN_PREFIX/var/lib/guarden/shared/routed-production/routes.toml
prodpub=$(sed -n 's/^web = \([0-9]*\)$/\1/p' "$prodreg")
tunnel_uid=$(getent passwd cloudflared-production | cut -d: -f3)
[ "$(destination_of "$prodslice")" = "tunnel" ] \
    || _fail "with cloudflared installed a new service rendered destination $(destination_of "$prodslice"), not tunnel"
run runuser -u guarden -- /usr/lib/guarden/bin/roots sync
assert_exit 0
assert_file_missing "$GUARDEN_PREFIX/var/lib/guarden/edge/dynamic/routed-production.yml"
assert_file_exists "$GUARDEN_PREFIX/var/lib/guarden/tunnel/config.yml"
assert_file_has "$GUARDEN_PREFIX/var/lib/guarden/tunnel/config.yml" 'hostname: "web"'
assert_file_has "$services" \
    "mod owner uid-owner $tunnel_uid daddr 127.0.0.1 proto tcp dport $prodpub jump ACCEPT;"

# 5. Grandfathering: the service created before the tunnel existed keeps its
# loopback posture across a substantive re-ingest, because its record was made
# once and a default that moves does not move a running fleet.
# The fixture's unit source carries no trailing newline, so the marker goes
# on a line of its own: appended flat it would become part of `Image=` and the
# refusal that follows would be about a quoted image, not about a re-ingest.
printf '\n# touched\n' >>"$GUARDEN_PREFIX/var/lib/guarden/staging/routed/9f2c1ab/.guarden/quadlet/web.container"
run weedr service ingest routed-staging --from poke routed@9f2c1ab
assert_exit 0
[ "$(destination_of "$slice")" = "loopback" ] \
    || _fail "installing cloudflared re-postured an existing service to $(destination_of "$slice")"
run runuser -u guarden -- /usr/lib/guarden/bin/roots sync
assert_exit 0
assert_file_missing "$GUARDEN_PREFIX/var/lib/guarden/edge/dynamic/routed-staging.yml"

# 6. The migration path for such a fleet is the act itself: recording the
# posture each service already holds makes the host clean again, and the check
# says so.
run weedr expose set routed-staging loopback
assert_exit 0
run weedr expose set other-staging loopback
assert_exit 0
run soil firewall --check
assert_exit 0

# 7. A default that moves behind the record's back is drift, named after the
# service it moved, and the verb that reports it changes nothing.
sed -i '/^name = "production"$/,/^fork_from/ s/^fork_from = ""$/expose = "loopback"\nfork_from = ""/' \
    "$GUARDEN_PREFIX/etc/guarden/guarden.toml"
run soil firewall --check
assert_exit 1
assert_stderr_has "drift"
assert_stderr_has "routed-production"
# Put the track back and the same check is clean: the report is about the
# configuration, not about a record that has to be chased.
sed -i '/^expose = "loopback"$/d' "$GUARDEN_PREFIX/etc/guarden/guarden.toml"
run soil firewall --check
assert_exit 0
