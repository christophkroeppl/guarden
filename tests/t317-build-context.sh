#!/usr/bin/env bash
# The build context is the whole staged tree, not four files (ticket 317).
#
# **What was false.** `weedr service build` ran `podman build` with the
# service's home as its context, and the home held only `.guarden/`,
# `compose.yaml`, `Containerfile` and `.dockerignore` — so a Containerfile
# whose `COPY` names a source file (`COPY Cargo.toml Cargo.lock ./`) died with
# `error: podman build exited 125: ... no such file or directory`, even though
# the poke's staged tree held the very files it named.
#
# **What this asserts, on the machine and not in the source.** A staged tree
# that carries a source file beside its Containerfile, a Containerfile that
# COPYs that file, and a build that finishes with the file INSIDE the image.
# The assertion reads the image's own contents, because a suite that grepped
# the program for a string would be asserting that the source reads like the
# fix rather than that the fix works.
#
# Three cases, each a different way the tree reaches the context:
#
#   1. a source file OUTSIDE the four-file set (`Cargo.toml`) is COPYed by the
#      Containerfile: the build succeeds and the image carries the file. This
#      is the ticket's own case and it is the one that was red.
#   2. a file the SOURCE's own `.dockerignore` excludes is NOT in the image:
#      the source owns what the build does not see (spec 6.6).
#   3. the podman image store — which holds the per-user secret database —
#      is NOT in the image, even though the repository shipped no ignore file
#      at all: guarden writes the exclusion itself, because the repository's
#      `.dockerignore` may be absent, and a context carrying the credential
#      material leaks it into an image layer.
#
# Real host, real useradd, real subuid, real linger, real podman: the verb
# runs `podman build` as the service user, and a stand-in would be asserting
# its own fake. `GUARDEN_PREFIX=/`, as `t230-build` does.
#
# The Containerfile is `FROM scratch`: no base image is pulled, so the build
# measures the context and not the network.

# machine: fresh

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GUARDEN_PREFIX=/

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
    local failed=0 service
    remove_snapper_configs "$@" || failed=1
    for service in "$@"; do
        rm -rf "/var/lib/guarden/services/$service" "/etc/guarden/services/$service" \
            "$creds/$service" "$registry/$service.toml" || failed=1
        userdel "$service" >/dev/null 2>&1 || :
    done
    assert_no_snapper_configs "$@" || failed=1
    [ "$failed" = 0 ] || { _fail "purge could not remove every path of: $*"; return 1; }
}

cleanup() {
    purge ctxapp-staging ctxignore-staging ctxboth-staging ctxstore-staging \
        ctxsrc-production ctxdst-staging
}
trap cleanup EXIT

cleanup

# stage_ctx <project> <service> <sha> <file> <line>...: a staged tree with a
# unit that declares the local image, a Containerfile, and one source file
# beside them.
#
# The staged tree is where a poke's source lands (`/var/lib/guarden/staging`),
# and it is the tree `weedr service ingest` copies into the service's home —
# so a file planted here is a file the repository shipped.
#
# **The unit declares the SERVICE's own reference**, because that is what the
# build tags: spec 6.6 step 2 says the image is tagged with the reference the
# unit source declares, and `weedr service build` prints that reference. A
# unit declaring some other reference would have the build tag that one, and
# the suite would be asserting about an image nobody built.
stage_ctx() {
    local project=$1 service=$2 sha=$3 file=$4
    shift 4
    local staged=/var/lib/guarden/staging/$project/$sha
    rm -rf "$staged"
    mkdir -p "$staged/.guarden/quadlet"
    seed "$staged/.guarden/service.yml" \
        "project: $project" \
        "units: .guarden/quadlet/"
    seed "$staged/.guarden/quadlet/app.container" \
        "[Unit]" \
        "Description=the build context subject" \
        "" \
        "[Container]" \
        "Image=localhost/$service:latest"
    seed "$staged/Containerfile" "FROM scratch" "COPY $file /copied"
    seed "$staged/$file" "$@"
}

# podman_as <service> <podman args...>: podman as the service user.
#
# The shape `t350-keepid.sh` established and measured: `setpriv` with the
# service's own uid and gid, `HOME` named for the service's home, and `USER`
# and `LOGNAME` named for the service — `runuser`/`setpriv` keep the CALLER's
# environment and the caller is root, and with USER=root podman's keep-id
# mapping reads the subid files keyed by that name, finds none, and produces a
# map crun refuses to init.
podman_as() {
    local service=$1 home uid
    shift
    home=/var/lib/guarden/services/$service/home
    uid=$(id -u "$service")
    run_in "$home" setpriv --reuid="$service" --regid="$service" --clear-groups \
        env -u OLDPWD HOME="$home" PWD="$home" USER="$service" LOGNAME="$service" \
        XDG_RUNTIME_DIR="/run/user/$uid" podman "$@"
}

