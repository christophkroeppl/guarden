#!/usr/bin/env bash
# tests/lxc.sh — the real-host harness. A throwaway LXD **VM**, cut from a
# golden snapshot, with the real tools and nothing standing in for them.
#
# Why this exists: fixtures/bin stood in for the host — every fake was a claim
# about what guarden would do on a machine that has the real tool.
# Here the machine has it — real useradd with real /etc/subuid arithmetic, real
# iptables, real btrfs subvolumes, real snapper, real systemd — so the assertion
# is about guarden and not about a stand-in for guarden's environment.
#
# The mechanics come from the retired `next` branch, which had a working LXD
# harness: a golden instance provisioned by cloud-init, readiness proven by
# `lxc exec <n> -- true` rather than by reading instance state, the exit-75
# "reboot required" contract for the btrfs conversion, and a boot-id poll
# because the LXD agent is absent for the whole of an initramfs conversion.
#
# Three things this file exists to get right, each of them learned the hard way:
#
#   * `lxc exec` runs with **-T**. Without it LXD allocates a PTY, stdin is a
#     tty, and `weedr service purge` — which refuses when stdin is not a
#     terminal — stops refusing and deletes real volumes.
#   * The storage pool is **btrfs**, not `dir`. On `dir` a snapshot copies the
#     whole disk and a restore measured 101 s, which is ~44 minutes for one
#     restore per test file. On btrfs a snapshot is a subvolume and the same
#     restore is seconds.
#   * The golden is **converted to btrfs before it is snapshotted**, because the
#     conversion is an offline, reboot-crossing operation and the harness drives
#     it the way an operator does — `soil storage` asks for each reboot. A cut
#     therefore arrives with the storage phase already converged, which is why a
#     suite whose subject is storage must stage its own unconverged state rather
#     than assert the golden's build history.
#
# Usage:
#   tests/lxc.sh provision   build the golden, convert it to btrfs, snapshot it
#   tests/lxc.sh run [pat] [opts]   run the suites, honouring what each says
#   tests/lxc.sh shell       a fresh VM you can poke at
#   tests/lxc.sh destroy     remove the golden
#
# run's options:
#   --fresh    cut a machine per file whatever any suite asks. The default was
#              this and it is the answer `--fresh` still gives; `just test-fresh`
#              is the recipe that says it out loud.
#   --shared   cut one machine for the whole run, ignoring every declaration.
#   --reverse  run the selected suites in the opposite order.
#   --no-cache run every selected suite and record the result. A release gate
#              uses this, because an inherited green is not an observed one.
#
# `--reverse` exists because sharing is a claim and a claim needs proving: the
# suites that share a machine are run in one order and then in the other, and
# both runs have to be green. It is the second half of that and nothing else.
#
# Everything else in a run is cached by default (ticket 210). A suite's result
# is a function of the golden it was cut from and the tree it read, so an
# unchanged suite is **inherited** and says so on its own line. The line does not
# read as a pass: `inherit t30-create.sh (green from the cache; not observed this
# run)`. A cache that could be read as a verification would be worse than none.
#
# lxc is the LXD snap. It is not on PATH for a non-interactive shell, so it is
# resolved by absolute path rather than hoped for.

set -uo pipefail

LXC=${GUARDEN_LXC:-/snap/bin/lxc}
GOLDEN=${GUARDEN_LXC_GOLDEN:-guarden-golden}
RUNNER=${GUARDEN_LXC_RUNNER:-guarden-run}
SNAPSHOT=${GUARDEN_LXC_SNAPSHOT:-base}
IMAGE=${GUARDEN_LXC_IMAGE:-ubuntu:26.04}
POOL=${GUARDEN_LXC_POOL:-guarden-btrfs}
POOL_SOURCE=${GUARDEN_LXC_POOL_SOURCE:-/media/data/guarden-lxd}
REPO=${GUARDEN_LXC_REPO:-$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")}
VM_REPO=${GUARDEN_LXC_VM_REPO:-/home/ubuntu/guarden}
CACHE_TOOL=${GUARDEN_LXC_CACHE_TOOL:-$REPO/tests/suitecache.py}

# The guest half of the apt-lock wait (ticket 271), read once at load. These
# bytes travel with the exec because `_wait_cloud_init` runs *before* the
# checkout is pushed into the cut, and `tests/t370-apt-lock-wait.sh` runs this
# same file in the machine — so what a suite asserts about the measurement is
# what a cut runs, not a copy of it. An absent file is caught before a machine
# is cut, the way a missing failure_messages.sh is caught before a run starts.
APT_LOCK_SH=$REPO/tests/aptlock.sh
APT_LOCK_GUEST=''
[ -r "$APT_LOCK_SH" ] && APT_LOCK_GUEST=$(<"$APT_LOCK_SH")

# Tests that cannot run in the machine, by construction rather than by accident.
#
# t35-env-schema.sh asks git about the repository: `check-ignore` and
# `ls-files` need a work tree, and this checkout's `.git` is a file pointing at
# /media/data/projects/infra/.git/worktrees/service-based, which is a host path
# that does not exist in a guest. The checkout is pushed without `.git`, so the
# commands fail and the test reports git's exit 128 as a guarden defect. It is a
# repository-hygiene test, not a guarden test; the VM runner skips it
# (`HOST_ONLY`, below), and nothing else runs it today — see ticket 266.
HOST_ONLY=${GUARDEN_LXC_HOST_ONLY:-t35-env-schema.sh}

_is_host_only() {
    local name=$1 candidate
    for candidate in $HOST_ONLY; do
        [ "$name" = "$candidate" ] && return 0
    done
    return 1
}

# A suite says whether it needs a machine of its own, in the suite itself:
#
#     # machine: shared
#     # machine: fresh
#
# The declaration is in the file rather than in a list here for the reason the
# ticket gives — it travels with the suite, and a suite that forgets it is the
# safe answer rather than a silent inheritor of another suite's system users.
#
# **An absent declaration is `fresh`, and that is the whole of the safety
# argument.** `sed -n 's/^# machine: //p'` reads one line, the value is checked
# against the two words, and anything else is refused by name rather than
# treated as a near miss. A typo that read as "share" would put a suite that
# writes real `/etc/guarden`, real users and real btrfs subvolumes on a machine
# another suite already changed, and the run would be green about a host nobody
# set up.
#
# `sed -n` with one substitution rather than `grep` because the first match is
# the answer: a second declaration in the same suite is a contradiction rather
# than a refinement, and reading the last one would let a file carry both
# answers and depend on which line came last.
_declaration_of() {
    sed -n 's/^# machine: //p' "$1" | head -n 1
}

_shares_machine() {
    local path=$1 declared
    declared=$(_declaration_of "$path")
    case "$declared" in
        '') return 1 ;;
        fresh) return 1 ;;
        shared) return 0 ;;
        *)
            die "${path##*/} declares '# machine: $declared'; it is 'fresh' or 'shared', and a suite that says neither gets a machine of its own"
            ;;
    esac
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

[ -x "$LXC" ] || die "$LXC not found; the LXD snap is not installed at that path"

# **The failure lines are a function in their own file, and this is its only
# caller in the runner.** A suite cannot drive this script — it runs inside
# the machine, where `lxc` does not exist — so the part of the runner whose
# whole value is its text is kept where `tests/t10-failure-messages.sh` can
# assert it: name, code and the guest's status word in, one diagnostic out.
# The path goes through `$REPO` — resolved by `readlink -f` above — because
# `$0` under a symlinked or PATH invocation points at the link, the `.` fails,
# and with no `set -e` every failure line then degrades to a command-not-found
# while the run looks normal: the silent diagnostic loss this file exists to
# remove. The hard stop for a missing file lives in `cmd_run`, not at this
# line: the cleanup verbs (`clean`, `destroy`, `shell`) must stay reachable in
# the one situation where the diagnostic file is absent — a broken checkout
# must not keep its 8 GiB machine because the thing that names failures is
# missing.
[ -r "$REPO/tests/failure_messages.sh" ] && . "$REPO/tests/failure_messages.sh"

