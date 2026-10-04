#!/usr/bin/env bash
# Previews: the fork a new instance takes, the cap on how many one service may
# hold, and the one verb a removal has (ticket 110, spec 5.3 step 12 and 9).
#
# What is asserted here is a claim about the host and not about a record of what
# guarden meant to do. A file is written into the staging service's live state
# volume and read back out of the instance's own, so "a clone of the live
# volume" is a fact about two directories rather than about a log line; the bulk
# volume the same manifest declares is a subvolume that did **not** get the copy,
# because a bulk volume is empty after a fork.
#
# The seed is the other half of the claim. Two instances of one service forked
# from one snapshot, one of them removed, and the snapshot is still marked: the
# release is of that instance's claim and not of the snapshot.
#
# The cap is `cap = 3` on the preview row of the shipped `guarden.toml`. It is
# counted per service, so the eviction that empties one workload's preview
# service leaves another's instances alone, and it evicts by creation, so a
# re-ingest of the oldest ref does not buy it a place at the front of the queue.
#
# The machine is this file's own: it writes real users, real btrfs subvolumes and
# real snapper configurations, which is the state a suite that says nothing about
# machines is assumed to be in (`t30-create`, `t30-remove`).

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

export GUARDEN_PREFIX=/

mkdir -p /etc/guarden
if ! getent group guarden >/dev/null 2>&1; then
    groupadd --system guarden
fi
ensure_accounts
stage_config guarden.toml
stage_poke myapp 9f2c1ab

# --- a fork source that is not on the box -------------------------------------

# The source is read from the track's `fork_from` field and there is no argument
# that changes it, so an instance whose source has not been created has nothing
# to clone. It starts empty and says so on stdout: a create that failed because
# of it would be a create a retry cannot fix, and an instance that came out
# silently empty would be worse than a line about it.
run weedr service ingest myapp-preview/orphan --from poke myapp@9f2c1ab
assert_exit 0
assert_stdout_has "the fork source myapp-staging has no registry entry"
assert_stderr_empty

# --- the fork, and what it leaves behind ---------------------------------------

run weedr service ingest myapp-staging --from poke myapp@9f2c1ab
assert_exit 0
assert_stderr_empty

# Two files, one in a `state` volume and one in a `bulk` volume, written by the
# service's own uid. Which of the two instance volumes ends up holding which is
# the whole subject of the next block.
run runuser -u myapp-staging -- touch /var/lib/guarden/services/myapp-staging/state/data/staged
assert_exit 0
run runuser -u myapp-staging -- touch \
    /var/lib/guarden/services/myapp-staging/bulk/chainstate/scratch
assert_exit 0

run weedr service ingest myapp-preview/feature-a --from poke myapp@9f2c1ab
assert_exit 0
assert_stdout_has "forked myapp-preview/feature-a from myapp-staging"

# The escaped form is `systemd-escape`'s, so a `-` in a ref is a `\x2d` in every
# path and every key. One rule, because one ref becomes a path, a table key and
# a lock name in this file and in the mutator alike.
instance_a="/var/lib/guarden/services/myapp-preview/instances/feature\\x2da"
assert_subvolume "$instance_a/state/data"
assert_subvolume "$instance_a/bulk/chainstate"

# The state volume is a clone of the source's live volume, read back as the
# instance's own uid: one trust domain, one home, and each other's directories.
run runuser -u myapp-preview -- cat "$instance_a/state/data/staged"
assert_exit 0

# The bulk volume is a subvolume and it is empty. A copy of it would be data no
# fork could reproduce afterwards, and the empty directory a plain `mkdir` leaves
# is not a subvolume at all.
assert_file_missing "$instance_a/bulk/chainstate/scratch"

# The seed names the snapshot it was cloned from, and the snapshot belongs to the
# source, so the source's configuration and the source's number are what a mark
# is written against.
run weedr service list --json
assert_exit 0
cp "$GUARDEN_STDOUT" "$GUARDEN_FIXTURES/list.json"
run python3 "$GUARDEN_ROOT/tests/jsonfield.py" services.0.instances.0.seed.data.service \
    <"$GUARDEN_FIXTURES/list.json"
assert_exit 0
assert_stdout_has "myapp-staging"
run python3 "$GUARDEN_ROOT/tests/jsonfield.py" services.0.instances.0.seed.data.number \
    <"$GUARDEN_FIXTURES/list.json"
assert_exit 0
seed_number=$(cat "$GUARDEN_STDOUT")
[ -n "$seed_number" ] || _fail "the instance recorded no snapshot number"

run weedr pin sync
assert_exit 0
assert_snapshot_marked myapp-staging-data "$seed_number" yes

# --- a second instance, and a removal that releases only its own claim ---------

