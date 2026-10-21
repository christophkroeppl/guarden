#!/usr/bin/env bash
# A postgres whose data is a guarden `state:` volume starts, and snapper's
# `.snapshots` is never reached (ticket 325, ADR-0020).
#
# **What was false.** The postgres image's own entrypoint runs
# `find "$PGDATA" \! -user postgres -exec chown postgres '{}' +` as root. A
# `state` volume is a btrfs subvolume and snapper puts its own root-owned
# `0750` `.snapshots` subtree INSIDE it, so with `$PGDATA` at the volume root
# the chown walks into that subtree and the container dies:
#
#   chown: changing ownership of '/var/lib/postgresql/data/.snapshots':
#   Operation not permitted
#
# Every postgres service whose data guarden owns a volume for could not start.
# The operator measured it on a real host (phase-a-snapshot-clone-testrun.md,
# finding F1).
#
# **The answer is ADR-0020's: the CONTENTS MOUNT.** A `state` volume's data
# lives one level down inside the subvolume, in a payload directory, and THAT
# is what the container mounts — so the container never sees `.snapshots` at
# all, and the image's chown never reaches it. The alternative ADR-0020
# refused — making `.snapshots` ownable by the service user — would hand the
# service write access to the marks that protect its own snapshots, and the
# `0700` home is the isolation boundary this platform rests on.
#
# **The `bulk` volume is untouched.** It carries no snapper configuration and
# therefore no `.snapshots` subtree, so its mount source is still the subvolume
# root. ADR-0020 says so, and this file asserts it: a rule that changed every
# volume would be a rule about a problem only `state` has.
#
# **The image's own convention wins, and guarden's layout makes room for it.**
# The container's data path is the mount target the repository wrote
# (`/var/lib/postgresql/data`), and the image's `PGDATA` default is that path.
# The payload directory is what is mounted THERE, so the image's default
# `PGDATA` lands inside the payload and the chown walks the payload only.
# Nothing in the repository changes and no environment value has to be set.
#
# Real host, real `useradd`, real subuid range, real btrfs subvolume, real
# snapper, real rootless podman, real systemd: `GUARDEN_PREFIX=/`, the way
# `t350-keepid` and `t120-deploy` do.
#
# machine: fresh

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GUARDEN_PREFIX=/

ensure_accounts
stage_config guarden-measured.toml
run soil install --apply
assert_exit 0
run podman --version
assert_exit 0
echo "MEASURE: podman: $(cat "$GUARDEN_STDOUT")"

# --- the service: a postgres with a `state:` volume and a `bulk:` volume ----
#
# The tree is written here rather than shipped as a fixture: `fixtures/`
# holds configuration inputs and manifests, and the unit source this file
# needs is one the suite stages. **The unit sets NO `PGDATA`**, which is the
# point: the fix is in guarden's volume layout, not in a value the repository
# has to remember to write. The `postgres` fixture that does set it
# (`fixtures/projects/postgres/`) would be green before the fix and prove
# nothing.
staged=/var/lib/guarden/staging/pgsvc/0000001
mkdir -p "$staged/.guarden/quadlet"
seed "$staged/.guarden/service.yml" \
    "project: pgsvc" \
    "units: .guarden/quadlet/" \
    "state:" \
    "  - pgdata" \
    "bulk:" \
    "  - scratch" \
    "ports:" \
    "  - container: db" \
    "    port: 5432"
seed "$staged/.guarden/quadlet/db.container" \
    "[Unit]" \
    "Description=the postgres under test" \
    "" \
    "[Container]" \
    "Image=docker.io/library/postgres:17" \
    "Volume=pgdata:/var/lib/postgresql/data" \
    "Volume=scratch:/var/lib/guarden/scratch" \
    "Environment=POSTGRES_PASSWORD=guarden-test-pw"

run weedr service ingest pgsvc-staging --from poke pgsvc@0000001
assert_exit 0
assert_stdout_has "created pgsvc-staging"

svc=pgsvc-staging
tree=/var/lib/guarden/services/$svc
home=$tree/home
unit=$home/.config/containers/systemd/db.container
group=$(id -gn "$svc")
svc_uid=$(id -u "$svc")

# --- the layout: the payload directory is where the data lives --------------
#
# The `state` volume is still the subvolume it has always been, and the
# payload directory is one level down inside it. The `bulk` volume is the
# subvolume itself, because it has no `.snapshots` to keep out of the way.
assert_subvolume "$tree/state/pgdata"
assert_subvolume "$tree/bulk/scratch"
assert_dir_exists "$tree/state/pgdata/data"
assert_no_subvolume "$tree/state/pgdata/data"
assert_mode "$tree/state/pgdata/data" 700
assert_owner "$tree/state/pgdata/data" "$svc:$group"

# The unit's `Volume=` line mounts the PAYLOAD, not the subvolume root. This
# is the line that decides whether the container can see `.snapshots` at all,
# and it is the whole of the fix.
assert_file_has "$unit" "Volume=$tree/state/pgdata/data:/var/lib/postgresql/data"
# And the `bulk` volume is the subvolume root, unchanged.
assert_file_has "$unit" "Volume=$tree/bulk/scratch:/var/lib/guarden/scratch"
# The image's own convention is what the container sees: the repository's
# mount target, unchanged, and NO `PGDATA` anywhere — guarden does not
# override the image's data path.
assert_file_lacks "$unit" "PGDATA"

# --- the start: the postgres comes up and `.snapshots` is untouched ---------
#
# The image is pulled as the SERVICE user, because a pull as root lands in
# root's store and the service cannot use it — and because root cannot reach
# the stub resolver, so a root pull fails with a DNS error that reads like a
# blocked registry.
runtime=/run/user/"$svc_uid"
for _ in $(seq 1 30); do
    [ -d "$runtime" ] && break
    sleep 1