# `lxc list -c s` prints the whole table, not the state, so the comparison
# against RUNNING never matched and every provision tried to start a machine
# that was already up. `-f csv` gives the bare value.
_state() { $LXC list "$1" -f csv -c s 2>/dev/null; }
_exists() { $LXC info "$1" >/dev/null 2>&1; }

# `lxc config get <instance> root.pool` answers with an empty string and exit 0
# on this LXD, so reading the pool that way reported every machine as being on
# no pool at all — which sent provision down the rebuild path every run. The
# value is in `config show`, under the root device.
_pool_of() {
    $LXC config show "$1" 2>/dev/null \
        | sed -n '/^  root:/,/^[a-z]/p' \
        | awk '/^[[:space:]]+pool:/ {print $2; exit}'
}

# This LXD build has no `lxc snapshot list`: `lxc snapshot` only creates, and
# `lxc snapshot list foo` parses "list" as an instance name. Snapshots are read
# out of `lxc info` and deleted as `<instance>/<snapshot>`.
_has_snapshot() {
    # `grep -q` exits at the first match and leaves `sed` with SIGPIPE, which
    # `set -o pipefail` then reports as the pipeline failing — so a snapshot that
    # demonstrably exists reads as absent, and every run rebuilt the golden for
    # ten minutes. Capture first, then match.
    local listing
    listing=$($LXC info "$1" 2>/dev/null | sed -n '/^Snapshots:/,$p') || return 1
    printf '%s\n' "$listing" | grep -qE "^\| +$SNAPSHOT +"
}

# The golden's identity, and the only half of the cache key the harness does not
# choose itself (ticket 210). Everything here is asked of LXD and hashed as read:
# which instance, which pool, which snapshot, and when LXD says that snapshot was
# created.
#
# **The creation time is the field that makes a rebuild visible**, and it has to
# come from LXD rather than from this file. A golden identified by what the
# harness put in it — the image, the user-data, the conversion state — is
# identical before and after a rebuild, because those inputs are identical, so
# every cached result would answer from a machine that no longer exists.
# `lxc info` reports each snapshot with its own creation time, and re-snapshotting
# a rebuilt golden gives a new one.
#
# The timestamp is found by its **shape** on the snapshot's own row rather than by
# its column. LXD's table carries a description column whose width follows the
# text in it, so a fixed field number reads a different column on a golden that
# happened to take a description, and reads the ETag on one that did not — either
# of which is an identity that changes for no reason. A row's first timestamp is
# the snapshot's creation, and there is nothing else on the row that has one.
#
# `--no-cache` is *not* an answer to an unreadable identity: it runs everything
# and inherits nothing, which is the honest response to a golden that may have
# been rebuilt and the only answer available without rebuilding it by hand.
_snapshot_created() {
    $LXC info "$1" 2>/dev/null | awk -v want="$SNAPSHOT" '{
        n = split($0, cell, "|")
        for (i = 1; i <= n; i++) {
            key = cell[i]
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
            if (key != want) continue
            for (j = i + 1; j <= n; j++) {
                value = cell[j]
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
                if (value ~ /^[0-9]{4}[-/][0-9]{2}[-/][0-9]{2} [0-9]{2}:[0-9]{2}/) {
                    print value
                    exit
                }
            }
        }
    }'
}
_golden_identity() {
    printf 'instance=%s\n' "$GOLDEN"
    printf 'pool=%s\n' "$(_pool_of "$GOLDEN")"
    printf 'snapshot=%s\n' "$SNAPSHOT"
    printf 'created=%s\n' "$(_snapshot_created "$GOLDEN")"
}

# _golden_digest: the identity, hashed. Empty output means the identity could not
# be read, and a run with no golden identity inherits nothing and says so —
# a cache keyed on nothing answers for a machine it cannot name.
_golden_digest() {
    printf '%s\n' "$(_golden_identity)" | python3 "$CACHE_TOOL" golden 2>/dev/null
}

vm_exec_t() {
    local instance=$1
    shift
    # stdin is inherited, and that is deliberate: `_push` pipes a tarball through
    # this helper, and a `</dev/null` here would hand the guest an empty archive.
    # The suite exec closes its own stdin at its own call site, which is the only
    # place a suite's stdin is a question rather than an input.
    $LXC exec -T "$instance" -- bash -lc "$*"
}

# A suite gets a wall clock. The VM is a real machine and a real tool can wedge,
# and a run that wedges reports nothing at all: the guest process is gone, the
# harness is waiting on `lxc exec`, and no line is ever printed. That is the one
# failure mode with no diagnostic, and this is the diagnostic.
# `GUARDEN_LXC_SUITE_TIMEOUT` is in seconds. Eight minutes, and the number is
# measured rather than preferred: the preamble every machine suite runs
# (`stage_podlet_release`, `soil packages --apply`, `soil install --apply`) is
# network-bound — the family's package index refresh and the pinned podlet
# fetch — and two back-to-back `--no-cache` runs of t250-verb-split.sh on this
# host measured that same preamble at 71 s and at 167 s. At the 180 s this used
# to be, the second run left the suite 13 s for its own work and `timeout` killed
# it with 124 before its first assertion — a false failure of a suite that had
# done nothing wrong, which is the opposite of what this clock is for. 480 s is
# the wall the reviewer's own measurement needed to pass the same suite, it still
# costs a genuinely wedged suite eight minutes rather than ten, and
# `GUARDEN_LXC_SUITE_TIMEOUT` still overrides it for a run that wants tighter.
SUITE_TIMEOUT=${GUARDEN_LXC_SUITE_TIMEOUT:-480}

# Two more wall clocks, both on the way to handing a machine to a suite
# (ticket 271).
#
# `APT_LOCK_WAIT` is how long a cut waits for apt's locks to come free, in
# seconds. It replaces a count of 60 checks — each of which could spend 20s in
# `lxc exec` before its 5s sleep, so the budget was somewhere between 300s and
# 25 minutes and the failure message had to say "at least 300s" because it did
# not know. 600s is twice what the three occurrences of 2026-10-13 burned; each
# one expired while a transient holder was still working (every suite skipped
# for one was green on a later re-run and green in the other pass), and this
# repository has already widened a bound against the same kind of holder —
# `apt_waits` in tests/lib.sh went from 12s to 60s when a boot-time
# `unattended-upgrades` proved it walks a whole machine's package set. No bound
# wins against every holder, so the budget is the guard and the evidence the
# failure prints is the answer when it does not.
APT_LOCK_WAIT=${GUARDEN_LXC_APT_LOCK_WAIT:-600}
# `cloud-init status --wait` polls until cloud-init reports a final state and
# has no end of its own: cloud-init that never gets there would hold the cut
# with nothing printed, which is the wedge every other exec on this path is
# bounded against. Its result was never read, and the lock wait is what decides
# readiness, so past the bound the only thing lost is the honest signal.
CLOUD_INIT_WAIT=${GUARDEN_LXC_CLOUD_INIT_WAIT:-600}

