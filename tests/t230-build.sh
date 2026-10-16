#!/usr/bin/env bash
# The build verb's own contract (spec 6.6 step 2): a service whose unit source
# declares an image AND whose home carries a Containerfile is built and tagged
# with the declared reference; a service whose home has no Containerfile is
# skipped, because there is nothing to build.
#
# Three cases, each asserted where the fact lands:
#
#   1. a name with no registry entry is refused — a refusal is not a skip, and
#      its own diagnostic says which of the two it is;
#   2. an ingested service whose home has no Containerfile is skipped: exit 1,
#      one diagnostic naming the service, no reference on stdout, and the
#      declared image absent from the service user's own podman store — nothing
#      was built;
#   3. the same poke, with a Containerfile dropped into the home, is built: the
#      verb prints each declared reference, one per line, and both images are in
#      the service user's store under the declared references — not under the
#      local `localhost/<service>` fallback a build with no declared image
#      would have tagged. This is the regression: the old verb read "an image
#      is declared" as "this is a pull" and skipped the only shape guarden
#      allows, a unit that declares `Image=` AND a home that carries the
#      Containerfile.
#
# Real host, real useradd, real subuid, real linger, real podman: the verb
# runs `podman build` as the service user, and a stand-in would be asserting
# its own fake. `GUARDEN_PREFIX=/`, as `t80-edges` and `t130-alias` do.
#
# The Containerfile is `FROM scratch` and COPYs one unit file: no base image
# is pulled, so the build measures the verb and not the network.

# machine: fresh

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GUARDEN_PREFIX=/

config=/etc/guarden/guarden.toml
registry=/var/lib/guarden/registry
creds=/etc/guarden/creds

ensure_accounts
stage_config guarden-measured.toml
stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_exit 0

# podman is the machine the build runs on: its absence is the name of a
# failure, not a failure mode of the verb.
run podman --version
assert_exit 0
assert_stdout_has "podman version"

purge() {
    for service in "$@"; do
        rm -rf "/var/lib/guarden/services/$service" "/etc/guarden/services/$service" \
            "$creds/$service" "$registry/$service.toml"
        userdel "$service" >/dev/null 2>&1 || :
    done
}

cleanup() {
    # the images this build tagged, out of the service user's own store
    runuser -u built-app-production -- env -C /tmp podman rmi \
        docker.io/library/nginx:1.27 docker.io/library/alpine:3.20 >/dev/null 2>&1 || :
    purge built-app-production plain-app-staging
}
trap cleanup EXIT

cleanup

# Case 1: no registry entry — refused, with a diagnostic of its own.

run weedr service build ghost-staging
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "ghost-staging"
assert_stderr_has "has no registry entry"
assert_stdout_empty

# Case 2: no Containerfile in the home — skipped, and nothing is built.

# The provider this project declares an edge on, staged and ingested first: its
# registry entry is what the edge check reads, and without it the ingest below
# is refused for a reason that has nothing to do with the build (t100-homepage
# and t120-deploy stage the same provider for the same reason).
stage_poke pgprov 9f2c1ab
run weedr service ingest postgres-staging --from poke pgprov@9f2c1ab
assert_exit 0

stage_poke quadlet-app 9f2c1ab
run weedr service ingest plain-app-staging --from poke quadlet-app@9f2c1ab
assert_exit 0
# the premise: the unit declares an image, and the home carries no
# Containerfile, so there is nothing to build
assert_file_has "/var/lib/guarden/services/plain-app-staging/home/.guarden/quadlet/web.container" \
    "Image=docker.io/library/nginx:1.27"
assert_file_missing "/var/lib/guarden/services/plain-app-staging/home/Containerfile"

run weedr service build plain-app-staging
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "plain-app-staging"
assert_stderr_has "no unit source with a build instruction"
assert_stdout_empty

# nothing was built: the declared image is not in the service user's own store.
# podman inspect answers a missing image with `image not known` (exit 125 on
# this version), so the diagnostic is asserted rather than the exit code
run runuser -u plain-app-staging -- env -C /tmp podman image inspect \
    docker.io/library/nginx:1.27
assert_stderr_has "image not known"

# Case 3: the same poke, with a Containerfile in the home — built and tagged.
# The production track, because a route host is allocated at ingest and a
# second staging service of this project would claim the same `staging.web`.

stage_poke quadlet-app 7d3e5f1
run weedr service ingest built-app-production --from poke quadlet-app@7d3e5f1
assert_exit 0

# the build runs as the service user: these are the machine facts that make a
# rootless podman possible, asserted here so their absence is diagnosable
assert_passwd built-app-production
assert_linger built-app-production
run grep -c "^built-app-production:" /etc/subuid
assert_exit 0
assert_stdout_has "1"

# the premise the old verb got wrong: the unit declares an image …
assert_file_has "/var/lib/guarden/services/built-app-production/home/.guarden/quadlet/web.container" \
    "Image=docker.io/library/nginx:1.27"
assert_file_has "/var/lib/guarden/services/built-app-production/home/.guarden/quadlet/worker.container" \
    "Image=docker.io/library/alpine:3.20"
# … and the home carries the Containerfile that says "build me"
seed "/var/lib/guarden/services/built-app-production/home/Containerfile" \
    "FROM scratch" "COPY .guarden/quadlet/web.container /unit"

run weedr service build built-app-production
assert_exit 0
# one reference per line, and each is the declared one
assert_stdout_lines 2
assert_stdout_has "docker.io/library/nginx:1.27"
assert_stdout_has "docker.io/library/alpine:3.20"
# not the local fallback a build with no declared image would have tagged
assert_stdout_lacks "localhost/built-app-production"

# the images are in the service user's own store, under the declared references
run runuser -u built-app-production -- env -C /tmp podman image inspect \
    docker.io/library/nginx:1.27
assert_exit 0
run runuser -u built-app-production -- env -C /tmp podman image inspect \
    docker.io/library/alpine:3.20
assert_exit 0
