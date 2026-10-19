#!/usr/bin/env bash
# ADR-0019's probe where the image itself is the boundary: every number and
# every byte the resolver answers from comes out of the image's OWN files, so
# an image that answers with something else is a one-line refusal (spec 1.2) —
# never a traceback out of the resolver — and the three spellings of "this
# container runs as root" take one path rather than two.
#
# Eleven services, each with its own image, in the order they are asked about:
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
#     ADR's own case). One table now: root, `0` and empty are one declaration —
#     and the two fixtures below read pid 1 to say what each spelling RUNS as,
#     which is where they turn out to differ (asserted in t351 too).
#   * `USER 0` with the same handoff — the row no suite covered before this
#     file, and the one that must not move.
#   * no `USER` and no handoff — the row the ADR promises a NO line for: the
#     default mapping already puts container root on the service identity.
#   * FOUR fields carrying a character `isdigit` calls a digit and `int()`
#     refuses — the superscript `²` in the image's own passwd uid field, in
#     the uid half of `Config.User`, in its gid half beside a numeric uid, and
#     in its gid half beside a named one. Every one of those four fields goes
#     through ONE predicate now, and each answer is the same refusal: exit `2`,
#     one line naming the service, the field and the character — never a
#     ValueError walking out of the probe, which is what each of them did while
#     the predicate was `isdigit`.
#   * an entrypoint script the image does not carry — the READ of it fails,
#     and a failed read is the host not being able to answer (exit `1`, one
#     line, nothing recorded) rather than the answer "no handoff" settled into
#     the record as `owner_uid = 0`.
#   * a passwd row that names a user and carries NO gid (`app:x:1000`) and one
#     that carries an EMPTY gid (`app:x:1000:`) — a field that is not a
#     number and a field that is not there are the same class of the image's
#     own declaration, and both are refused the same way: exit `2`, one line
#     naming the service, the field and the value it found. The short row was
#     an `IndexError` out of the probe — a traceback where the spec promises
#     one line — because the row was accepted and its gid read unguarded.
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
# ADR-0019's drop-in model: the pin is a drop-in of guarden's own, and the
# base unit carries no `UserNS=` line at all.
pin_root=/etc/containers/systemd/users/"$(id -u kidroot-staging)"/app.container.d/50-guarden-keepid.conf
record_root=$registry/kidroot-staging.toml
[ "$(unit_line "$pin_root")" = "UserNS=keep-id:uid=3000,gid=3000" ] \
    || _fail "a USER root image whose entrypoint hands off to app renders $(unit_line "$pin_root"), and that handoff user is keep-id:uid=3000,gid=3000"
assert_file_has "$record_root" "owner_uid = 3000"
assert_file_has "$record_root" "owner_gid = 3000"

# The pin is the line, and what is running under it is read below: the
# container has to be up before its pid 1 can be asked anything.
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

# What podman is actually running here, read off the container's own pid 1.
#
# This is the fixture that can tell the two sides of ADR-0019's amendment
# apart for an image that NAMES its user, so the reading is ASSERTED rather
# than echoed: the image's `USER` is `root` and the pin is
# `keep-id:uid=3000,gid=3000`, so pid 1 answering `0` settles that an
# explicit `USER` is what init runs as and the pin decides where that uid
# LANDS, while pid 1 answering `3000` would settle that the pin decides who
# starts. The other spelling measures the other way and is asserted in t351:
# an image with NO `USER` line runs the pinned pair (pid 1 = 2000 under
# `keep-id:uid=2000`) — so the root row's spellings are one answer to the
# PROBE and not one behaviour at run time, and each is asserted where it
# stands. The forcing claim is what the refusal of a repository's
# own `User=` used to rest on; it now rests on the mapping (a `User=` that is
# not the pinned pair runs where the line maps nothing), which both readings
# leave standing. `podman exec`'s own `id -u` cannot
# answer this: exec starts a NEW process as the container's configured user
# (the image's own `USER`), which is why every fixture where image USER and
# pinned pair are the same number proves nothing about init.
podman_as kidroot-staging exec kidroot-staging-app sh -c 'grep ^Uid: /proc/1/status'
assert_exit 0
echo "MEASURE: pid 1 of the USER root container under its pin: $(cat "$GUARDEN_STDOUT")"
pid1_uid=$(awk '/^Uid:/ { print $2 }' "$GUARDEN_STDOUT")
[ "$pid1_uid" = 0 ] \
    || _fail "pid 1 under keep-id:uid=3000 answers uid $pid1_uid, and ADR-0019 says a pin does not override the image's USER — this measurement is what settles which side of the contradiction is true"

# `USER 0` + the same handoff: the row the ADR never named and no suite
# covered. It already took the handoff, and the table is what keeps it there.
stage_root_subject kidzero 0
unit_zero=/var/lib/guarden/services/kidzero-staging/home/.config/containers/systemd/app.container
pin_zero=/etc/containers/systemd/users/"$(id -u kidzero-staging)"/app.container.d/50-guarden-keepid.conf
record_zero=$registry/kidzero-staging.toml
[ "$(unit_line "$pin_zero")" = "UserNS=keep-id:uid=3000,gid=3000" ] \
    || _fail "a USER 0 image whose entrypoint hands off to app renders $(unit_line "$pin_zero"), and that handoff user is keep-id:uid=3000,gid=3000"
