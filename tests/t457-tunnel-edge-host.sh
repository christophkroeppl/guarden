#!/usr/bin/env bash
# `needs:` over the tunnel hostname — the MUTATOR's half and the machine's
# (ticket 307f T2, spec 4, 7.3, 7.6).
#
# A `via: tunnel` edge names a service on ANOTHER host. Three things follow, and
# this suite is all three:
#
#   1. **the host records the name and allocates nothing.** `weedr service
#      ingest` writes the edge's `via` and `hostname` into the consumer's
#      registry and no publication, so the render has a name to write and
#      nothing to forward;
#   2. **a producer this host DOES know is checked, not trusted.** Its recorded
#      route has to be published `tunnel`; a producer recorded `loopback`
#      publishes no name a consumer could dial, and the ingest is refused before
#      it leaves a user, a home and a subvolume behind (spec 4, `edges.check`);
#   3. **the firewall is untouched.** The consumer is a client of the other
#      host's ingress, so nothing here accepts its uid on a publication and no
#      rule in `50-services.conf` names `443`.
#
# **A container in a pasta namespace resolves the producer's name, measured** —
# pasta's DNS behaviour is not obvious from the pin, and the loopback deny is
# between a service uid and the stub resolver (§7.6). What is measured is the
# mechanism the edge relies on: an unprivileged container resolves a public name
# through pasta's forwarder. The producer's own name is NOT resolved here — the
# harness has no Cloudflare account and no zone — and the manual round trip is
# recorded in `docs/notes/tunnel-edge-manual-check.md`. This suite does not
# pretend to have made it.
#
# Real host, real uid, real render: `GUARDEN_PREFIX=/`, as `t84` and `t455` do.
# The container probe needs a package and an image in `ubuntu`'s own store, so
# the machine is this suite's own.
#
# machine: fresh

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GUARDEN_PREFIX=/

registry=/var/lib/guarden/registry
services=/etc/guarden/firewall/50-services.conf
producer=orders-staging
consumer=tunneled-staging

cleanup() {
    purge "$consumer" "$producer"
}
trap cleanup EXIT

cleanup
ensure_accounts

# `[ingress] tunnel_domain` is the zone the tunnel serves, root-owned and out of
# any repository's reach. It is set because a producer on THIS host can only
# publish a name through the tunnel when the zone exists (ticket 324), and case
# 2 below is about a producer whose recorded destination is not the tunnel.
cat >/etc/guarden/guarden.toml <<'TOML'
[host]
domain = "example.com"
interface = ""
admin_user = "operator"

[ingress]
alias = "10.0.2.2"
tunnel_domain = "tunnel.example.net"
publication_range = [20000, 32767]

[network]
backend = "pasta"
pasta_options = [ "--map-gw", "--ipv4-only", "-a", "10.0.2.100", "-n", "24", "-g", "10.0.2.2" ]

[build]
lanes = 1

[share]
max = "2d"
account = ""
app = ""

[modules]
enabled = []

[[environments]]
name = "production"
host_prefix = ""
gated = true
weight = 1000
free_limit = 0.10
keep_last = 7
kind = "slot"
fork_from = ""

[[environments]]
name = "staging"
host_prefix = "staging."
gated = false
weight = 100
free_limit = 0.20
keep_last = 0
kind = "slot"
fork_from = "production"

[[environments]]
name = "preview"
host_prefix = "preview."
gated = false
weight = 10
free_limit = 0.20
keep_last = 0
kind = "instance"
fork_from = "staging"
cap = 3
TOML

stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_exit 0

# --- 1. a service on another host -------------------------------------------
#
# `orders` is not a service this host has: no registry entry, no container, no
# publication. The name in `hostname:` is the other host's, so the ingest takes
# it and records it.
tree=/var/lib/guarden/staging/tunneled/9f2c1ab
mkdir -p "$tree/.guarden/quadlet"
seed "$tree/.guarden/service.yml" "project: tunneled" "units: .guarden/quadlet/" \
    "state:" "  - data" "needs:" "  - service: orders" "    as: api" \
    "    auth: secret" "    via: tunnel" "    hostname: orders.tunnel.example.net"
seed "$tree/.guarden/quadlet/web.container" "[Container]" \
    "Image=docker.io/library/nginx:1.27" "Volume=data:/var/lib/app"

run weedr service ingest "$consumer" --from poke tunneled@9f2c1ab
assert_exit 0

# The record is the authority (spec 3.4): the name it carries is what the render
# writes and what `weedr service list` reports.
assert_file_has "$registry/$consumer.toml" 'hostname = "orders.tunnel.example.net"'
assert_file_has "$registry/$consumer.toml" 'via = "tunnel"'
# No publication is allocated for the edge: nothing on this host carries that
# traffic, and a number would be a port the firewall admits and nothing answers.
assert_file_lacks "$registry/$consumer.toml" "publications = ["

