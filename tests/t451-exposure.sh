#!/usr/bin/env bash
# t451-exposure.sh — ticket 294: public exposure is a manual root-side act,
# recorded per service per environment, selectable only on gated tracks, and
# refused when a manifest asks for it. The record is `[exposure] value` in the
# service's registry; `weedr expose set/unset/list` is the whole surface; and
# the act changes the recorded destinations so the next render follows it.
#
# What is asserted is state: the record in the registry, the destination in
# the rendered slice, the refusal's one line, and the fact that a refusal
# leaves the record untouched. The default's *value* is deliberately never
# asserted absolutely — the suite captures what the default resolved to and
# asserts the record wins over it and that unsetting returns to it, which is
# the same claim on a host whose default is edge and on one whose default is
# the tunnel-or-loopback posture of ticket 293.
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
stage_config guarden-nomodules.toml
stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_not_rejected
run weedr module add gate-traefik
assert_exit 0

destination_of() {
    sed -n 's/^destination = "\(.*\)"$/\1/p' "$1" | head -n 1
}

slice_of() {
    echo "$GUARDEN_PREFIX/var/lib/guarden/shared/$1/routes.toml"
}

# A service on staging, where the default resolves to whatever this host's
# posture says — captured, not asserted, because the record is what this
# ticket is about.
staged=$GUARDEN_PREFIX/var/lib/guarden/staging/routed/9f2c1ab
mkdir -p "$staged/.guarden/quadlet"
seed "$staged/.guarden/service.yml" "project: routed" "units: .guarden/quadlet/" \
    "routes:" "  - container: web" "    port: 8080" "    host: web"
seed "$staged/.guarden/quadlet/web.container" "[Container]" \
    "Image=docker.io/library/nginx:1.27"
run weedr service ingest routed-staging --from poke routed@9f2c1ab
assert_exit 0
reg=$GUARDEN_PREFIX/var/lib/guarden/registry/routed-staging.toml
slice=$(slice_of routed-staging)
d0=$(destination_of "$slice")
[ -n "$d0" ] || _fail "the fresh service's slice carries no destination at all"
assert_file_lacks "$reg" "exposure"

# A manifest that asks for public exposure is refused with one guarden line
# naming where the decision is recorded, and the refusal happens before a
# system account exists — a repository cannot even leave the request behind.
publicapp=$GUARDEN_PREFIX/var/lib/guarden/staging/publicapp/9f2c1ab
mkdir -p "$publicapp/.guarden/quadlet"
seed "$publicapp/.guarden/service.yml" "project: publicapp" "units: .guarden/quadlet/" \
    "exposure: public" "routes:" "  - container: web" "    port: 8080" "    host: web"
seed "$publicapp/.guarden/quadlet/web.container" "[Container]" \
    "Image=docker.io/library/nginx:1.27"
run weedr service ingest publicapp-staging --from poke publicapp@9f2c1ab
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "exposure"
# The refusal is "by name" — the message says where the decision IS recorded,
# not merely that a key was unknown. The generic closed-key-set line names the
# key too, so only the verb's own name tells the two messages apart.
assert_stderr_has "weedr expose set"
assert_file_missing "$GUARDEN_PREFIX/var/lib/guarden/registry/publicapp-staging.toml"
assert_no_passwd publicapp-staging

# The same key inside a block is refused by name as well: two vocabularies,
# one answer.
publicapp2=$GUARDEN_PREFIX/var/lib/guarden/staging/publicapp2/9f2c1ab
mkdir -p "$publicapp2/.guarden/quadlet"
seed "$publicapp2/.guarden/service.yml" "project: publicapp2" "units: .guarden/quadlet/" \
    "routes:" "  - container: web" "    port: 8080" "    host: web" "    exposure: public"
seed "$publicapp2/.guarden/quadlet/web.container" "[Container]" \
    "Image=docker.io/library/nginx:1.27"
run weedr service ingest publicapp2-staging --from poke publicapp2@9f2c1ab
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "exposure"
# Inside a block the key is refused with the SAME message as at the top level:
# the block's generic unknown-key line would satisfy "exposure" alone, and
# ticket 294 asks for the refusal-by-name in both places.
assert_stderr_has "weedr expose set"
assert_file_missing "$GUARDEN_PREFIX/var/lib/guarden/registry/publicapp2-staging.toml"