# Ready means the agent answers, not that the state says RUNNING.
_wait_ready() {
    local instance=$1 i
    for ((i = 0; i < 160; i++)); do
        if $LXC exec -T "$instance" -- true >/dev/null 2>&1; then
            return 0
        fi
        sleep 3
    done
    return 1
}

_boot_id() {
    vm_exec_t "$1" 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null | tr -d '\r\n'
}

# cloud-init reports done, and it is the only thing that knows when apt is no
# longer holding the dpkg lock.
_wait_cloud_init() {
    local instance=$1
    # **Wait on apt's locks as well as on cloud-init, and this is the whole fix.**
    # `cloud-init status --wait` returns as soon as cloud-init reports done, but
    # cloud-init's own `package_update` can still be holding
    # `/var/lib/apt/lists/lock` at that moment. Measured on a cut machine: the
    # lists lock is held from 12.5s of uptime to 23.5s, and `_wait_ready` has
    # already returned by 12s — so a suite that calls `soil packages --apply` in
    # its first seconds loses the race, and `apt-get` does not wait: it exits 100
    # with `Could not get lock`.
    #
    # **What was observed is a `FAIL` with no `error:` line under it**, which is
    # how t20-podlet and t90-projects failed in a full gate while passing alone.
    # An earlier version of this comment said "nothing on stderr", and that is a
    # stronger claim than the evidence: `hosttool.run` uses `capture_output=True`
    # and `run_or_die` re-reports the first line as `error: apt-get ...`, so an
    # apt-lock failure should print. The mechanism above is measured; the silence
    # is not fully explained by it, and that gap is recorded rather than papered
    # over.
    #
    # Both locks are asked about, and the lists one first: `package_update` holds
    # the lists lock on its own and the `packages:` install holds `lock-frontend`
    # afterwards, and the lock that lost the race was the lists one.
    # The cloud-init wait is kept because it is the honest signal when it works,
    # and its result is deliberately not used to skip the lock wait: `status
    # --wait` can return before `package_update` has released the lists lock,
    # which is the race this function exists to close. It is bounded — see
    # `CLOUD_INIT_WAIT` above — because `status --wait` has no end of its own;
    # the lock wait below is what decides readiness, so past the bound the only
    # thing lost is that signal.
    timeout --foreground --signal=KILL "$CLOUD_INIT_WAIT" \
        $LXC exec -T "$instance" -- cloud-init status --wait >/dev/null 2>&1 || :
    # **`fuser` may be absent, and its absence would make this a silent no-op.**
    # It comes from `psmisc`, which is NOT in the cloud-init package list below —
    # it is present on the golden only because `ubuntu-standard` pulls it in
    # (measured: `apt-cache rdepends --installed psmisc` lists ubuntu-standard).
    # A minimal image that drops that metapackage would lose it, and the wait
    # below would then spend its whole budget answering `unmeasured` before
    # failing: a slow failure where an immediate, named one is what a
    # host this broken deserves. That is why the check exists, and why it is
    # checked rather than assumed.
    #
    # **`sh -c` is load-bearing.** `command -v` is a shell BUILTIN, not a binary,
    # so `lxc exec … -- command -v fuser` tries to exec a file called `command`
    # and fails with `Error: Command not found` — which this guard then read as
    # "fuser is absent" and returned early on EVERY machine. Measured: it fired
    # 52 times in one gate and disabled the very wait it was added to protect.
    # Running it through `sh -c` is what makes the builtin resolve.
    # **The wait's own outcome is reported, and the loop's timeout is a failure.**
    # `return 0` on every path means a caller under `set -euo pipefail` cannot
    # tell "waited and the locks came free" from "waited 300s and gave up", from
    # "`lxc exec` was dead", or from "fuser was never there". The first is the
    # purpose of this function and the other three are all the same thing: no
    # wait happened and the race is wide open. Adversarial review named this the
    # strongest remaining defect, so every path that did not wait now says so
    # with its exit status rather than only on stderr.
    # **`fuser` absent is exit 1, not a warning-and-continue.** An earlier version
    # of this returned 0 after printing a warning, and adversarial review caught
    # that it contradicted its own commit message: "a warning rather than a
    # silent success" is false, because the exit code IS the contract and 0 says
    # the wait succeeded. A caller cannot see stderr and a code at once. Every
    # path that did not wait must say so with its status, or the caller proceeds
    # into the race believing it was protected.
    if ! $LXC exec -T "$instance" -- sh -c 'command -v fuser' >/dev/null 2>&1; then
        printf 'error: fuser is not on %s, so the apt lock wait cannot run; ' \
            "$instance" >&2
        printf 'install psmisc on the golden, or a suite that calls `soil packages` ' >&2
        printf 'early will lose the lock race\n' >&2
        return 1
    fi
    # **The lock files themselves are checked for the same reason `fuser` is,
    # and the check answers in a word for the same reason too.** A missing
    # file is the second measured fatal cause (`Specified filename … does not
    # exist.`) and the loop reads it as `unmeasured`: correct, and slow. But
    # a bare `lxc exec` status cannot carry the answer — a transport blip
    # exits 1 as well, and reading that as "missing" would fail a cut with a
    # wrong cause, which is worse than the slow honest path. The guest prints
    # which of the files is absent; no word at all means the exec could not be
    # reached, and the loop below then measures it honestly instead.
    local lockword missing
    lockword=$(timeout --foreground --signal=KILL 20 $LXC exec -T "$instance" -- sh -c '
        for f in /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock; do
            [ -e "$f" ] || printf "missing:%s\n" "$f"
        done
        printf ok') || lockword=''
    case "$lockword" in
        ok) ;;
        missing:*)
            missing=${lockword#missing:}
            missing=${missing%%$'\n'*}
            printf 'error: %s is missing %s, so no check of the wait can come free\n' \
                "$instance" "$missing" >&2
            return 1 ;;
    esac
    # **The guest answers one word, because every exit code the local side can
    # read is ambiguous.** Measured: `fuser` exits 1 both for "none of the
    # specified files is accessed" (empty stderr) and for a fatal error that
    # measured nothing — `Specified filename … does not exist.` and `Cannot
    # stat …: Permission denied` say so on stderr and exit 1 — and an `lxc
    # exec` that cannot reach the instance exits 1 as well. The man page says
    # it outright: non-zero covers "none accessed **or a fatal error**". So
    # the guest decides — `free`, `held:<who>(<pid>),…` or `unmeasured` — and a
    # transport failure produces no word at all, which is a fourth way of not
    # having measured and is treated as such. The held word now carries the
    # holder because ticket 271's message could not say who: `last answer: held`
    # told a run that a lock existed and nothing about whether it was
    # cloud-init's apt, `unattended-upgrades`, or the measurement itself.
    # **The loop runs to a wall clock and not to a count of checks** (see
    # `APT_LOCK_WAIT`): a count whose every iteration may cost 20s of `lxc exec`
    # before its sleep is a budget nobody can state, which is why the old
    # message had to print "at least 300s" — the loop did not know its own
    # elapsed time. `SECONDS` is the shell's own clock and the elapsed time it
    # gives back is what the failure below prints.
    local started=$SECONDS answer='' holder='' elapsed
    while [ $((SECONDS - started)) -lt "$APT_LOCK_WAIT" ]; do
        # The poll itself is bounded, so a wedged `lxc exec` cannot hold the
        # loop past a single pass: a 124 from `timeout` leaves the word empty and
        # is retried like any other failed measurement. `--foreground` is as
        # load-bearing here as it is on the suite exec below — without it
        # `timeout` puts the child in a new process group, and `lxc exec`'s
        # session does not survive that: the client then waits on a session
        # nobody will close, so the bound would reintroduce the wedge it is
        # here to cap.
        answer=$(timeout --foreground --signal=KILL 20 $LXC exec -T "$instance" \
            -- sh -c "$APT_LOCK_GUEST" aptlock probe 2>/dev/null)
        # Only `free` — measured with an empty stderr — is the answer being
        # waited for. A `held:` word keeps the last holder it named, and
        # `unmeasured` and the empty word both want another pass, so anything
        # but `free` falls through to the sleep.
        case $answer in
            free) return 0 ;;
            held:*) holder=${answer#held:} ;;
        esac
        sleep 5
    done
    # **Held after the whole budget, or not askable at all — and ticket 271 says
    # printing those as one line is the defect.** The old message read
    # "still holds the apt lock after …, or the wait could not measure it (last
    # answer: held)": two diagnoses and the evidence for neither, so the next
    # occurrence was a re-run rather than a fact. So the expiry prints what was
    # seen first — `fuser -v` naming whoever has the locks open, the
    # `systemctl status` of cloud-init.service, apt-daily.service and
    # unattended-upgrades.service, and the tail of cloud-init's own log, which
    # is the ticket's list in the ticket's order — and then one of two lines:
    # the holder, if one was ever named, or the plain fact that nothing could be
    # measured. A silent success here is the failure mode this function exists
    # to prevent: the caller proceeds, loses the race, and the suite dies with
    # no diagnostic.
    elapsed=$((SECONDS - started))
    local evidence
    evidence=$(timeout --foreground --signal=KILL 30 $LXC exec -T "$instance" \
        -- sh -c "$APT_LOCK_GUEST" aptlock evidence 2>/dev/null) || evidence=''
    if [ -n "$evidence" ]; then
        printf 'note: apt lock evidence on %s, waited %ss:\n' "$instance" "$elapsed" >&2
        printf '%s\n' "$evidence" >&2
    else
        printf 'note: no apt lock evidence could be captured from %s (the exec did not answer)\n' \
            "$instance" >&2
    fi
    if [ -n "$holder" ]; then
        printf 'error: %s still holds the apt lock after %ss (held by %s; last answer: %s); ' \
            "$instance" "$elapsed" "$holder" "${answer:-no answer from the exec}" >&2
        printf 'the evidence above is fuser -v, systemctl status and cloud-init.log; a suite that runs `soil packages` now may exit 100\n' >&2
    else
        printf 'error: the apt locks on %s could not be shown free after %ss (last answer: %s); ' \
            "$instance" "$elapsed" "${answer:-no answer from the exec}" >&2
        printf 'the evidence above is what the wait could see; a suite that runs `soil packages` now may exit 100\n' >&2
    fi
    return 1
}

