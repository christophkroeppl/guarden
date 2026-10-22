#!/usr/bin/env bash
# A poke records the commit it deployed, and the only "is this a no-op" answer on
# the deploy path is `weedr service ingest --check`.
#
# **What was false.** `hose` answered "this sha is already deployed" out of the
# registry before it unpacked anything, and the field it read — `deployed_sha` —
# was written by no code path in the tree. So the short-circuit could not fire,
# `weedr service list --json` reported `deployed_sha: null` for every service on
# every host, and on a repository that ships several apps (ADR-0028) the name it
# looked up, `<project>-<environment>`, is a record no deploy ever writes.
#
# **What is asserted instead.** The receiver asks nothing: every poke unpacks its
# tree, and `furrow` asks the mutator's own convergence question once per app,
# before the destructive step. The sha lands in the record as a REPORT — the
# commit the record's tree came from — and never as a decision, because a sha is
# the caller's claim and the tree on disk is not checked against it (ticket 297).
#
# Four facts, in the order they are measured:
#
#   1. a poke through `hose` writes `deployed_sha`, and `weedr service list
#      --json` reports the commit that was deployed;
#   2. a second poke of the same sha and the same tree answers `unchanged` — and
#      it UNPACKED first, which is what a short-circuit would have skipped;
#   3. a poke of that same sha with the tree EDITED still deploys (ticket 297),
#      and the home carries the edit;
#   4. a re-poke of a three-app repository is answered per app, so the question is
#      asked of `<project>-<app>-<environment>` and never of a project-level
#      service that does not exist.
#
# machine: fresh

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GUARDEN_PREFIX=/

registry=/var/lib/guarden/registry
homes=/var/lib/guarden/services
staging=/var/lib/guarden/staging
fixtures=$GUARDEN_ROOT/fixtures/projects

services="poked-staging shop-web-production shop-api-production \
shop-worker-api-production"

cleanup() {
    local rc=0
    purge $services || rc=1
    rm -f /var/lib/guarden/queue/poked-*.json
    rm -f /var/lib/guarden/queue/shop-*.json
    rm -f /etc/guarden/projects.d/poked.toml /etc/guarden/projects.d/shop.toml
    rm -rf "$staging/poked" "$staging/shop"
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

# `assert_no_error` rather than `assert_stderr_empty`: the golden carries
# `/etc/guarden/firewall/50-services.conf` while `guarden-firewall.service` is not
# installed, so every render of the uid-matched filter set says so with one
# `warning:`, and that is a fact about this machine rather than about the poke.
assert_no_error() {
    assert_stderr_lacks "error:"
}

# project_for <name> <environments>: a project the receiver may deploy, written
# the way `weedr project add` writes it — `0444` and root-owned.
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

# stage_tree <directory> <fixture>: a staged tree of this suite's own.
stage_tree() {
    rm -rf "$1"
    mkdir -p "$1"
    cp -a "$2/." "$1/"
    printf '%s\n' "$1"
}

# --- 1. a poke writes the sha it deployed ------------------------------------

project_for poked '"main" = ["production"], "develop" = ["staging"]'

own=$(stage_tree "$GUARDEN_FIXTURES/poked" "$fixtures/solo")
rm -f "$own/.guarden/.env.schema"
seed "$own/.guarden/service.yml" "project: poked" "units: .guarden/quadlet/"
seed "$own/.guarden/quadlet/app.container" \
    "[Container]" "Image=docker.io/library/alpine:3.20" "Exec=sleep 3600"

tree_tar=$(tar_tree "$own")
run hose --project poked poke develop 0000001 <"$tree_tar"
assert_exit 0
assert_no_error

# The writer exists: the record names the commit, and the report repeats it.
assert_file_has "$registry/poked-staging.toml" 'deployed_sha = "0000001"'
run weedr service list --json
assert_exit 0
assert_json services.0.name '"poked-staging"'
assert_json services.0.deployed_sha '"0000001"'

assert_file_has "$homes/poked-staging/home/.guarden/quadlet/app.container" "Exec=sleep 3600"

# --- 2. the same sha and the same tree is a no-op, and it unpacked -----------

run hose --project poked poke develop 0000001 <"$tree_tar"
assert_exit 0
assert_no_error
# **The unpacked line is the assertion a short-circuit cannot pass**: a poke that
# answered "already at" from the record would never have read the archive, and
# the tree it did not read is the thing the convergence question is about.
assert_stdout_has "unpacked "
assert_stdout_has "unchanged poked-staging at 0000001"
assert_stdout_lacks "already at"

# --- 3. an edited tree under the same sha still deploys (ticket 297) ---------

seed "$own/.guarden/quadlet/app.container" \
    "[Container]" "Image=docker.io/library/alpine:3.20" "Exec=sleep 1800"
edited_tar=$(tar_tree "$own")
run hose --project poked poke develop 0000001 <"$edited_tar"
assert_exit 0
assert_no_error
assert_stdout_has "unpacked "
assert_stdout_has "deployed poked-staging at 0000001"
assert_stdout_lacks "unchanged poked-staging at 0000001"
# The tree on disk moved, which is what "deployed" has to mean, and the record
# still names the commit the client claimed — a report, not a verdict.
assert_file_has "$homes/poked-staging/home/.guarden/quadlet/app.container" "Exec=sleep 1800"
assert_file_has "$registry/poked-staging.toml" 'deployed_sha = "0000001"'

# --- 4. a three-app repository is asked once per app -------------------------

project_for shop '"main" = ["production"]'
multi_tar=$(tar_tree "$fixtures/multi")
run hose --project shop poke main 9f2c1ab <"$multi_tar"
assert_exit 0
assert_no_error
assert_file_exists "$registry/shop-web-production.toml"
assert_file_exists "$registry/shop-api-production.toml"
assert_file_exists "$registry/shop-worker-api-production.toml"
# A blocked gate stops the START, not the install: the commit is recorded anyway.
assert_file_has "$registry/shop-web-production.toml" 'deployed_sha = "9f2c1ab"'

run hose --project shop poke main 9f2c1ab <"$multi_tar"
assert_exit 0
assert_no_error
assert_stdout_has "render  shop-web-production (app apps/web): nothing changed, so nothing to render"
assert_stdout_has "render  shop-api-production (app apps/api): nothing changed, so nothing to render"
assert_stdout_has "render  shop-worker-api-production (app apps/worker-api): nothing changed, so nothing to render"
assert_stdout_lacks "already at"