# Staging can never go public: the refusal is exit 2, it names the track, and
# it leaves no record behind.
run weedr expose set routed-staging public
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "gated"
assert_file_lacks "$reg" "exposure"

# A tunnel with no tunnel to carry it is refused rather than recorded, so a
# module removal can never be prefaced by a record nothing honours.
run weedr expose set routed-staging tunnel
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "cloudflared"
assert_file_lacks "$reg" "exposure"

# An unknown value names the three that exist.
run weedr expose set routed-staging sideways
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "loopback"

# On a gated track the act is accepted, writes exactly one record, and the
# next render's slice carries the promoted destination — `public` speaking the
# operator's word, `edge` the slice's, because the edge is the host's public
# ingress and the share vocabulary already says so.
#
# **The track is pinned to `loopback` BEFORE the service is created**, and the
# reason is the one that makes every assertion below mean something: the
# fixture pins `expose = "edge"` on every track, so a service created on this
# host already resolves to `edge` and a public promotion changes nothing an
# observer can see. The slice said `edge` before the act and says `edge` after
# it, and the suite would be green for a verb that wrote a record and moved
# nothing at all. With a private default, the record is the only thing on the
# box that can make the route public — so a router that appears, or an accept
# that appears, is the act's doing and not the fixture's.
#
# The pin REPLACES the fixture's `expose` line rather than adding one beside
# it: a second `expose` in the same `[[environments]]` table is a TOML error,
# and the whole file would stop parsing — which is a different failure from the
# one this block is about.
sed -i '/^name = "production"$/,/^kind =/ s/^expose = "edge"$/expose = "loopback"/' \
    "$GUARDEN_PREFIX/etc/guarden/guarden.toml"
grep -q '^expose = "loopback"$' "$GUARDEN_PREFIX/etc/guarden/guarden.toml" \
    || _fail "the production track was not pinned to loopback"

prod=$GUARDEN_PREFIX/var/lib/guarden/staging/routed/aa11bb22
mkdir -p "$prod/.guarden/quadlet"
seed "$prod/.guarden/service.yml" "project: routed" "units: .guarden/quadlet/" \
    "routes:" "  - container: web" "    port: 8080" "    host: web"
seed "$prod/.guarden/quadlet/web.container" "[Container]" \
    "Image=docker.io/library/nginx:1.27"
run weedr service ingest routed-production --from poke routed@aa11bb22
assert_exit 0
prodreg=$GUARDEN_PREFIX/var/lib/guarden/registry/routed-production.toml
prodslice=$(slice_of routed-production)
d0p=$(destination_of "$prodslice")
[ "$d0p" = "loopback" ] \
    || _fail "a service on a private track rendered destination $d0p, not loopback"

# A second service on the same gated track, under the same private default. It
# exists so the block below can assert that the promotion reached ONE service:
# the record is per service, and a promotion that moved the track's other
# service would be a promotion nobody asked for.
#
# Its route host is `api`, not `web`: two services on one track cannot claim the
# same host — the allocator refuses the second claimant, and the refusal would
# be about the fixture rather than about exposure.
other=$GUARDEN_PREFIX/var/lib/guarden/staging/routed2/bb22cc33
mkdir -p "$other/.guarden/quadlet"
seed "$other/.guarden/service.yml" "project: routed2" "units: .guarden/quadlet/" \
    "routes:" "  - container: web" "    port: 8080" "    host: api"
seed "$other/.guarden/quadlet/web.container" "[Container]" \
    "Image=docker.io/library/nginx:1.27"
run weedr service ingest routed2-production --from poke routed2@bb22cc33
assert_exit 0
otherreg=$GUARDEN_PREFIX/var/lib/guarden/registry/routed2-production.toml
otherslice=$(slice_of routed2-production)
[ "$(destination_of "$otherslice")" = "loopback" ] \
    || _fail "the second service on a private track rendered $(destination_of "$otherslice"), not loopback"

# The private default, asserted as the shape the promotion has to change: no
# edge router for either service, and no edge uid on either publication.
#
# The second half is the load-bearing one. The OUTPUT chain's default deny
# drops every service uid on 127.0.0.0/8, so an edge uid with no accept ABOVE
# the deny cannot reach the publication at all: a router naming it would be a
# route the edge dials and never reaches, and the deny is what makes that
# invisible from outside the box.
edge_uid=$(getent passwd traefik-production | cut -d: -f3)
[ -n "$edge_uid" ] || _fail "the edge service has no uid on this host"
services=$GUARDEN_PREFIX/etc/guarden/firewall/50-services.conf
prodpub=$(sed -n 's/^web = \([0-9]*\)$/\1/p' "$prodreg")
otherpub=$(sed -n 's/^web = \([0-9]*\)$/\1/p' "$otherreg")
[ -n "$prodpub" ] || _fail "no publication was allocated for the routed service"
[ -n "$otherpub" ] || _fail "no publication was allocated for the routed2 service"
[ "$prodpub" != "$otherpub" ] \
    || _fail "the two services on one track share a publication"
