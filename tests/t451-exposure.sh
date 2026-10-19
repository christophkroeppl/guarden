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
[ -n "$d0p" ] || _fail "the production service's slice carries no destination at all"

run weedr expose set routed-production public
assert_exit 0
assert_file_has "$prodreg" 'value = "public"'

# Re-render: a changed poke sha is a non-converged ingest, and that is the
# path that re-renders a service's slice — the record is read at render time,
# so this is the "next render" the act promises.
echo "# exposure-touched" >>"$prod/.guarden/quadlet/web.container"
run weedr service ingest routed-production --from poke routed@aa11bb22
assert_exit 0
[ "$(destination_of "$prodslice")" = "edge" ] \
    || _fail "a promoted service rendered destination $(destination_of "$prodslice"), not edge"

# Demotion is the same act in reverse, and unsetting returns the service to
# exactly what the default resolved to before any record existed.
run weedr expose set routed-production loopback
assert_exit 0
echo "# exposure-touched-2" >>"$prod/.guarden/quadlet/web.container"
run weedr service ingest routed-production --from poke routed@aa11bb22
assert_exit 0
[ "$(destination_of "$prodslice")" = "loopback" ] \
    || _fail "a demoted service rendered destination $(destination_of "$prodslice"), not loopback"

run weedr expose unset routed-production
assert_exit 0
assert_file_lacks "$prodreg" "exposure"
echo "# exposure-touched-3" >>"$prod/.guarden/quadlet/web.container"
run weedr service ingest routed-production --from poke routed@aa11bb22
assert_exit 0
[ "$(destination_of "$prodslice")" = "$d0p" ] \
    || _fail "unsetting the record left destination $(destination_of "$prodslice"), not the default $d0p"

# The record is one service's: staging never received one while production was
# promoted and demoted beside it.
assert_file_lacks "$reg" "exposure"
[ "$(destination_of "$slice")" = "$d0" ] \
    || _fail "the staging service's destination moved without an act"

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
