#!/usr/bin/env bash
# One poke deploys N apps (ticket 307h).
#
# **The receiver's own path, end to end.** `t307-multi-app` drives `furrow` and
# `weedr` directly, so it proves the queue fans a repository out into one request
# per app and says nothing about the receiver that asks it to: a CI key reaches
# `hose` and never `furrow`, and `hose` is where the poke's one name is derived.
# Every poke below goes through `hose`, so what is measured is the path a push
# takes.
#
# Four facts, in the order they are measured:
#
#   1. one poke of a three-app repository creates three services, providers
#      before consumers, and every line of the report names the app it is about;
#   2. each service installs ITS OWN app's manifest — the consumer's edge is
#      rendered from the consumer's app and the provider's sibling from the
#      provider's, so neither could have come from the tree root;
#   3. a repository with one app at the root is unchanged: one service, no `app`
#      key in its record, and a report that names no app at all;
#   4. an unchanged app is NOT restarted, and a restart IS visible to the same
#      measurement — the control that keeps that assertion from being vacuous.
#
# **A refusal by the tree refuses the whole poke; a failure of one app does
# not.** The two are different kinds of fact and this suite measures both: a
# `needs: app:` naming an app the tree does not ship stops the poke before a
# service exists, and an app whose build fails is reported by name while the
# apps after it still deploy.
#
# machine: fresh

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GUARDEN_PREFIX=/

registry=/var/lib/guarden/registry
homes=/var/lib/guarden/services
staging=/var/lib/guarden/staging
fixtures=$GUARDEN_ROOT/fixtures/projects

services="shop-web-production shop-api-production shop-worker-api-production \
shop-web-staging solo-production restart-staging"

cleanup() {
    local rc=0
    purge $services || rc=1
    rm -f /var/lib/guarden/queue/shop-*.json /var/lib/guarden/queue/solo-*.json \
        /var/lib/guarden/queue/restart-*.json
    rm -f /etc/guarden/projects.d/shop.toml /etc/guarden/projects.d/solo.toml
    rm -rf "$staging/shop" "$staging/solo" "$staging/restart"
    assert_no_service_left $services || rc=1
    return "$rc"
}
trap cleanup EXIT
cleanup || true

install -d -m 0770 -o root -g guarden /var/lib/guarden/queue
install -d -m 0755 /etc/guarden/projects.d
stage_config guarden-measured.toml
stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_not_rejected

# assert_no_error: the verb printed no `error:`. NOT `assert_stderr_empty`, and
# the reason is a fact about this machine rather than about this ticket: the
# golden carries `/etc/guarden/firewall/50-services.conf` while
# `guarden-firewall.service` is not installed, so every render of the uid-matched
# filter set says so with one `warning:`.
assert_no_error() {
    assert_stderr_lacks "error:"
}

# project_for <name> <environments>: a project the receiver may deploy, written
# the way `weedr project add` writes it — `0444` and root-owned, because that
# mode is the carve-out that lets the network-facing program read a ref
# allowlist.
project_for() {
    seed /etc/guarden/projects.d/"$1".toml \
        "[projects.$1]" \
        "repository = \"git@github.com:you/$1.git\"" \
        "environments = { $2 }"
    chmod 0444 /etc/guarden/projects.d/"$1".toml
}

# tar_tree <directory>: the archive a CI client streams into a poke.
tar_tree() {
    local out=$GUARDEN_FIXTURES/$(basename "$1").tar
    tar -C "$1" -cf "$out" .
    printf '%s\n' "$out"
}

# stage_tree <directory> <fixture>: a staged tree of this suite's own, beside the
# fixture it was copied from.
stage_tree() {
    rm -rf "$1"
    mkdir -p "$1"
    cp -a "$2/." "$1/"
    printf '%s\n' "$1"
}

project_for shop '"main" = ["production"], "develop" = ["staging"]'
project_for solo '"main" = ["production"]'

# --- 1. one poke of a three-app repository is three services ------------------

shop_tar=$(tar_tree "$fixtures/multi")
run hose --project shop poke main 9f2c1ab <"$shop_tar"
assert_exit 0
assert_no_error

# **Three services, and each record carries ITS app root.** The app root is what
# locates the manifest, the schema and the unit source in the home, and the name
# was derived by the receiver and never accepted from the caller.
assert_file_has "$registry/shop-web-production.toml" 'app = "apps/web"'
assert_file_has "$registry/shop-api-production.toml" 'app = "apps/api"'
assert_file_has "$registry/shop-worker-api-production.toml" 'app = "apps/worker-api"'
assert_passwd shop-web-production
assert_passwd shop-worker-api-production

