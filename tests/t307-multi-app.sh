#!/usr/bin/env bash
# One manifest per app: a repository may ship several, and one app is one
# service (ticket 307a, ADR-0026, spec 5.1 / 5.3 / 6.6 / 7.3).
#
# **The three facts this suite pins, in the order it pins them.**
#
#   1. A repository with one app at its root behaves EXACTLY as it did: the app
#      is the tree root, its service is `<project>-<environment>`, and the
#      record carries no `app` key at all — absence is the tree root, and it is
#      a state rather than a gap.
#   2. A repository that ships `apps/web` and `apps/api` deploys TWO services,
#      `shop-web-<env>` and `shop-api-<env>`, each with its own user, home and
#      copy of the whole tree — the home is the build context (spec 6.6), so a
#      Containerfile that COPYs a sibling path still builds.
#   3. `needs: - app: api` renders through the same path a `siblings:` entry
#      does — `<AS>_HOST=<name>` and `<AS>_PORT=<publication>` in the
#      environment file, `AddHost=<name>:<alias>` in every unit — so the two
#      cannot disagree about what a name and a port mean. What differs is only
#      who resolves the name: a container of this unit source, or another
#      service of this repository.
#
# **Renaming is the fourth.** Renaming an app directory renames its service, and
# a deploy that asks for the old name is REFUSED with the apps the tree now
# ships — the service is not silently left behind carrying a tree nobody
# deploys. `weedr service list` is the inventory; destroying the old one is
# `weedr service remove`, which this suite leaves to the operator it belongs to.
#
# **`GUARDEN_PREFIX=/` and the machine's own tools.** These are real services: a
# real `useradd`, a real home, a real btrfs subvolume where a volume is
# declared, and a real `loom` render installed by `soil install`. Nothing here
# reads a record of what guarden was about to ask the host to do.
#
# machine: fresh

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GUARDEN_PREFIX=/

cleanup() {
    local rc=0
    purge solo-staging shop-web-staging shop-api-staging shop-worker-api-staging \
        shop-web-production shop-api-production shop-worker-api-production || rc=1
    # A request file is named after a service and a sha, so one left behind is a
    # request a later suite's `furrow queue list` counts.
    rm -f /var/lib/guarden/queue/shop-*.json /var/lib/guarden/queue/solo-*.json
    assert_no_service_left solo-staging shop-web-staging shop-api-staging \
        shop-worker-api-staging shop-web-production shop-api-production \
        shop-worker-api-production || rc=1
    rm -rf /var/lib/guarden/staging/shop /var/lib/guarden/staging/solo
    return "$rc"
}
trap cleanup EXIT
cleanup || true

install -d -m 0770 -o root -g guarden /var/lib/guarden/queue
# `guarden-measured.toml` because every manifest here declares an edge or a
# sibling, so the units carry `AddHost=` and the renderer refuses an empty
# `ingress.alias` (spec 6.3). Production is `gated = true` in this table, which
# is what makes the furrow half of this suite stop at the gate instead of
# starting a container nothing here has pulled.
stage_config guarden-measured.toml
stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_not_rejected

registry=/var/lib/guarden/registry
homes=/var/lib/guarden/services
fixtures=$GUARDEN_ROOT/fixtures/projects

# assert_no_error: the verb printed no `error:`. NOT `assert_stderr_empty`, and
# the reason is a fact about this machine rather than about this ticket: the
# golden carries `/etc/guarden/firewall/50-services.conf` while
# `guarden-firewall.service` is not installed, so every render of the uid-matched
# filter set says so with one `warning:` — a host state `soil firewall --apply`
# is the verb for, and not what this suite is measuring.
assert_no_error() {
    assert_stderr_lacks "error:"
}

# stage_tree <fixture> <project> <sha>: the fixture into the poke's staging tree.
stage_tree() {
    local fixture=$1 project=$2 sha=$3
    local staged=/var/lib/guarden/staging/$project/$sha
    rm -rf "$staged"
    mkdir -p "$staged"
    cp -a "$fixtures/$fixture/." "$staged/"
    chmod -R a+rX "$staged"
    printf '%s\n' "$staged"
}

# --- 1. one app at the root is the regression case ---------------------------

stage_tree solo solo 9f2c1ab >/dev/null
run weedr service ingest solo-staging --from poke solo@9f2c1ab
assert_exit 0
assert_no_error
assert_file_exists "$registry/solo-staging.toml"
# **The absence is the fact.** The tree-root app's name is empty, and a record
# that wrote `app = ""` would be a second spelling of it (spec 3.4). `grep -F`,
# so the needle is the line a record would carry and not a regular expression.
assert_file_lacks "$registry/solo-staging.toml" 'app = '

# The manifest, the unit source and the Containerfile are read from the root of
# the home, which is what every repository that is one service has always done.
assert_file_exists "$homes/solo-staging/home/.guarden/service.yml"
assert_file_exists \
    "$homes/solo-staging/home/.config/containers/systemd/app.container"

