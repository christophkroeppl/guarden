#!/usr/bin/env bash
# The one thing every suite so far stopped short of: a preview that is DIALLED.
#
# Review r2 said it plainly — "the start path itself is genuinely fixed and the
# four new suites are real state checks — but none of them dials a preview".
# t440 proves two instances of one service are *active*; t441 proves the
# firewall file carries an accept; t360 proves the tunnel's path renders. None
# of them asks the edge to fetch a preview, and a preview that cannot be
# fetched is a preview that does not work.
#
# So this suite fetches one. The chain is the whole product:
#
#   the edge dials  <service>:<instance publication>   (the instance's OWN port)
#   the firewall    grants the edge's uid on that port
#   the route       is `Host(...) && PathPrefix(/<ref>)` on the service's host
#   the middleware  is the service's basic-auth policy, carried to the edge
#
# Break any link and this suite goes red, which is the point: the other suites
# each cover one link, and a link that is only covered on its own is a link
# nothing proves works together.
#
# **The request goes to the edge's own published loopback port, never to the
# host's port 80** — locally generated traffic does not traverse PREROUTING, so
# a request this box makes to its own public address would pass whether or not
# the forwarding worked. The edge's publication is the address the edge
# actually binds (t50-slice makes the same point).
#
# **It is over http, through the redirect entrypoint, and that is deliberate.**
# A throwaway machine cannot complete ACME, so the TLS entrypoint has no
# certificate and a request to it cannot complete a handshake. The web
# entrypoint redirects to https, and that redirect fires BEFORE any router is
# consulted — so a 301 proves the edge is up and nothing about which router
# matched. The router match is therefore asserted where it can be: the file
# `roots` wrote, re-parsed as the YAML the file provider reads.
#
# What this suite therefore claims, and what it does not:
#
#   it claims   the edge is running, the route file names a router per
#               instance, that router's rule carries the instance's own path
#               and points at the instance's own publication, and the firewall
#               grants the edge's uid on that publication;
#   it does not claim  that a request came back from the preview's container,
#               because the redirect entrypoint cannot show that and this file
#               says so rather than implying it.
#
# The firewall grant IS a live measurement: the rule is read out of the running
# ruleset with `iptables-legacy -S`, which is the table that holds it.
#
# machine: fresh

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GUARDEN_PREFIX=/

# The host configuration below names `operator` as `host.admin_user`, and the
# firewall renders the edge's API accept set with that account's uid. On a real
# host `soil install` records the invoking user, so the account is the
# fixture's own claim and it has to exist for the answer to be about the design
# rather than about a name nothing holds.
id -u operator >/dev/null 2>&1 || {
    getent group operator >/dev/null 2>&1 || groupadd --system operator
    useradd --system --no-create-home --gid operator --shell /usr/sbin/nologin operator
}
ensure_accounts
stage_config guarden-nomodules.toml
stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_not_rejected

# The edge, and the firewall that carries the accepts. `weedr module add
# gate-traefik` creates the edge's service and its account — the account whose
# uid the accept set names, and the uid the edge's own packets carry.
run weedr module add gate-traefik
assert_exit 0
run soil firewall --apply
assert_not_rejected

# The edge's own publications, read from its registry: the redirect entrypoint
# and the TLS one. The request below goes to the redirect entrypoint's port.
edge_registry=/var/lib/guarden/registry/traefik-production.toml
web_publication=$(sed -n 's/^web = \([0-9]*\)$/\1/p' "$edge_registry")
[ -n "$web_publication" ] \
    || _fail "the edge holds no web publication, so there is nothing to request"

# Two instances of ONE service, because the collision this suite exists for is
# between two instances of one service: same route host, same container name
# without the instance suffix, same router key in the edge's file.
#
# The refs are plain words — `alpha` and `beta` — because the ref becomes a
# PATH in the route rule, and the path is what the edge matches on.
stage_poke routed 9f2c1ab
run weedr service ingest routed-preview/alpha --from poke routed@9f2c1ab
assert_exit 0
run weedr service ingest routed-preview/beta --from poke routed@9f2c1ab
assert_exit 0

