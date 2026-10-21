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
# **`edges.install` makes one other answer about the name — a WARNING when the
# resolved provider has no registry entry — and a poke cannot observe it.** The
# same ingest renders the consumer's units once the registry is saved, the
# render refuses the edge that was recorded with no publication, and the raise
# takes `_emit` with it: the warning sits in `outcome.warnings` and is never
# printed. This suite therefore pins the one site a poke reaches. The warning's
# name is held to the same rule in `edges.install` and has no suite that could
# assert it; ticket 289 is the ordering that would make it observable.
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
    purge postgres-staging ghost-staging
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
