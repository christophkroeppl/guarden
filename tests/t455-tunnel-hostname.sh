#!/usr/bin/env bash
# t455-tunnel-hostname.sh — ticket 324: a tunnel route's published name is a
# name IN THE TUNNEL'S ZONE, and it is the mutator that allocates it.
#
# The defect this file measures: `roots.render_tunnel` publishes a route at the
# name the mutator allocated, and `publications.claim_host` returns
# `<host_prefix><label>` with NO domain appended at all. So a production
# service whose route label is `web` and whose track prefix is empty was
# published at the bare line `hostname: "web"` — a name in no zone whatsoever,
# which no DNS can answer. The service is fail-closed (no edge file, no edge
# accept) AND unreachable, and nothing says so.
#
# The zone the tunnel actually serves is `[ingress] tunnel_domain`, and until
# this change it was used for previews only.
#
# **The mutator allocates the qualified name, and the record holds it.** The
# record is the authority (spec 3.4), and it is what `roots` renders, what
# `weedr share issue` grants a customer access to, what `weedr service list`
# reports and what `twig` links to. A name that existed only at render time
# would be a second place to be wrong, and a grant would name a hostname the
# tunnel does not serve.
#
# What is asserted is STATE: the registry's `[route_hosts]`, the rendered
# tunnel ingress file read back as YAML, and the grant's own record. Never a
# record of what a program said it was about to do.
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

# The shipped table with the tunnel's zone set, so the tunnel is configured
# (`weedr module add cloudflared` refuses without it) and the module set makes
# the DERIVED default resolve to `tunnel` — which is the posture under test.
#
# `[ingress] tunnel_domain` is root-owned and no repository can write it, and
# it is the zone the tunnel serves.
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
assert_not_rejected
run weedr module add cloudflared
assert_exit 0
run weedr module add gate-traefik
assert_exit 0

registry=/var/lib/guarden/registry
tunnel=/var/lib/guarden/tunnel/config.yml

# --- a production service behind the tunnel ---------------------------------
#
# The derived default is the tunnel, because the cloudflared module is
# installed and the track states no `expose` of its own (ticket 293).
stage_poke routed 9f2c1ab
run weedr service ingest routed-production --from poke routed@9f2c1ab
assert_exit 0

prodreg=$registry/routed-production.toml
assert_file_exists "$prodreg"

# **The record carries the name in the tunnel's zone.** Read with a TOML
# parser rather than with `sed`: the registry writes a table of label -> name,
# and the assertion is about the VALUE under the `web` key.
run python3 "$GUARDEN_ROOT/tests/registryhost.py" "$prodreg" web
assert_exit 0
prodhost=$(cat "$GUARDEN_STDOUT")
[ "$prodhost" = "web.tunnel.example.net" ] \
    || _fail "the production service claims the route host ${prodhost:-none}, expected web.tunnel.example.net"

# And the name is in the TUNNEL's zone, not the host's own: the two zones are
# different and the tunnel serves its own. Asserted against the zone the
# configuration names rather than against a literal, so a host with another
# zone is measured against its own.
[ "$prodhost" != "web.example.com" ] \
    || _fail "the tunnel route claims the host's own zone (web.example.com), not the tunnel's"

# --- the tunnel ingress file carries that name, asserted in full -----------
run runuser -u guarden -- /usr/lib/guarden/bin/roots sync
assert_exit 0
assert_file_exists "$tunnel"

# **A WHOLE LINE, not a substring.** The bare label `web` is a substring of
# `web.tunnel.example.net`, so a substring assertion would pass on the defect
# this file exists to catch — and on the fix. The whole line is matched, so
# the value is measured exactly and a name that is not in a zone cannot pass.
run grep -qxF '  - hostname: "web.tunnel.example.net"' "$tunnel"
assert_exit 0
# And the bare label is NOT what is published: the line that carried it is
# gone, which is the half a whole-line match alone does not prove.
assert_file_lacks "$tunnel" 'hostname: "web"'

# The row is the tunnel's and the tunnel's alone: a tunnel route is not
# rendered into the edge's directory (ticket 220), so the edge never answers
# this name.
assert_file_missing /var/lib/guarden/edge/dynamic/routed-production.yml

