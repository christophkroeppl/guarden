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
# **It goes to the edge's TLS publication, over plain HTTP, and that is
# deliberate.** The routers `roots` renders are attached to `websecure` — the
# entrypoint that terminates TLS — and a request has to reach THAT
# entrypoint's container port, because the redirect entrypoint answers a
# redirect before any router is consulted. Over plain HTTP the router matches
# and the chain is visible end to end; over HTTPS it does not match at all,
# because the rendered router carries no `tls:` section. The block at the end
# of this file sets that out in full, with the measurement, and names it as
# the defect it is. This suite asserts the chain that is real today and says
# plainly what it does not claim.
#
# What this suite therefore claims, and what it does not:
#
#   it claims   the edge is running, the route file names a router per
#               instance, that router's rule carries the instance's own path
#               and points at the instance's own publication, the EDGE has
#               loaded that router, the edge's own load balancer has reached
#               each instance, the firewall grants the edge's uid on that
#               publication, and a request carrying the preview's own host
#               and path is answered by the preview's own basic-auth policy
#               and reaches the preview's container with the right credential;
#   it does not claim  that an HTTPS request is served, because today the
#               rendered router does not match on a TLS entrypoint. That is
#               reported, not papered over.
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
# and the TLS one.
#
# **The request below goes to the TLS publication, over plain HTTP.** That is
# deliberate and it is measured: the routers `roots` renders are attached to
# `websecure` — the entrypoint that terminates TLS — and the request has to
# reach THAT entrypoint's container port, because a router attached to the
# redirect entrypoint would answer a redirect instead of the container. The
# edge's own routing entrypoints are the serving ones (`edgeconf.
# routing_entrypoints` drops the redirect and the API), so `websecure` is
# where the chain lives. Over HTTPS the router does not match, for the reason
# the block at the end of this file sets out in full.
edge_registry=/var/lib/guarden/registry/traefik-production.toml
web_publication=$(sed -n 's/^web = \([0-9]*\)$/\1/p' "$edge_registry")
tls_publication=$(sed -n 's/^websecure = \([0-9]*\)$/\1/p' "$edge_registry")
[ -n "$web_publication" ] \
    || _fail "the edge holds no web publication, so there is nothing to request"
[ -n "$tls_publication" ] \
    || _fail "the edge holds no websecure publication, so there is nothing to request"

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
#
# **Counted in the ROUTERS section and not over the whole file.** The file has
# three sections at the same indent — `routers:`, `services:` and
# `middlewares:` — and each carries one key per router under it. A count over
# the whole file therefore counted the routers twice and the basic-auth
# middleware once, and read a file with two routers as a file with five. The
# section is cut out first, so the count is of routers.
#
# **`|| true` on both counts, and it is load-bearing.** `grep -c` exits 1 when
# it matches nothing, and a suite runs `set -Eeuo pipefail` — so a file with
# no router at all would kill the suite at the assignment, with the shell's
# own diagnostic, and the message that names the defect would never print.
# The count is the claim, and the claim needs to reach the reader.
routers_section=$(sed -n '/^  routers:$/,/^  [a-z]/p' "$edge_file")
router_count=$(printf '%s\n' "$routers_section" | grep -cE '^    [A-Za-z0-9._-]+:$' || true)
[ "$router_count" = 2 ] \
    || _fail "the edge file names $router_count routers, expected 2 (one per instance)"
distinct=$(printf '%s\n' "$routers_section" | grep -E '^    [A-Za-z0-9._-]+:$' | sort -u | wc -l || true)
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

# **The service's own publication is a third number, and nothing binds it.**
#
# The orphan's version of this file asserted that the slot's publication was
# BOUND (`assert_stdout_has "127.0.0.1:$pub_slot"`), and that assertion is
# wrong on develop's tree. On a `kind = "instance"` track the slot is never
# rendered: `t440` holds the fact with `assert_file_missing
# "$slot_quadlet/web.container"` — every render on that track is an instance's
# render, and the slot's own quadlet directory holds only the search-path
# entries the generator reads. So the slot's publication is ALLOCATED (the
# registry carries it, and the two instances hold two others) and nothing
# listens on it, because there is no slot container to listen.
#
# The claim that is worth making is therefore the one that is true and that
# would catch a real defect: the three numbers are three numbers, the slot's
# unit is NOT there, and the slot's port is NOT bound. A slot that DID bind
# would be a service publishing an address the edge's route file never points
# at — a preview served on a third port that nothing asked for.
slot_quadlet="/var/lib/guarden/services/routed-preview/home/.config/containers/systemd"
assert_file_missing "$slot_quadlet/web.container"
run ss -ltn
assert_exit 0
assert_stdout_lacks "127.0.0.1:$pub_slot"

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

