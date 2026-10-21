#!/usr/bin/env bash
# t453-tunnel-credential.sh — ticket 323: a tunnel route carries no middleware,
# so the credential that covers it is the vendor's, and the act that promotes a
# service to the tunnel says so.
#
# What is asserted is state and the act's own words: the record, the rendered
# artefacts, the stdout of `weedr expose set … tunnel`, and the absence of an
# edge file for a tunnel route. Nothing here needs a Cloudflare account — the
# vendor's policy is the answer, and the answer is what the act must state.
#
# The three claims:
#
#   1. `weedr expose set <name> tunnel` says what protects a tunnel route and
#      what does not, and it says it when the service carries a basic-auth
#      login — the case the ticket names. A service with no login says
#      nothing extra, because there is no credential to have followed.
#
#   2. No rendered artefact implies a middleware on a path that has none: the
#      tunnel's ingress carries no traefik vocabulary, and a tunnel route has
#      no edge file at all.
#
#   3. The credential is the vendor's, and guarden's own instrument for it is
#      `weedr share issue` — the act's words name that command, and the verb's
#      own refusal proves the split: a grant names a tunnel route and refuses
#      an edge one.
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

# The shipped table with the tunnel's one root-owned key set, and the gate
# module's default posture: the basic-auth policy is what mints the login
# this ticket is about, so the gate is installed and the service is created
# after it.
#
# The tracks state `expose = "edge"`, so the DEFAULT is the edge and the
# tunnel is something an operator promotes a service to. That is what makes
# the two terminators distinguishable in this file: a service left alone is
# an edge route, and only the act moves it.
cat >"$GUARDEN_PREFIX/etc/guarden/guarden.toml" <<'TOML'
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
expose = "edge"

[[environments]]
name = "staging"
host_prefix = "staging."
gated = false
weight = 100
free_limit = 0.20
keep_last = 0
kind = "slot"
fork_from = "production"
expose = "edge"

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
assert_not_rejected

# A service created BEFORE the gate module's policy exists is grandfathered: it
# carries no login at all, because the policy is asked at creation time and the
# record is the record (spec 3.4). It is the control for the claim below — a
# service with no credential has no credential that could have failed to
# follow it, so the act must say nothing about one.
oldapp=$GUARDEN_PREFIX/var/lib/guarden/staging/oldapp/9f2c1ab
mkdir -p "$oldapp/.guarden/quadlet"
seed "$oldapp/.guarden/service.yml" "project: oldapp" "units: .guarden/quadlet/" \
    "routes:" "  - container: web" "    port: 80" "    host: old"
seed "$oldapp/.guarden/quadlet/web.container" "[Unit]" "Description=the old container" \
    "[Container]" "Image=docker.io/library/nginx:1.27"
run weedr service ingest oldapp-staging --from poke oldapp@9f2c1ab
assert_exit 0
assert_file_lacks "$GUARDEN_PREFIX/var/lib/guarden/registry/oldapp-staging.toml" "basicauth"

run weedr module add gate-traefik
assert_exit 0
run weedr module add cloudflared
assert_exit 0

# A service created while the gate's policy is in force carries a login of its
# own: this is the service the ticket is about — one that HAS a credential and
# is about to be published on the tunnel.
staged=$GUARDEN_PREFIX/var/lib/guarden/staging/routed/9f2c1ab
mkdir -p "$staged/.guarden/quadlet"
seed "$staged/.guarden/service.yml" "project: routed" "units: .guarden/quadlet/" \
    "routes:" "  - container: web" "    port: 80" "    host: web"
seed "$staged/.guarden/quadlet/web.container" "[Unit]" "Description=the routed container" \
    "[Container]" "Image=docker.io/library/nginx:1.27"
run weedr service ingest routed-staging --from poke routed@9f2c1ab
assert_exit 0

reg=$GUARDEN_PREFIX/var/lib/guarden/registry/routed-staging.toml
slice=$GUARDEN_PREFIX/var/lib/guarden/shared/routed-staging/routes.toml
# The login is there: this is the precondition the whole ticket is about.
assert_file_has "$reg" "basicauth = true"
assert_file_has "$reg" "GUARDEN_BASICAUTH = "
assert_file_exists /etc/guarden/creds/routed-staging/GUARDEN_BASICAUTH.cred
assert_file_exists /var/lib/guarden/edge/basicauth/routed-staging.htpasswd

# --- claim 1: the act says what protects the route and what does not --------
#
# The act that promotes a service to the tunnel is the only place an operator
# decides it, so it is the only place the split between the two terminators can
# be read. Its stdout names BOTH: what protects the route (the vendor's policy,
# and guarden's instrument for it) and what does not (the edge's basic-auth
# login and its forward-auth, both of which are in front of the edge's own
# routes only).
run weedr expose set routed-staging tunnel
assert_exit 0
# The record is written, whatever the act says.
assert_file_has "$reg" 'value = "tunnel"'
# What protects the route: the vendor, and guarden's own verb for it.
assert_stdout_has "weedr share issue"
# What does not: the edge's own middleware, named as the thing that is not in
# this path.
assert_stdout_has "basic auth"
# And the route's own new posture is named, so the line is about THIS service.
assert_stdout_has "routed-staging"
assert_stdout_has "tunnel"