run runuser -u guarden -- /usr/lib/guarden/bin/roots sync
assert_exit 0
assert_file_missing "$GUARDEN_PREFIX/var/lib/guarden/edge/dynamic/routed-production.yml"
assert_file_missing "$GUARDEN_PREFIX/var/lib/guarden/edge/dynamic/routed2-production.yml"
[ "$(grep -cE "uid-owner $edge_uid daddr 127\.0\.0\.1 proto tcp dport $prodpub jump ACCEPT;" \
    "$services" || true)" = 0 ] \
    || _fail "the edge holds an accept on a private service's publication"

# **The promotion: the edge router appears and the edge uid accept appears.**
# These are the two consequences the ticket names and that nothing else in the
# suite asserted: the slice's destination is the record's answer, the router is
# what the edge reads, and the accept is what lets the edge's own packet
# through the deny. A public route with no accept is a route the edge dials and
# cannot reach.
run weedr expose set routed-production public
assert_exit 0
assert_file_has "$prodreg" 'value = "public"'
echo "# exposure-touched" >>"$prod/.guarden/quadlet/web.container"
run weedr service ingest routed-production --from poke routed@aa11bb22
assert_exit 0
[ "$(destination_of "$prodslice")" = "edge" ] \
    || _fail "a promoted service rendered destination $(destination_of "$prodslice"), not edge"
run runuser -u guarden -- /usr/lib/guarden/bin/roots sync
assert_exit 0
assert_file_exists "$GUARDEN_PREFIX/var/lib/guarden/edge/dynamic/routed-production.yml"
assert_file_has "$GUARDEN_PREFIX/var/lib/guarden/edge/dynamic/routed-production.yml" \
    'Host(`web`)'
# The accept is on the PUBLICATION, not on the public port: the edge dials the
# loopback publication the service's unit publishes, and a rule naming any
# other number matches no packet.
assert_file_has "$services" \
    "mod owner uid-owner $edge_uid daddr 127.0.0.1 proto tcp dport $prodpub jump ACCEPT;"

# **The record is ONE service's.** The other service on the same gated track
# never received a record and never became public, so its publication holds no
# edge accept — a promotion that reached the track instead of the service
# would publish the whole environment, which is the failure this ticket exists
# to prevent.
assert_file_missing "$GUARDEN_PREFIX/var/lib/guarden/edge/dynamic/routed2-production.yml"
[ "$(grep -cE "uid-owner $edge_uid daddr 127\.0\.0\.1 proto tcp dport $otherpub jump ACCEPT;" \
    "$services" || true)" = 0 ] \
    || _fail "the edge holds an accept on an unpromoted service's publication"

# `unset` reverses it: the router goes and the accept goes with it, and the
# route is private again. The reversal is the half of the act that says the
# promotion was a choice and not a posture.
run weedr expose unset routed-production
assert_exit 0
assert_file_lacks "$prodreg" "exposure"
echo "# exposure-touched-unset" >>"$prod/.guarden/quadlet/web.container"
run weedr service ingest routed-production --from poke routed@aa11bb22
assert_exit 0
[ "$(destination_of "$prodslice")" = "loopback" ] \
    || _fail "an unset service rendered destination $(destination_of "$prodslice"), not loopback"
run runuser -u guarden -- /usr/lib/guarden/bin/roots sync
assert_exit 0
assert_file_missing "$GUARDEN_PREFIX/var/lib/guarden/edge/dynamic/routed-production.yml"
[ "$(grep -cE "uid-owner $edge_uid daddr 127\.0\.0\.1 proto tcp dport $prodpub jump ACCEPT;" \
    "$services" || true)" = 0 ] \
    || _fail "the edge still holds an accept on an unset service's publication"