# --- the edge is READY, not merely started ----------------------------------
# **`is-active` is not readiness, and this is the one wait the file needs.**
# Measured on the machine: `traefik.service` reports `active` while the
# container is still coming up, and pasta binds the HOST port before traefik
# has bound `:80` inside the container — so the first request answers with an
# empty reply (curl 52) or a connection reset (56), and the request after it
# answers. Measured: the edge answered at 1.53s after the start; the attempts
# at 1.03s and 1.29s both failed.
#
# This is a race in the CALLER, not a fault in the edge — the same shape as
# `wait_settled` in lib.sh, for the same reason: the unit is up before the
# thing it fronts is. It is waited for ONCE here, at the one place the edge
# becomes reachable, and every request below is then made against an edge
# that is up. A per-request retry would hide the same race in three places
# and would still leave the first of them unguarded.
#
# The probe is the edge's own API: the API answers as soon as traefik is
# serving, and it is the instrument the router table is read with below. The
# wait is bounded (thirty attempts, two seconds apart) and the failure names
# the last answer, so a genuinely dead edge is red and not slow.
#
# **The signal is the status code and not the body.** Traefik's router table is
# a JSON array of router objects, and nothing in it is the string `routers` —
# so a body that "contains routers" is a signal that never becomes true, and a
# wait on it times out on a perfectly healthy edge. The status code is
# unambiguous: `200` is the edge answering, and `000` is curl's own word for
# "no answer at all", which is exactly what the race produces.
api_publication=$(sed -n 's/^api = \([0-9]*\)$/\1/p' "$edge_registry")
[ -n "$api_publication" ] \
    || _fail "the edge holds no api publication, so its router table cannot be read"
code=''
for _ in $(seq 1 30); do
    run curl -s -o /dev/null -w '%{http_code}' \
        "http://127.0.0.1:$api_publication/api/http/routers" || true
    code=$(cat "$GUARDEN_STDOUT")
    if [ "$code" = 200 ]; then
        break
    fi
    sleep 2
done
[ "$code" = 200 ] \
    || _fail "the edge's API answered '$code' after 30 attempts, not 200"

# --- the edge's OWN router table names both instances ------------------------
# The edge's API is the edge's own answer about what it loaded, and t50-slice
# established the pattern: `curl http://127.0.0.1:$api_publication/api/http/routers`
# and read the table. Before ticket 263's fix the table held only traefik's
# three internal routers and not the route at all — the file provider could not
# read the directory. So this is the same question and the same instrument.
#
# **And this is where the router match is measured, not guessed.** The file
# above says the router is in the configuration; this says the EDGE has it.
#
# The table is FETCHED again here, because the readiness wait above asked for
# the status code and not the body: one `run` leaves one answer in
# `$GUARDEN_STDOUT`, and an assertion about a body it did not ask for would be
# an assertion about the previous command's output.
run curl -s "http://127.0.0.1:$api_publication/api/http/routers"
assert_exit 0
assert_stdout_has "routed-preview-web-"
assert_stdout_has "PathPrefix(\`/alpha\`)"
assert_stdout_has "PathPrefix(\`/beta\`)"
assert_stdout_has "Host(\`preview.web\`)"

# --- the edge DIALS each instance, and the instance answers -----------------
# This is the chain, measured on the wire: the edge's own load balancer has a
# server for each instance's publication, and that server's status is UP,
# which is the edge's own statement that it reached the instance.
run curl -s "http://127.0.0.1:$api_publication/api/http/services"
assert_exit 0
assert_stdout_has "http://routed-preview:$pub_a"
assert_stdout_has "http://routed-preview:$pub_b"
assert_stdout_has "UP"

