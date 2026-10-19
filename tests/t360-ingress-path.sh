#!/usr/bin/env bash
# ticket 264: a preview ref rendered into cloudflared's ingress `path:` — the
# path is a regex matched first-match-wins with the `http_status:404` catch-all
# last, so an unquoted ref (`.` is a metacharacter that `systemd_escape` passes
# through raw) and an unanchored one (`/abc` matching `/abcd`) let one preview
# capture another's traffic. The template's scalar is double-quoted YAML, and
# `\x2d` is an escape that decodes in transit, undoing the escaping the ref
# validation depends on (ticket 264, spec 5.2, 6.4).
#
# Real host, real uids: `GUARDEN_PREFIX=/` and the machine's own tools, as
# `t50-route` and `t220-tendril` do. What is asserted is state — the rendered
# tunnel ingress, parsed back as the YAML `cloudflared` will parse it — and
# never a record of what a program said it was about to do.
#
# The ref-bearing route slice is written into `shared/<service>/routes.toml`,
# the one directory `roots.slices()` reads, because that is the input
# `roots.render_tunnel` codes against: spec 5.2 says the ref arrives raw and
# the escaping is internal. Reaching an instance's own slice from there is the
# ticket's follow-on — a walk and an ADR — and this suite's subject is how the
# path renders, not the walk, so the input is stated directly rather than
# depending on it.
#
# machine: fresh

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GUARDEN_PREFIX=/

ensure_accounts

# The shipped table with the tunnel's one root-owned key set. `tunnel_domain`
# is in `[ingress]` and no repository can write it, and it is what puts a
# preview hostname on the tunnel.
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

[[environments]]
name = "staging"
host_prefix = "staging."
gated = false
weight = 100
free_limit = 0.20
keep_last = 0
kind = "slot"
fork_from = "production"
expose = "tunnel"

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

# Three previews of one service in the slice `roots` reads, each ref chosen for
# the hole it exercises: `.` is the bare metacharacter, `abc` is the prefix an
# unanchored path would match `/abcd` with, `feature-x` carries `\x2d` through
# `systemd_escape` and is the byte a double-quoted YAML scalar decodes back to
# `-`. The routes are tunnel routes, which is what puts them on the tunnel.
slice=$GUARDEN_PREFIX/var/lib/guarden/shared/routed-preview/routes.toml
seed "$slice" \
    'service = "routed-preview"' \
    'project = "routed"' \
    'track = "preview"' \
    '' \
    '[[routes]]' \
    'container = "web"' \
    'port = 8080' \
    'publication = 32001' \
    'host = "dot.tunnel.example.net"' \
    'label = "dot"' \
    'auth = false' \
    'target = "routed-preview:32001"' \
    'destination = "tunnel"' \
    'ref = "."' \
    '' \
    '[[routes]]' \
    'container = "web"' \
    'port = 8080' \
    'publication = 32002' \
    'host = "abc.tunnel.example.net"' \
    'label = "abc"' \
    'auth = false' \
    'target = "routed-preview:32002"' \
    'destination = "tunnel"' \
    'ref = "abc"' \
    '' \
    '[[routes]]' \
    'container = "web"' \
    'port = 8080' \
    'publication = 32003' \
    'host = "fx.tunnel.example.net"' \
    'label = "fx"' \
    'auth = false' \
    'target = "routed-preview:32003"' \
    'destination = "tunnel"' \
    'ref = "feature-x"'

# The render under test, driven from the working tree: the failure being
# hunted is in `roots`, and `run` executes the checkout's own module precisely
# so a stale installed copy cannot answer for it.
run roots sync
assert_exit 0

tunnel=$GUARDEN_PREFIX/var/lib/guarden/tunnel/config.yml
assert_file_exists "$tunnel"
assert_file_has "$tunnel" "ingress:"
# One path rule per preview, and the ticket's hole is measured in them.
[ "$(grep -c 'path:' "$tunnel")" = 3 ] \
    || _fail "expected one ingress path per preview, found $(grep -c 'path:' "$tunnel")"

# The assertions live in the .py beside this file: the path is a regex, and
# whether one preview captures another's traffic is asked with the engine the
# pattern is written for, against the file re-read as YAML.
run python3 "$GUARDEN_ROOT/tests/t360-ingress-path.py" "$tunnel"
assert_exit 0
assert_stdout_empty
assert_stderr_empty
