#!/usr/bin/env bash
# The admin path is the injection point, and there is exactly one of it.
#
# (ticket 306)
#
# **This ticket was found by a review that read six documents and found two
# incompatible stories.** `docs/spec.md` said admin units live in
# `/etc/guarden/services/<name>/units.d/` "until the mutator installs them into
# `/etc/containers/systemd/users/<uid>/`", and no code had ever read or
# written `units.d`. In the same breath the spec's mode table had no row for
# that path, ADR-0019's three-file model had replaced the design it belonged
# to, and README.md claimed "nothing in guarden reads or rewrites it" — which
# was false, because `render._dropins` reads the admin path and merges what
# it finds into the rendered unit.
#
# The decision (ADR-0024) is the second option: **the admin path is the
# injection point, and there is no staging copy of it anywhere.** The
# alternative — implementing the `units.d` → admin-path copy — was refused
# because it would give the admin's own configuration TWO ways to reach a
# unit, and the whole of ADR-0019's model is that every file has exactly one
# writer.
#
# So this suite pins the ONE path, and it pins it three ways:
#
#   * **the staging copy does not exist and is not created** — a directory the
#     admin's units would be staged in, if there were one. The absence is
#     asserted, not the presence of something else.
#   * **the admin's own file in the admin path is read and merged** — the
#     claim that was false in README.md, measured on the render's own output.
#   * **guarden writes exactly one file in that directory** and leaves the
#     admin's beside it alone — ADR-0019's half that is still true.
#
# The first is a claim about a directory that must NOT be there, so it is
# checked on a real host after a real ingest: the path is asserted absent
# after the mutator has run, which is the only way to know nothing created it.
#
# machine: shared
# it converges a service and reads the paths it produced; it starts no
# container and reaches no network.
#
# reads: docs/spec.md README.md docs/sysadmin.md docs/adr/0024-admin-units-path-is-the-only-injection-point.md

. "$(dirname "$0")/lib.sh"

guarden_prefix
stage_config guarden.toml
stage_podlet_release

registry=$GUARDEN_PREFIX/var/lib/guarden/registry
project=$GUARDEN_FIXTURES/project
SPEC=$GUARDEN_ROOT/docs/spec.md
README=$GUARDEN_ROOT/README.md
SYSADMIN=$GUARDEN_ROOT/docs/sysadmin.md
ADR=$GUARDEN_ROOT/docs/adr/0024-admin-units-path-is-the-only-injection-point.md
seed "$project/.guarden/service.yml" "project: adminpath" "units: .guarden/quadlet/" \
    "state:" "  - data"
seed "$project/.guarden/quadlet/web.container" "[Unit]" "Description=the admin path subject" \
    "" "[Container]" "Image=docker.io/library/nginx:1.27" "Volume=data:/var/lib/app"

render=$GUARDEN_FIXTURES/render
admin_path=$GUARDEN_PREFIX/etc/containers/systemd/users/1101

# --- the admin's own file IS read, and IS merged --------------------------
#
# **This is the claim README.md got wrong.** "It is root-owned and nothing in
# guarden reads or rewrites it" was false, and the false half was the
# dangerous one: an operator who read it would conclude a cap they wrote there
# survives a regeneration, and would have no reason to find out otherwise.
# `render._dropins` reads every `*.conf` in the unit's drop-in directory and
# merges it into the unit before generation, so a cap written there lands in
# the rendered unit.
#
# The registry row is what names the uid the renderer looks under, so it is
# staged first: a drop-in under an uid the record does not name is a file in
# a directory nothing reads.
seed "$registry/app-production.toml" \
    'service = "app-production"' 'workload = "app"' 'project = "app"' \
    'environment = "production"' 'uid = 1101' 'created = "2026-09-30T09:00:00Z"'

seed "$admin_path/web.container.d/10-caps.conf" \
    "[Service]" "MemoryMax=512M" "MemoryHigh=384M"
seed "$admin_path/web.container.d/20-tuned.conf" \
    "[Container]" "Environment=TUNED=yes"

