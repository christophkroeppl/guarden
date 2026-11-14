#!/usr/bin/env bash
# Ticket 307e — option B: the deployed_sha is written after the build succeeds.
#
# **What is asserted.** A failed build never reaches the commit step, so the
# record never claims a sha that did not run. The commit is a separate verb
# (`weedr service commit`) that runs after the build and the gate, in its own
# subprocess, so it takes the `registry` lock without holding `deploy-<service>`.
#
# Two facts, in the order they are measured:
#
#   1. a first deploy records the sha it actually deployed;
#   2. a nudge (empty commit, same tree, new sha) updates the record to the
#      sha the deploy reports — not the one the first deploy wrote.
#
# machine: fresh

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GUARDEN_PREFIX=/

registry=/var/lib/guarden/registry
staging=/var/lib/guarden/staging
fixtures=$GUARDEN_ROOT/fixtures/projects

project_for() {
    seed /etc/guarden/projects.d/"$1".toml \
        "[projects.$1]" \
        "repository = \"git@github.com:you/$1.git\"" \
        "environments = { $2 }"
    chmod 0444 /etc/guarden/projects.d/"$1".toml
}

tar_tree() {
    local out=$GUARDEN_FIXTURES/$(basename "$1").tar
    tar -C "$1" -cf "$out" .
    printf '%s\n' "$out"
}

cleanup() {
    local rc=0
    purge solo-production || rc=1
    rm -f /var/lib/guarden/queue/solo-*.json
    rm -f /etc/guarden/projects.d/solo.toml
    rm -rf "$staging/solo"
    assert_no_service_left solo-production || rc=1
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

assert_no_error() {
    assert_stderr_lacks "error:"
}

project_for solo '"main" = ["production"]'

# --- 1. a first deploy records the sha it actually deployed ------------------

solo_tar=$(tar_tree "$fixtures/solo")
run hose --project solo poke main 1a2b3c4 <"$solo_tar"
assert_exit 0
assert_no_error
assert_file_has "$registry/solo-production.toml" 'deployed_sha = "1a2b3c4"'
run weedr service list --json
assert_exit 0
assert_json 'services.0.deployed_sha' '"1a2b3c4"'

# --- 2. a nudge (empty commit, same tree, new sha) updates deployed_sha -------

nudge_tar=$(tar_tree "$fixtures/solo")
run hose --project solo poke main 5d6e7f8 <"$nudge_tar"
assert_exit 0
assert_no_error
assert_file_has "$registry/solo-production.toml" 'deployed_sha = "5d6e7f8"'
run weedr service list --json
assert_exit 0
assert_json 'services.0.deployed_sha' '"5d6e7f8"'