# **And the request itself, over PLAIN HTTP to the edge's TLS publication.**
#
# **This is not a workaround and not a fudge; it is where the chain is
# measurable today, and the reason is measured.** `roots` renders the edge's
# routers with no `tls:` section (`src/guarden/templates/edge-routes.yml.j2`)
# and attaches them to `websecure`, the entrypoint that terminates TLS. In
# traefik v3 a router on a TLS entrypoint matches only if it carries a `tls:`
# section; without one it never matches and the request falls through to
# traefik's default handler. Measured on a real machine: the same request over
# HTTPS answers 404 (traefik's own, 19 bytes), and over plain HTTP to the same
# container port answers 401 — the router matched and the basic-auth
# middleware answered.
#
# So this suite asserts the link that is real — the router matches, it points
# at the instance's own publication, the firewall admits the edge's uid on
# that publication, and the instance's own port answers the host — and it
# does NOT claim an HTTPS fetch works. That gap is a defect in the renderer,
# it is reported as such, and it is not this suite's to paper over: a `tls:`
# section needs a certificate, a throwaway machine cannot complete ACME, and
# the template is not this file's to change.
#
# **The answer is 401, and that IS the claim.** A 401 with a `WWW-Authenticate`
# header is the basic-auth middleware answering, which means the router
# matched THIS host and THIS path and handed the request to the service's
# policy. A 404 is traefik's default handler, which means no router matched.
# So the discriminator is exactly the one that matters: 401 says the chain is
# live, 404 says it is not, and the wrong host or the wrong path answers 404
# too — which is what makes 401 a claim about the ROUTE rather than about the
# edge being up.
#
# The credential is the service's own, decrypted from the blob the mutator
# planted, exactly as t450-basicauth does it. With it the request reaches the
# BACKEND, and the answer is nginx's own — which is the whole chain: the edge
# matched, the middleware admitted the credential, and the preview's container
# answered.
blob=/etc/guarden/creds/routed-preview/GUARDEN_BASICAUTH.cred
assert_file_exists "$blob"
run python3 -c "
import subprocess, sys
password = subprocess.run(
    ['systemd-creds', 'decrypt', sys.argv[1]],
    capture_output=True, text=True, check=True,
).stdout.rstrip('\n')
sys.stdout.write(password)
" "$blob"
assert_exit 0
password=$(cat "$GUARDEN_STDOUT")
[ -n "$password" ] || _fail "the service's basic-auth credential decrypts to nothing"

# **Retried, because `is-active` is not readiness.** Measured on the machine:
# `traefik.service` reports `active` while the container is still coming up,
# and pasta binds the HOST port before traefik has bound `:80` inside the
# container — so the first request answers with an empty reply (curl 52) or a
# connection reset (56), and the one after it answers. Measured: the edge
# answered at 1.53s; the attempts at 1.03s and 1.29s both failed.
#
# This is a race in the CALLER, not a fault in the edge: the same shape as
# `wait_settled` in lib.sh, for the same reason — the unit is up before the
# thing it fronts is. The retry is bounded (thirty attempts, two seconds
# apart) and the failure names the last answer, so a genuinely dead edge is
# red and not slow.
answer=''
for _ in $(seq 1 30); do
    run curl -s -o /dev/null -w '%{http_code}' \
        -H 'Host: preview.web' "http://127.0.0.1:$tls_publication/alpha" || true
    answer=$(cat "$GUARDEN_STDOUT")
    case "$answer" in
        401) break ;;
    esac
    sleep 2
done
[ "$answer" = 401 ] \
    || _fail "the edge answered '$answer' for the preview's route, not 401"

# And the wrong host answers 404 — which is what makes the 401 above a claim
# about the ROUTE and not about the edge being up.
run curl -s -o /dev/null -w '%{http_code}' \
    -H 'Host: nosuchhost.example' "http://127.0.0.1:$tls_publication/alpha" || true
assert_stdout_has "404"

# And with the service's OWN credential the request reaches the BACKEND, which
# answers with its own server header. That is the whole chain in one request:
# the edge matched the route, the middleware admitted the credential, and the
# preview's container answered.
#
# **The server header is the claim, and not the status code.** The backend's
# own status is the backend's business — the fixture's nginx serves `/` and not
# `/alpha`, so it answers 404 with `Server: nginx/1.27.5` — while the header
# is what says WHO answered. Traefik's own default handler answers with no
# server header at all, so the header is the discriminator between "the edge
# answered because no router matched" and "the preview's container answered".
run curl -s -D - -o /dev/null \
    -u "routed-preview:$password" \
    -H 'Host: preview.web' "http://127.0.0.1:$tls_publication/alpha" || true
assert_stdout_has "nginx"