# **The report names the app on every line that is about one.** A poke of three
# apps whose output says only `shop-api-production` makes an operator read the
# name to find the directory; the line carries both.
assert_stdout_has "ensure  shop-web-production (app apps/web)"
assert_stdout_has "ensure  shop-api-production (app apps/api)"
assert_stdout_has "ensure  shop-worker-api-production (app apps/worker-api)"

# **Providers before consumers, and the assertion is an ORDER.** `api` sorts
# before `web`, so an implementation that deployed in queue-name order would
# refuse the consumer for a provider that does not exist yet.
web_line=$(grep -nE 'ensure +shop-web-production' "$GUARDEN_STDOUT" | cut -d: -f1 || true)
api_line=$(grep -nE 'ensure +shop-api-production' "$GUARDEN_STDOUT" | cut -d: -f1 || true)
worker_line=$(grep -nE 'ensure +shop-worker-api-production' "$GUARDEN_STDOUT" | cut -d: -f1 || true)
[ -n "$web_line" ] || _fail "the poke never ensured shop-web-production"
[ -n "$api_line" ] || _fail "the poke never ensured shop-api-production"
[ -n "$worker_line" ] || _fail "the poke never ensured shop-worker-api-production"
[ "$web_line" -lt "$api_line" ] \
    || _fail "shop-api-production was ensured before its provider (line $api_line < $web_line)"
[ "$api_line" -lt "$worker_line" ] \
    || _fail "shop-worker-api-production was ensured before api ($worker_line < $api_line)"

# --- 2. each service renders ITS OWN app's manifest ---------------------------

# The whole tree is the home (spec 6.6), so every app's files are in every
# service's home and their presence says nothing. What says which manifest the
# service was built from is what the RENDER made of it: the provider's sibling
# and the consumer's edge are different mechanisms on different apps, and neither
# can be produced by the other app's document.
web_units=$homes/shop-web-production/home/.config/containers/systemd
api_units=$homes/shop-api-production/home/.config/containers/systemd
worker_units=$homes/shop-worker-api-production/home/.config/containers/systemd

assert_file_has "$web_units/shop-web.pod" "AddHost=cache:10.0.2.2"
assert_file_lacks "$web_units/web.container" "AddHost="
assert_file_has "$web_units/guarden.env" "CACHE_HOST=cache"
assert_file_has "$api_units/shop-api.pod" "AddHost=shop-web-production:10.0.2.2"
assert_file_lacks "$api_units/api.container" "AddHost="
assert_file_has "$api_units/guarden.env" "WEB_HOST=shop-web-production"
assert_file_has "$worker_units/shop-worker-api.pod" "AddHost=shop-api-production:10.0.2.2"

# The negative half: the provider's `siblings:` entry is not a name the consumer
# holds, and the consumer's edge is not in the provider's units.
assert_file_lacks "$api_units/guarden.env" "CACHE_HOST"
assert_file_lacks "$web_units/guarden.env" "WEB_HOST"

# A production poke is gated and both schemas declare a required key, so each
# service is installed and waiting rather than started — which is also what keeps
# this suite from pulling an image it does not need (spec 6.6).
assert_file_has "$registry/shop-web-production.toml" 'state = "blocked"'
assert_file_has "$registry/shop-api-production.toml" 'state = "blocked"'

# `weedr`'s own answer names the app too, on the one verb whose stdout a poke
# never shows: `furrow` swallows it, so this is driven directly. The app with no
# `needs:` is the one that can be created alone, because an edge needs its
# provider's record to exist first. **The tree is staged again**: a poke removes
# the tree it unpacked once its deploy returns, so the one it carried is gone.
stage_tree "$staging/shop/9f2c1ab" "$fixtures/multi" >/dev/null
run weedr service ingest shop-web-staging --from poke shop@9f2c1ab
assert_exit 0
assert_no_error
assert_stdout_has "created shop-web-staging (app apps/web) uid "
assert_file_has "$registry/shop-web-staging.toml" 'app = "apps/web"'
purge shop-web-staging
assert_no_service_left shop-web-staging

# --- 3. one app at the root is the repository that still deploys one service --

