#!/usr/bin/env bash
# The auth-authelia module and the one root-owned file that connects it to roots
# (ticket 150, spec 3.6, 6.4).
#
# Real host, real uids, real `useradd`: `GUARDEN_PREFIX=/` and the machine's own
# tools, as `t50-module` and `t50-route` do. What is asserted is state — a file's
# mode and owner, what a rendered edge file says, what a sync refuses — and never
# a record of what a program said it was about to do.
#
# Every negated assertion below is an `if …; then … fi` and never `grep -q …
# && _fail`: `tests/lib.sh` runs `set -euo pipefail`, and a `&&` chain on a grep
# that finds nothing ends the suite silently at that line with no report at all.
#
# machine: fresh

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GUARDEN_PREFIX=/

getent group guarden >/dev/null 2>&1 || groupadd --system guarden
id -u guarden >/dev/null 2>&1 || useradd --system --no-create-home --gid guarden guarden
id -u operator >/dev/null 2>&1 || {
    getent group operator >/dev/null 2>&1 || groupadd --system operator
    useradd --system --no-create-home --gid operator --shell /usr/sbin/nologin operator
}
mkdir -p /etc/guarden
stage_config guarden-nomodules.toml
run soil install --apply
assert_not_rejected

# The module ships, and it declares one service and the program it switches on.
assert_file_exists /usr/lib/guarden/modules/auth-authelia/module.toml
assert_file_exists /usr/lib/guarden/modules/auth-authelia/authelia-production/.guarden/service.yml
assert_file_exists /usr/lib/guarden/modules/auth-authelia/authelia-production/.guarden/quadlet/authelia.container
assert_file_has /usr/lib/guarden/modules/auth-authelia/module.toml 'program = "roots"'
# **No new program and no code.** `roots` is the only program a module may
# switch on that writes the edge's routes, and the whole connection between the
# module and the middleware is the one marker file below: no plugin interface,
# no per-module code path, and nothing in the module's own tree but declarations
# and a shipped service.
run weedr module list --json
assert_exit 0
assert_json available.0 '"auth-authelia"'
assert_json enabled '[]'

# --- claim 1: the marker is root-owned 0640 and written once -----------------
#
# Nothing has written it yet: the module ships but is not enabled, and a module
# that is not installed has no provider.
assert_file_missing /etc/guarden/edge/auth-provider

run weedr module add gate-traefik
assert_exit 0
run weedr module add auth-authelia
assert_exit 0
marker=/etc/guarden/edge/auth-provider
assert_file_exists "$marker"
assert_mode "$marker" 0640
assert_owner "$marker" "root:guarden"
# It names the auth service **by its service name** — the name the edge resolves
# and the name the registry holds — and nothing else.
[ "$(cat "$marker")" = authelia-production ] \
    || _fail "$marker names '$(cat "$marker")', not the auth service name authelia-production"
assert_passwd authelia-production

# Written **once**: a re-add rewrites nothing, and neither does any other verb.
inode=$(stat -c %i "$marker")
run weedr module add auth-authelia
assert_exit 0
[ "$(stat -c %i "$marker")" = "$inode" ] \
    || _fail "$marker was rewritten by a re-add of the same module"
run weedr module add gate-traefik
assert_exit 0
[ "$(stat -c %i "$marker")" = "$inode" ] \
    || _fail "$marker was rewritten by adding a different module"
run soil firewall --apply
assert_not_rejected
[ "$(stat -c %i "$marker")" = "$inode" ] \
    || _fail "$marker was rewritten by a firewall converge"

# The shared edge directory and the `edge` group are untouched by this ticket:
# the auth-authelia module declares no ingress, so adding it granted nothing.
assert_group edge
assert_supplementary_group traefik-production edge
assert_no_supplementary_group authelia-production edge
assert_no_supplementary_group authelia-production guarden
assert_mode /var/lib/guarden/edge/dynamic 2750
assert_owner /var/lib/guarden/edge/dynamic "guarden:edge"

# --- a route that asks for it ------------------------------------------------
#
# One service with two routes: one declaring `auth: true`, one not. Both go into
# the same rendered file, so the unprotected route in it is the comparison the
# byte-for-byte claim is made against.
staged=$GUARDEN_PREFIX/var/lib/guarden/staging/protected/9f2c1ab
mkdir -p "$staged/.guarden/quadlet"
seed "$staged/.guarden/service.yml" "project: protected" "units: .guarden/quadlet/" \
    "routes:" \
    "  - container: web" "    port: 8080" "    host: web" "    auth: true" \
    "  - container: web" "    port: 8080" "    host: open"