_conversion_state() {
    $LXC exec -T "$1" -- cat /var/lib/guarden/soil/state 2>/dev/null | tr -d '\r\n'
}

# _reboot <instance>: reboot and come back. The boot id is the only honest
# signal, because a machine still up from before the reboot answers `lxc exec`
# perfectly well for the first few seconds.
_reboot() {
    local instance=$1 old new i
    old=$(_boot_id "$instance")
    vm_exec_t "$instance" 'sudo systemctl reboot' >/dev/null 2>&1 || true
    for ((i = 0; i < 240; i++)); do
        sleep 3
        new=$(_boot_id "$instance")
        if [ -n "$new" ] && [ "$new" != "$old" ]; then
            _wait_ready "$instance"
            return $?
        fi
    done
    return 1
}

# _push <instance> <local-path> <guest-path>: tar over stdin rather than a disk
# device. A mounted host tree would let the harness's state land back on the
# developer's checkout, which is the one leak this design must not have.
#
# **The developer's `.venv` does not travel.** It is the checkout's own
# interpreter and the two libraries the renderer needs, so it can change what
# a suite runs against — but a suite in the machine must run against the
# machine's `python3-yaml` and `python3-jinja2`, which the golden carries, and
# not against whatever the developer last installed. Shipping the venv would
# put a host's `pip install` in the middle of a machine's result: a suite
# could pass on one checkout and fail on another for a reason the tree does
# not hold. The guest's packages are the substrate; the venv is the
# developer's.
_push() {
    local instance=$1 src=$2 dst=$3
    tar -C "$src" --exclude=./.venv -cf - . | vm_exec_t "$instance" \
        "sudo mkdir -p '$dst' && sudo tar -C '$dst' -xf - && sudo chown -R root:root '$dst'"
}
# The package list is the harness's, not guarden's: `soil packages` converges
# packages/packages.toml on a host, and the harness must not test its own list
# against itself. Everything here stands in for something a fake used to.
_user_data() {
    cat <<'CLOUD'
#cloud-config
package_update: true
packages:
  - python3
  - python3-yaml
  - python3-jinja2
  - iproute2
  - iptables
  - btrfs-progs
  - snapper
  - passwd
  - uidmap
  - curl
  - ca-certificates
  - sudo
  - util-linux
  - kmod
  - procps
  - git
  - rsync
  - dracut-core
  # **The substrate, and it is deliberate that it is here as well as in
  # `packages/packages.toml`.** Ticket 200's doctrine is "the packages are
  # already baked into the golden", and the rebuild of 2026-10-12 showed what
  # a golden without `ferm`, `fail2ban` and `podman` does to the suites that
  # use them before their own apply: `t100-homepage`'s firewall unit never
  # loaded and `t150-auth`'s module add failed the same way. The other two reds
  # of that rebuild were different classes and were fixed elsewhere --
  # `t110-previews` needed the `/var/lib/guarden` traverse (`df0b268`) and
  # `t130-packages` died on a rolled-back golden transaction, not on this
  # list. The rendered document carries the raw
  # substrate; `t15-cutlist.sh` holds this list to `soil packages --list`, so a
  # package added to the one list cannot miss the other.
  - ferm
  - fail2ban
  - podman
  - python3-pip
CLOUD
}

_ensure_pool() {
    if $LXC storage show "$POOL" >/dev/null 2>&1; then
        return 0
    fi
    mkdir -p "$POOL_SOURCE" || die "cannot create $POOL_SOURCE"
    $LXC storage create "$POOL" btrfs source="$POOL_SOURCE" >/dev/null \
        || die "cannot create the btrfs pool $POOL; a dir pool makes a restore take 101s"
}

# _convert <instance>: converge the root filesystem with the product's own
# machinery, across the reboots it asks for.
#
# **This drives `soil storage`, not a copy of it.** The conversion script is
# shipped under `src/guarden/templates/convert/` and the phase is what runs it
# and reports a staged reboot, so the harness pushes the checkout and does what
# an operator does — apply, reboot when the marker says so, apply again. There
# used to be a second copy of the script under `tests/` for this function; it
# was the same file kept in two places, and it is gone.
_convert() {
    local instance=$1 rc attempt
    _wait_ready "$instance" || die "$instance is not answering"
    if ! _push "$instance" "$REPO" "$VM_REPO"; then
        die "cannot place the checkout on $instance"
    fi
    for ((attempt = 1; attempt <= 6; attempt++)); do
        rc=0
        vm_exec_t "$instance" "cd $VM_REPO && PYTHONPATH=src python3 -m guarden.soil storage --apply" || rc=$?
        # 255 is the LXD agent not answering, which right after a boot is a
        # transient rather than a conversion failure. Re-prove the machine is
        # alive and try the same stage again before giving up on it.
        if [ "$rc" = 255 ]; then
            printf '  storage: agent did not answer (attempt %d), settling\n' "$attempt"
            _wait_ready "$instance" || die "$instance stopped answering"
            sleep 10
            continue
        fi
        # **A reboot is the marker's question, not an exit code's.** `soil`
        # exits 0/1/2 and never 75 (spec 1.2), and an armed machine is a 1 with
        # the marker set: the marker is the thing that survives the reboot, and
        # it is the file `soil storage --check` reports by name.
        if vm_exec_t "$instance" 'test -e /var/lib/guarden/soil/reboot-required'; then
            printf '  storage: a reboot is required (attempt %d)\n' "$attempt"
            _reboot "$instance" || die "the machine did not come back after a conversion reboot"
            continue
        fi
        if vm_exec_t "$instance" "cd $VM_REPO && PYTHONPATH=src python3 -m guarden.soil storage --check"; then
            printf '  storage: the conversion converged\n'
            return 0
        fi
        die "storage did not converge and no reboot is outstanding (apply exited $rc)"
    done
    die "storage did not converge in six stages (last apply exited $rc)"
}