solo_tar=$(tar_tree "$fixtures/solo")
run hose --project solo poke main 1a2b3c4 <"$solo_tar"
assert_exit 0
assert_no_error
assert_file_exists "$registry/solo-production.toml"
# **The absence is the fact.** A record that wrote `app = ""` would be a second
# spelling of the tree root (spec 3.4), and `grep -F` so the needle is the line a
# record would carry.
assert_file_lacks "$registry/solo-production.toml" 'app = '
# The report of a one-app repository carries no app, because it has none to name:
# this is the byte-identical regression, asserted on the line.
assert_stdout_has "ensure  solo-production: "
assert_stdout_lacks "(app "
assert_file_exists "$homes/solo-production/home/.guarden/service.yml"
# One service for the project and no second one: the registry's own inventory.
solo_records=$(find "$registry" -maxdepth 1 -name 'solo-*.toml' | wc -l)
[ "$solo_records" -eq 1 ] \
    || _fail "one poke of a one-app repository created $solo_records services, not one"

# --- 4. a refusal by the tree refuses the whole poke -------------------------

# `needs: app: worker` names an app this tree does not ship. It is a fact about
# the repository, so no service of the poke is created — deploying the apps that
# would have worked would install a half of a repository that can never be whole.
before_web=$(sha256sum "$registry/shop-web-production.toml" | cut -d' ' -f1)
before_api=$(sha256sum "$registry/shop-api-production.toml" | cut -d' ' -f1)
broken=$(stage_tree "$staging/shop/00bad00" "$fixtures/multi")
seed "$broken/apps/api/.guarden/service.yml" \
    "project: shop" "units: .guarden/quadlet/" "needs:" "  - app: worker" \
    "    as: worker" "    port: 3000" "    auth: none"
refused_tar=$(tar_tree "$broken")
rm -rf "$broken"
run hose --project shop poke main 00bad00 <"$refused_tar"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "needs the app 'worker'"
assert_stderr_has "ships no such app"
# Nothing of that poke landed: neither record was written at all. The bytes are
# the assertion rather than a field, because a refused poke that touched these
# services would have touched all of one record, not the one field this names.
after_web=$(sha256sum "$registry/shop-web-production.toml" | cut -d' ' -f1)
after_api=$(sha256sum "$registry/shop-api-production.toml" | cut -d' ' -f1)
[ "$before_web" = "$after_web" ] \
    || _fail "a refused poke wrote shop-web-production's record"
[ "$before_api" = "$after_api" ] \
    || _fail "a refused poke wrote shop-api-production's record"

# --- 5. one app failing does not skip the next one --------------------------

# The build of one app fails, after its own ingest and before the apps that come
# after it. `worker-api` needs `api`'s RECORD and not its container, and the
# record exists by then, so the third app deploys over a failed second one.
before_web=$(sha256sum "$registry/shop-web-production.toml" | cut -d' ' -f1)
before_api=$(sha256sum "$registry/shop-api-production.toml" | cut -d' ' -f1)
before_worker=$(sha256sum "$registry/shop-worker-api-production.toml" | cut -d' ' -f1)
failing=$(stage_tree "$staging/shop/000badd" "$fixtures/multi")
seed "$failing/apps/api/.guarden/quadlet/api.container" \
    "[Container]" "Image=docker.io/library/alpine:3.20" "BuildFile=Containerfile"
seed "$failing/apps/api/Containerfile" \
    "FROM scratch" "COPY not-here /not-here"
failed_tar=$(tar_tree "$failing")
rm -rf "$failing"
run hose --project shop poke main 000badd <"$failed_tar"
assert_exit 1
# The failing app is reported by name, and the step that failed names the app
# root as well as the service.
assert_stderr_has "the build of shop-api-production failed"
assert_stdout_has "build   shop-api-production (app apps/api): weedr service build"
# **The third app ran after the second one failed**, and it is an ORDER rather
# than a count: a drain that stopped at the first failure would report the build
# line and nothing after it, and a check for the line alone would pass on a
# poke that deployed two of its three apps.
failed_at=$(grep -nE '^build +shop-api-production' "$GUARDEN_STDOUT" | cut -d: -f1 || true)
worker_at=$(grep -nE '^ensure +shop-worker-api-production' "$GUARDEN_STDOUT" | cut -d: -f1 || true)
[ -n "$failed_at" ] || _fail "the poke never reached shop-api-production's build"
[ -n "$worker_at" ] \
    || _fail "shop-worker-api-production was never ensured after shop-api-production's build failed"