# The source has not moved, so this instance is cloned from the same snapshot
# rather than from a new one. That is what makes the next assertion mean
# something: two claims on one snapshot, and only one of them goes.
run weedr service ingest myapp-preview/feature-b --from poke myapp@9f2c1ab
assert_exit 0
assert_stdout_has "forked myapp-preview/feature-b from myapp-staging"

run weedr service remove myapp-preview/feature-a
assert_exit 0
assert_stdout_has "removed the instance feature-a of myapp-preview"
assert_stdout_has "released the seed (data=myapp-staging:data@$seed_number)"
assert_file_missing "$instance_a"
assert_file_exists "/var/lib/guarden/services/myapp-preview/instances/feature\\x2db"

run weedr pin sync
assert_exit 0
assert_snapshot_marked myapp-staging-data "$seed_number" yes

# --- the cap ------------------------------------------------------------------

# A second workload, because the cap is counted per service and one workload's
# eviction is not supposed to be visible in another's. Two state volumes and one
# bulk volume, so the fork above is not the only thing being repeated.
stage_poke twovol 7c4e8b1
run weedr service ingest twovol-staging --from poke twovol@7c4e8b1
assert_exit 0

for ref in feature-z feature-a feature-m; do
    run weedr service ingest "twovol-preview/$ref" --from poke twovol@7c4e8b1
    assert_exit 0
    assert_stdout_lacks "removed the instance"
done
# The count is read from the registry rather than counted off stdout, because the
# cap is a claim about what the service holds and stdout is a claim about one run.
run weedr service list --json
assert_exit 0
cp "$GUARDEN_STDOUT" "$GUARDEN_FIXTURES/twovol.json"
held=$(ls -1 /var/lib/guarden/services/twovol-preview/instances | wc -l)
[ "$held" = 3 ] || _fail "twovol-preview holds $held instances after three creates, expected 3"
assert_file_exists /var/lib/guarden/services/twovol-preview/instances/feature\\x2dz
assert_file_exists /var/lib/guarden/services/twovol-preview/instances/feature\\x2da
assert_file_exists /var/lib/guarden/services/twovol-preview/instances/feature\\x2dm

# A manual redeploy of an instance that exists, and then a fourth create.
# `feature-z` was created first and is the one evicted, although `feature-a`
# sorts before it and was the one re-ingested: the ordering is a property of
# creation, and re-ingesting is not a way to make an instance newer.
run weedr service ingest twovol-preview/feature-a --from poke twovol@7c4e8b1
assert_exit 0
assert_stdout_lacks "removed the instance"
run weedr service ingest twovol-preview/feature-q --from poke twovol@7c4e8b1
assert_exit 0
assert_stdout_has "removed the instance feature-z of twovol-preview"

# The eviction is the removal verb's own work: the directory is gone, the
# publication is released, and the service keeps the two instances that are left.
assert_file_missing /var/lib/guarden/services/twovol-preview/instances/feature\\x2dz
assert_file_exists /var/lib/guarden/services/twovol-preview/instances/feature\\x2da
assert_file_exists /var/lib/guarden/services/twovol-preview/instances/feature\\x2dm
assert_file_exists /var/lib/guarden/services/twovol-preview/instances/feature\\x2dq
held=$(ls -1 /var/lib/guarden/services/twovol-preview/instances | wc -l)
[ "$held" = 3 ] || _fail "twovol-preview holds $held instances, expected 3"

# And it is this workload's eviction. The other preview service's instance is
# where it was, and the snapshot it was cloned from is still marked.
assert_file_exists /var/lib/guarden/services/myapp-preview/instances/feature\\x2db
run weedr pin sync
assert_exit 0
assert_snapshot_marked myapp-staging-data "$seed_number" yes

# --- one verb, by hand -------------------------------------------------------

# `furrow preview drop` is the same removal, so it has the same refusals. The
# second run asks for an instance that is not there, which is a host fact and
# exit 1, not a silent success.
run furrow preview drop twovol-preview feature-m
assert_exit 0
assert_stdout_has "dropped the instance feature-m of twovol-preview"
assert_file_missing /var/lib/guarden/services/twovol-preview/instances/feature\\x2dm
assert_file_exists /var/lib/guarden/services/twovol-preview

run furrow preview drop twovol-preview feature-m
assert_exit 1
assert_stderr_has "has no instance 'feature-m'"

# --- a ref taken raw ---------------------------------------------------------

# Two refs that are one name after `systemd-escape` and two before it. The
# service is at its cap again here, so the first of the two evicts the oldest
# survivor and both raw refs still have a directory of their own.
run weedr service ingest twovol-preview/feature/x --from poke twovol@7c4e8b1
assert_exit 0
run weedr service ingest twovol-preview/feature-x --from poke twovol@7c4e8b1
assert_exit 0
assert_file_exists /var/lib/guarden/services/twovol-preview/instances/feature-x
assert_file_exists /var/lib/guarden/services/twovol-preview/instances/feature\\x2dx
preview_registry=/var/lib/guarden/registry/twovol-preview.toml
assert_file_has "$preview_registry" 'ref = "feature/x"'
assert_file_has "$preview_registry" 'ref = "feature-x"'