# _prove <instance>: the capabilities the suite depends on, checked before any
# test runs. A missing capability is a harness finding, reported as one, rather
# than surfacing later as a guarden defect.
_prove() {
    local instance=$1
    vm_exec_t "$instance" 'python3 -c "import yaml, jinja2"' \
        || die "$instance lacks python3-yaml or python3-jinja2"
    vm_exec_t "$instance" 'btrfs subvolume show / >/dev/null && btrfs subvolume list / | grep -q "@var"' \
        || die "$instance has no btrfs root with @ and @var; soil storage will never converge on it"
    vm_exec_t "$instance" 'btrfs subvolume create /var/lib/guarden/.probe >/dev/null 2>&1 &&
        btrfs subvolume delete /var/lib/guarden/.probe >/dev/null 2>&1' \
        || die "$instance cannot create a btrfs subvolume under /var/lib/guarden"
    vm_exec_t "$instance" 'getent passwd nobody >/dev/null' \
        || die "$instance has no real user database"
    vm_exec_t "$instance" 'command -v iptables >/dev/null && command -v snapper >/dev/null' \
        || die "$instance lacks iptables or snapper"
}

cmd_provision() {
    # A missing guest half of the wait is a broken checkout, not a machine's
    # problem, so it stops the run here — before a machine is cut — the way a
    # missing failure_messages.sh stops `cmd_run`. Waiting without it would
    # spend the whole budget answering nothing and report the wrong cause; and
    # `die` rather than a returned 1, because every caller of the wait treats a
    # failure as that one machine's and would skip suites instead of the run.
    [ -n "$APT_LOCK_GUEST" ] \
        || die "$APT_LOCK_SH is unreadable; a cut cannot wait for apt's locks without it"
    _ensure_pool

    # The rebuild decision needs the machine's own conversion state, which needs
    # it running. So the existence check comes first, the start happens, and only
    # then can the state be asked — otherwise a stopped golden reads as "no
    # state" and every run rebuilds for ten minutes.
    if _exists "$GOLDEN"; then
        local pool
        pool=$(_pool_of "$GOLDEN")
        if [ "$pool" != "$POOL" ]; then
            printf 'replacing %s: it is on pool %s, not %s\n' "$GOLDEN" "$pool" "$POOL"
            $LXC stop "$GOLDEN" --force >/dev/null 2>&1 || true
            $LXC delete "$GOLDEN" --force >/dev/null 2>&1 \
                || die "cannot delete $GOLDEN; remove it by hand"
        elif _has_snapshot "$GOLDEN"; then
            # Nothing to do, and nothing needs the machine booted to say so:
            # `lxc info` lists a stopped instance's snapshots. Booting it just to
            # ask costs 45 seconds on every invocation.
            return 0
        fi
    fi

    if ! _exists "$GOLDEN"; then
        $LXC init "$IMAGE" "$GOLDEN" --vm --storage "$POOL" >/dev/null \
            || die "cannot create $GOLDEN from $IMAGE on pool $POOL"
        $LXC config set "$GOLDEN" limits.cpu 4
        $LXC config set "$GOLDEN" limits.memory 8GiB
        $LXC config set "$GOLDEN" boot.autostart false
        $LXC config device override "$GOLDEN" root size=32GiB >/dev/null 2>&1 || true
        # Piped on stdin, as `next` did: no temporary file, no `lxc config edit`.
        # A document whose first line is not `#cloud-config` is ignored in
        # silence, which is why readiness is proven by asking the machine whether
        # the packages arrived rather than by waiting a fixed time.
        _user_data | $LXC config set "$GOLDEN" cloud-init.user-data -
        _needs_build=1
    fi

    [ "$(_state "$GOLDEN")" = RUNNING ] || $LXC start "$GOLDEN" >/dev/null
    _wait_ready "$GOLDEN" || die "$GOLDEN did not become ready"

    # cloud-init installs the package list, and it answers before it has
    # finished. Asking anything of apt while it runs loses the dpkg lock, which
    # is how snapper went missing from a golden — the capability gate caught it,
    # but the honest wait is cloud-init's own.
    #
    # **The exit status is checked, and that is the point of the function
    # returning one.** `tests/lxc.sh` runs under `set -uo pipefail` and NOT
    # `set -e`, so an unchecked non-zero return here is silently ignored — the
    # diagnostic prints and the run continues into the race anyway.
    _wait_cloud_init "$GOLDEN" || die "cannot wait for cloud-init on $GOLDEN"

    if [ "${_needs_build:-0}" = 0 ] && [ "$(_conversion_state "$GOLDEN")" != done ]; then
        printf 'replacing %s: no snapshot and its conversion state is not done\n' "$GOLDEN"
        $LXC stop "$GOLDEN" --force >/dev/null 2>&1 || true
        $LXC delete "$GOLDEN" --force >/dev/null 2>&1 \
            || die "cannot delete $GOLDEN; remove it by hand"
        cmd_provision
        return 0
    fi

    local i
    for ((i = 0; i < 120; i++)); do
        vm_exec_t "$GOLDEN" 'python3 -c "import yaml, jinja2"' >/dev/null 2>&1 && break
        sleep 5
    done
    vm_exec_t "$GOLDEN" 'python3 -c "import yaml, jinja2"' \
        || die "$GOLDEN never finished installing python3-yaml and python3-jinja2"

    # cloud-init installs the list, and it silently skips a package whose
    # install fails — snapper was missing from one golden this way, and the
    # capability gate below is what caught it. Re-assert the list rather than
    # trust that it landed.
    #
    # **The apt lock has to be waited for, because on a FRESH boot the
    # lock is held by cloud-init's own `package_update`.** Measured
    # 2026-10-21: this install lost the race and printed "Could not get lock
    # /var/lib/dpkg/lock-frontend. It is held by process 6351 (apt-get)", and
    # because the whole call was `|| true` the failure was INVISIBLE — the
    # provision carried on to the conversion, which then failed on a missing
    # snapper ("snapper is not installed (No such file or directory)"), and the
    # real cause was two steps earlier.
    #
    # The wait is `_wait_cloud_init`'s, which is already the runner's own
    # answer to "are apt's locks free" — but it is called BEFORE the yaml
    # loop above, and cloud-init's `package_update` can still be running
    # after that returns, because `status --wait` can report done while the
    # per-boot `package_update` still holds the lists lock. So the wait is
    # repeated HERE, immediately before the install that needs it, and the
    # install's own failure is no longer swallowed.
    #
    # **The install is no longer `|| true`, and that is the point.** A golden
    # that silently lacks snapper is a golden whose conversion fails an hour
    # later with a cause three steps removed. Failing here, with apt's own
    # message, is the cheap and honest failure.
    _wait_cloud_init "$GOLDEN" || die "cannot wait for apt's locks on $GOLDEN"
    vm_exec_t "$GOLDEN" 'export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq --no-install-recommends
            snapper btrfs-progs iptables iproute2 passwd uidmap curl ca-certificates' \
        >/dev/null 2>&1 \
        || die "$GOLDEN could not install the golden's own packages; apt's locks are held or the mirror is unreachable"
    # **And the install is ASSERED, not assumed.** The `|| true` that used to
    # hide this also hid a partially-installed list, and the capability gate
    # below is the only other place snapper's absence was caught — after the
    # conversion had already failed. snapper is the one package the conversion
    # itself needs, so its absence is fatal here rather than later.
    vm_exec_t "$GOLDEN" 'command -v snapper >/dev/null' \
        || die "$GOLDEN has no snapper, and the root conversion cannot configure one"

    # Preconditions the real-host tests plant for themselves today. They are
    # planted here instead so a green run does not depend on one test having run
    # first: `users.group_id` raises without the group, and `snapper
    # create-config` fails if snapperd is not answering over dbus.
    vm_exec_t "$GOLDEN" 'getent group guarden >/dev/null || groupadd -r guarden
        mkdir -p /etc/guarden /var/lib/guarden
        systemctl enable --now snapperd >/dev/null 2>&1 || true' >/dev/null 2>&1 || true

    # LXD grows the block device; the guest has to grow the partition and the
    # filesystem. Left undone, btrfs-convert refuses for want of headroom and
    # the refusal reads as a conversion problem rather than a disk-size one.
    vm_exec_t "$GOLDEN" 'export DEBIAN_FRONTEND=noninteractive
        apt-get install -y -qq cloud-guest-utils >/dev/null 2>&1 || true
        growpart /dev/sda 1 >/dev/null 2>&1 || true
        resize2fs /dev/sda1 >/dev/null 2>&1 || true
        partprobe /dev/sda 2>/dev/null || true' >/dev/null 2>&1 || true
    vm_exec_t "$GOLDEN" 'avail=$(df -Pk / | awk "NR==2 {print \$4}")
        [ "${avail:-0}" -ge 4194304 ] || {
            echo "only ${avail}KB free on /; refusing to convert" >&2; exit 1; }' \
        || die "$GOLDEN has less than 4GiB free on /; btrfs-convert needs headroom"

    printf 'converting the golden root to btrfs (this reboots it twice)...\n'
    _convert "$GOLDEN"
    _prove "$GOLDEN"

    if _has_snapshot "$GOLDEN"; then
        $LXC delete "$GOLDEN/$SNAPSHOT" >/dev/null 2>&1 || true
    fi
    # **A graceful stop, and the sync before it, because the snapshot is the
    # artifact.** A forced stop kills the guest within seconds of the phase's
    # last convergence, and btrfs commits roughly every 30s: the final
    # transaction -- `state=done`, the marker cleared, the root snapper
    # configuration -- was still in the page cache, and the snapshot carried
    # the state before it (`migrated`, marker present, no configurations). The
    # build's own `--check` had passed because it read the same page cache;
    # only a rebooted cut could see the rollback, which is how `t130-packages`
    # found it through the apt hook. The sync commits what the phase wrote;
    # systemd's own shutdown then unmounts cleanly. Force is the fallback, not
    # the first choice, and it exists for a guest that will not shut down.
    vm_exec_t "$GOLDEN" "sync" >/dev/null 2>&1 || true
    $LXC stop "$GOLDEN" --timeout 60 >/dev/null 2>&1 \
        || $LXC stop "$GOLDEN" --force >/dev/null 2>&1 || true
    $LXC snapshot "$GOLDEN" "$SNAPSHOT" >/dev/null \
        || die "cannot snapshot $GOLDEN"

    # **The snapshot is verified from a machine that reboots from it, because
    # the builder's own session cannot see what a stop rolls back.** Every
    # check above reads the running machine, and the running machine's page
    # cache is exactly what an uncommitted transaction lives in: on
    # 2026-10-12 `soil storage --check` passed on a golden whose snapshot
    # carried the state before its final apply, and only a cut could tell.
    # This cut reads the premises the suites ride: the conversion state, the
    # marker, and the snapper configuration the apt hook needs.
    local probe="${GOLDEN}-probe"
    $LXC delete "$probe" --force >/dev/null 2>&1 || true
    $LXC copy "$GOLDEN/$SNAPSHOT" "$probe" >/dev/null 2>&1 \
        || die "cannot cut a probe from $GOLDEN/$SNAPSHOT"
    $LXC start "$probe" >/dev/null 2>&1 || die "the probe cut did not start"
    for ((i = 0; i < 60; i++)); do
        $LXC exec -T "$probe" -- true >/dev/null 2>&1 && break
        sleep 3
    done
    $LXC exec -T "$probe" -- bash -lc '
        test "$(cat /var/lib/guarden/soil/state 2>/dev/null)" = done &&
        test ! -e /var/lib/guarden/soil/reboot-required &&
        snapper -c root get-config >/dev/null 2>&1' >/dev/null 2>&1 \
        || die "a cut from $GOLDEN/$SNAPSHOT does not carry the converged storage state"
    $LXC delete "$probe" --force >/dev/null 2>&1 || true
    printf '  the probe cut carries the converged state\n'

    printf 'provisioned %s on pool %s (snapshot %s)\n' "$GOLDEN" "$POOL" "$SNAPSHOT"
}