# The track goes back to the fixture's own posture, so the rest of the suite
# measures what it was written to measure.
sed -i '/^name = "production"$/,/^kind =/ s/^expose = "loopback"$/expose = "edge"/' \
    "$GUARDEN_PREFIX/etc/guarden/guarden.toml"

# Demotion is the same act in reverse: a record that says `loopback` on a
# service whose track says `edge` is a private service on a public track, and
# the record — not the track — is what governs it.
run weedr expose set routed-production loopback
assert_exit 0
echo "# exposure-touched-2" >>"$prod/.guarden/quadlet/web.container"
run weedr service ingest routed-production --from poke routed@aa11bb22
assert_exit 0
[ "$(destination_of "$prodslice")" = "loopback" ] \
    || _fail "a demoted service rendered destination $(destination_of "$prodslice"), not loopback"

# Unsetting returns the service to exactly what the default resolved to before
# any record existed. The default is now the fixture's own `edge` again, and the
# service's recorded destination was minted under this block's `loopback`
# posture — so the value the unset returns to is the one the RESOLVER says,
# not the one the record was minted with. This is the grandfathering rule
# (ticket 293) meeting the unset: the first answer stands until an act moves
# it, and the unset is that act.
run weedr expose unset routed-production
assert_exit 0
assert_file_lacks "$prodreg" "exposure"
echo "# exposure-touched-3" >>"$prod/.guarden/quadlet/web.container"
run weedr service ingest routed-production --from poke routed@aa11bb22
assert_exit 0
[ "$(destination_of "$prodslice")" = "edge" ] \
    || _fail "unsetting the record left destination $(destination_of "$prodslice"), not the default edge"

# The record is one service's: staging never received one while production was
# promoted and demoted beside it.
assert_file_lacks "$reg" "exposure"
[ "$(destination_of "$slice")" = "$d0" ] \
    || _fail "the staging service's destination moved without an act"

# **The drift item.** The ticket says `soil --check`, which is every phase;
# the firewall phase carries the item, so the whole-host form reaches it too —
# but the whole-host form is the wrong INSTRUMENT for this claim, because it
# reports every phase's drift and a throwaway machine has plenty: the sysctl
# keys are not set and the recurring units are not installed on a host that
# only ran `soil install`. So the item is asked through the phase that owns
# it, `soil firewall --check`, which is where the phase's own exit code is
# the exposure item's exit code and no other.
#
# **The drift is a DEFAULT that moved under a service that holds no record of
# its own.** A service that holds a record cannot drift: the record overrides
# the track (spec 3.4's projection rule — the record is the authority), so the
# expected value is what the record says and the two always agree. What moves
# underneath a service is the DEFAULT it was minted under — the track's
# `expose`, the enabled module set — and that is what the item compares.
#
# So the service under test here is `routed2-production`: it was created under
# a track that said `loopback` and it holds no record, so the track — restored
# to `edge` above — now says something the service's own recorded destination
# does not. Its recorded destination says `loopback`, the current resolution
# says `edge`, and the two disagree. The check names the service, so an
# operator can act on it — a drift nobody can attribute to a service is a drift
# nobody acts on — and the check changes NOTHING: the way back is the act, not
# a converge.
run soil firewall --check
assert_exit 1
assert_stderr_has "drift"
# The offenders are named in the line itself, in parentheses after the item's
# sentence. The whole parenthesised list is asserted, so the line that names
# the service is the exposure item's and not some other drift that happens to
# mention it.
assert_stderr_has "(off: routed2-production)"
# The check changed nothing: the service's posture is still the one its record
# was minted under, and the way back is the act.
assert_file_lacks "$otherreg" "exposure"
# The act is the way back: recording what the service already holds makes the
# host clean again, and the check says so.
run weedr expose set routed2-production loopback
assert_exit 0
run soil firewall --check
assert_exit 0

# `list` reports the record and the default state, per service, so an operator
# can see which services are held off their default. The row is asserted in
# full — a name on one line and the word `public` on another would pass a
# substring pair even if the two were different services' rows.
run weedr expose list
assert_exit 0
assert_stdout_has "routed-production default"
run weedr expose set routed-production public
assert_exit 0
run weedr expose list
assert_exit 0
assert_stdout_has "routed-production public edge"
# `--json` is the same answer in the one-line form spec 1.2 requires.
run weedr expose list --json
assert_exit 0
assert_stdout_lines 1
assert_stdout_has '"service": "routed-production"'
assert_stdout_has '"exposure": "public"'
assert_stdout_has '"destination": "edge"'
