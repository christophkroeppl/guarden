#!/usr/bin/env bash
# ADR-0019's probe, where it refuses: two images whose declared user cannot
# become a keep-id line, each with the exit code the failure actually is.
#
#   * `USER nosuchuser` — the image runs, its `/etc/passwd` does not name the
#     user it declares, so the declaration is rejected input: exit `2`, one
#     line, naming the service and the user, and never a traceback from inside
#     the resolver.
#   * an image that is not in the service user's store and cannot be pulled —
#     the filesystem, not an argument: exit `1`, one line, naming the service
#     and the reference.
#
# Both are asserted on the verb that promises a start, because that is where an
# operator meets them: `weedr service start` refuses with the probe's own
# diagnostic rather than starting a container that cannot write, and nothing is
# printed for a start that did not happen.
#
# The positive half is last: a name that the image's passwd DOES carry is
# resolved inside the image, and the rendered line carries the uid and gid that
# file names — the same resolution these two failures are the edges of.
#
# Real host, real rootless podman: `GUARDEN_PREFIX=/`, as `t230-build` does.

# machine: fresh

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GUARDEN_PREFIX=/

registry=/var/lib/guarden/registry

ensure_accounts
stage_config guarden-nomodules.toml
stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_exit 0

# stage_kid <project> <image> <Containerfile lines...>: a staged tree with a
# unit that declares the local image, plus the Containerfile that builds it.
# `none` in the first line's place plants no Containerfile at all — the shape
# of a service whose image exists only in a registry, and for this one, nowhere
# at all.
stage_kid() {
    local project=$1 image=$2
    shift 2
    local staged=/var/lib/guarden/staging/$project/0000001
    rm -rf "$staged"
    mkdir -p "$staged/.guarden/quadlet"
    seed "$staged/.guarden/service.yml" \
        "project: $project" \
        "units: .guarden/quadlet/"
    seed "$staged/.guarden/quadlet/app.container" \
        "[Unit]" \
        "Description=the keep-id probe subject" \
        "" \
        "[Container]" \
        "Image=$image"
    if [ "$1" != "none" ]; then
        seed "$staged/Containerfile" "$@"
    fi
}

# --- a user the image does not name: rejected input --------------------------

stage_kid kidc localhost/kidbad-staging:latest \
    "FROM docker.io/library/alpine:3.20" \
    "USER nosuchuser" \
    "CMD [\"sleep\", \"3600\"]"
run weedr service ingest kidbad-staging --from poke kidc@0000001
assert_exit 0
run weedr service build kidbad-staging
assert_exit 0

run weedr service start kidbad-staging
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "kidbad-staging"
assert_stderr_has "nosuchuser"
assert_stdout_lacks "started kidbad-staging"

# --- an image that is not on the host: the host, not the argument ------------

stage_kid kidd localhost/kidnone-staging:latest none
run weedr service ingest kidnone-staging --from poke kidd@0000001
assert_exit 0

run weedr service start kidnone-staging
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "kidnone-staging"
assert_stderr_has "kidnone-staging:latest"
assert_stdout_lacks "started kidnone-staging"

# --- a name the image's passwd carries: resolved inside the image ------------

stage_kid kidb localhost/kidname-staging:latest \
    "FROM docker.io/library/alpine:3.20" \
    "USER daemon" \
    "CMD [\"sleep\", \"3600\"]"
run weedr service ingest kidname-staging --from poke kidb@0000001
assert_exit 0
run weedr service build kidname-staging
assert_exit 0

home_b=/var/lib/guarden/services/kidname-staging/home
unit_b=$home_b/.config/containers/systemd/app.container
record_b=$registry/kidname-staging.toml

run weedr service start kidname-staging
assert_exit 0

# The runtime dir the passwd probe below points podman at, waited for the way
# t350 waits: linger starts the manager, and it comes up on its own.
runtime_b=/run/user/"$(id -u kidname-staging)"
for _ in $(seq 1 30); do
    [ -d "$runtime_b" ] && break
    sleep 1