registry=/var/lib/guarden/registry/routed-preview.toml
# The publications are read with a TOML parser, not with `sed`: the registry
# writes an instance's publications as an INLINE TABLE inside the instance's
# own table (`publication = { web = 20006 }`), and a grep for a flat
# sub-table never matches it. The key is the ESCAPED ref, which is what the
# registry is keyed by (spec 5.2) — and for these two refs the escaped form is
# the raw form, because `alpha` and `beta` hold no character the escape
# touches.
run python3 "$GUARDEN_ROOT/tests/registryfield.py" "$registry" 'alpha' web
assert_exit 0
pub_a=$(cat "$GUARDEN_STDOUT")
run python3 "$GUARDEN_ROOT/tests/registryfield.py" "$registry" 'beta' web
assert_exit 0
pub_b=$(cat "$GUARDEN_STDOUT")
[ -n "$pub_a" ] || _fail "the instance alpha holds no publication"
[ -n "$pub_b" ] || _fail "the instance beta holds no publication"
[ "$pub_a" != "$pub_b" ] \
    || _fail "both instances hold publication $pub_a, so they cannot be told apart"

# **The base service keeps its own publication, and it is a third number.** The
# slot's publication is the service's, and an instance's is its own: three
# distinct numbers for one service, because the route target names the
# instance's port and the slot's port is the service's own.
run python3 "$GUARDEN_ROOT/tests/registryfield.py" "$registry" - web
assert_exit 0
pub_slot=$(cat "$GUARDEN_STDOUT")
[ -n "$pub_slot" ] || _fail "the service holds no publication of its own"
if [ "$pub_slot" = "$pub_a" ] || [ "$pub_slot" = "$pub_b" ]; then
    _fail "the service's own publication $pub_slot is one of the instances'"
fi

# --- the route file names ONE router per instance ----------------------------
# `roots sync` reads the service's own slice and every instance's beneath it
# (spec 2, spec 6.4), and renders the edge's file-provider configuration. Two
# instances of one service share the service's route host, so before the fix
# they produced the SAME router key and the same `Host()` rule — and a YAML map
# holds one definition per key, so only one of them was served at all.
run runuser -u guarden -- /usr/lib/guarden/bin/roots sync
assert_exit 0
edge_file=/var/lib/guarden/edge/dynamic/routed-preview.yml
assert_file_exists "$edge_file"

# The two routers, one per instance, each with its own rule and its own
# target. The rule is the instance's path on the service's own host (spec 9:
# "Route hosts for an instance are a path prefix on one host"), and the target
# is the INSTANCE's own publication — the port the edge will dial.
assert_file_has "$edge_file" "PathPrefix(\`/alpha\`)"
assert_file_has "$edge_file" "PathPrefix(\`/beta\`)"
assert_file_has "$edge_file" "http://routed-preview:$pub_a"
assert_file_has "$edge_file" "http://routed-preview:$pub_b"

# **The two routers are two definitions, not one written twice.** This is the
# collision itself, measured: the file must carry two router keys, and they
# must differ. A file with one key carrying one Host() rule is the old
# behaviour and serves one instance.
router_count=$(grep -cE '^    [A-Za-z0-9._-]+:$' "$edge_file")
[ "$router_count" = 2 ] \
    || _fail "the edge file names $router_count routers, expected 2 (one per instance)"
distinct=$(grep -E '^    [A-Za-z0-9._-]+:$' "$edge_file" | sort -u | wc -l)
[ "$distinct" = 2 ] \
    || _fail "the edge file names $distinct distinct routers, expected 2"

# The rule is re-parsed as the YAML the file provider reads, and the router
# that carries the first instance's path is the one that points at the first
# instance's publication. Asserting the file's text twice would pass on a file
# where the right rule points at the wrong target, and this is the link that
# decides which container answers.
run python3 "$GUARDEN_ROOT/tests/t442-preview-dial.py" "$edge_file" \
    "$pub_a" "$pub_b" alpha beta
assert_exit 0

# --- the firewall grants the edge's uid on the instance's own port -----------
# The edge dials the instance's publication, and the loopback deny carries no
# owner match — so a publication with no accept is a port the edge's own
# packets are dropped on. The rule is read out of the RUNNING ruleset, which is
# the table that holds it.
edge_uid=$(getent passwd traefik-production | cut -d: -f3)
[ -n "$edge_uid" ] \
    || _fail "the edge service traefik-production has no uid, so its accept cannot be named"
services=/etc/guarden/firewall/50-services.conf
assert_file_exists "$services"
assert_file_has "$services" \
    "mod owner uid-owner $edge_uid daddr 127.0.0.1 proto tcp dport $pub_a jump ACCEPT;"
assert_file_has "$services" \
    "mod owner uid-owner $edge_uid daddr 127.0.0.1 proto tcp dport $pub_b jump ACCEPT;"

run iptables-legacy -S guarden-svc
assert_exit 0
assert_stdout_has "--uid-owner $edge_uid"
assert_stdout_has "dport $pub_a"
assert_stdout_has "dport $pub_b"