# The name is read back as the YAML cloudflared will parse it, and it is the
# name in the ingress list — not a line that happens to contain it.
run python3 "$GUARDEN_ROOT/tests/t455-tunnel-hostname.py" "$tunnel" "web.tunnel.example.net"
assert_exit 0
assert_stdout_empty
assert_stderr_empty

# --- a staging service takes the track's prefix with it ---------------------
#
# The prefix is the track's own and it is not a zone: the name is
# `<prefix><label>` inside the tunnel's zone, so a staging service is
# `staging.web.tunnel.example.net` and not `staging.web` and not
# `web.tunnel.example.net`.
run weedr service ingest routed-staging --from poke routed@9f2c1ab
assert_exit 0
run python3 "$GUARDEN_ROOT/tests/registryhost.py" "$registry/routed-staging.toml" web
assert_exit 0
stagehost=$(cat "$GUARDEN_STDOUT")
[ "$stagehost" = "staging.web.tunnel.example.net" ] \
    || _fail "the staging service claims the route host ${stagehost:-none}, expected staging.web.tunnel.example.net"

# --- a grant names the name the tunnel serves --------------------------------
#
# `weedr share issue` writes a Cloudflare Access policy keyed on the route's
# recorded name. A grant that named the bare label would grant access to a
# hostname the tunnel does not answer, and the customer would be refused for
# a reason nobody can see.
run weedr share issue routed-production alice@example.com --until 2d
assert_exit 0
first=$(sed -n 's/^issued \([0-9a-f]*\) .*/\1/p' "$GUARDEN_STDOUT")
[ -n "$first" ] || _fail "the issue printed no id"
assert_file_has "/var/lib/guarden/share/$first.toml" 'hosts = ["web.tunnel.example.net"]'

# --- a preview keeps the ONE shared host -------------------------------------
#
# Every preview of every project shares one host and the ref is a path on it
# (spec 9), so an instance is not given a name of its own: the mutator leaves
# the instance's route alone and the tunnel publishes the shared host. This is
# asserted because a "qualify every tunnel name" rule applied to an instance
# would give every preview a hostname of its own and undo spec 9.
run weedr service ingest routed-preview/alpha --from poke routed@9f2c1ab
assert_exit 0
run python3 "$GUARDEN_ROOT/tests/registryhost.py" "$registry/routed-preview.toml" web
assert_exit 0
previewhost=$(cat "$GUARDEN_STDOUT")
[ "$previewhost" = "preview.web" ] \
    || _fail "the preview service claims the route host ${previewhost:-none}, expected preview.web"

# The preview's own slice carries the ref, so the tunnel's ingress holds a
# path rule on the shared host and not a hostname of the instance's own —
# neither a qualified one (which would give every preview its own host) nor the
# recorded `preview.web` (a name in no zone, first-match-wins above the path).
run runuser -u guarden -- /usr/lib/guarden/bin/roots sync
assert_exit 0
assert_file_has "$tunnel" 'hostname: "preview.tunnel.example.net"'
assert_file_lacks "$tunnel" "preview.web.tunnel.example.net"
assert_file_lacks "$tunnel" 'hostname: "preview.web"'

# --- an empty tunnel domain is refused, and it says why ----------------------
#
# A route whose destination is the tunnel and no zone to name it in is a
# hostname no DNS can answer — the defect this file is about. So the host says
# so rather than allocating a name in no zone. The service is not created, so
# nothing half-configured is left behind: no system user, no home, no registry
# entry. The source is seeded here as a second project whose route label is
# `api`, so the refusal cannot be confused with a name already claimed.
other=/var/lib/guarden/staging/other/9f2c1ab
mkdir -p "$other/.guarden/quadlet"
seed "$other/.guarden/service.yml" "project: other" "units: .guarden/quadlet/" \
    "routes:" "  - container: web" "    port: 8080" "    host: api"
seed "$other/.guarden/quadlet/web.container" "[Container]" \
    "Image=docker.io/library/nginx:1.27"
sed -i '/^tunnel_domain = "tunnel.example.net"$/s/.*/tunnel_domain = ""/' \
    "$GUARDEN_PREFIX/etc/guarden/guarden.toml"
run weedr service ingest other-production --from poke other@9f2c1ab
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "tunnel_domain"
assert_file_missing "$registry/other-production.toml"
assert_no_passwd other-production