# A second ingest converges: nothing about the app machinery made the tree root
# look like a change.
run weedr service ingest solo-staging --from poke solo@9f2c1ab
assert_exit 0
assert_stdout_has "converged"

# --- 2. two apps are two services ------------------------------------------

stage_tree multi shop 9f2c1ab >/dev/null

# The provider first, because an app edge is an edge: the mutator refuses a
# consumer whose provider has no registry entry, and a poke creates services in
# dependency order (spec 4).
run weedr service ingest shop-web-staging --from poke shop@9f2c1ab
assert_exit 0
assert_no_error
assert_file_has "$registry/shop-web-staging.toml" 'app = "apps/web"'

run weedr service ingest shop-api-staging --from poke shop@9f2c1ab
assert_exit 0
assert_no_error
assert_file_has "$registry/shop-api-staging.toml" 'app = "apps/api"'

# **An app name carrying a dash is still an app name**, and the environment is
# still the LAST segment of the service name: `shop-worker-api-staging` is the
# app `worker-api` of `shop` on `staging`, and the project half is the poke's
# own `--from` pair rather than anything counted out of the name.
run weedr service ingest shop-worker-api-staging --from poke shop@9f2c1ab
assert_exit 0
assert_no_error
assert_file_has "$registry/shop-worker-api-staging.toml" 'app = "apps/worker-api"'
assert_file_has "$registry/shop-worker-api-staging.toml" 'environment = "staging"'

# Seven characters of app name in the service name, and the environment is
# still the LAST segment — an app name carrying a dash would be the same rule.
assert_file_has "$registry/shop-api-staging.toml" 'environment = "staging"'

# **The whole tree is the home, and the app root is a path inside it.** The
# build context is the home (spec 6.6), so the api app's own files are in the web
# service's home too, and a Containerfile that copies a sibling path resolves.
assert_file_exists "$homes/shop-web-staging/home/apps/web/.guarden/service.yml"
assert_file_exists "$homes/shop-web-staging/home/apps/api/.guarden/service.yml"

# Two services, two users, two homes: the api app is not a container inside the
# web service (spec 5.3).
assert_passwd shop-web-staging
assert_passwd shop-api-staging
[ "$(getent passwd shop-web-staging | cut -d: -f3)" != \
  "$(getent passwd shop-api-staging | cut -d: -f3)" ] \
    || _fail "the two apps of one repository share one uid"

# --- 3. an app edge renders what a sibling renders --------------------------

api_units=$homes/shop-api-staging/home/.config/containers/systemd
web_units=$homes/shop-web-staging/home/.config/containers/systemd

# The provider's publication, out of the provider's own record: the app edge
# dials the publication and never the container port (spec 7.4).
web_pub=$(python3 "$GUARDEN_ROOT/tests/registryfield.py" \
    "$registry/shop-web-staging.toml" - web)
[ -n "$web_pub" ] || _fail "shop-web-staging allocates no publication for web"

# The app's edge, in the consumer's own environment file and its own units.
assert_file_has "$api_units/guarden.env" "WEB_HOST=shop-web-staging"
assert_file_has "$api_units/guarden.env" "WEB_PORT=$web_pub"
assert_file_has "$api_units/api.container" "AddHost=shop-web-staging:10.0.2.2"
# The container port the manifest wrote is not what the consumer dials.
assert_file_lacks "$api_units/guarden.env" "WEB_PORT=3000"

# The sibling, in the same file and the same unit: a container of the web app's
# own unit source, on the web service's own allocation.
cache_pub=$(python3 "$GUARDEN_ROOT/tests/registryfield.py" \
    "$registry/shop-web-staging.toml" - cache)
[ -n "$cache_pub" ] || _fail "shop-web-staging allocates no publication for cache"
assert_file_has "$web_units/guarden.env" "CACHE_HOST=cache"
assert_file_has "$web_units/guarden.env" "CACHE_PORT=$cache_pub"
assert_file_has "$web_units/web.container" "AddHost=cache:10.0.2.2"
assert_file_lacks "$web_units/guarden.env" "CACHE_PORT=6379"

# **The two paths agree on the SHAPE, which is what makes them one rule.** An
# app edge's HOST is a service name and a sibling's is a container name; both
# are followed by `_PORT` carrying a publication, and both names appear in the
# consumer's own `AddHost=` pointing at the alias. A second implementation of
# either half would show up here as a key that is spelled differently.
if ! grep -qE '^[A-Z0-9_]+_HOST=[a-z0-9][a-z0-9._-]*$' "$api_units/guarden.env" \
   || ! grep -qE '^[A-Z0-9_]+_HOST=[a-z0-9][a-z0-9._-]*$' "$web_units/guarden.env"; then
    _fail "a _HOST value is not a name: $(cat "$api_units/guarden.env")"
fi

# --- 4. renaming an app refuses the old name --------------------------------

# The same repository with `apps/web` renamed to `apps/frontend`, under its own
# sha: the tree is a different tree, and the name the deploy asks for is the one
# that no longer selects an app.
stage_tree multi shop 8a1d2f0 >/dev/null
mv /var/lib/guarden/staging/shop/8a1d2f0/apps/web \
   /var/lib/guarden/staging/shop/8a1d2f0/apps/frontend

