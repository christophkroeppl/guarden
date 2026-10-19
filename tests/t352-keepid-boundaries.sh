#!/usr/bin/env bash
# ADR-0019's probe where the image itself is the boundary: every number and
# every byte the resolver answers from comes out of the image's OWN files, so
# an image that answers with something else is a one-line refusal (spec 1.2) —
# never a traceback out of the resolver — and the three spellings of "this
# container runs as root" take one path rather than two.
#
# Six services, each with its own image, in the order they are asked about:
#
#   * `USER app` on a `/etc/passwd` row whose uid is not a number
#     (`app:x:abc:0:...`) — rejected input: exit `2`, one line naming the
#     service, the field and the value it found.
#   * `USER 1000:staff` on a `/etc/group` row whose gid is not a number
#     (`staff:x:abc:`) — the same refusal out of the other database, which is
#     the resolver's second `int()`.
#   * an entrypoint script carrying bytes that are not UTF-8 — guarden reads a
#     tool's answer as text, so the decode is refused where the bytes enter:
#     exit `2`, one line naming the service, and never a UnicodeDecodeError
#     walking out of the probe.
#   * `USER root` with a gosu handoff — the row that was read differently from
#     `USER 0` (which took the handoff) and from no `USER` at all (which is the
#     ADR's own case). One table now: root, `0` and empty are one declaration.
#   * `USER 0` with the same handoff — the row no suite covered before this
#     file, and the one that must not move.
#   * no `USER` and no handoff — the row the ADR promises a NO line for: the
#     default mapping already puts container root on the service identity.
#
# The other two shapes of `Config.User` are asserted where they were written:
# a name the image's passwd carries (and one it does not) in
# t351-keepid-diagnostics, and the bare number `USER 10001` with the line it
# renders in t350-keepid.
#
# Real host, real rootless podman: `GUARDEN_PREFIX=/`, as t351 does.

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

# stage_kid <project> <image> <Containerfile lines...>: a staged tree with one
# unit declaring the local image, plus the Containerfile that builds it — the
# shape t351 stages its probe images in.
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
        "Description=the probe's boundary subject" \
        "" \
        "[Container]" \
        "Image=$image"
    seed "$staged/Containerfile" "$@"
}

# unit_line <path>: the unit's own guarden-rendered line, or `none`. The
# comparisons below are written against this rather than against a grep that
# only says the pattern is missing: a red that prints what the unit actually
# carries is evidence, and a red that prints "does not carry" is a hope.
unit_line() {
    grep -m1 '^UserNS=' "$1" || printf 'none\n'
}

# podman_as <service> <podman args...>: podman as the service user, with USER
# and LOGNAME named for the service — the shape t350 drives the machine's
# answers with, and the same reason: `runuser` keeps the CALLER's environment,
# and the caller is root.
podman_as() {
    local service=$1 home uid
    shift
    home=/var/lib/guarden/services/$service/home
    uid=$(id -u "$service")
    run_in "$home" setpriv --reuid="$service" --regid="$service" --clear-groups \
        env -u OLDPWD HOME="$home" PWD="$home" USER="$service" LOGNAME="$service" \
        XDG_RUNTIME_DIR="/run/user/$uid" podman "$@"
}

# --- a passwd row whose uid is not a number: rejected input ------------------

stage_kid kidbaduid localhost/kidbaduid-staging:latest \
    "FROM docker.io/library/alpine:3.20" \
    "RUN echo 'app:x:abc:0:app:/home/app:/bin/sh' >> /etc/passwd" \
    "USER app" \
    "CMD [\"sleep\", \"3600\"]"
run weedr service ingest kidbaduid-staging --from poke kidbaduid@0000001
assert_exit 0
run weedr service build kidbaduid-staging
assert_exit 0

run weedr service start kidbaduid-staging
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "kidbaduid-staging"
assert_stderr_has "uid"
assert_stderr_has "abc"
assert_stdout_lacks "started kidbaduid-staging"

# --- a group row whose gid is not a number: the same refusal -----------------

stage_kid kidbadgrp localhost/kidbadgrp-staging:latest \
    "FROM docker.io/library/alpine:3.20" \
    "RUN echo 'staff:x:abc:' >> /etc/group" \
    "USER 1000:staff" \
    "CMD [\"sleep\", \"3600\"]"
run weedr service ingest kidbadgrp-staging --from poke kidbadgrp@0000001
assert_exit 0
run weedr service build kidbadgrp-staging
assert_exit 0

run weedr service start kidbadgrp-staging
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "kidbadgrp-staging"
assert_stderr_has "gid"
assert_stderr_has "abc"
assert_stdout_lacks "started kidbadgrp-staging"

# --- an entrypoint whose bytes are not UTF-8 ---------------------------------

# The script the probe reads when the image declares no user: an entrypoint
# carrying a byte no text codec accepts, which is the shape a Windows-edited
# or binary script leaves behind. Every tool answer guarden reads is text, so
# the decode belongs at the boundary and the answer is one line, not a
# UnicodeDecodeError walking out of the probe.
stage_kid kidbadutf localhost/kidbadutf-staging:latest \
    "FROM docker.io/library/alpine:3.20" \
    "ADD .guarden/entry.sh /entry.sh" \
    "RUN chmod +x /entry.sh" \
    "ENTRYPOINT [\"/entry.sh\"]"
printf '#!/bin/sh\n# bytes no codec accepts: \377\376\nexec sleep 3600\n' \
    >/var/lib/guarden/staging/kidbadutf/0000001/.guarden/entry.sh
