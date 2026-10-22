#!/usr/bin/env bash
# `needs:` over the tunnel hostname — the MUTATOR's half and the machine's
# (ticket 307f T2, spec 4, 7.3, 7.6).
#
# A `via: tunnel` edge names a service on ANOTHER host. Three properties follow,
# and this suite checks all three:
#
#   1. **the host records the name and allocates nothing.** `weedr service
#      ingest` writes the edge's `via` and `hostname` into the consumer's
#      registry and no publication, so the render has a name to write and
#      nothing to forward;
#   2. **a producer this host DOES know is checked, not trusted.** Its recorded
#      route has to be published `tunnel`; a producer recorded `loopback`
#      publishes no name a consumer could dial, and the ingest is refused before
#      it leaves a user, a home and a subvolume behind (spec 4, `edges.check`);
#   3. **the rendered firewall set is untouched.** The consumer is a client of
#      the other host's ingress, so nothing here accepts its uid on a publication
#      and no rule in `50-services.conf` names `443`. (The suite loads that set
#      later, for the lookup below — loading it is what makes the measurement
#      mean anything, and the set it loads carries no rule for this edge.)
#
# **A container in a pasta namespace resolves a public name with the policy in
# force, and a uid with no accept does not — measured.** pasta forwards a
# container's lookup to the host's stub resolver from the uid that started the
# container, and §7.6's default deny drops every loopback packet from a service
# uid except the two accepts above it. So the suite loads
# `guarden-firewall.service` — `soil firewall --apply` writes and starts it, and
# it loads `50-services.conf` — and runs the same lookup twice: as the consumer's
# own uid, and as `ubuntu`, which is not a service and has no accept. The deny's
# packet counter is read across each row, so the second row failing and the first
# not is what says the policy is loaded rather than that nothing was. The
# producer's own name does NOT resolve here — no zone, no Cloudflare account —
# and the live round trip is a MANUAL check in
# `docs/notes/tunnel-edge-manual-check.md`, which this suite does not pretend to
# have made.
#
# Real host, real uid, real render: `GUARDEN_PREFIX=/`, as `t84` and `t455` do.
# The container probe puts a package and an image into two users' stores — the
# consumer's and `ubuntu`'s — so the machine is this suite's own.
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

unit_dir=/var/lib/guarden/services/$consumer/home/.config/containers/systemd
env_file=$unit_dir/guarden.env
assert_file_has "$env_file" "API_HOST=orders.tunnel.example.net"
assert_file_has "$env_file" "API_PORT=443"
# The credential is a REQUEST; the value is the operator's, because a vendor's
# Access token is minted by the vendor.
assert_file_has "$unit_dir/web.container" "Secret=API_SECRET,type=mount"
# Nothing resolves a public name through this host's alias, and there is no
# local unit for the edge to start.
assert_file_lacks "$unit_dir/web.container" "AddHost="
assert_file_exists /etc/systemd/system/guarden-order.target
assert_file_lacks /etc/systemd/system/guarden-order.target "orders"

# --- 3. the firewall is unchanged -------------------------------------------
#
# No rule names 443: the consumer reaches the vendor's edge as any client does,
# and a grant on this host would be a rule nothing sends a packet to.
assert_file_exists "$services"
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

# --- the container resolves a public name, with the policy in force ----------
#
# **Measured, because pasta's DNS behaviour is not obvious.** The pin fixes the
# gateway and the addressing; name resolution goes through pasta's forwarder to
# the host's stub resolver, and the query is forwarded **from the uid that
# started the container**, so the composed question is whether §7.6's accept set
# admits that uid. The suite answers it on the deployed state: the policy is
# loaded from `50-services.conf` first, and the same lookup then runs twice — as
# the consumer's own uid, whose two stub-resolver accepts sit above the deny, and
# as `ubuntu`, which is not a service uid and has none.
#
# **The second row is the one that proves the policy is loaded.** A suite that
# asserted only the first would pass on a machine where the deny was never
# installed — the deployment guarden never has — and the deny's own packet
# counter is what tells the two apart, so it is read across both rows.
run grep -c "^ubuntu:" /etc/subuid
assert_exit 0
assert_stdout_has "1"
run pasta --version
assert_exit 0

apt_waits install -y busybox-static
assert_executable /bin/busybox
hop=/tmp/guarden-t457-hop
hop_tar=/tmp/guarden-t457-hop.tar
mkdir -p "$hop/bin"
cp /bin/busybox "$hop/bin/busybox"
tar -C "$hop" -cf "$hop_tar" bin
chmod 644 "$hop_tar"

# The consumer's OWN store: the probe has to run as the uid under test, so the
# image is imported by that uid rather than by root or by `ubuntu`.
home=/var/lib/guarden/services/$consumer/home
svc_uid=$(id -u "$consumer")
[ -n "$svc_uid" ] || _fail "$consumer has no uid, so it has no accept to measure"
runtime=/run/user/"$svc_uid"
for _ in $(seq 1 30); do
    [ -d "$runtime" ] && break
    sleep 1
done
assert_file_exists "$runtime"

run_in "$home" setpriv --reuid="$consumer" --regid="$consumer" --clear-groups \
    env -u OLDPWD HOME="$home" PWD="$home" USER="$consumer" LOGNAME="$consumer" \
    XDG_RUNTIME_DIR="$runtime" podman import \
    --change 'CMD ["/bin/busybox","true"]' "$hop_tar" localhost/probe-bb:latest