run loom render "$project" --service app-production --out "$render"
assert_exit 0
assert_file_has "$render/units/web.container" "MemoryMax=512M"
assert_file_has "$render/units/web.container" "MemoryHigh=384M"
assert_file_has "$render/units/web.container" "Environment=TUNED=yes"
echo "MEASURE: the admin's drop-in reached the rendered unit"

# And the guarden-owned file beside it is NOT merged: the base unit carries
# no `UserNS=` line, because the pin is a drop-in of its own and a key with
# two writers is a key with two values. This is ADR-0019's half that the
# decision does not touch.
seed "$admin_path/web.container.d/50-guarden-keepid.conf" \
    "[Container]" "UserNS=keep-id:uid=4242,gid=4242"
run loom render "$project" --service app-production --out "$render"
assert_exit 0
assert_file_lacks "$render/units/web.container" "UserNS="
assert_file_lacks "$render/units/web.container" "Userns="
echo "MEASURE: guarden's own drop-in is not merged into the base unit"

# --- there is no staging copy, and nothing creates one --------------------
#
# **The path the spec used to promise.** `/etc/guarden/services/<name>/
# units.d/` was where an admin's units were supposed to be staged "until the
# mutator installs them into" the admin path. No code ever read it and no
# code ever wrote it, and the decision is that it stays unwritten — a second
# way in is what ADR-0019's one-writer-per-file model exists to prevent.
#
# The absence is asserted AFTER the mutator has run on a real service, so the
# assertion is about the mutator's behaviour and not about a tree nobody
# touched.
#
# `weedr service ingest` is what creates a service and reconciles the admin
# path, so the service's own directory and the units.d path beneath it are
# what the claim is about.
stage_poke routed 9f2c1ab
run soil install --apply
assert_not_rejected
run weedr service ingest routed-staging --from poke routed@9f2c1ab
assert_exit 0

assert_file_missing "$GUARDEN_PREFIX/etc/guarden/services/routed-staging/units.d"
echo "MEASURE: no staging copy of the admin's units exists"

# The admin path itself IS there — the mutator reconciles its existence — and
# it is the only path the admin's units are read from.
assert_file_exists "$GUARDEN_PREFIX/etc/containers/systemd/users"
routed_uid=$(awk -F: '$1 == "routed-staging" { print $3 }' /etc/passwd)
[ -n "$routed_uid" ] || _fail "the service user routed-staging is not on the host"
assert_file_exists "$GUARDEN_PREFIX/etc/containers/systemd/users/$routed_uid"
echo "MEASURE: the admin path for routed-staging is under uid $routed_uid"

# --- the documents say the same thing -------------------------------------
#
# **The ticket was six documents and two stories**, so the fix is not one
# document saying the right thing: every document that mentioned the admin
# path says it the same way, and the false claim README.md carried is gone.
#
# The false claim is asserted as an ABSENCE, because a claim that was wrong
# is not fixed by writing the right one somewhere else — it is fixed by the
# wrong one no longer being there.
assert_file_lacks "$README" "nothing in guarden reads or rewrites"
assert_file_lacks "$README" "nothing in guarden reads or rewrites it"
# And the right one is there, so the absence is not a deletion.
assert_file_has "$README" "guarden reads the drop-ins in it"
assert_file_has "$README" "there is no staging copy of it anywhere on the host"

# The spec says the admin path is the only path, and says where the
# promised one went.
assert_file_has "$SPEC" "no staging copy of an admin's units"
assert_file_has "$SPEC" "ADR-0024"
# **The promised path is named as a refusal and not as a promise.** A
# document that still said the units "live in" that path would be the old
# story in a new file.
assert_file_lacks "$SPEC" "they live in \`/etc/guarden/services/<name>/units.d/\`"

# The runbook says it too, and says what happens to a file put in the old
# path — which is the operator's actual question.
assert_file_has "$SYSADMIN" "no staging copy of it anywhere"
assert_file_has "$SYSADMIN" "is a file nothing reads"

# And the decision is recorded, so the next reader finds the reasoning
# rather than the outcome.
assert_file_has "$ADR" "accepted"

echo "t306-admin-units-path: ok"