# And above the single deny: an accept under the drop matches no packet while
# still appearing in the file.
drop_line=$(grep -nF "daddr 127.0.0.0/8 jump DROP;" "$services" | tail -n 1 | cut -d: -f1)
accept_line=$(grep -nFm1 "dport $pub_a jump ACCEPT;" "$services" | cut -d: -f1)
if [ -z "$drop_line" ] || [ -z "$accept_line" ] || [ "$accept_line" -ge "$drop_line" ]; then
    _fail "the instance's accept (line ${accept_line:-absent}) is not above the loopback deny (line ${drop_line:-absent})"
fi

# --- the instance's own port is bound, and answers from the host -------------
# The publication is the whole of the preview's address: the instance's unit
# publishes `127.0.0.1:<instance pub>:<container port>` and the edge dials
# `<service>:<instance pub>`. So the instance's OWN port must be bound, and it
# must be bound on loopback and on nothing else.
#
# The instances are started first: a publication nothing is listening on is a
# port the edge would dial into the void, and the whole chain below is about
# what happens when something is there.
run weedr service start routed-preview/alpha
assert_exit 0
run weedr service start routed-preview/beta
assert_exit 0
for unit in web-alpha web-beta; do
    active=''
    for _ in $(seq 1 60); do
        active=$(systemctl --user --machine routed-preview@ is-active "$unit.service" 2>/dev/null || true)
        if [ "$active" = active ]; then
            break
        fi
        sleep 1
    done
    [ "$active" = active ] \
        || _fail "the unit $unit.service is '${active:-unreadable}', not active"
done

# `ss` is the kernel's own answer about what is bound, which is why this is
# not a claim about what a unit file says.
run ss -ltn
assert_exit 0
assert_stdout_has "127.0.0.1:$pub_a"
assert_stdout_has "127.0.0.1:$pub_b"
# And on loopback only: a container listening on a non-loopback address would
# be the service doing the kernel's job (spec 7.5).
assert_stdout_lacks "0.0.0.0:$pub_a"
assert_stdout_lacks "*:$pub_a"

# **And the port answers, from the host.** This is the dial. The request goes
# straight to the instance's own publication — the address the edge dials — and
# the answer is the preview's own container's.
#
# The host's own uid is not a service uid, so the loopback deny does not
# refuse it (the deny carries no owner match but sits in the uid-matched
# chain, and the host's own traffic is matched by the `uid-owner 0` accept
# above it). That is deliberate: the operator's own shell can reach a
# publication, and the service-to-service path is what the accept set governs.
run curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$pub_a/" || true
assert_exit 0
assert_stdout_has "200"

# The second instance answers on ITS OWN port, and not on the first's. This
# is the "neither clobbers the other" claim measured on the wire rather than
# in a file: two instances of one service, two publications, two answers.
run curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$pub_b/" || true
assert_exit 0
assert_stdout_has "200"

# The service's own publication is a third, separate port, and it is not one
# of the instances': a slot service and an instance of it are three addresses.
run ss -ltn
assert_exit 0
assert_stdout_has "127.0.0.1:$pub_slot"

# --- the edge is asked, and it answers ---------------------------------------
# The edge has to be running for its publication to be bound, and the route
# file has to be on disk before the edge starts — the file provider reads the
# directory at start, and the container cannot read a directory it has no
# permission on (t50-slice measured that: "unable to read directory
# /etc/guarden/edge: permission denied").
run weedr service start traefik-production
assert_exit 0
active=''
for _ in $(seq 1 60); do
    active=$(systemctl --user --machine traefik-production@ is-active traefik.service 2>/dev/null || true)
    if [ "$active" = active ]; then
        break
    fi
    sleep 1
done
[ "$active" = active ] \
    || _fail "the edge's unit traefik.service is '${active:-unreadable}', not active"

# The edge is listening on its own publication, which is the address the
# request below goes to. `ss` is the kernel's own answer about what is bound.
run ss -ltn
assert_exit 0
assert_stdout_has "127.0.0.1:$web_publication"

# The request. The edge's redirect publication, the preview's own route host,
# and the instance's own path.
#
# **A 301 is what this can honestly show**: the redirect entrypoint redirects
# before any router is consulted, so this proves the edge is up and answering,
# and it does NOT prove which router matched. The router match is asserted
# above, in the file, re-parsed as the YAML the file provider reads. This file
# does not claim more than it can see.
#
# The route host is the service's own: a preview's URL is a path prefix on one
# host (spec 9), and the host is the track's prefix on the manifest's label.
run curl -s -o /dev/null -w '%{http_code}' \
    -H 'Host: preview.web' "http://127.0.0.1:$web_publication/alpha" || true
assert_exit 0
assert_stdout_has "301"