# _reset: cut a fresh machine from the golden. A test that leaks is a test that
# passes for the wrong reason, and the next test is the one that reports it.
_reset() {
    if _exists "$RUNNER"; then
        $LXC stop "$RUNNER" --force >/dev/null 2>&1 || true
        $LXC delete "$RUNNER" --force >/dev/null 2>&1 || true
    fi
    if _has_snapshot "$GOLDEN"; then
        # Copying *from the snapshot* is the documented form and the cheap one:
        # on a btrfs pool it is a subvolume snapshot, not a disk copy.
        # 4GiB per runner, not the golden's 8GiB: measured, a booted-but-idle
        # guest costs ~1.1GB of HOST memory and dpkg peaked at 1.4GB, so 4GiB is
        # headroom over any observed use and is what makes three parallel runners
        # uneventful rather than watchdog-managed. Set at CUT time because LXD
        # refuses to RAISE memory on a running instance ("Cannot increase memory
        # size beyond boot time size"), and lowering it live works but then the
        # boot-time size and the limit disagree.
        $LXC copy "$GOLDEN/$SNAPSHOT" "$RUNNER" -c limits.memory=4GiB \
            >/dev/null 2>&1 || return 1
    else
        $LXC copy "$GOLDEN" "$RUNNER" >/dev/null || return 1
    fi
    $LXC start "$RUNNER" >/dev/null || return 1
    _wait_ready "$RUNNER" || return 1
    # **cloud-init, before the suite.** A machine cut from the golden is a new
    # instance to cloud-init, so it re-runs this harness's own user-data on every
    # boot: `package_update: true` and nineteen packages, which is an
    # `apt-get update` followed by an `apt-get install` holding apt's locks.
    #
    # Measured on a cut machine: the lists lock is held from 12.5 s of uptime to
    # 23.5 s, and `_wait_ready` above has already returned by 12 s, so a suite
    # that calls `soil packages --apply` in its first seconds loses the race and
    # gets `E: Could not get lock /var/lib/apt/lists/lock. It is held by process
    # N (apt-get)`. `apt-get` does not wait: two concurrent real `apt-get update`
    # runs on this machine, one exit 0 and one exit 100 with that diagnostic,
    # both inside five seconds.
    #
    # **This is the harness's claim and not the product's.** The writer is this
    # file's own user-data, so no change to `soil` can remove the race — which is
    # exactly why `soil packages` also disables the distribution's own apt timers
    # and why that change fixes no suite here: no timer in the list is the thing
    # holding the lock at 12 s.
    # **A non-zero return here is the caller's to handle, not this function's to
    # act on.** `_reset`'s callers already branch on it: the per-suite cut prints
    # `error: cannot cut a clean <name>` and CONTINUES to the next suite, and the
    # shared cut dies. Calling `die` from in here would abort the whole gate for
    # one machine's problem, which is the opposite of what the caller wants.
    _wait_cloud_init "$RUNNER" || return 1
    _push "$RUNNER" "$REPO" "$VM_REPO"
}