# image_lists <service>: the image's own contents, one path per line, in
# GUARDEN_STDOUT.
#
# The image is exported and the tarball listed, which is the image's contents
# and not a rendering of them. `podman export` needs a container, so one is
# created from the image and removed again.
#
# **The listing is the LAST thing written to stdout.** Every `run` and
# `run_in` captures into the same two files and OVERWRITES them, so a helper
# that cleaned up after itself left the cleanup's (empty) stdout in place and
# the caller's assertion read that instead of the listing.
image_lists() {
    local service=$1
    podman_as "$service" create --name "t317-$service" "localhost/$service:latest"
    assert_exit 0
    podman_as "$service" export --output "/tmp/t317-$service.tar" "t317-$service"
    assert_exit 0
    podman_as "$service" rm -f "t317-$service"
    run_in /tmp tar -tf "/tmp/t317-$service.tar"
    assert_exit 0
}

# --- Case 1: a source file outside the four-file set reaches the context ----
#
# This is the ticket's own case. The Containerfile COPYs `Cargo.toml`, which
# is not `.guarden/`, not `compose.yaml`, not `Containerfile` and not
# `.dockerignore` — so under the old four-file copy the build died with 125
# and the service never had an image.

stage_ctx ctxapp ctxapp-staging 9f2c1ab Cargo.toml '[package]' 'name = "ctxapp"'
run weedr service ingest ctxapp-staging --from poke ctxapp@9f2c1ab
assert_exit 0

# the premise: the file is in the staged tree and the Containerfile names it
assert_file_has "/var/lib/guarden/staging/ctxapp/9f2c1ab/Cargo.toml" 'name = "ctxapp"'
assert_file_has "/var/lib/guarden/staging/ctxapp/9f2c1ab/Containerfile" "COPY Cargo.toml /copied"

run weedr service build ctxapp-staging
assert_exit 0
assert_stdout_has "localhost/ctxapp-staging:latest"

# the outcome: the image exists, and the COPY landed — the file is IN the
# image, which is the fact the old build could not produce
image_lists ctxapp-staging
assert_stdout_has "copied"

# --- Case 2: the source's own ignore file narrows what the build sees ------
#
# The spec says the source's own ignore file decides what the build does not
# see. A file the source excludes is not in the image.
#
# **The Containerfile copies the whole tree**, so the build SUCCEEDS and the
# assertion is on the image's contents. A Containerfile that copied the
# excluded file would fail the build instead, which shows the exclusion
# holding but says nothing about the image — and the question here is what the
# image carries.

stage_ctx ctxignore ctxignore-staging 9f2c1ab Cargo.toml '[package]' 'name = "ctxignore"'
seed /var/lib/guarden/staging/ctxignore/9f2c1ab/.dockerignore "Cargo.toml"
# the whole tree is copied, so the build succeeds and the image is readable
seed /var/lib/guarden/staging/ctxignore/9f2c1ab/Containerfile \
    "FROM scratch" "COPY . /all"
run weedr service ingest ctxignore-staging --from poke ctxignore@9f2c1ab
assert_exit 0

run weedr service build ctxignore-staging
assert_exit 0
assert_stdout_has "localhost/ctxignore-staging:latest"

# the source's own exclusion holds: the file it names is not in the image,
# and the rest of the tree is
image_lists ctxignore-staging
assert_stdout_lacks "all/Cargo.toml"
assert_stdout_has "all/Containerfile"

# --- Case 2b: the source's narrowing survives guarden's own file -------------
#
# **This is the case that caught a real bug.** Podman reads `.containerignore`
# in preference to `.dockerignore` and never consults the second when the
# first is present (measured on podman 5.7.0). Guarden writes BOTH names so
# that its exclusion is always read -- but a first version wrote only
# guarden's block into the `.containerignore` and kept the source's patterns
# in the `.dockerignore`, and a source's own `.containerignore` was then
# OVERWRITTEN: its narrowing was silently dropped and the file it excluded
# went into the image.
#
# So the source's patterns must reach BOTH names. The case is here because it
# is the one that can pass while case 2 passes: case 2's source ships a
# `.dockerignore`, and podman reads the `.containerignore` guarden wrote
# beside it — so the two are indistinguishable until the source ships the
# name podman prefers.

