#!/usr/bin/env bash
# The refusal names the provider the operator has to act on — the MUTATOR's
# half (ticket 290).
#
# A `needs:` entry may name a LOGICAL provider, and the host resolves it per
# track through `[providers]` in `guarden.toml`. The mutator resolves the name
# too, against the consumer's own track, and the refusal it makes has to name
# the CONCRETE provider — the one the registry was consulted for — because that
# is the service the operator has to fix. A refusal that named the logical name
# would send the operator looking for a service that does not exist on this
# host.
#
# The other edge answers a `needs:` entry can get are refusals made in the same
# place, before identity, because none of them can be rendered: an absent
# provider has no allocation to dial, a port the provider names no container for
# has no publication either, and a self-edge has no consumer at all. The ingest
# renders the consumer in the same command, so an answer discovered there would
# leave a system user, a home, its volumes and a registry record with no units
# (ticket 289). Each scenario below therefore asserts BOTH the one line and the
# absence of everything the mutator would have created before the render.
#
# The RENDERER's refusals are the same rule on the other side of the same
# resolution, and they need no real host, so they live in
# `t83-provider-diagnostics.sh`.
#
# Real host, real uids, a real `useradd`: the mutator creates a system user and
# a home, and a staged tree cannot answer for either. `GUARDEN_PREFIX=/`, as
# `t30-create`, `t50-route` and `t60-secrets` do.
#
# machine: fresh

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GUARDEN_PREFIX=/

registry=/var/lib/guarden/registry

purge() {
    for service in "$@"; do
        rm -rf "/var/lib/guarden/services/$service" "/etc/guarden/services/$service" \
            "/etc/guarden/creds/$service" "$registry/$service.toml"
        userdel "$service" >/dev/null 2>&1 || :
    done
}

cleanup() {
    purge postgres-staging ghost-staging nowhere-staging
}
trap cleanup EXIT

cleanup
# `host.admin_user` names the uid the whole OUTPUT accept set admits and the
# firewall refuses to render without it. `soil install` records the invoking user
# there, so the account is this fixture's own claim and it has to exist.
ensure_accounts
stage_config guarden-provider-diag.toml

# The provider the `[providers]` table names for staging: it exists, and it
# offers a cache rather than a database.
seed "$registry/postgres-staging.toml" \
    'service = "postgres-staging"' 'workload = "postgres"' 'project = "postgres"' \
    'environment = "staging"' 'uid = 1099' 'created = "2026-09-30T09:00:00Z"' \
    '[provides]' 'kinds = [ "cache" ]'

# `soil install --apply` is a precondition, not the subject: ingest renders
# through `loom`, and the programs are not on this host until install has run.
stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_exit 0

# The provider does not offer the kind the consumer wants. The mutator
# consults the registry before it creates anything, so the refusal comes from
# `edges.check` and nothing is left behind. The refusal names the CONCRETE
# provider — `postgres-staging` — and not the logical name the manifest wrote.
ghost=/var/lib/guarden/staging/ghost/9f2c1ab
mkdir -p "$ghost/.guarden/quadlet"
seed "$ghost/.guarden/service.yml" "project: ghost" "units: .guarden/quadlet/" \
    "state:" "  - data" "needs:" "  - service: postgres" "    as: db" \
    "    port: 5432" "    auth: database"
seed "$ghost/.guarden/quadlet/web.container" "[Container]" \
    "Image=docker.io/library/nginx:1.27"
run weedr service ingest ghost-staging --from poke ghost@9f2c1ab
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "postgres-staging"
assert_stderr_has "ghost-staging"
assert_stderr_has "db"
assert_stderr_has "cache"

# The edge resolves to the service that declares it. A self-edge has no
# consumer, so no unit can be rendered for it — and the manifest named the
# service itself, so this is a rejected input (exit `2`) and not an answer about
# the host. Refused before identity like the rest: nothing is created.
seed "$ghost/.guarden/service.yml" "project: ghost" "units: .guarden/quadlet/" \
    "state:" "  - data" "needs:" "  - service: ghost-staging" "    as: db" \
    "    port: 5432" "    auth: database"
seed "$ghost/.guarden/quadlet/web.container" "[Container]" \
    "Image=docker.io/library/nginx:1.27" "Volume=data:/var/lib/app"
run weedr service ingest ghost-staging --from poke ghost@9f2c1ab
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "self-edge"
assert_stderr_has "ghost-staging"
assert_no_passwd ghost-staging
assert_file_missing "$registry/ghost-staging.toml"
assert_file_missing "/var/lib/guarden/services/ghost-staging"

# The logical name resolves to a provider this host has never heard of. There is
# no allocation to dial, so the ingest's render would refuse the consumer's
# units — after the user, the home, the volumes and the registry record existed.
# The mutator refuses the edge first, and the service is not left half-created.
nowhere=/var/lib/guarden/staging/nowhere/9f2c1ab
mkdir -p "$nowhere/.guarden/quadlet"
seed "$nowhere/.guarden/service.yml" "project: nowhere" "units: .guarden/quadlet/" \
    "state:" "  - data" "needs:" "  - service: absent" "    as: db" \
    "    port: 5432" "    auth: database"
seed "$nowhere/.guarden/quadlet/web.container" "[Container]" \
    "Image=docker.io/library/nginx:1.27" "Volume=data:/var/lib/app"
run weedr service ingest nowhere-staging --from poke nowhere@9f2c1ab
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "absent-staging"
assert_stderr_has "nowhere-staging"
assert_stderr_has "no registry entry"
assert_no_passwd nowhere-staging
assert_file_missing "$registry/nowhere-staging.toml"
assert_file_missing "/var/lib/guarden/services/nowhere-staging"