assert_file_has "$record_zero" "owner_uid = 3000"

# The third spelling of the root row, read off pid 1: `USER 0` names uid 0
# explicitly, so the rule the other two measurements give is that it runs as 0
# just as `USER root` does — the pin decides where the uid LANDS — and the
# row that has no `USER` line at all is the only one podman starts as the
# pinned pair (t351). Asserted, not echoed, because the probe's table calls
# all three one declaration and this is where the runtime disagrees with that
# for one of them.
zero_runtime=/run/user/"$(id -u kidzero-staging)"
for _ in $(seq 1 30); do
    [ -d "$zero_runtime" ] && break
    sleep 1
done
assert_file_exists "$zero_runtime"
zero_ready=0
for _ in $(seq 1 60); do
    podman_as kidzero-staging exec kidzero-staging-app true
    if [ "$GUARDEN_EXIT" = 0 ]; then
        zero_ready=1
        break
    fi
    sleep 2
done
[ "$zero_ready" = 1 ] || _fail "the kidzero container never became exec-able, so nothing can read its pid 1"
podman_as kidzero-staging exec kidzero-staging-app sh -c 'grep ^Uid: /proc/1/status'
assert_exit 0
echo "MEASURE: pid 1 of the USER 0 container under its pin: $(cat "$GUARDEN_STDOUT")"
pid1_zero=$(awk '/^Uid:/ { print $2 }' "$GUARDEN_STDOUT")
[ "$pid1_zero" = 0 ] \
    || _fail "pid 1 of the USER 0 image under keep-id:uid=3000 answers uid $pid1_zero, and an image that names uid 0 runs as uid 0 — t352's own root spelling says the same"

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
pin_plain=/etc/containers/systemd/users/"$(id -u kidplain-staging)"/app.container.d/50-guarden-keepid.conf
record_plain=$registry/kidplain-staging.toml
[ "$(unit_line "$pin_plain")" = "none" ] \
    || _fail "an image that declares no user and names no handoff renders $(unit_line "$pin_plain"), and it must render no line at all"
assert_file_has "$record_plain" "owner_uid = 0"

# --- fields that `isdigit` calls digits and `int()` refuses ------------------
#
# `isdigit` is a strict SUPERSET of the numbers `int()` accepts: `'²'.isdigit()`
# is True and `int('²')` raises ValueError, so every one of these four fields
# walked out of the probe as a traceback — the same defect as the `abc` field
# above, which `isdigit` happened to catch, wearing a character `isdigit`
# counts as a digit. Four fixtures because four fields take the predicate:
# the uid field of the image's own passwd, and each half of `Config.User`
# (uid alone; gid beside a numeric uid; gid beside a named one).

# The image's own passwd uid field — the resolver's own `int()`, where the
# documented "isdigit decides what is a number" equivalence was false.
stage_kid kidunifield localhost/kidunifield-staging:latest \
    "FROM docker.io/library/alpine:3.20" \
    "RUN echo 'app:x:²:0:app:/home/app:/bin/sh' >> /etc/passwd" \
    "USER app" \
    "CMD [\"sleep\", \"3600\"]"
run weedr service ingest kidunifield-staging --from poke kidunifield@0000001
assert_exit 0
run weedr service build kidunifield-staging
assert_exit 0

run weedr service start kidunifield-staging
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "kidunifield-staging"
assert_stderr_has "uid"
assert_stderr_has "²"
assert_stdout_lacks "started kidunifield-staging"

# The uid half of `Config.User` itself: the image declares a user whose first
# part is not a number and not a name its passwd carries.
stage_kid kiduniuser localhost/kiduniuser-staging:latest \
    "FROM docker.io/library/alpine:3.20" \
    "USER 1²" \
    "CMD [\"sleep\", \"3600\"]"
run weedr service ingest kiduniuser-staging --from poke kiduniuser@0000001
assert_exit 0
run weedr service build kiduniuser-staging
assert_exit 0

run weedr service start kiduniuser-staging
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "kiduniuser-staging"
assert_stderr_has "1²"
assert_stdout_lacks "started kiduniuser-staging"

# The gid half beside a NUMERIC uid: `USER 1000:²` takes the row where the
# separator's own digit check ran before the resolver's.
stage_kid kidunigrid localhost/kidunigrid-staging:latest \
    "FROM docker.io/library/alpine:3.20" \
    "USER 1000:²" \
    "CMD [\"sleep\", \"3600\"]"
run weedr service ingest kidunigrid-staging --from poke kidunigrid@0000001
assert_exit 0
run weedr service build kidunigrid-staging
assert_exit 0

run weedr service start kidunigrid-staging
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "kidunigrid-staging"
assert_stderr_has "²"
assert_stderr_has "group"
assert_stdout_lacks "started kidunigrid-staging"