# The line is on stdout, not stderr: stdout is what the act's own report is,
# and a warning on stderr is the program's opinion rather than its answer.
assert_stderr_empty

# The same act, said the same way, twice. An act whose answer depends on how
# many times it has been run is not an answer.
run weedr expose set routed-staging tunnel
assert_exit 0
assert_stdout_has "weedr share issue"
assert_stdout_has "basic auth"

# A service with NO login says nothing about a credential that does not exist:
# the line would be a claim about nothing. The service here was created BEFORE
# the gate module's policy existed, so it is grandfathered and carries no
# login at all.
run weedr expose set oldapp-staging tunnel
assert_exit 0
assert_stdout_lacks "basic auth"

# --- claim 2: no rendered artefact implies a middleware on a path that has -
#
# The tunnel route is rendered into cloudflared's own ingress file, and
# cloudflared has no traefik vocabulary: the file must not carry a middleware
# definition, a basic-auth block or a users file, because there is no traefik
# in that path to read one.
#
# The slice is the NEXT RENDER's (ticket 294), so the route reaches the tunnel
# at the next render and not at the act. The re-ingest is that render.
echo "# promoted" >>"$staged/.guarden/quadlet/web.container"
run weedr service ingest routed-staging --from poke routed@9f2c1ab
assert_exit 0
[ "$(sed -n 's/^destination = "\(.*\)"$/\1/p' "$slice" | head -n 1)" = "tunnel" ] \
    || _fail "the slice's destination did not follow the record"

run runuser -u guarden -- /usr/lib/guarden/bin/roots sync
assert_exit 0
tunnel=$GUARDEN_PREFIX/var/lib/guarden/tunnel/config.yml
assert_file_exists "$tunnel"
assert_file_lacks "$tunnel" "middlewares"
assert_file_lacks "$tunnel" "basicAuth"
assert_file_lacks "$tunnel" "usersFile"
assert_file_lacks "$tunnel" "forward-auth"

# And a tunnel route has NO edge file: the edge is not a route that declines
# to serve, it is a different terminator. A file that existed here would be a
# route served by traefik with no middleware on it — the exact impression this
# ticket exists to remove.
assert_file_missing "$GUARDEN_PREFIX/var/lib/guarden/edge/dynamic/routed-staging.yml"

# The EDGE half is untouched by the promotion: another service, left on the
# edge, still gets its login in front of its route. This is the case the
# ticket's decision does NOT touch, and a change that moved the login would
# break it.
edgeapp=$GUARDEN_PREFIX/var/lib/guarden/staging/edgeapp/9f2c1ab
mkdir -p "$edgeapp/.guarden/quadlet"
seed "$edgeapp/.guarden/service.yml" "project: edgeapp" "units: .guarden/quadlet/" \
    "routes:" "  - container: web" "    port: 80" "    host: edge"
seed "$edgeapp/.guarden/quadlet/web.container" "[Unit]" "Description=the edge container" \
    "[Container]" "Image=docker.io/library/nginx:1.27"
run weedr service ingest edgeapp-staging --from poke edgeapp@9f2c1ab
assert_exit 0
assert_file_has "$GUARDEN_PREFIX/var/lib/guarden/registry/edgeapp-staging.toml" "basicauth = true"
run runuser -u guarden -- /usr/lib/guarden/bin/roots sync
assert_exit 0
rendered=$GUARDEN_PREFIX/var/lib/guarden/edge/dynamic/edgeapp-staging.yml
assert_file_exists "$rendered"
assert_file_has "$rendered" "basicAuth:"
assert_file_has "$rendered" 'usersFile: "/etc/guarden/basicauth/edgeapp-staging.htpasswd"'

# And the promoted service's OWN edge file does not exist, while the edge
# half of another service does: the difference is the destination, not the
# service.
assert_file_missing "$GUARDEN_PREFIX/var/lib/guarden/edge/dynamic/routed-staging.yml"

# --- claim 3: the credential is the vendor's, and guarden names its own -----
#
# `weedr share issue` is guarden's instrument for the vendor's policy, and it
# refuses a route the tunnel does not carry — so a tunnel route is exactly the
# route a grant may name. The act's words name that verb, and the verb's own
# refusal proves the route is the tunnel's.
run weedr share issue routed-staging alice@example.com --until 1h
assert_exit 0
assert_stdout_has "routed-staging"
run weedr share list
assert_exit 0
assert_stdout_has "routed-staging"

# A route that is NOT on the tunnel is refused by the grant — which is the
# vendor-side half of the split, measured: the edge's route is the edge's and
# the tunnel's route is the tunnel's, and no grant crosses them.
run weedr share issue edgeapp-staging alice@example.com --until 1h
assert_exit 2
assert_stderr_has "edge"

# The grant is a record of guarden's own, and it is time-bounded: the design
# says a grant that cannot be time-bounded is a grant whose expiry is
# somebody's memory. The record is what the vendor's policy is projected from.
run weedr share list --json
assert_exit 0
assert_json issuances.0.service '"routed-staging"'
assert_json issuances.0.state '"live"'

# --- the demotion says nothing, because nothing was lost -------------------
#
# The line is about a credential that does not travel. Unsetting the record
# returns the service to the edge's path, where the login is in front of it
# again — so there is nothing to warn about and the act's answer is the plain
# one.
run weedr expose unset routed-staging
assert_exit 0
assert_stdout_lacks "basic auth"
