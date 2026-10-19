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

# podman_as <service> <podman args...>: podman as the service user, with USER
# and LOGNAME named for the service — `runuser`/`setpriv` keep the CALLER's
# environment and the caller is root, and podman's keep-id mapping reads the
# subid files keyed by USER (the shape t350 and t352 drive the machine's
# answers with).
podman_as() {
    local service=$1 home uid
    shift
    home=/var/lib/guarden/services/$service/home
    uid=$(id -u "$service")
    run_in "$home" setpriv --reuid="$service" --regid="$service" --clear-groups \
        env -u OLDPWD HOME="$home" PWD="$home" USER="$service" LOGNAME="$service" \
        XDG_RUNTIME_DIR="/run/user/$uid" podman "$@"
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
# image's passwd only resolves them, and a passwd row on its own would never
# have found `appuser` here.
#
# What runs in it, read off pid 1 below: a pin decides where a uid LANDS and
# does not override the image's `USER` — the entrypoint starts as container
# root on this row too, so the script's `id -u = 0` branch is the branch it
# takes. It is guarded by gosu's own absence for the same reason t352's root
# fixture guards it: alpine ships no gosu, and the fixture exists for the pin
# the probe renders and for the pid 1 that says which doctrine is true — not
# for a handoff it cannot complete.
stage_kid kidgosu localhost/kidgosu-staging:latest \
    "FROM docker.io/library/alpine:3.20" \
    "RUN adduser -D -u 2000 appuser" \
    "ADD .guarden/entry.sh /entry.sh" \
    "RUN chmod +x /entry.sh" \
    "ENTRYPOINT [\"/entry.sh\"]"
seed /var/lib/guarden/staging/kidgosu/0000001/.guarden/entry.sh \
    '#!/bin/sh' \
    'if [ x$(id -u) = x0 ] && [ -x /usr/sbin/gosu ] ; then exec gosu appuser /entry.sh ; fi' \
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

# The empty-USER row, read off pid 1: the measurement the two sides of
# ADR-0019's amendment disagree about, taken on the spelling that carries no
# `USER` line at all (t352 asserts the same for `USER root`, which is one
# table with it). pid 1 answering 0 says the entrypoint starts as the image's
# own user and the pin decides where a uid LANDS; pid 1 answering 2000 would
# say keep-id with an explicit `uid=` forces init to the pinned pair — which
# is what the refusal of a repository's own `User=` was argued from.
runtime_g=/run/user/"$(id -u kidgosu-staging)"
for _ in $(seq 1 30); do
    [ -d "$runtime_g" ] && break
    sleep 1
done
assert_file_exists "$runtime_g"
gosu_ready=0
for _ in $(seq 1 60); do
    podman_as kidgosu-staging exec kidgosu-staging-app true
    if [ "$GUARDEN_EXIT" = 0 ]; then
        gosu_ready=1
        break
    fi
    sleep 2
done
[ "$gosu_ready" = 1 ] || _fail "the kidgosu container never became exec-able, so nothing can read its pid 1"
podman_as kidgosu-staging exec kidgosu-staging-app sh -c 'grep ^Uid: /proc/1/status'
assert_exit 0
echo "MEASURE: pid 1 of the empty-USER container under its pin: $(cat "$GUARDEN_STDOUT")"
pid1_g=$(awk '/^Uid:/ { print $2 }' "$GUARDEN_STDOUT")
[ "$pid1_g" = 0 ] \
    || _fail "pid 1 under keep-id:uid=2000 answers uid $pid1_g, and ADR-0019 says a pin does not override the image's USER — the empty-USER row must say what the root row in t352 says"

# --- a repository's own `User=`, which would silently outrun the pin ---------
#
# The line maps exactly ONE uid — the probed pair — onto the service identity,
# and `User=` names the uid the container actually runs as: anything but the
# pinned pair runs where the line maps nothing, so its writes land in the
# subuid band (ticket 277) with nothing in the run saying the line named a uid
# the container never ran as. It is not about forcing init — a pin does not
# override the image's `USER` (measured above: pid 1 is the image's own user)
# — it is two owners of one container's user, and the repo is not one of them.
# Refused where the start would apply the pin: exit 2, one line, naming the
# service, the key and the value, and no start at all. With no pin this field
# passes through as it always has; this service's image declares a non-root
# user, which is what puts a pin in force.
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

# --- a RELATIVE entrypoint: the name the runtime resolves, not the cwd --------
#
# The stock postgres and mysql shape — `ENTRYPOINT ["docker-entrypoint.sh"]`,
# a bare name on the image's PATH with a WORKDIR somewhere else entirely, which
# is the shape the probe's own comment names. The probe handed that name to
# `cat`, and `cat` resolves it against the container's WORKDIR rather than
# PATH, so the read failed — and a failed read was read as "no handoff": the
# record settled on `owner_uid = 0`, no line rendered, nothing printed, while
# the record claimed the question had been answered. The keep-id line this ADR
# exists for then never appears for exactly the images it exists for.
#
# The resolution now answers the way the OCI runtime resolves the same name —
# PATH first (`command -v`), then the literal name against the WORKDIR — and
# this fixture's script is deliberately NOT in its WORKDIR, so only the PATH
# half can find it. The handoff is in the script's own words, resolved against
# the image's passwd, exactly as the root row resolves it.
unit_line() {
    grep -m1 '^UserNS=' "$1" || printf 'none\n'
}

stage_kid kidrel localhost/kidrel-staging:latest \
    "FROM docker.io/library/alpine:3.20" \
    "RUN echo 'app:x:3000:3000::/home/app:/bin/sh' >> /etc/passwd" \
    "ADD .guarden/entry.sh /usr/local/bin/entry.sh" \
    "RUN chmod +x /usr/local/bin/entry.sh" \
    "WORKDIR /srv" \
    "ENTRYPOINT [\"entry.sh\"]"
seed /var/lib/guarden/staging/kidrel/0000001/.guarden/entry.sh \
    '#!/bin/sh' \
    'if [ -x /usr/sbin/gosu ] ; then exec gosu app /usr/local/bin/entry.sh ; fi' \
    'exec sleep 3600'
run weedr service ingest kidrel-staging --from poke kidrel@0000001
assert_exit 0
run weedr service build kidrel-staging
assert_exit 0

run weedr service start kidrel-staging
assert_exit 0
unit_rel=/var/lib/guarden/services/kidrel-staging/home/.config/containers/systemd/app.container
record_rel=$registry/kidrel-staging.toml
[ "$(unit_line "$unit_rel")" = "UserNS=keep-id:uid=3000,gid=3000" ] \
    || _fail "a relative entrypoint whose script is on the image's PATH renders $(unit_line "$unit_rel"), and the handoff its script names is keep-id:uid=3000,gid=3000"
assert_file_has "$record_rel" "owner_uid = 3000"
assert_file_lacks "$record_rel" "owner_uid = 0"

# The same name answered by the RUNTIME: the container is only running if the
# image's `ENTRYPOINT ["entry.sh"]` was resolved and started, so coming up
# exec-able is what shows the probe reads the same file the container runs.
runtime_rel=/run/user/"$(id -u kidrel-staging)"
for _ in $(seq 1 30); do
    [ -d "$runtime_rel" ] && break
    sleep 1
done
assert_file_exists "$runtime_rel"
rel_ready=0
for _ in $(seq 1 60); do
    podman_as kidrel-staging exec kidrel-staging-app true
    if [ "$GUARDEN_EXIT" = 0 ]; then
        rel_ready=1
        break
    fi
    sleep 2
done
[ "$rel_ready" = 1 ] || _fail "the kidrel container never became exec-able, so nothing resolved its bare entrypoint name"