[ "$failed_at" -lt "$worker_at" ] \
    || _fail "shop-worker-api-production was ensured before the build that failed ($worker_at <= $failed_at)"
# The apps that could deploy did, and the one that could not changed nothing: a
# failure is one app's and the poke does not take the others with it.
[ "$(sha256sum "$registry/shop-web-production.toml" | cut -d' ' -f1)" != "$before_web" ] \
    || _fail "the app before the failing one did not deploy"
[ "$(sha256sum "$registry/shop-worker-api-production.toml" | cut -d' ' -f1)" != "$before_worker" ] \
    || _fail "the app after the failing one did not deploy"
[ "$(sha256sum "$registry/shop-api-production.toml" | cut -d' ' -f1)" = "$before_api" ] \
    || _fail "the app whose build failed wrote its record anyway"

# --- 6. an unchanged app is not restarted -----------------------------------

# A tree of its own, on the ungated track, with a real long-running container:
# the only way to observe a restart is to have something running to restart.
#
# **No schema**, and that is what keeps the start from refusing: a key the
# schema marks `@required` becomes a `Secret=` request, and on an ungated track
# nothing plants a value for a key that is not `@sensitive` — so the manifest
# names no schema and the tree carries none.
own=$(stage_tree "$staging/restart/0000001" "$fixtures/solo")
rm -f "$own/.guarden/.env.schema"
seed "$own/.guarden/service.yml" "project: restart" "units: .guarden/quadlet/"
seed "$own/.guarden/quadlet/app.container" \
    "[Container]" "Image=docker.io/library/alpine:3.20" "Exec=sleep 3600"

run weedr service ingest restart-staging --from poke restart@0000001
assert_exit 0
assert_no_error

# The unit's own activation, from systemd rather than from the deploy's report.
started() {
    systemctl --user --machine restart-staging@ show app.service \
        -p ActiveEnterTimestampMonotonic 2>/dev/null | cut -d= -f2
}

# **The question `furrow` asks before it stops anything**, on its own: the tree
# the service is at answers `converged` and exits 0; a tree it is not at answers
# exit 1 and changes nothing.
before_check=$(sha256sum "$registry/restart-staging.toml" | cut -d' ' -f1)
run weedr service ingest restart-staging --from poke restart@0000001 --check
assert_exit 0
assert_stdout_has "converged"
cp -a "$staging/restart/0000001" "$staging/restart/0000002"
say "$staging/restart/0000002/.guarden/quadlet/app.container" "Exec=sleep 1800"
run weedr service ingest restart-staging --from poke restart@0000002 --check
assert_exit 1
assert_stdout_has "restart-staging would deploy"
[ "$(sha256sum "$registry/restart-staging.toml" | cut -d' ' -f1)" = "$before_check" ] \
    || _fail "a --check wrote the service's record"

# The first deploy of an installed but never-started service starts it, and says
# that nothing about the tree changed — which is what a converged deploy of a
# stopped service is.
run furrow deploy restart-staging --from poke restart@0000001
assert_exit 0
assert_no_error
assert_stdout_has "unchanged restart-staging at 0000001"
first=$(started)
[ -n "$first" ] || _fail "restart-staging's app.service has no ActiveEnterTimestampMonotonic"
[ "$first" != 0 ] || _fail "a deploy of an installed service never started it"

# The poke again, unchanged: no stop, no render, nothing to build, and the
# container is the same activation it was — measured, not reported.
run furrow deploy restart-staging --from poke restart@0000001
assert_exit 0
assert_no_error
assert_stdout_has "unchanged restart-staging at 0000001"
if grep -qE '^stop +restart-staging' "$GUARDEN_STDOUT"; then
    _fail "an unchanged app was stopped: $(grep -E '^stop +restart-staging' "$GUARDEN_STDOUT")"
fi
second=$(started)
[ "$second" = "$first" ] \
    || _fail "an unchanged app was restarted: ActiveEnterTimestampMonotonic $first then $second"

# **The control, and it is what makes the line above an assertion at all.** A
# restart the operator asks for moves the number the second poke did not.
run weedr service restart restart-staging
assert_exit 0
third=$(started)
[ "$third" != "$first" ] \
    || _fail "a restart did not change ActiveEnterTimestampMonotonic ($first then $third), so the check above measures nothing"

echo "MEASURE: an unchanged poke left the activation at $first; a restart moved it to $third"