# --- the last claim on the snapshot -------------------------------------------

# The only instance naming that snapshot is gone, so the reconciler's derived set
# is empty and the mark is cleared. Nothing here releases the snapshot: it stops
# naming it, and the reconciler does the rest.
run furrow preview drop myapp-preview feature-b
assert_exit 0
run furrow preview drop myapp-preview orphan
assert_exit 0
run weedr pin sync
assert_exit 0
assert_snapshot_marked myapp-staging-data "$seed_number" no

# Removing the last instance leaves the service, and the service is only removed
# when it is asked for by name.
assert_file_exists /var/lib/guarden/services/myapp-preview
assert_file_exists /var/lib/guarden/registry/myapp-preview.toml
run weedr service remove myapp-preview
assert_exit 0
assert_stdout_has "removed myapp-preview"

# --- one service per workload, one host, one credential ----------------------

# A second ref of a service that already exists creates an instance and nothing
# else: no second user, no second home, no second image store. The uid is the
# fact, because "one user per workload" is a claim about a number and a second
# creation would change it.
stage_poke shelf 3ab91d7
run weedr service ingest shelf-staging --from poke shelf@3ab91d7
assert_exit 0
assert_stderr_empty
run weedr service ingest shelf-preview/one --from poke shelf@3ab91d7
assert_exit 0
assert_stderr_empty
uid_one=$(id -u shelf-preview)
home_one=$(stat -c %i /var/lib/guarden/services/shelf-preview/home)

# The second ref of a service that already exists. Nothing about it may change:
# the uid is the same number and the home is the same inode, which is what "no
# second user, home or image store" is made of.
run weedr service ingest shelf-preview/two --from poke shelf@3ab91d7
assert_exit 0
assert_file_exists /var/lib/guarden/services/shelf-preview/home
assert_passwd_field shelf-preview "$uid_one" uid
[ "$home_one" = "$(stat -c %i /var/lib/guarden/services/shelf-preview/home)" ] \
    || _fail "the second ref replaced the service's home, so it made a second one"

# A generated credential is minted once for the service. The preview track is
# ungated, so a `@sensitive` key gets a value rather than blocking the create, and
# both instances read that one file: a per-instance secret is a second secret for
# one workload.
assert_file_exists /etc/guarden/creds/shelf-preview/SESSION_SIGNING_KEY.cred
assert_file_exists /var/lib/guarden/services/shelf-preview/instances/one
assert_file_exists /var/lib/guarden/services/shelf-preview/instances/two

# The route host is the track's own `host_prefix` on **one** host. An instance
# gets no host of its own, because the ref is a path segment and not a host name,
# and there is therefore nothing to put in a wildcard certificate.
run weedr service list --json
assert_exit 0
cp "$GUARDEN_STDOUT" "$GUARDEN_FIXTURES/shelf.json"
# The route host is found by the service's own name rather than by a list index,
# because an index into `services` is an ordering the registry decides and this
# file is about a workload's own host.
host=$(python3 -c '
import json, sys
for entry in json.load(open(sys.argv[1]))["services"]:
    if entry["name"] == "shelf-preview":
        print(entry["route_hosts"].get("shelf", ""))
' "$GUARDEN_FIXTURES/shelf.json")
[ "$host" = "preview.shelf" ] \
    || _fail "shelf-preview claims the route host ${host:-none}, expected preview.shelf"
# No `.internal` suffix and no name map. Both are anchored to files the run
# actually wrote: the registry and the rendered edge slice. A grep over JSON that
# no code path emits is vacuous, so the search is over the whole registry
# directory rather than over one service's own record, and `/etc/hosts` is
# compared against the bytes guarden was given the chance to write.
if grep -rq '\.internal' /var/lib/guarden/registry/; then
    _fail "a preview carries an .internal suffix, which is not a name guarden has"
fi
if grep -q 'shelf' /etc/hosts 2>/dev/null; then
    _fail "guarden wrote a name into /etc/hosts; there is no name map"
fi

# --- cap lives only on an instance track -------------------------------------

# `cap` is read from the track's row and nowhere else, so there is no second
# place a cap could be agreed. A `kind = "slot"` row carrying one is exit 2 naming
# the track, and the shipped table is restored afterwards because every other
# block in this file resolves against it.
capped=$GUARDEN_PREFIX/etc/guarden/guarden.toml
awk '/^host_prefix = "staging\."$/{print "cap = 2"}1' "$capped" > "$capped.capped"
mv "$capped.capped" "$capped"
run weedr service ingest shelf-staging --from poke shelf@3ab91d7
assert_exit 2
assert_stderr_has "must not carry a cap"
stage_config guarden.toml