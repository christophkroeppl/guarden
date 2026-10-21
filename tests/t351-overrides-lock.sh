#!/usr/bin/env bash
# t351-overrides-lock.sh — ticket 351: a deploy's read-modify-write of
# `/etc/guarden/services/<name>/overrides.toml` is ONE act under the
# `overrides` lock.
#
# The window: `service.create` read the admin's file, seeded the track's
# retention defaults into what it had read, and wrote the result back — with no
# `conf.lock("overrides")` around any of the three. Every other writer of that
# file takes the lock (`weedr port open`/`close`, `weedr firewall
# open`/`close`, `weedr basicauth on`/`off`, `units.allow_mounts`), so a deploy
# that read before an operator's verb wrote and saved after installed a document
# seeded from its own stale read: the operator's key is gone, silently, and the
# one whose loss turns a login back ON is `[basicauth] required = false`.
#
# **What this file pins, and why it is not the lost update itself.**
#
# The loss is real and the fix is the lock, but the interleaving that would drop
# a key is not reachable from a suite. The read and the save are two adjacent
# statements — `seeded(load(...))` and then `save(...)` — so the window an
# operator's write would have to land in is microseconds wide, with no seam to
# stop the process in. A test that slept "long enough" and then looked would
# pass most runs and fail the rest, and a racy red is not evidence: it would
# report on the machine's speed rather than on the code. So the loss is not
# claimed here, and this file says so instead of staging a race it cannot stage.
#
# What is pinned is the property that makes the loss impossible: **the deploy
# waits for the `overrides` lock**, and the operator's document written while it
# waits is the document it reads and preserves. The evidence is a file that does
# not change:
#
#   * an external process takes `/run/guarden/locks/overrides.lock` with
#     `flock(1)` and writes the exact document `weedr basicauth off` writes —
#     `[basicauth] required = false`, one table and one key. The verb itself
#     cannot be used here: it refuses a service with no minted login, and this
#     service does not exist yet;
#   * `weedr service ingest` is started against a service that does not exist.
#     It creates the user, makes the tree and copies the source — all of them
#     BEFORE the lock — and then stops;
#   * **the assertion is that `overrides.toml` is still byte-for-byte the
#     operator's document** seconds after the copy landed, and that
#     `registry/<name>.toml` still does not exist. Without the lock the deploy
#     writes its own seeded document there at once, which is what makes this
#     assertion RED on the code the ticket names; with the lock the write cannot
#     happen until the holder lets go;
#   * the lock is released, the deploy finishes, and the file it wrote carries
#     **both** halves: the operator's `required = false` and the retention it
#     seeds. That is the read happening AFTER the operator's write, which is
#     what the lock buys, and its mode and owner say `overrides.save` is the
#     writer rather than the operator's own `cp`.
#
# The lock file the holder takes is not where the claim comes from: **the
# deploy blocking on it is what proves the deploy takes that lock**, so a suite
# that guessed the path wrong would not block at all.
#
# machine: fresh

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# A real host: `weedr service ingest` allocates a real uid with a real
# `useradd`, a real `/etc/subuid` range and a real tree under
# `/var/lib/guarden/services`, none of which `GUARDEN_PREFIX` can relocate
# (tests/lib.sh says why a staged identity database asserts two databases).
export GUARDEN_PREFIX=/

ensure_accounts
stage_config guarden-nomodules.toml
stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_not_rejected

service=lockapp-staging
staged=/var/lib/guarden/staging/lockapp/9f2c1ab
home=/var/lib/guarden/services/$service/home
overrides=/etc/guarden/services/$service/overrides.toml
record=/var/lib/guarden/registry/$service.toml
lock=/run/guarden/locks/overrides.lock
release=$GUARDEN_FIXTURES/release

holder=
ingest=

# A wedged run must not leave the lock held and a deploy waiting: the holder
# watches for this file, so the trap is what ends it.
cleanup() {
    touch "$release"
    if [ -n "$holder" ]; then
        wait "$holder" 2>/dev/null || true
        holder=
    fi
    if [ -n "$ingest" ]; then
        kill "$ingest" 2>/dev/null || true
        wait "$ingest" 2>/dev/null || true
        ingest=
    fi
}
trap cleanup EXIT

# --- the service the deploy creates ----------------------------------------
#
# A quadlet source and no `state` volume: a `compose.yaml` would need the pinned
# converter and a state volume would put snapper and btrfs in the path, and
# neither is this file's subject. What the create does with the admin's file is.

mkdir -p "$staged/.guarden/quadlet"
seed "$staged/.guarden/service.yml" \
    "project: lockapp" \
    "units: .guarden/quadlet/"
seed "$staged/.guarden/quadlet/app.container" \
    "[Container]" \
    "Image=docker.io/library/nginx:1.27"

assert_file_missing "$overrides"
assert_file_missing "$record"