assert_exit 0
run runuser -u ubuntu -- env -C /tmp podman import \
    --change 'CMD ["/bin/busybox","true"]' "$hop_tar" localhost/probe-bb:latest
assert_exit 0

run soil firewall --apply
assert_not_rejected
run systemctl start guarden-firewall.service
assert_exit 0
wait_settled guarden-firewall.service
assert_active guarden-firewall.service

# **The uid under test is in the set that was loaded**, one accept per protocol,
# before the lookup leans on it: a suite that never asked would read the
# denial's absence as an accept.
assert_file_has "$services" \
    "mod owner uid-owner $svc_uid daddr 127.0.0.53 proto udp dport 53 jump ACCEPT;"

pinned=--map-gw,--ipv4-only,-a,10.0.2.100,-n,24,-g,10.0.2.2

# **The server is named on every row.** podman writes the container's
# `resolv.conf` with pasta's forwarder **and the host's own nameserver beside
# it** (measured: `169.254.1.1`, then the machine's), so an unqualified
# `nslookup` falls back to the second and answers a uid the deny just refused —
# the row would read as "accepted" whatever the policy said. Naming the forwarder
# asks pasta and nothing else, which is the path under test.
forwarder=169.254.1.1

# `iptables -nvx -L` prints `pkts bytes target prot …`, so a rule's counter is
# the first field. Two readings — the deny, and the uid's own stub-resolver
# accept — one function each, so no two readings differ in how they were taken.
deny_packets() {
    iptables-legacy -nvx -L guarden-svc 2>/dev/null \
        | awk '$3 == "DROP" && $NF ~ /^127\.0\.0\.0\/8/ {print $1; exit}'
}
accept_packets() {
    iptables-legacy -nvx -L guarden-svc 2>/dev/null \
        | awk -v uid="$svc_uid" \
            '$0 ~ ("owner UID match " uid " udp dpt:53") {print $1; exit}'
}

before_deny=$(deny_packets)
before_accept=$(accept_packets)
[ -n "$before_deny" ] || _fail "guarden-svc has no DROP rule on 127.0.0.0/8 to measure"
[ -n "$before_accept" ] || _fail "uid $svc_uid has no stub-resolver accept to measure"
run_in "$home" setpriv --reuid="$consumer" --regid="$consumer" --clear-groups \
    env -u OLDPWD HOME="$home" PWD="$home" USER="$consumer" LOGNAME="$consumer" \
    XDG_RUNTIME_DIR="$runtime" podman run --rm --log-level=error \
    --network "pasta:$pinned" localhost/probe-bb /bin/busybox nslookup \
    example.com "$forwarder"
assert_exit 0
assert_stdout_has "Name:"
after_deny=$(deny_packets)
after_accept=$(accept_packets)
printf 'MEASURE: SERVICE_UID_LOOKUP DENY=%s->%s ACCEPT=%s->%s\n' \
    "$before_deny" "$after_deny" "$before_accept" "$after_accept" >&2
[ "$after_deny" = "$before_deny" ] \
    || _fail "the consumer uid's lookup met the loopback deny, so its stub-resolver accept is not above it"
[ "$after_accept" != "$before_accept" ] \
    || _fail "the consumer uid's query never reached its stub-resolver accept, so the answer came from somewhere else"

# **The same lookup as a uid with no accept.** uid 1000 is not a service and the
# deny names no uid, so the query pasta forwards is dropped: no `Name:` line, and
# the deny's counter moves. Both halves are asserted — a name that failed to
# resolve for some other reason would leave the counter still.
before=$(deny_packets)
run timeout 120 runuser -u ubuntu -- env -C /tmp podman run --rm --log-level=error \
    --network "pasta:$pinned" localhost/probe-bb /bin/busybox nslookup \
    example.com "$forwarder"
after=$(deny_packets)
printf 'MEASURE: NON_SERVICE_UID_LOOKUP DENY=%s->%s\n' "$before" "$after" >&2
printf 'MEASURE: the non-service uid lookup printed:\n%s\n' "$(cat "$GUARDEN_STDOUT")" >&2
[ "$after" != "$before" ] \
    || _fail "a non-service uid's lookup did not meet the deny, so the deny is not in force and the row above proves nothing"
assert_stdout_lacks "Name:"

# The producer's own name is in the tunnel's zone, and no Cloudflare account is
# reachable from a test machine — so the lookup is the evidence that this suite
# did NOT make the round trip, and the output is printed rather than an exit
# code: busybox's `nslookup` returns 0 on a name it cannot resolve, so a status
# would read as success and mean nothing.
#
# The live round trip is a MANUAL check —
# `docs/notes/tunnel-edge-manual-check.md` carries the procedure and the result
# — and nothing here claims to have made it.
run_in "$home" setpriv --reuid="$consumer" --regid="$consumer" --clear-groups \
    env -u OLDPWD HOME="$home" PWD="$home" USER="$consumer" LOGNAME="$consumer" \
    XDG_RUNTIME_DIR="$runtime" podman run --rm --log-level=error \
    --network "pasta:$pinned" localhost/probe-bb /bin/busybox nslookup \
    orders.tunnel.example.net "$forwarder"
printf 'MEASURE: the producer hostname from inside a pasta container:\n%s\n' \
    "$(cat "$GUARDEN_STDOUT")"
assert_stdout_lacks "Name:"