done
assert_file_exists "$runtime"

podman_as() {
    local service=$1
    shift
    local svc_home svc_runtime
    svc_home=/var/lib/guarden/services/$service/home
    svc_runtime=/run/user/"$(id -u "$service")"
    run_in "$svc_home" setpriv --reuid="$service" --regid="$service" --clear-groups \
        env -u OLDPWD HOME="$svc_home" PWD="$svc_home" USER="$service" LOGNAME="$service" \
        XDG_RUNTIME_DIR="$svc_runtime" podman "$@"
}

podman_as "$svc" pull docker.io/library/postgres:17
assert_exit 0
echo "MEASURE: the image is in the service's own store"

# `.snapshots` is snapper's, and the mark it protects is the mark. Its
# identity is read BEFORE the start, so the assertion after it is about the
# start and not about the seed.
snapshots=$tree/state/pgdata/.snapshots
assert_dir_exists "$snapshots"
before=$(stat -c '%u:%g:%a:%i' "$snapshots")
echo "MEASURE: .snapshots before the start: $before"

run weedr service start "$svc"
assert_exit 0
assert_stdout_has "started $svc"

# The container answers. The unit reaching `active` is not the claim — the
# claim is that the postgres came up, which is what the container's own
# `pg_isready` answers.
ready=0
for _ in $(seq 1 90); do
    podman_as "$svc" exec pgsvc-staging-db pg_isready -U postgres
    if [ "$GUARDEN_EXIT" = 0 ]; then
        ready=1
        break
    fi
    sleep 2
done
[ "$ready" = 1 ] || _fail "the postgres never became ready; the unit's own log names the reason"
echo "MEASURE: the postgres is ready"

# The data landed in the payload directory — one level down, inside the
# volume — and NOT at the subvolume root, which is where the chown used to
# walk into `.snapshots`.
assert_file_exists "$tree/state/pgdata/data/PG_VERSION"
assert_file_missing "$tree/state/pgdata/PG_VERSION"

# **`.snapshots` is byte-identical.** The chown never reached it, so its
# owner, its mode and its inode are exactly what they were before the start.
after=$(stat -c '%u:%g:%a:%i' "$snapshots")
echo "MEASURE: .snapshots after the start: $after"
[ "$before" = "$after" ] \
    || _fail "the start changed .snapshots ($before -> $after); the image's chown reached snapper's subtree"

# The snapper configuration is still there and still lists: the start did
# not disturb the volume's own bookkeeping.
assert_snapper_config "$svc-pgdata" NUMBER_MIN_AGE 3600
run snapper --machine-readable json -c "$svc-pgdata" list
assert_exit 0
echo "MEASURE: the snapper configuration still lists"

# --- the refusal: a volume whose data is at the root is refused, not moved --
#
# An existing host's `state` volume holds its data at the subvolume ROOT,
# because that is where it was before this change. **Guarden does not move
# it**: a move renames live data under a running process, it cannot skip
# `.snapshots`, and it is not atomic across a service's several volumes. So
# the mutator refuses with one line and the operator moves the data across
# deliberately — the same rule the spec already states for a newly declared
# volume ("the new volume starts EMPTY: move the data across yourself").
#
# The refusal is the HOST not being in the state the request assumed, so it
# is exit `1` and not `2` (spec 1.2), and nothing is created and no unit is
# installed.
legacy=/var/lib/guarden/staging/legacy/0000001
mkdir -p "$legacy/.guarden/quadlet"
seed "$legacy/.guarden/service.yml" \
    "project: legacy" \
    "units: .guarden/quadlet/" \
    "state:" \
    "  - pgdata" \
    "ports:" \
    "  - container: db" \
    "    port: 5432"
seed "$legacy/.guarden/quadlet/db.container" \
    "[Container]" \
    "Image=docker.io/library/postgres:17" \
    "Volume=pgdata:/var/lib/postgresql/data"

# The volume is made the way it was made before, with its data at the root:
# a subvolume, a snapper configuration of its own, and `.snapshots` inside it.
legacy_tree=/var/lib/guarden/services/legacy-staging
mkdir -p "$legacy_tree/state"
btrfs subvolume create "$legacy_tree/state/pgdata"
snapper --config legacy-staging-pgdata create-config "$legacy_tree/state/pgdata"
printf 'legacy data at the root\n' >"$legacy_tree/state/pgdata/PG_VERSION"
chown -R "$svc:$group" "$legacy_tree/state/pgdata" 2>/dev/null || true
chown root:root "$legacy_tree/state/pgdata/.snapshots"
chmod 0750 "$legacy_tree/state/pgdata/.snapshots"

run weedr service ingest legacy-staging --from poke legacy@0000001
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "legacy-staging"
assert_stderr_has "pgdata"
# The line says what to do, and it says the thing that is easy to get wrong:
# the payload directory starts EMPTY, so the data does not follow the change.
assert_stderr_has "move"
# And nothing was created: the refusal came before the payload directory and
# before the unit, so there is no tree and no registry entry for a service
# that does not exist.
assert_file_missing "$legacy_tree/state/pgdata/data"
assert_file_missing "$legacy_tree/home/.config/containers/systemd/db.container"

# The seeded data is where it was: the refusal moved nothing.
assert_file_exists "$legacy_tree/state/pgdata/PG_VERSION"
assert_file_missing "$legacy_tree/state/pgdata/data"

echo "MEASURE: the refusal moved nothing and created nothing"