run weedr service ingest kidbadutf-staging --from poke kidbadutf@0000001
assert_exit 0
run weedr service build kidbadutf-staging
assert_exit 0

run weedr service start kidbadutf-staging
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "kidbadutf-staging"
assert_stderr_has "UTF-8"
assert_stdout_lacks "started kidbadutf-staging"

# --- the root spellings: one resolution table --------------------------------
#
# `USER root`, `USER 0` and no `USER` at all are one declaration — container
# root — and each is answered the same way: the handoff the entrypoint names
# when there is one, and `(0, 0)` (no line, the default mapping) when there is
# not. The script below carries `gosu app` where the probe reads it and never
# runs it: alpine ships no gosu, and the branch is guarded, so the container
# comes up under the pin either way.

stage_root_subject() {
    local project=$1 user=$2
    stage_kid "$project" "localhost/${project}-staging:latest" \
        "FROM docker.io/library/alpine:3.20" \
        "RUN echo 'app:x:3000:3000::/home/app:/bin/sh' >> /etc/passwd" \
        "USER $user" \
        "ADD .guarden/entry.sh /entry.sh" \
        "RUN chmod +x /entry.sh" \
        "ENTRYPOINT [\"/entry.sh\"]"
    seed "/var/lib/guarden/staging/$project/0000001/.guarden/entry.sh" \
        '#!/bin/sh' \
        'if [ -x /usr/sbin/gosu ] ; then exec gosu app /entry.sh ; fi' \
        'exec sleep 3600'
    run weedr service ingest "${project}-staging" --from poke "$project@0000001"
    assert_exit 0
    run weedr service build "${project}-staging"
    assert_exit 0
    run weedr service start "${project}-staging"
    assert_exit 0
}

# `USER root` + a handoff: the row that used to fall through to the passwd
# row for `root` and record container root without ever asking the entrypoint.
stage_root_subject kidroot root
unit_root=/var/lib/guarden/services/kidroot-staging/home/.config/containers/systemd/app.container
record_root=$registry/kidroot-staging.toml
[ "$(unit_line "$unit_root")" = "UserNS=keep-id:uid=3000,gid=3000" ] \
    || _fail "a USER root image whose entrypoint hands off to app renders $(unit_line "$unit_root"), and that handoff user is keep-id:uid=3000,gid=3000"
assert_file_has "$record_root" "owner_uid = 3000"
assert_file_has "$record_root" "owner_gid = 3000"

# The pin is the line and the init it forces: the container answers its own
# uid and gid, read the way t350 reads them.
root_runtime=/run/user/"$(id -u kidroot-staging)"
for _ in $(seq 1 30); do
    [ -d "$root_runtime" ] && break
    sleep 1
done
assert_file_exists "$root_runtime"
root_ready=0
for _ in $(seq 1 60); do
    podman_as kidroot-staging exec kidroot-staging-app true
    if [ "$GUARDEN_EXIT" = 0 ]; then
        root_ready=1
        break
    fi
    sleep 2
done
[ "$root_ready" = 1 ] || _fail "the pinned kidroot container never became exec-able"
run_in /var/lib/guarden/services/kidroot-staging/home \
    setpriv --reuid=kidroot-staging --regid=kidroot-staging --clear-groups \
    env -u OLDPWD HOME=/var/lib/guarden/services/kidroot-staging/home \
    PWD=/var/lib/guarden/services/kidroot-staging/home USER=kidroot-staging \
    LOGNAME=kidroot-staging XDG_RUNTIME_DIR="/run/user/$(id -u kidroot-staging)" \
    podman exec kidroot-staging-app sh -c 'id -u; id -g'
assert_exit 0
[ "$(sed -n '1p' "$GUARDEN_STDOUT")" = "3000" ] \
    || _fail "the root-spelled container inits as uid $(sed -n '1p' "$GUARDEN_STDOUT"), and the pin names 3000"

# `USER 0` + the same handoff: the row the ADR never named and no suite
# covered. It already took the handoff, and the table is what keeps it there.
stage_root_subject kidzero 0
unit_zero=/var/lib/guarden/services/kidzero-staging/home/.config/containers/systemd/app.container
record_zero=$registry/kidzero-staging.toml
[ "$(unit_line "$unit_zero")" = "UserNS=keep-id:uid=3000,gid=3000" ] \
    || _fail "a USER 0 image whose entrypoint hands off to app renders $(unit_line "$unit_zero"), and that handoff user is keep-id:uid=3000,gid=3000"
assert_file_has "$record_zero" "owner_uid = 3000"

# No `USER` at all and no handoff anywhere: the record says root (0) and the
# unit carries no line, because the default map already moves container root
# onto the service identity (ADR-0019's promise, now asserted).
stage_kid kidplain localhost/kidplain-staging:latest \
    "FROM docker.io/library/alpine:3.20" \
    "CMD [\"sleep\", \"3600\"]"
run weedr service ingest kidplain-staging --from poke kidplain@0000001
assert_exit 0
run weedr service build kidplain-staging
assert_exit 0
run weedr service start kidplain-staging
assert_exit 0
unit_plain=/var/lib/guarden/services/kidplain-staging/home/.config/containers/systemd/app.container
record_plain=$registry/kidplain-staging.toml
[ "$(unit_line "$unit_plain")" = "none" ] \
    || _fail "an image that declares no user and names no handoff renders $(unit_line "$unit_plain"), and it must render no line at all"
assert_file_has "$record_plain" "owner_uid = 0"