unit=/var/lib/guarden/services/$consumer/units/guarden.env
assert_file_has "$unit" "API_HOST=orders.tunnel.example.net"
assert_file_has "$unit" "API_PORT=443"
# The credential is a REQUEST; the value is the operator's, because a vendor's
# Access token is minted by the vendor.
assert_file_has "/var/lib/guarden/services/$consumer/units/web.container" \
    "Secret=API_SECRET,type=mount"
# Nothing resolves a public name through this host's alias, and there is no
# local unit for the edge to start.
assert_file_lacks "/var/lib/guarden/services/$consumer/units/web.container" "AddHost="
assert_file_lacks "/var/lib/guarden/services/$consumer/system/guarden-order.target" \
    "orders"

# --- 3. the firewall is unchanged -------------------------------------------
#
# No rule names 443: the consumer reaches the vendor's edge as any client does,
# and a grant on this host would be a rule nothing sends a packet to.
assert_file_lacks "$services" "--dport 443"
assert_file_lacks "$services" "dport 443 "

# --- 2. a producer this host knows, recorded `loopback` ---------------------
#
# The name is real here and it is this host's own route, published on loopback:
# no tunnel carries it, so the edge would leave the host and never come back.
seed "$registry/$producer.toml" \
    'service = "orders-staging"' 'workload = "orders"' 'project = "orders"' \
    'environment = "staging"' 'uid = 1099' 'created = "2026-09-30T09:00:00Z"' \
    '[provides]' 'kinds = [ "api" ]' \
    '[route_hosts]' 'web = "staging.orders.example.com"' \
    '[route_destinations]' 'web = "loopback"'

seed "$tree/.guarden/service.yml" "project: tunneled" "units: .guarden/quadlet/" \
    "state:" "  - data" "needs:" "  - service: orders-staging" "    as: api" \
    "    auth: secret" "    via: tunnel" "    hostname: staging.orders.example.com"
run weedr service ingest "$consumer" --from poke tunneled@9f2c1ab
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "staging.orders.example.com"
assert_stderr_has "loopback"

# The same producer, published through the tunnel: the same entry is accepted,
# and the name it dials is the one the producer's record holds.
seed "$registry/$producer.toml" \
    'service = "orders-staging"' 'workload = "orders"' 'project = "orders"' \
    'environment = "staging"' 'uid = 1099' 'created = "2026-09-30T09:00:00Z"' \
    '[provides]' 'kinds = [ "api" ]' \
    '[route_hosts]' 'web = "staging.orders.example.com"' \
    '[route_destinations]' 'web = "tunnel"'
run weedr service ingest "$consumer" --from poke tunneled@9f2c1ab
assert_exit 0
assert_file_has "$registry/$consumer.toml" 'hostname = "staging.orders.example.com"'

# --- the container resolves a public name -----------------------------------
#
# **Measured, because pasta's DNS behaviour is not obvious.** The pin fixes the
# gateway and the addressing; name resolution goes through pasta's forwarder to
# the host's stub resolver, and the loopback deny is owner-matched, so the
# question is whether a *container* is a client the accept admits (spec 7.6).
# That is not obvious from either file, so it is measured with the real podman and a
# real image this machine built. The machine's network is a precondition of the
# lookup, not a stand-in for the vendor's edge: `example.com` resolves through
# the golden's own resolver or this suite fails saying so.
run grep -c "^ubuntu:" /etc/subuid
assert_exit 0
assert_stdout_has "1"
run pasta --version
assert_exit 0

apt_waits install -y busybox-static
assert_executable /bin/busybox
hop=$GUARDEN_FIXTURES/hop
mkdir -p "$hop/bin"
cp /bin/busybox "$hop/bin/busybox"
tar -C "$hop" -cf "$GUARDEN_FIXTURES/hop.tar" bin
run runuser -u ubuntu -- env -C /tmp podman import \
    --change 'CMD ["/bin/busybox","true"]' "$GUARDEN_FIXTURES/hop.tar" localhost/probe-bb:latest
assert_exit 0

pinned=--map-gw,--ipv4-only,-a,10.0.2.100,-n,24,-g,10.0.2.2
run runuser -u ubuntu -- env -C /tmp podman run --rm --log-level=error \
    --network "pasta:$pinned" localhost/probe-bb /bin/busybox nslookup example.com
assert_exit 0
assert_stdout_has "Name:"

# The producer's own name is in the tunnel's zone, and no Cloudflare account is
# reachable from a test machine: the lookup answers nothing, and the suite says
# so rather than reading silence as success. The live round trip is a MANUAL
# check — `docs/notes/tunnel-edge-manual-check.md` carries the procedure and the
# result — and nothing here claims to have made it.
run runuser -u ubuntu -- env -C /tmp podman run --rm --log-level=error \
    --network "pasta:$pinned" localhost/probe-bb /bin/busybox nslookup \
    orders.tunnel.example.net
echo "MEASURE: the producer's hostname from inside a pasta container: exit $GUARDEN_EXIT"