run weedr service ingest shop-web-staging --from poke shop@8a1d2f0
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "no app called 'web'"
# The refusal names what the tree DOES ship, because the fix is to rename or to
# deploy the new name.
assert_stderr_has "frontend"

# The old service is untouched and still listed: nothing was silently orphaned
# and nothing was silently moved.
assert_file_exists "$registry/shop-web-staging.toml"
assert_file_has "$registry/shop-web-staging.toml" 'app = "apps/web"'
run weedr service list
assert_exit 0
assert_stdout_has "shop-web-staging"

# The renamed app deploys under its own name, and its service is a service of
# its own — the rename is a new service, not a move of the old one.
run weedr service ingest shop-frontend-staging --from poke shop@8a1d2f0
assert_exit 0
assert_file_has "$registry/shop-frontend-staging.toml" 'app = "apps/frontend"'
purge shop-frontend-staging || true

# --- the traps, as refusals -------------------------------------------------

# `<project>--<environment>` is not a service name, and the empty middle is the
# tree-root app's spelling — which is the spelling WITHOUT the second hyphen.
run weedr service ingest shop--staging --from poke shop@9f2c1ab
assert_exit 2
assert_one_diagnostic "error:"

# `needs: app: worker` names an app this tree does not ship: a fact about the
# repository, refused before identity and before the home (exit 2).
stage_tree multi shop b0b0b0b >/dev/null
seed /var/lib/guarden/staging/shop/b0b0b0b/apps/api/.guarden/service.yml \
    "project: shop" "units: .guarden/quadlet/" "needs:" "  - app: worker" \
    "    as: worker" "    port: 3000" "    auth: none"
run weedr service ingest shop-api-staging --from poke shop@b0b0b0b
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "needs the app 'worker'"
assert_stderr_has "ships no such app"
assert_stderr_has "'api'"

# **Two app directories with one last component collide**, and the refusal names
# both of them rather than picking one: the name is what a service is called, so
# whichever one won, the other's deploy would land on a service carrying a
# different tree's manifest.
stage_tree multi shop c1d2e3f >/dev/null
mkdir -p /var/lib/guarden/staging/shop/c1d2e3f/services
cp -a /var/lib/guarden/staging/shop/c1d2e3f/apps/web \
      /var/lib/guarden/staging/shop/c1d2e3f/services/web
run weedr service ingest shop-web-staging --from poke shop@c1d2e3f
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "two apps called 'web'"
assert_stderr_has "apps/web"
assert_stderr_has "services/web"

# --- 5. one poke is one request per app, providers first --------------------

# The production track is gated in `guarden-measured.toml`. Both apps declare a
# required key, so both gates are blocked and the deploy exits 0 having created,
# rendered and installed both services and started nothing — which is also what
# keeps this suite from pulling an image it does not need (spec 6.6).
stage_tree multi shop 7b3e1d9 >/dev/null
run furrow deploy shop-production --from poke shop@7b3e1d9
assert_exit 0
assert_file_exists "$registry/shop-web-production.toml"
assert_file_exists "$registry/shop-api-production.toml"
assert_file_exists "$registry/shop-worker-api-production.toml"
assert_file_has "$registry/shop-api-production.toml" 'app = "apps/api"'
assert_file_has "$registry/shop-web-production.toml" 'state = "blocked"'
assert_file_has "$registry/shop-api-production.toml" 'state = "blocked"'

# **The consumer ran after the provider**, and the assertion is an order rather
# than a count: `api` sorts before `web`, so an implementation that fell back to
# the queue's name ordering would deploy the consumer first and refuse it for a
# provider that does not exist yet.
web_line=$(grep -n "ensure shop-web-production" "$GUARDEN_STDOUT" | cut -d: -f1)
api_line=$(grep -n "ensure shop-api-production" "$GUARDEN_STDOUT" | cut -d: -f1)
worker_line=$(grep -n "ensure shop-worker-api-production" "$GUARDEN_STDOUT" | cut -d: -f1)
[ -n "$web_line" ] || _fail "the deploy never ensured shop-web-production"
[ -n "$api_line" ] || _fail "the deploy never ensured shop-api-production"
[ -n "$worker_line" ] || _fail "the deploy never ensured shop-worker-api-production"
[ "$web_line" -lt "$api_line" ] \
    || _fail "shop-api-production was ensured before its provider (line $api_line < $web_line)"
[ "$api_line" -lt "$worker_line" ] \
    || _fail "shop-worker-api-production was ensured before api ($worker_line < $api_line)"

# The consumer's edge was installed from the provider's allocation on the same
# track, which is the property the ordering exists for: a staging deploy cannot
# dial a production sibling.
assert_file_has "$registry/shop-api-production.toml" "shop-web-production"

# Nothing is left waiting: one poke, two requests, both settled.
run furrow status --json
assert_exit 0
assert_json queued 0
assert_json in_flight 0