# --- the operator's document, written under the lock ------------------------
#
# Byte for byte what `weedr basicauth off` leaves in the file: the setter loads
# the document, merges the one key and saves, so a document carrying nothing but
# that key is the state it produces for a service whose file has no retention
# seeded yet — which is exactly a service the deploy has not finished creating.
operator_doc=$GUARDEN_FIXTURES/operator.toml
seed "$operator_doc" "[basicauth]" "required = false"

hold_overrides_lock() {
    exec 9>"$lock"
    flock -x 9
    mkdir -p "$(dirname "$overrides")"
    cp "$operator_doc" "$overrides"
    # Held until the suite says so, and bounded so that a run killed before its
    # trap fires still ends: the machine is thrown away either way.
    for _ in $(seq 1 1200); do
        [ -e "$release" ] && break
        sleep 0.1
    done
    exec 9>&-
}
hold_overrides_lock &
holder=$!

held=0
for _ in $(seq 1 300); do
    if [ -s "$overrides" ]; then
        held=1
        break
    fi
    sleep 0.1
done
[ "$held" = 1 ] || _fail "the holder never wrote $overrides, so the overrides lock was never taken and this suite would assert nothing"
assert_file_has "$overrides" "required = false"
echo "MEASURE: the operator's document is in the file, and another process is holding $lock"

# --- the deploy, which must wait for the lock ------------------------------
python3 -m guarden.weedr service ingest "$service" --from poke lockapp@9f2c1ab \
    >"$GUARDEN_FIXTURES/ingest.out" 2>"$GUARDEN_FIXTURES/ingest.err" &
ingest=$!

# The copied source is the last thing the create does BEFORE it reaches the
# admin's file, so its appearing is what says the deploy is at the lock rather
# than still on its way there.
ready=0
for _ in $(seq 1 600); do
    if [ -e "$home/.guarden/service.yml" ]; then
        ready=1
        break
    fi
    sleep 0.1
done
[ "$ready" = 1 ] \
    || _fail "$home/.guarden/service.yml never appeared: the deploy never reached the copy that sits in front of the write this suite is about, and what it said was: $(tr '\n' '|' <"$GUARDEN_FIXTURES/ingest.err")"

# Long enough that "it had not got there yet" is not an answer: the lock is the
# very next statement after the copy, and the copy is already on disk.
sleep 3

if ! cmp -s "$operator_doc" "$overrides"; then
    echo "MEASURE: what the deploy left in the file: $(tr '\n' '|' <"$overrides")"
    _fail "the deploy rewrote $overrides while another process held the overrides lock, so its read, its seed and its write are not one act: the document it installed is the one it seeded from its own read, and an operator's setting written in that window would be gone"
fi
# `ps` and not `kill -0`: a child that has exited but not been reaped is a
# zombie, `kill -0` succeeds on one, and "still running" is the whole claim. `||
# true` because `ps` exits 1 for a pid that is gone, and an exit code in a
# command substitution fails the assignment under `set -e`.
state=$(ps -o stat= -p "$ingest" 2>/dev/null | tr -d ' ' || true)
case "$state" in
    "" | Z*)
        echo "MEASURE: the deploy's stderr: $(tr '\n' '|' <"$GUARDEN_FIXTURES/ingest.err")"
        _fail "the deploy was no longer running 3s after it copied the source while another process held the overrides lock (process state [${state:-gone}]): either it did not wait for the lock at all, or it failed — and the deploy's own error is above"
        ;;
esac
assert_file_missing "$record"
echo "MEASURE: the deploy is waiting with the operator's document untouched, and no registry entry exists"

# --- the lock released: the write happens, and it keeps the operator's key --
touch "$release"
wait "$holder" || true
holder=

status=0
wait "$ingest" || status=$?
ingest=
[ "$status" = 0 ] \
    || _fail "the deploy exited $status after the lock was released: $(tr '\n' '|' <"$GUARDEN_FIXTURES/ingest.err")"
grep -qF -- "created $service" "$GUARDEN_FIXTURES/ingest.out" \
    || _fail "the deploy said nothing about creating $service: $(tr '\n' '|' <"$GUARDEN_FIXTURES/ingest.out")"

# The two halves of the same write. The operator's key is there because the read
# that fed the seed happened AFTER the operator's write; the retention is there
# because the seed and the save ran at all. A file holding only the first would
# be a deploy that never saved; only the second, a deploy that dropped the key.
assert_file_has "$overrides" "required = false"
assert_file_has "$overrides" "keep_last = 0"
assert_file_has "$overrides" "free_limit = 0.2"
# And the writer was `overrides.save`, not the operator's `cp`: the mode and the
# group are the ones the write protocol states.
assert_mode "$overrides" 640
assert_owner "$overrides" root:guarden
assert_file_exists "$record"
echo "MEASURE: after the release the file holds $(tr '\n' '|' <"$overrides")"

echo "t351-overrides-lock: ok"