stage_ctx ctxboth ctxboth-staging 9f2c1ab Cargo.toml '[package]' 'name = "ctxboth"'
seed /var/lib/guarden/staging/ctxboth/9f2c1ab/.containerignore "Cargo.toml"
seed /var/lib/guarden/staging/ctxboth/9f2c1ab/Containerfile \
    "FROM scratch" "COPY . /all"
run weedr service ingest ctxboth-staging --from poke ctxboth@9f2c1ab
assert_exit 0

run weedr service build ctxboth-staging
assert_exit 0

# the source's own exclusion holds even though guarden wrote a
# `.dockerignore` beside it — and the file podman prefers, the one the source
# shipped, is the one that decides
image_lists ctxboth-staging
assert_stdout_lacks "all/Cargo.toml"
assert_stdout_has "all/Containerfile"

# --- Case 3: the podman store is never in the context ----------------------
#
# Guarden writes the exclusion itself, because the repository's ignore file
# may be absent — and this tree ships NONE. The home's podman store holds the
# per-user secret database in cleartext, and a context carrying it leaks the
# credential material into an image layer.
#
# The assertion is on the IMAGE, not on the home: the store is in the home
# either way, and only the image says whether the build saw it. And the
# Containerfile here COPYs the whole tree, because a store that only a named
# file's COPY would have missed is not in the context at all — `COPY .` is
# what puts the store in the image, and it is what the exclusion has to stop.
#
# **The store is created BY the build**, so the premise is asserted after it:
# podman writes its image store into the home as it builds, and the store is
# therefore in the home the build read — which is the whole of what makes the
# exclusion load-bearing. A store that were never there would make the
# assertion below true for the wrong reason.

stage_ctx ctxstore ctxstore-staging 9f2c1ab Cargo.toml '[package]' 'name = "ctxstore"'
# the Containerfile copies the whole tree, so the store is a candidate
seed /var/lib/guarden/staging/ctxstore/9f2c1ab/Containerfile \
    "FROM scratch" "COPY . /all"
run weedr service ingest ctxstore-staging --from poke ctxstore@9f2c1ab
assert_exit 0

run weedr service build ctxstore-staging
assert_exit 0
assert_stdout_has "localhost/ctxstore-staging:latest"

# the premise: the build put podman's store in the home, so the store WAS in
# the context the build read
assert_file_exists "/var/lib/guarden/services/ctxstore-staging/home/.local/share/containers"

# and it is not in the image
image_lists ctxstore-staging
assert_stdout_lacks "all/.local/share/containers"

# and the source file the Containerfile named IS in the image, so the
# exclusion did not exclude everything
assert_stdout_has "all/Cargo.toml"

# --- Case 4: a whole-tree copy carries no other service's credentials ------
#
# **The copy's exclusions are not the ignore file's.** The ignore file keeps
# the store out of the BUILD; the copy keeps it out of the HOME, and the two
# are different questions. The copy's case is `weedr service add --from
# <service>`: the source is ANOTHER SERVICE'S HOME, so it carries that
# service's podman store — and the store holds the per-user secret database
# in cleartext. A whole-tree copy without the exclusion would write another
# service's credential material into the new home.
#
# The premise is planted rather than hoped for: the source service's store
# and its secret database are written by hand, because a service that has
# never built anything has no store and the case would be vacuous.

stage_poke myapp 9f2c1ab
run weedr service ingest ctxsrc-production --from poke myapp@9f2c1ab
assert_exit 0

seed "/var/lib/guarden/services/ctxsrc-production/home/.local/share/containers/storage/secrets/secrets.json" \
    "THE-SECRET-VALUE"
run chown -R ctxsrc-production:ctxsrc-production \
    /var/lib/guarden/services/ctxsrc-production/home/.local/share
assert_file_has \
    "/var/lib/guarden/services/ctxsrc-production/home/.local/share/containers/storage/secrets/secrets.json" \
    "THE-SECRET-VALUE"

run weedr service add ctxdst-staging --from ctxsrc-production
assert_exit 0

# the destination holds no secret database of the source's
assert_file_missing \
    "/var/lib/guarden/services/ctxdst-staging/home/.local/share/containers/storage/secrets/secrets.json"

# and the source's own is untouched
assert_file_has \
    "/var/lib/guarden/services/ctxsrc-production/home/.local/share/containers/storage/secrets/secrets.json" \
    "THE-SECRET-VALUE"