# The gid half beside a NAMED uid: the name resolves against the image's own
# passwd first, so this is the second of the two `int()`s and the branch the
# other three do not reach.
stage_kid kiduname localhost/kiduname-staging:latest \
    "FROM docker.io/library/alpine:3.20" \
    "RUN echo 'app:x:3000:3000::/home/app:/bin/sh' >> /etc/passwd" \
    "USER app:²" \
    "CMD [\"sleep\", \"3600\"]"
run weedr service ingest kiduname-staging --from poke kiduname@0000001
assert_exit 0
run weedr service build kiduname-staging
assert_exit 0

run weedr service start kiduname-staging
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "kiduname-staging"
assert_stderr_has "²"
assert_stderr_has "group"
assert_stdout_lacks "started kiduname-staging"

# --- a passwd row that carries NO gid: a missing field is a refusal ---------
#
# `app:x:1000` names a user and a uid and stops. The gid the container will
# run with is a field of that row, and a row without one says nothing about
# it — so the row is the image's own declaration and it is rejected where it
# is visible, the same way a gid that is not a number is (spec 1.2: one line,
# exit `2`).
#
# The defect this fixture exists for: the row was ACCEPTED (three fields is
# enough to name a user) and its gid was then read out of it unguarded, so
# `app:x:1000` walked out of `weedr service start` as an `IndexError` — a
# traceback where the spec promises one line, and the same class the chain
# has already paid for twice (the unicode digits and the TOML float).
#
# The empty-gid row below is the same field with a value that is not a
# number, and it is here as the control: the two refusals must be the same
# refusal, and the empty one was already refused before the short one was.
stage_kid kidnogid localhost/kidnogid-staging:latest \
    "FROM docker.io/library/alpine:3.20" \
    "RUN echo 'app:x:1000' >> /etc/passwd" \
    "USER app" \
    "CMD [\"sleep\", \"3600\"]"
run weedr service ingest kidnogid-staging --from poke kidnogid@0000001
assert_exit 0
run weedr service build kidnogid-staging
assert_exit 0

run weedr service start kidnogid-staging
echo "MEASURE: stderr of a start whose image's passwd row carries no gid: $(tr '\n' '|' <"$GUARDEN_STDERR")"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "kidnogid-staging"
assert_stderr_has "gid"
assert_stdout_lacks "started kidnogid-staging"
# Nothing is recorded either: a refused declaration is not an answer, and a
# record that holds `owner_uid = 0` would be the "no handoff" answer this
# whole family of refusals exists to keep out of the tree.
record_nogid=$registry/kidnogid-staging.toml
recorded_nogid=$(grep '^owner_uid' "$record_nogid" 2>/dev/null || printf 'none\n')
echo "MEASURE: the record of the short-row refusal holds: $recorded_nogid"
[ "$recorded_nogid" = "none" ] \
    || _fail "the image's passwd row carries no gid and the record settled on $recorded_nogid instead of refusing — a missing field is not an answer"

# The same field, EMPTY rather than absent: the control that says the two
# refusals are one refusal and not two accidents.
stage_kid kidemptygid localhost/kidemptygid-staging:latest \
    "FROM docker.io/library/alpine:3.20" \
    "RUN echo 'app:x:1000:' >> /etc/passwd" \
    "USER app" \
    "CMD [\"sleep\", \"3600\"]"
run weedr service ingest kidemptygid-staging --from poke kidemptygid@0000001
assert_exit 0
run weedr service build kidemptygid-staging
assert_exit 0

run weedr service start kidemptygid-staging
echo "MEASURE: stderr of a start whose image's passwd row carries an empty gid: $(tr '\n' '|' <"$GUARDEN_STDERR")"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "kidemptygid-staging"
assert_stderr_has "gid"
assert_stdout_lacks "started kidemptygid-staging"

# --- a read that FAILED is not an answer -------------------------------------
#
# The entrypoint names a script the image does not carry, so the probe's read
# of it fails — the host cannot answer the question, which is exit `1` and one
# line naming the service (spec 1.2). What it must never become is the answer
# "no handoff": that settles the record on `owner_uid = 0`, the line this ADR
# exists for never renders, and the record claims the question was answered
# while nothing printed. The record's own state is read first, because that is
# the claim.
stage_kid kidnoscript localhost/kidnoscript-staging:latest \
    "FROM docker.io/library/alpine:3.20" \
    "ENTRYPOINT [\"/missing.sh\"]"
run weedr service ingest kidnoscript-staging --from poke kidnoscript@0000001
assert_exit 0
run weedr service build kidnoscript-staging
assert_exit 0

run weedr service start kidnoscript-staging
record_script=$registry/kidnoscript-staging.toml
recorded_owner=$(grep '^owner_uid' "$record_script" || printf 'none\n')
echo "MEASURE: a start whose entrypoint script the image does not carry recorded: $recorded_owner"
[ "$recorded_owner" = "none" ] \
    || _fail "the read of the entrypoint script failed and the probe recorded $recorded_owner instead of refusing — a failed read is not the answer 'no handoff'"
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "kidnoscript-staging"
assert_stderr_has "could not be run to resolve"
assert_stdout_lacks "started kidnoscript-staging"
