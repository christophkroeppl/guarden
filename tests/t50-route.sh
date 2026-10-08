#!/usr/bin/env bash
# The first vertical slice: a manifest with a `routes:` section becomes a
# publication, a host name the edge answers, an accept rule that lets the edge
# dial it, and an `AddHost=` entry in the edge's own units (ticket 50, spec 4,
# 7.3, 7.4, 7.6).
#
# Real host, real uids, real `useradd`: `GUARDEN_PREFIX=/` and the machine's own
# tools, as `t30-create` and `t60-gate` do. What is asserted is state — a
# registry number, a rendered file, a uid-matched rule — and never a record of
# what a program said it was about to do.
#
# The request itself is the golden VM's: a manifest in and an HTTP request out
# needs a container image and a network, which is `t50-slice.sh`.
#
# machine: fresh

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GUARDEN_PREFIX=/

# The host configuration below names `operator` as `host.admin_user`, and the
# firewall renders the edge's API accept set with that account's uid. On a real
# host `soil install` records the invoking user, so the account is the fixture's
# own claim and it has to exist for the answer to be about the design rather
# than about a name nothing holds.
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
run weedr module add gate
assert_exit 0

edge_uid=$(getent passwd traefik-production | cut -d: -f3)
edge_unit=/var/lib/guarden/services/traefik-production/home/.config/containers/systemd/traefik.container

# A poke's staged tree, where guarden itself puts it, and a service with one
# route. `staging` because its `host_prefix` is `staging.`, which is where the
# host name in the rendered route comes from and a repository does not.
staged=$GUARDEN_PREFIX/var/lib/guarden/staging/routed/9f2c1ab
mkdir -p "$staged"
cp -r "$GUARDEN_ROOT/fixtures/projects/routed/." "$staged/"

run weedr service ingest routed-staging --from poke routed@9f2c1ab
assert_exit 0
registry=$GUARDEN_PREFIX/var/lib/guarden/registry/routed-staging.toml
routed_uid=$(getent passwd routed-staging | cut -d: -f3)

# The publication is allocated from the range and recorded, and the host name is
# the track's prefix with the manifest's label behind it.
publication=$(sed -n 's/^web = \([0-9]*\)$/\1/p' "$registry")
[ -n "$publication" ] || _fail "routes: names a container and no publication was allocated"
[ "$publication" -ge 20000 ] && [ "$publication" -le 32767 ] \
    || _fail "publication $publication is outside ingress.publication_range"
assert_file_has "$registry" 'web = "staging.web"'

# The route target is `<service>:<publication>` — the service's own name, no
# suffix, no alias and no loopback address, because the edge is a container and
# the host's loopback is not its own.
slice=$GUARDEN_PREFIX/var/lib/guarden/shared/routed-staging/routes.toml
assert_file_exists "$slice"
assert_file_has "$slice" "target = \"routed-staging:$publication\""
assert_file_has "$slice" 'host = "staging.web"'
assert_file_lacks "$slice" "127.0.0.1"
assert_file_lacks "$slice" "192.0.2.1"

# The edge resolves that name through an `AddHost=` entry in **its own** units.
# Without it the edge cannot resolve its own configuration and every route 502s,
# which is why this is in the edge's units and not in the routed service's.
assert_file_has "$edge_unit" "AddHost=routed-staging:192.0.2.1"

# The edge is allowed to dial the publication, by uid, and nobody else is: the
# owner, the edge, and the declared consumers — and this service declared none.
services=/etc/guarden/firewall/50-services.conf
assert_file_has "$services" \
    "mod owner uid-owner $edge_uid daddr 127.0.0.1 proto tcp dport $publication jump ACCEPT;"
assert_file_has "$services" \
    "mod owner uid-owner $routed_uid daddr 127.0.0.1 proto tcp dport $publication jump ACCEPT;"
# One rule per uid on this publication, so nothing else reaches it.
# Anchored on the whole match: a bare dport would count another publication's rule.
[ "$(grep -vE '^[[:space:]]*(#|$)' "$services" \
    | grep -cE "^[[:space:]]+mod owner uid-owner [0-9]+ daddr 127\.0\.0\.1 proto tcp dport $publication jump ACCEPT;\$" || true)" = 2 ] \
    || _fail "the route publication's accept set is not the owner and the edge and nobody else"