seed "$staged/.guarden/quadlet/web.container" "[Unit]" "Description=protected" \
    "[Container]" "Image=docker.io/library/nginx:1.27"
run weedr service ingest protected-staging --from poke protected@9f2c1ab
assert_exit 0
assert_file_has "$staged/.guarden/service.yml" "auth: true"

roots() {
    run runuser -u guarden -- /usr/lib/guarden/bin/roots sync
}

# --- claim 3 and 4: the middleware on one route, byte-for-byte on the other ---
roots
assert_exit 0
rendered=/var/lib/guarden/edge/dynamic/protected-staging.yml
assert_file_exists "$rendered"
assert_file_has "$rendered" "guarden-forward-auth"
# The middleware is attached to the protected router and **not** to the open
# one. Counted in the file, not on the word anywhere: a router carrying it twice
# and an open router carrying it once would both satisfy "the file has one".
[ "$(grep -c -- '- guarden-forward-auth' "$rendered" || true)" = 1 ] \
    || _fail "$rendered does not carry the middleware exactly once"
# Which router carries it is a structural question, so it is asked structurally:
# the open router's block is read out of the parsed document, where a substring
# can pass on the wrong rule or fail on a correct one.
run python3 -c "import sys,yaml; r=yaml.safe_load(open(sys.argv[1]))['http']['routers']; \
p=r['protected-staging-web']; o=r['protected-staging-open']; \
assert p.get('middlewares')==['guarden-forward-auth'], p; \
assert 'middlewares' not in o, o" "$rendered"
assert_exit 0
# The definition is aimed at the provider's own name and publication, so the
# edge resolves it through its AddHost entry rather than dialling the host's own
# loopback — which a container does not share.
auth_file=/var/lib/guarden/edge/dynamic/_guarden-forward-auth.yml
assert_file_exists "$auth_file"
provider_publication=$(sed -n 's/^authelia = \([0-9]*\)$/\1/p' \
    /var/lib/guarden/registry/authelia-production.toml)
[ -n "$provider_publication" ] \
    || _fail "the auth provider holds no publication, so nothing can be aimed at it"
assert_file_has "$auth_file" "address: \"http://authelia-production:$provider_publication\""
assert_file_lacks "$auth_file" "127.0.0.1"

# **Claim 4, asserted by diffing the rendered file and not by a substring.**
# With the module installed and then not installed, the two rendered files are
# compared line for line, and the ONLY differences permitted are the two lines
# the protected router gained. Everything else — the open router, both load
# balancers, every key order — must be byte identical, so "renders exactly what
# it rendered before" is a claim about the file and not about a token in it.
cp "$rendered" "$GUARDEN_FIXTURES/with-auth.yml"

# --- claim 6: the module not installed is a warning, not a failure ----------
sed -i 's/^enabled = \[.*\]$/enabled = ["gate-traefik"]/' /etc/guarden/guarden.toml
rm -f /var/lib/guarden/edge/dynamic/_guarden-forward-auth.yml
roots
assert_exit 0
assert_file_exists "$rendered"
[ "$(grep -c -- '- guarden-forward-auth' "$rendered" || true)" = 0 ] \
    || _fail "$rendered still carries the middleware with the auth-authelia module not installed"
assert_file_missing "$auth_file"
# Read the warnings NOW. `run diff` below overwrites both capture files, so a
# check placed after it would read diff's empty stderr and see nothing.
cp "$GUARDEN_STDERR" "$GUARDEN_FIXTURES/roots-warning.txt"
# The whole of the difference, and nothing else: exactly two lines gone, both of
# them the protected router's middleware, and not one line added. The line
# numbers are not asserted — they move with the template's own comment block —
# but the CONTENT of the diff is, and it is small enough to state exactly.
run diff "$GUARDEN_FIXTURES/with-auth.yml" "$rendered"
assert_exit 1
[ "$(grep -c '^> ' "$GUARDEN_STDOUT" || true)" = 0 ] \
    || _fail "removing the module ADDED lines to the rendered file:
$GUARDEN_STDOUT"
[ "$(grep -vE '^(<|[0-9])' "$GUARDEN_STDOUT" || true)" = "" ] \
    || _fail "the diff carries output that is neither a deletion nor a line number:
$GUARDEN_STDOUT"
[ "$(grep '^< ' "$GUARDEN_STDOUT" || true)" = "<       middlewares:
<         - guarden-forward-auth" ] \
    || _fail "the two renders differ by more than the protected router's middleware:
$GUARDEN_STDOUT"
# ... and one warning per route that asked for it, on this sync. TWO, not one:
# the auth-authelia module's own service declares `auth: true` on purpose, so it is warned
# about too. A count of one would have meant the provider's own route was skipped,
# which is the case this suite exists to keep honest.
[ "$(grep -c '^warning: ' "$GUARDEN_FIXTURES/roots-warning.txt" || true)" = 2 ] \
    || _fail "expected one warning per auth route, got: $(cat "$GUARDEN_FIXTURES/roots-warning.txt")"
grep -q "protected-staging" "$GUARDEN_FIXTURES/roots-warning.txt" \
    || _fail "no warning names protected-staging"
grep -q "protected-staging-web" "$GUARDEN_FIXTURES/roots-warning.txt" \
    || _fail "no warning names the protected route"
# The warning repeats rather than being a once-ever event somebody missed.
cp "$GUARDEN_STDERR" "$GUARDEN_FIXTURES/warning-once.txt"
roots
assert_exit 0
[ "$(grep -c '^warning: ' "$GUARDEN_STDERR" || true)" = 2 ] \
    || _fail "the warning did not repeat"
run cmp -s "$GUARDEN_STDERR" "$GUARDEN_FIXTURES/warning-once.txt"
assert_exit 0

# A service with no `auth:` at all adds no line: the warning is about the route
# that asked for it, and warning about every route would be noise nobody reads.
plain=$GUARDEN_PREFIX/var/lib/guarden/staging/plain/9f2c1ab
mkdir -p "$plain/.guarden/quadlet"
seed "$plain/.guarden/service.yml" "project: plain" "units: .guarden/quadlet/" \
    "routes:" "  - container: web" "    port: 8080" "    host: plain"
seed "$plain/.guarden/quadlet/web.container" "[Unit]" "Description=plain" \
    "[Container]" "Image=docker.io/library/nginx:1.27"
run weedr service ingest plain-staging --from poke plain@9f2c1ab
assert_exit 0
roots
assert_exit 0
[ "$(grep -c '^warning: ' "$GUARDEN_STDERR" || true)" = 2 ] \
    || _fail "expected one warning per auth route, got: $(cat "$GUARDEN_STDERR")"
assert_stderr_has "protected-staging"
assert_stderr_lacks "plain-staging"
assert_file_exists /var/lib/guarden/edge/dynamic/plain-staging.yml
[ "$(grep -c -- '- guarden-forward-auth' /var/lib/guarden/edge/dynamic/plain-staging.yml || true)" = 0 ] \
    || _fail "a route declaring no auth carries a middleware"

# --- claim 2: the marker is validated on EVERY sync, fail-closed ------------
#
# Back on, with a marker that cannot be right. Each case is exit 1 **and no
# configuration written**: the file the edge is reading must still be the one
# that worked, byte for byte, which is what "the routes that were working keep
# working" means on a machine.
run weedr module add auth-authelia
assert_exit 0
roots
assert_exit 0
cp "$rendered" "$GUARDEN_FIXTURES/converged.yml"
cp "$auth_file" "$GUARDEN_FIXTURES/converged-auth.yml"

# (a) the marker names a service that does not exist.
say "$marker" "nosuchservice-production"
roots
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "nosuchservice-production"
run cmp -s "$rendered" "$GUARDEN_FIXTURES/converged.yml"
assert_exit 0
run cmp -s "$auth_file" "$GUARDEN_FIXTURES/converged-auth.yml"
assert_exit 0

# (b) the marker names a service that exists and is **not** in a gated track.
# `staging` is gated = false in the shipped table and `protected-staging` is in
# it, so this is a real service in a real ungated track rather than a name.
say "$marker" "protected-staging"
roots
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "protected-staging"
assert_stderr_has "staging"
run cmp -s "$rendered" "$GUARDEN_FIXTURES/converged.yml"
assert_exit 0
run cmp -s "$auth_file" "$GUARDEN_FIXTURES/converged-auth.yml"
assert_exit 0

# (c) the marker is not a service name at all.
say "$marker" "not a name/../etc"
roots
assert_exit 1
assert_one_diagnostic "error:"
run cmp -s "$rendered" "$GUARDEN_FIXTURES/converged.yml"
assert_exit 0

# (d) the marker names a service whose environment is no track on this host.
# `weedr service ingest` resolves a service name against the table before a
# registry entry exists, so this one is seeded as the registry record `roots`
# reads rather than created through the mutator — and a registry whose
# environment names no track is a host fact, not an input `weedr` could be
# asked to make.
seed /var/lib/guarden/registry/auth-nosuchtrack.toml \
    'service = "auth-nosuchtrack"' 'workload = "auth"' 'project = "auth"' \
    'environment = "nosuchtrack"' 'uid = 0' 'created = "2026-01-01T00:00:00Z"'
say "$marker" "auth-nosuchtrack"
roots
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "nosuchtrack"
run cmp -s "$rendered" "$GUARDEN_FIXTURES/converged.yml"
assert_exit 0

# --- claim 5: the provider's own route never carries the rule --------------
#
# The shipped manifest already declares `auth: true` on the provider's own
# route, and `weedr module add auth-authelia` rendered that slice with it. So this needs
# no staging and no re-render: the assertion is made against a slice that really
# declares the rule, which is the only form of it that is not vacuous — a test
# that removed `auth: true` first would pass on a renderer that had no opinion.
seed "$marker" "authelia-production"
provider_slice=/var/lib/guarden/shared/authelia-production/routes.toml
assert_file_has "$provider_slice" "auth = true"
roots
assert_exit 0
own=/var/lib/guarden/edge/dynamic/authelia-production.yml
assert_file_exists "$own"
[ "$(grep -c -- '- guarden-forward-auth' "$own" || true)" = 0 ] \
    || _fail "the auth service's own route carries the middleware, and the operator cannot sign in"
run python3 -c "import sys,yaml; r=yaml.safe_load(open(sys.argv[1]))['http']['routers']; \
assert 'middlewares' not in r['authelia-production-authelia'], r" "$own"
assert_exit 0
# The middleware is still defined and still aimed at the provider: the rule is
# absent from one router, not from the edge.
assert_file_has "$auth_file" "guarden-forward-auth"
assert_file_has "$auth_file" "address: \"http://authelia-production:$provider_publication\""
# And the protected route in the other service still has it, in the same sync.
assert_file_has "$rendered" "- guarden-forward-auth"

# --- re-running with nothing changed writes nothing ------------------------
#
# The file's **contents** are unchanged, which is the property the edge's watch
# turns into "no reload". The inode is deliberately not asserted: `conf.write_file`
# is spec 3.5's temp-and-rename protocol, so a converging sync legitimately
# replaces the file with identical bytes, and a test demanding a stable inode
# would be asking for the protocol to be abandoned.
cp "$rendered" "$GUARDEN_FIXTURES/before-quiet-sync.yml"
cp "$auth_file" "$GUARDEN_FIXTURES/before-quiet-auth.yml"
listing_before=$(cd /var/lib/guarden/edge/dynamic && ls -1 | sort)
roots
assert_exit 0
run cmp -s "$rendered" "$GUARDEN_FIXTURES/before-quiet-sync.yml"
assert_exit 0
run cmp -s "$auth_file" "$GUARDEN_FIXTURES/before-quiet-auth.yml"
assert_exit 0
run ls -1 /var/lib/guarden/edge/dynamic
assert_exit 0
[ "$(printf '%s\n' "$listing_before")" = "$(sort <"$GUARDEN_STDOUT")" ] \
    || _fail "a sync with nothing changed added or removed a file"
# Nothing on stdout about anything but the routes it rendered, and nothing on
# stderr: with the marker valid there is no warning to repeat.
assert_stderr_empty

# The rendered file is parseable YAML carrying the shape the edge needs, read
# through the parser rather than grepped, so a token in a comment cannot satisfy
# it. `python3 -c` over the rendered file reads the program's output; it imports
# no guarden module and executes no repo code.
run python3 -c "import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); \
r=d['http']['routers']; assert r['protected-staging-web']['middlewares']==['guarden-forward-auth'], r" \
    "$rendered"
assert_exit 0
run python3 -c "import sys,yaml; m=yaml.safe_load(open(sys.argv[1]))['http']['middlewares'] \
['guarden-forward-auth']['forwardAuth']; \
assert m['address']=='http://authelia-production:$provider_publication', m; \
assert m['trustForwardHeader'] is True, m" "$auth_file"
assert_exit 0