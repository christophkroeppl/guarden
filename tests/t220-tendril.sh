#!/usr/bin/env bash
# The second terminator: a track may carry routes that are not published on the
# edge at all, reached instead by a tunnel that dials out and is bound by nobody
# (ticket 220, ADR-0015, spec 3.6, 7.7).
#
# Real host, real uids, real `useradd`: `GUARDEN_PREFIX=/` and the machine's own
# tools, as `t50-route` does. What is asserted is state — a rendered file, an
# absent file, an unchanged file — and never a record of what a program said it
# was about to do.
#
# The tunnel is not started here: that needs a real Cloudflare account and a
# delegated zone, which the ticket marks as an operator acceptance step. What is
# assertable without either is the refusal, the render, the routing decision and
# the firewall, and that is this file.
#
# machine: fresh

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GUARDEN_PREFIX=/

ensure_accounts

# The shipped table with the tunnel's one root-owned key set. `tunnel_domain` is
# in `[ingress]` and no repository can write it. The staging track's `expose` is
# `tunnel`, which is what puts its routes on the tunnel rather than the edge.
cat >"$GUARDEN_PREFIX/etc/guarden/guarden.toml" <<'TOML'
[host]
domain = "example.com"
interface = ""
admin_user = "operator"

[ingress]
alias = "192.0.2.1"
tunnel_domain = "tunnel.example.net"
publication_range = [20000, 32767]

[network]
backend = "pasta"
pasta_options = [ "--map-gw" ]

[build]
lanes = 1

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
free_limit = "0.20"
keep_last = 0
kind = "slot"
fork_from = "production"
expose = "tunnel"

[[environments]]
name = "preview"
host_prefix = "preview."
gated = false
weight = 10
free_limit = "0.20"
keep_last = 0
kind = "instance"
fork_from = "staging"
cap = 3
TOML

stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_not_rejected

# **An empty `tunnel_domain` refuses the module.** The tunnel has nothing to
# render a hostname against, so installing it would create a service that can
# never carry a route. The refusal is at the CLI seam and names the key.
cp "$GUARDEN_PREFIX/etc/guarden/guarden.toml" "$GUARDEN_FIXTURES/guarden-tunnel.toml"
sed -i 's/^tunnel_domain = .*/tunnel_domain = ""/' "$GUARDEN_PREFIX/etc/guarden/guarden.toml"
run weedr module add tendril
assert_exit 2
assert_stderr_has "tunnel_domain"
run weedr module list
assert_exit 0
assert_stdout_has "enabled   none"

run cp "$GUARDEN_FIXTURES/guarden-tunnel.toml" "$GUARDEN_PREFIX/etc/guarden/guarden.toml"

# **`20-ingress-nat.conf` is byte-identical across the module add, and that is
# the assertion that separates the tunnel from the edge.** The tunnel dials out,
# so no `nat PREROUTING` DNAT exists for it and no public port forwards to it. A
# module that added one would be a door, which ADR-0015 says it is not.
run soil firewall --apply
assert_not_rejected
nat=$GUARDEN_PREFIX/etc/guarden/firewall/20-ingress-nat.conf
run cp "$nat" "$GUARDEN_FIXTURES/nat-before.conf"
run weedr module add tendril
assert_exit 0
run cmp -s "$nat" "$GUARDEN_FIXTURES/nat-before.conf"
assert_exit 0

# The service exists and is a service like any other. It declares no port of its
# own, so there is no publication and nothing to forward.
assert_file_exists "$GUARDEN_PREFIX/var/lib/guarden/registry/tendril-production.toml"
run weedr service list
assert_exit 0
assert_stdout_has "tendril-production"

# The unit is a podman `[Container]`, like every other module's, and it passes
# its arguments one `Exec=` line each. A raw systemd unit with a multi-word
# `ExecStart=` is refused by `unitsource.format_line` by design, which is what
# the container route exists to avoid.
unit=$GUARDEN_PREFIX/usr/lib/guarden/modules/tendril/tendril-production/.guarden/quadlet/tendril-production.container
assert_file_exists "$unit"
assert_file_has "$unit" "[Container]"
assert_file_has "$unit" "Image=docker.io/cloudflare/cloudflared"
assert_file_lacks "$unit" "ExecStart="

run weedr module add gate
assert_exit 0
stage_poke routed 9f2c1ab
run weedr service ingest routed-staging --from poke routed@9f2c1ab
assert_exit 0