_run_suite() {
    local name=$1 rc=0 marker
    # -T always, and with stdin closed and a wall clock. A command that reads
    # stdin — an echo-off prompt, a tool that asks a question — otherwise
    # blocks forever on a stream nobody is feeding, and the run stops with no
    # failure anywhere. A suite that needs input must be given it the way
    # `lib.sh` gives a value to `systemd-creds` — on a pipe, in the test.
    #
    # `--foreground` is load-bearing and was not optional. `timeout` otherwise
    # puts its child in a **new process group**, and `lxc exec` talks to the
    # guest agent over a session that does not survive that: the guest ran the
    # suite to completion, exited, and the client waited on a session nobody
    # would ever close again. The symptom was a wedge with no test process in
    # the guest and nothing printed, which is the failure this timeout exists
    # to report — so the timeout was causing the thing it was added to catch.
    #
    # **The exit code is returned rather than reduced to a boolean.** A failure
    # must reach the ledger and must not be recorded, and the one thing that
    # decides both is whether this suite actually passed.
    # **The guest writes its own word before it exits, and the runner reads it
    # when the code alone is ambiguous.** The wrapper below puts `<name> <rc>`
    # in a file inside the machine; if the file says `<name> 1`, the suite
    # itself stopped with 1 and its own line is the diagnostic; if it does not,
    # the exec never confirmed the suite ran. Measured: `lxc exec` itself exits
    # 1 when it cannot reach the instance, so rc=1 is the one code an assertion
    # and a lost transport share.
    timeout --foreground --signal=KILL "$SUITE_TIMEOUT" \
        $LXC exec -T "$RUNNER" --cwd "$VM_REPO" \
        --env "PYTHONPATH=$VM_REPO/src" \
        --env "GUARDEN_ROOT=$VM_REPO" \
        -- bash -c "cd '$VM_REPO' || exit 97; rm -f /tmp/guarden-suite-status; \
bash tests/$name; rc=\$?; printf '%s %s' \"$name\" \"\$rc\" >/tmp/guarden-suite-status; exit \$rc" \
        </dev/null || rc=$?
    if [ "$rc" -eq 0 ]; then
        python3 "$CACHE_TOOL" line pass "$name"
        return 0
    fi
    python3 "$CACHE_TOOL" line fail "$name"
    if [ "$rc" -eq 1 ] || [ "$rc" -eq 124 ]; then
        # rc=1 and rc=124 are the two codes an assertion and a lost transport
        # (or the wall clock) share — measured: `timeout` passes a child's own
        # 124 through, so 124 alone is as ambiguous as 1 — and the guest's own
        # word is read back for both before the line is chosen; the choice
        # itself is `_failure_message`, where a suite can assert it.
        marker=$(timeout --foreground --signal=KILL 20 $LXC exec -T "$RUNNER" -- cat /tmp/guarden-suite-status 2>/dev/null) \
            || marker=''
        _failure_message "$name" "$rc" "$marker"
    else
        _failure_message "$name" "$rc"
    fi
    return "$rc"
}