# `roots sync` turns the installed slices into the edge's file-provider
# configuration, in the one directory it may write. The installed path, not
# `PATH`: a venv on the suite's `PATH` would otherwise answer for the program
# the suite means to exercise.
run runuser -u guarden -- /usr/lib/guarden/bin/roots sync
assert_exit 0
rendered=/var/lib/guarden/edge/dynamic/routed-staging.yml
assert_file_exists "$rendered"
assert_file_has "$rendered" 'Host(`staging.web`)'
assert_file_has "$rendered" "url: \"http://routed-staging:$publication\""
# Routers attach to the entrypoint that serves, never to the redirect and never
# to the API. `grep -c` exits 1 on no match, so the count is read rather than the
# exit code asserted.
assert_file_has "$rendered" "entryPoints:"
assert_file_has "$rendered" "- websecure"
[ "$(grep -c -- '        - web$' "$rendered" || true)" = 0 ] \
    || _fail "a router was attached to the redirect entrypoint"
[ "$(grep -c -- '        - api$' "$rendered" || true)" = 0 ] \
    || _fail "a router was attached to the edge's API entrypoint"

# A service with no routes produces no file and no error: the edge already has
# one of its own (traefik-production, whose slice declares none) and a sync that
# failed on that would fail on every host.
assert_file_missing /var/lib/guarden/edge/dynamic/traefik-production.yml
run runuser -u guarden -- /usr/lib/guarden/bin/roots sync
assert_exit 0

# A route change appears without restarting the edge, and the property that
# makes it so is that the file the edge reads is *derived*: a sync that finds
# the same slice writes the same bytes, so nothing is reloaded for nothing, and
# a changed slice is one file changing. The deploy path that changes a slice is
# ticket 120's; what is asserted here is that `roots` is a function of the
# installed tree and writes one file per service.
cp "$rendered" "$GUARDEN_FIXTURES/first-sync.yml"
run runuser -u guarden -- /usr/lib/guarden/bin/roots sync
assert_exit 0
run cmp -s "$rendered" "$GUARDEN_FIXTURES/first-sync.yml"
assert_exit 0
run ls /var/lib/guarden/edge/dynamic
assert_exit 0
assert_stdout_has "routed-staging.yml"
assert_stdout_lacks "traefik-production.yml"

# The publication did not move: it is persisted, and a second creation of a
# converged service must not renumber a port a rendered rule already names.
run weedr service ingest routed-staging --from poke routed@9f2c1ab
assert_exit 0
assert_stdout_has "converged"
assert_file_has "$registry" "web = $publication"

# A second claimant of the same host name is refused, with the holder named.
# Two services on one track claiming one name is undefined, and the allocator
# refuses the second rather than letting the edge answer for whichever loaded
# last. The holder is named because "the host is out of state" with no holder
# is a question an operator cannot act on.
other=$GUARDEN_PREFIX/var/lib/guarden/staging/other/9f2c1ab
mkdir -p "$other/.guarden/quadlet"
seed "$other/.guarden/service.yml" "project: other" "units: .guarden/quadlet/" \
    "routes:" "  - container: web" "    port: 8080" "    host: web"
seed "$other/.guarden/quadlet/web.container" "[Container]" \
    "Image=docker.io/library/nginx:1.27"
run weedr service ingest other-staging --from poke other@9f2c1ab
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "staging.web"
assert_stderr_has "routed-staging"
assert_file_missing "$GUARDEN_PREFIX/var/lib/guarden/registry/other-staging.toml"
# The claim is refused before identity, so the refusal leaves no system account
# behind: a service that exists on the box and in no registry is the state the
# check exists to prevent.
assert_no_passwd other-staging

# Two instances of one preview service each get their own publication, which is
# the whole reason a publication is allocated per instance.
run weedr service ingest routed-preview/feature-a --from poke routed@9f2c1ab
assert_exit 0
run weedr service ingest routed-preview/feature-b --from poke routed@9f2c1ab
assert_exit 0
preview=$GUARDEN_PREFIX/var/lib/guarden/registry/routed-preview.toml
# Keyed on `ref`, not on the escaped table key: the registry writes the ref raw
# beside the escaped key, and the escaped one carries a backslash a regex has to
# guess the length of.
first=$(awk '/^ref = "feature-a"$/{found=1} found && /^web = /{print $3; exit}' "$preview")
second=$(awk '/^ref = "feature-b"$/{found=1} found && /^web = /{print $3; exit}' "$preview")
[ -n "$first" ] && [ -n "$second" ] \
    || _fail "two previews of one service did not each get a publication"
[ "$first" != "$second" ] || _fail "two previews of one service share one publication"
[ "$first" != "$publication" ] && [ "$second" != "$publication" ] \
    || _fail "a preview took a publication the slot service already holds"