# The staging track's `expose` is `tunnel`, so the route belongs to the tunnel
# and **not** to the edge. It is absent from the edge's dynamic directory — not
# rendered disabled and not rendered behind a deny, absent, because a second
# route table the two terminators both honour is how one hostname ends up
# reachable twice.
run runuser -u guarden -- /usr/lib/guarden/bin/roots sync
assert_exit 0
tunnel_config=$GUARDEN_PREFIX/var/lib/guarden/tunnel/config.yml
assert_file_exists "$tunnel_config"
assert_file_missing "$GUARDEN_PREFIX/var/lib/guarden/edge/dynamic/routed-staging.yml"

# **One file for the whole host, and it is a real cloudflared config**: the
# credential it reads and a single `ingress:` list. Not a bare list of rules,
# which is not a file cloudflared would accept.
assert_file_has "$tunnel_config" "credentials-file: /run/secrets/TUNNEL_CREDENTIAL"
assert_file_has "$tunnel_config" "ingress:"
assert_file_has "$tunnel_config" 'hostname: "staging.web"'

# The catch-all is `http_status:404` and it is **last**: a hostname in the
# tunnel's zone that no service claims is a 404 from the tunnel, not a default
# page and not a fall-through to the edge.
[ "$(grep -c 'http_status:404' "$tunnel_config")" = 1 ] \
    || _fail "the tunnel's catch-all is not exactly one rule"
case "$(tail -1 "$tunnel_config")" in
    *http_status:404*) : ;;
    *) _fail "the tunnel's catch-all is not last: $(tail -1 "$tunnel_config")" ;;
esac

# A service's own root-owned override can only ever move a route FROM the edge
# TO the tunnel, and there is deliberately no `[expose] edge`. The override names
# labels, so an override present on a track that says `edge` changes nothing.
sed -i 's/^expose = "tunnel"$//' "$GUARDEN_PREFIX/etc/guarden/guarden.toml"
mkdir -p "$GUARDEN_PREFIX/etc/guarden/services/routed-staging"
cat >"$GUARDEN_PREFIX/etc/guarden/services/routed-staging/overrides.toml" <<'TOML'
[expose]
tunnel = ["web"]
TOML
run weedr service ingest routed-staging --from poke routed@9f2c1ab
assert_exit 0
run runuser -u guarden -- /usr/lib/guarden/bin/roots sync
assert_exit 0
assert_file_exists "$tunnel_config"
assert_file_missing "$GUARDEN_PREFIX/var/lib/guarden/edge/dynamic/routed-staging.yml"

# The loopback deny still applies to the tunnel's uid: it is one more service
# uid, closed to loopback by exactly the same rule as every other, and being the
# thing that reaches the publications is an explicit accept ABOVE the deny rather
# than a gap in it.
services=$GUARDEN_PREFIX/etc/guarden/firewall/50-services.conf
assert_file_exists "$services"
assert_file_has "$services" "127.0.0.0/8"

# **The tunnel's uid is granted the publication it fronts, and nothing else.**
# Without this the route is in the tunnel's config and reachable by nobody: the
# deny stops the tunnel's uid before it reaches the service, so a tunnel-declared
# route 404s at the tunnel rather than answering.
tunnel_uid=$(getent passwd tendril-production | cut -d: -f3)
[ -n "$tunnel_uid" ] || _fail "the tendril service user has no uid"
routed_publication=$(sed -n 's/^publication = //p' \
    "$GUARDEN_PREFIX/var/lib/guarden/shared/routed-staging/routes.toml" | head -n 1)
[ -n "$routed_publication" ] || _fail "routed-staging holds no publication"

grant="uid-owner $tunnel_uid daddr 127.0.0.1 proto tcp dport $routed_publication"
grep -vE '^[[:space:]]*#' "$services" | grep -qF "$grant" \
    || _fail "the tunnel's uid is not granted the publication it fronts: $grant"

# And the accept is above the deny, because a grant that lands below a default
# deny is unreachable while still appearing in the file.
grant_line=$(grep -nF "$grant" "$services" | head -n 1 | cut -d: -f1)
deny_line=$(grep -nF 'daddr 127.0.0.0/8 jump DROP' "$services" | head -n 1 | cut -d: -f1)
[ -n "$grant_line" ] && [ -n "$deny_line" ] && [ "$grant_line" -lt "$deny_line" ] \
    || _fail "the tunnel's accept is not above the deny (grant line $grant_line, deny line $deny_line)"