cmd_run() {
    local pat=${1:-}
    [ "$#" -gt 0 ] && shift

    # **The one hard stop for a missing failure_messages.sh, scoped to the verb
    # that needs it.** The source line above is tolerant on purpose, so `clean`,
    # `destroy` and `shell` still work in a checkout where the diagnostic file
    # is gone; a run without it could not name a single failure, so this is
    # where the die belongs.
    command -v _failure_message >/dev/null 2>&1 \
        || die "$REPO/tests/failure_messages.sh is unreadable; a run cannot name a failure without it"

    # Four flags and none of them about the suites: what a run shares is decided
    # by each suite, and the flags decide what happens to a suite that says
    # nothing.
    local fresh=0 shared=0 reverse=0 no_cache=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --fresh) fresh=1 ;;
            --shared) shared=1 ;;
            --reverse) reverse=1 ;;
            --no-cache) no_cache=1 ;;
            *) die "unknown option for run: $1" ;;
        esac
        shift
    done
    if [ "$fresh" = 1 ] && [ "$shared" = 1 ]; then
        die "--fresh and --shared are opposites; pass one"
    fi

    cmd_provision || exit 1

    # A run that is interrupted must not leave a running VM behind holding 8 GiB
    # of the host's memory until someone notices. The golden survives; the
    # runner does not.
    trap '_teardown_runner' EXIT INT TERM

    # The selected suites, in the order they will run, and for each one **the
    # machine it will be on** — both decided here, before anything runs.
    #
    # `--reverse` reverses the selection rather than the machine: sharing is a
    # claim about one suite not contaminating the next, and only running the
    # shared ones in both orders asks the question. The machine travels with the
    # suite through the reversal, because it is a property of the suite's place
    # in the sharing order.
    #
    # Both are decided here rather than in the loop because **the cache must not
    # change them.** A group derived from the run's own progress would make a
    # shared suite's key a function of whether its neighbours hit or missed: a
    # first run where three shared suites all ran numbers them 1, and a second
    # run where the first is inherited numbers the other two 2 — so the two runs
    # disagree about the machine they were on and the cache inherits nothing.
    # Counted from the selection, the number is the same in every run and
    # describes what was cut rather than what was observed.
    #
    # `runner` is one machine and no history, so every suite wanting its own
    # shares that name: a green observed on one of them is a claim about the
    # machine it ran on and nothing else.
    local files=() groups=() frishes=() reversed=() rev_groups=() rev_frishes=()
    local file name i group=0 slot=0 want_fresh machine
    local overridden=0
    for file in "$REPO"/tests/t[0-9]*.sh; do
        [ -f "$file" ] || continue
        name=${file##*/}
        if [ -n "$pat" ] && [[ "$name" != *"$pat"* ]]; then
            continue
        fi
        if _is_host_only "$name"; then
            continue
        fi
        if [ "$shared" = 1 ]; then
            want_fresh=0
            machine=0
        elif [ "$fresh" = 1 ]; then
            want_fresh=1
            machine="fresh-$slot"
            _shares_machine "$file" && overridden=$((overridden + 1))
        else
            want_fresh=1
            _shares_machine "$file" && want_fresh=0
            if [ "$want_fresh" = 1 ]; then
                machine="fresh-$slot"
            else
                machine="shared-$group"
                group=$((group + 1))
            fi
        fi
        files+=("$file")
        groups+=("$machine")
        slot=$((slot + 1))
        frishes+=("$want_fresh")
    done
    if [ "$reverse" = 1 ]; then
        for ((i = ${#files[@]} - 1; i >= 0; i--)); do
            reversed+=("${files[$i]}")
            rev_groups+=("${groups[$i]}")
            rev_frishes+=("${frishes[$i]}")
        done
        files=("${reversed[@]}")
        groups=("${rev_groups[@]}")
        frishes=("${rev_frishes[@]}")
    fi

    local total=0 failures=0 cuts=0

    # What this run may inherit is decided once, before the first suite. It is
    # the golden's identity and nothing else: the tree is read per suite, by the
    # key, from the checkout the suite is about to run against.
    #
    # `--no-cache` does not skip the identity, because it still records: a release
    # gate's run is an observation like any other, and the results it observed are
    # the best thing to leave behind. It is the consulting that is suppressed.
    local golden_digest
    golden_digest=$(_golden_digest)
    if [ -z "$golden_digest" ]; then
        printf 'note: the golden at %s carries no readable snapshot identity, so\n' "$GOLDEN"
        printf 'note: nothing can be inherited and nothing can be recorded\n'
    else
        python3 "$CACHE_TOOL" prune "$golden_digest"
    fi

    # The ledger: one line per selected suite, `verdict<TAB>name`. It is the run's
    # own record of what happened, and the summary is computed from it rather
    # than from counters that a caller could set to anything. A ledger written
    # somewhere it cannot be read is a run that reports nothing, so it is
    # created up front and its directory is refused if it cannot be written.
    local ledger
    ledger=$(mktemp -d)/ledger
    : >"$ledger" || die "cannot write a run ledger"

    # The mode is part of the key, not a run-wide annotation, and it carries two
    # things a run decides.
    #
    # **The policy**, because `--shared` and `--fresh` put a suite on a machine
    # another suite changed, and a green observed that way is a claim about a
    # different machine than a green observed on one of its own.
    #
    # **The order**, because a shared suite's machine carries the history of
    # whatever shared suites ran on it before, and `just test-reverse` runs the
    # same suites in the opposite order. Without the order in the key, a green
    # observed in a reversed run would answer for the forward run's machine —
    # the one contamination claim this repository cares most about not making,
    # because `--reverse` exists to ask exactly that question.
    local mode
    case "$fresh:$shared:$reverse" in
        1:0:0) mode=fresh ;;
        1:0:1) mode=fresh-reversed ;;
        0:1:0) mode=shared ;;
        0:1:1) mode=shared-reversed ;;
        0:0:0) mode=declared ;;
        0:0:1) mode=declared-reversed ;;
    esac

    # One machine for the shared suites, cut once before the first of them and
    # kept for the rest. A suite that needs one of its own closes the group: the
    # next shared suite gets a clean machine rather than the one the fresh suite
    # just changed.
    local shared_open=0

    for ((i = 0; i < ${#files[@]}; i++)); do
        file=${files[$i]}
        name=${file##*/}
        total=$((total + 1))
        group=${groups[$i]}
        want_fresh=${frishes[$i]}

        # A hit costs nothing: no machine is cut and no suite is executed. What it
        # costs is the claim, so the line printed is the ticket's central
        # requirement — an inherited suite announces itself as inherited, and a
        # line that could be read as a pass is not acceptable here.
        #
        # A hit does not open a shared group either. The suite it stands for did
        # not run, so the machine the next shared suite gets is the one its group
        # was cut as, which was decided from the selection above.
        local key=''
        if [ -n "$golden_digest" ]; then
            key=$(python3 "$CACHE_TOOL" key "$golden_digest" "$file" "$mode" "$group")
            if [ "$no_cache" = 0 ] && python3 "$CACHE_TOOL" get "$golden_digest" "$key" "$name"; then
                printf 'inherit\t%s\n' "$name" >>"$ledger"
                python3 "$CACHE_TOOL" line inherited "$name"
                continue
            fi
        fi

        if [ "$want_fresh" = 1 ]; then
            if ! _reset; then
                printf 'fail\t%s\n' "$name" >>"$ledger"
                printf 'error: cannot cut a clean %s\n' "$RUNNER" >&2
                failures=$((failures + 1))
                shared_open=0
                continue
            fi
            cuts=$((cuts + 1))
            shared_open=0
        elif [ "$shared_open" = 0 ]; then
            _reset || die "cannot cut a clean $RUNNER"
            cuts=$((cuts + 1))
            shared_open=1
        fi

        local rc=0
        _run_suite "$name" || rc=$?
        if [ "$rc" -eq 0 ]; then
            printf 'pass\t%s\n' "$name" >>"$ledger"
        else
            printf 'fail\t%s\n' "$name" >>"$ledger"
            failures=$((failures + 1))
            continue
        fi

        # Reached only for exit 0, and `put` refuses anything else a second time.
        # A failure has no record, so the next run runs the suite rather than
        # inheriting it — the whole of what makes a cached green worth anything.
        if [ -n "$golden_digest" ]; then
            python3 "$CACHE_TOOL" put "$golden_digest" "$key" "$name" "$mode" "$group" 0 \
                || die "cannot record the result of $name; the cache is not writable"
        fi
    done

    if [ "$fresh" = 1 ] && [ "$overridden" -gt 0 ]; then
        printf 'note: --fresh cuts a machine per file and overrode the shared declaration of %d suite(s)\n' \
            "$overridden"
    fi
    local report_args=(--ledger "$ledger" --golden "$golden_digest" --cuts "$cuts")
    [ "$no_cache" = 1 ] && report_args+=(--no-cache)
    python3 "$CACHE_TOOL" report "${report_args[@]}"
    [ "$failures" -eq 0 ]
}

cmd_shell() {
    cmd_provision || exit 1
    _reset || die "cannot cut a clean $RUNNER"
    exec $LXC exec "$RUNNER" --cwd / -- bash
}

_teardown_runner() {
    if _exists "$RUNNER"; then
        $LXC stop "$RUNNER" --force >/dev/null 2>&1 || true
        $LXC delete "$RUNNER" --force >/dev/null 2>&1 || true
    fi
}

cmd_clean() {
    # Everything this harness made, and nothing else. `infra-test-golden` is the
    # maintainer's own fixture and is never touched here; `probe-c1` is a
    # leftover from an earlier session whose snapshot holds a read-only /etc,
    # which needs root to remove.
    _teardown_runner
    if _exists "$GOLDEN"; then
        $LXC stop "$GOLDEN" --force >/dev/null 2>&1 || true
        $LXC delete "$GOLDEN" --force >/dev/null 2>&1 \
            && printf 'deleted %s\n' "$GOLDEN"
    fi
    if $LXC storage show "$POOL" >/dev/null 2>&1; then
        $LXC storage delete "$POOL" >/dev/null 2>&1 \
            && printf 'deleted pool %s (%s)\n' "$POOL" "$POOL_SOURCE"
    fi
    printf 'clean. still present, not mine:\n'
    $LXC list 2>&1 | tail -n +2
}

cmd_destroy() {
    _teardown_runner
    if _exists "$GOLDEN"; then
        $LXC stop "$GOLDEN" --force >/dev/null 2>&1 || true
        $LXC delete "$GOLDEN" --force >/dev/null 2>&1 || true
    fi
    printf 'destroyed %s and %s\n' "$GOLDEN" "$RUNNER"
}

case "${1:-run}" in
    provision) shift; cmd_provision "$@" ;;
    run) shift; cmd_run "$@" ;;
    shell) shift; cmd_shell "$@" ;;
    destroy) shift; cmd_destroy "$@" ;;
    clean) shift; cmd_clean "$@" ;;
    *)
        printf 'usage: %s {provision|run [pat] [--fresh|--shared|--reverse|--no-cache]|shell|destroy|clean}\n' \
            "$0" >&2
        exit 2
        ;;
esac