done

# The line carries the uid and gid the image's own /etc/passwd names for
# `daemon` — read straight out of the image by running it, rather than assumed
# from any knowledge guarden has.
run_in "$home_b" setpriv --reuid=kidname-staging --regid=kidname-staging \
    --clear-groups env -u OLDPWD HOME="$home_b" PWD="$home_b" XDG_RUNTIME_DIR="$runtime_b" \
    podman run --rm --user 0 --entrypoint cat localhost/kidname-staging:latest /etc/passwd
assert_exit 0
daemon_line=$(grep "^daemon:" "$GUARDEN_STDOUT" || true)
[ -n "$daemon_line" ] || _fail "the image's passwd names no daemon user to resolve against"
daemon_uid=$(printf '%s\n' "$daemon_line" | cut -d: -f3)
daemon_gid=$(printf '%s\n' "$daemon_line" | cut -d: -f4)
assert_file_has "$unit_b" "UserNS=keep-id:uid=$daemon_uid,gid=$daemon_gid"
assert_file_has "$record_b" "owner_uid = $daemon_uid"
assert_file_has "$record_b" "owner_gid = $daemon_gid"

# --- an image that declares no user: the entrypoint's own handoff -----------
#
# The stock postgres shape: `Config.User` empty, and the app account the
# entrypoint would gosu to. The pin comes from the words of the script, the
# image's passwd only resolves them, and the root branch of that script is
# exactly what the pin makes unreachable: init is forced to the pinned uid, so
# `id -u` is never 0 and the gosu line — which alpine does not even ship —
# never runs. A passwd row on its own would never have found `appuser` here.
stage_kid kidgosu localhost/kidgosu-staging:latest \
    "FROM docker.io/library/alpine:3.20" \
    "RUN adduser -D -u 2000 appuser" \
    "ADD .guarden/entry.sh /entry.sh" \
    "RUN chmod +x /entry.sh" \
    "ENTRYPOINT [\"/entry.sh\"]"
seed /var/lib/guarden/staging/kidgosu/0000001/.guarden/entry.sh \
    '#!/bin/sh' \
    'if [ x$(id -u) = x0 ] ; then exec gosu appuser /entry.sh ; fi' \
    'exec sleep 3600'
run weedr service ingest kidgosu-staging --from poke kidgosu@0000001
assert_exit 0
run weedr service build kidgosu-staging
assert_exit 0

run weedr service start kidgosu-staging
assert_exit 0
unit_g=/var/lib/guarden/services/kidgosu-staging/home/.config/containers/systemd/app.container
record_g=$registry/kidgosu-staging.toml
assert_file_has "$unit_g" "UserNS=keep-id:uid=2000,gid=2000"
assert_file_has "$record_g" "owner_uid = 2000"
assert_file_has "$record_g" "owner_gid = 2000"

# --- a repository's own `User=`, which would silently outrun the pin ---------
#
# An explicit `--user` beats keep-id's init-forcing, so a source that sets
# `User=` would run the container outside the mapping the line exists to
# create — with nothing in the run saying so. Refused where the start would
# apply the pin: exit 2, one line, naming the service, the key and the value,
# and no start at all. With no pin this field passes through as it always
# has; this service's image declares a non-root user, which is what puts a pin
# in force.
stage_kid kiduser localhost/kiduser-staging:latest \
    "FROM docker.io/library/alpine:3.20" \
    "USER daemon"
printf '%s\n' "User=4242" >> /var/lib/guarden/staging/kiduser/0000001/.guarden/quadlet/app.container
run weedr service ingest kiduser-staging --from poke kiduser@0000001
assert_exit 0
run weedr service build kiduser-staging
assert_exit 0

run weedr service start kiduser-staging
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "kiduser-staging"
assert_stderr_has "User="
assert_stderr_has "4242"
assert_stdout_lacks "started kiduser-staging"
