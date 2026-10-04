#!/usr/bin/env bash
# tests/lxc.sh — the real-host harness. A throwaway LXD **VM**, cut from a
# golden snapshot, with the real tools instead of fixtures/bin.
#
# Why this exists: fixtures/bin stands in for the host. Every one of those fakes
# is a claim about what guarden would do on a machine that has the real tool.
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
#   * The golden is **converted to btrfs before it is snapshotted**, because
#     `soil storage` verifies the layout rather than creating it.
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
#
# `--reverse` exists because sharing is a claim and a claim needs proving: the
# suites that share a machine are run in one order and then in the other, and
# both runs have to be green. It is the second half of that and nothing else.
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
CONVERT=${GUARDEN_LXC_CONVERT:-$REPO/tests/lxc-btrfs-convert}

# Tests that cannot run in the machine, by construction rather than by accident.
#
# t35-env-schema.sh asks git about the repository: `check-ignore` and
# `ls-files` need a work tree, and this checkout's `.git` is a file pointing at
# /media/data/projects/infra/.git/worktrees/service-based, which is a host path
# that does not exist in a guest. The checkout is pushed without `.git`, so the
# commands fail and the test reports git's exit 128 as a guarden defect. It is a
# repository-hygiene test, not a guarden test; `just test` still runs it.
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

_needs_fresh() {
    local path=$1 declared
    declared=$(_declaration_of "$path")
    case "$declared" in
        '') return 0 ;;
        fresh) return 0 ;;
        shared) return 1 ;;
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
# `GUARDEN_LXC_SUITE_TIMEOUT` is in seconds. Three minutes is far longer than any
# suite here takes — the whole 34-file run is about half an hour — and short
# enough that a wedge costs a quarter of a minute rather than ten.
SUITE_TIMEOUT=${GUARDEN_LXC_SUITE_TIMEOUT:-180}

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
    if $LXC exec -T "$instance" -- cloud-init status --wait >/dev/null 2>&1; then
        return 0
    fi
    # An image with no cloud-init answer is not a failure, only something that
    # cannot be waited on. Fall back to asking whether apt is still busy.
    #
    # **Both of apt's locks, and the lists one first.** `package_update` holds
    # `/var/lib/apt/lists/lock` on its own and the `packages:` install holds
    # `lock-frontend` afterwards, and the lock that lost a `soil packages` refresh
    # on the golden VM was the lists one — so a fallback that asked only about the
    # frontend lock would return while the refresh was still the thing running.
    local i
    for ((i = 0; i < 60; i++)); do
        if ! $LXC exec -T "$instance" -- sh -c \
            'fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock >/dev/null 2>&1'; then
            return 0
        fi
        sleep 5
    done
    return 0
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
_push() {
    local instance=$1 src=$2 dst=$3
    tar -C "$src" -cf - . | vm_exec_t "$instance" \
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
  - btrfs-convert
  - dracut-core
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

# _convert <instance>: drive the three-stage conversion to convergence.
#
# Exit 75 is not a failure. It is the script's way of saying the machine must
# reboot for the next stage to exist, which is the whole reason it was ported
# rather than replaced with an online conversion: btrfs-progs refuses a mounted
# device, and a live root cannot be converted under itself.
_convert() {
    local instance=$1 rc attempt
    _wait_ready "$instance" || die "$instance is not answering"
    if ! _push "$instance" "$REPO/tests" /root/guarden-tests; then
        die "cannot place the conversion script on $instance"
    fi
    for ((attempt = 1; attempt <= 6; attempt++)); do
        rc=0
        vm_exec_t "$instance" '/root/guarden-tests/lxc-btrfs-convert --apply --yes' || rc=$?
        if [ "$rc" = 0 ]; then
            return 0
        fi
        if [ "$rc" = 75 ]; then
            printf '  btrfs: stage needs a reboot (attempt %d)\n' "$attempt"
            _reboot "$instance" || die "the machine did not come back after a conversion reboot"
            continue
        fi
        # 255 is the LXD agent not answering, which right after a boot is a
        # transient rather than a conversion failure. Re-prove the machine is
        # alive and try the same stage again before giving up on it.
        if [ "$rc" = 255 ]; then
            printf '  btrfs: agent did not answer (attempt %d), settling\n' "$attempt"
            _wait_ready "$instance" || die "$instance stopped answering"
            sleep 10
            continue
        fi
        die "btrfs conversion failed with exit $rc"
    done
    die "btrfs conversion did not converge"
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
    _wait_cloud_init "$GOLDEN"

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
    vm_exec_t "$GOLDEN" 'export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq --no-install-recommends
            snapper btrfs-progs iptables iproute2 passwd uidmap curl ca-certificates || true' \
        >/dev/null 2>&1 || true

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
    $LXC stop "$GOLDEN" --force >/dev/null 2>&1 || true
    $LXC snapshot "$GOLDEN" "$SNAPSHOT" >/dev/null \
        || die "cannot snapshot $GOLDEN"

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
        $LXC copy "$GOLDEN/$SNAPSHOT" "$RUNNER" >/dev/null 2>&1 || return 1
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
    _wait_cloud_init "$RUNNER"
    _push "$RUNNER" "$REPO" "$VM_REPO"
}

_run_suite() {
    local name=$1 rc
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
    if timeout --foreground --signal=KILL "$SUITE_TIMEOUT" \
        $LXC exec -T "$RUNNER" --cwd "$VM_REPO" \
        --env "PYTHONPATH=$VM_REPO/src" \
        --env "GUARDEN_ROOT=$VM_REPO" \
        -- bash -c "cd '$VM_REPO' && bash tests/$name" </dev/null; then
        printf 'ok   %s\n' "$name"
        return 0
    fi
    rc=$?
    printf 'FAIL %s\n' "$name"
    if [ "$rc" -eq 137 ]; then
        printf 'error: %s exceeded %ss and was killed; a suite that hangs reports nothing\n' \
            "$name" "$SUITE_TIMEOUT" >&2
    fi
    return 1
}

cmd_run() {
    local pat=${1:-}
    [ "$#" -gt 0 ] && shift

    # Three flags and none of them about the suites: what a run shares is decided
    # by each suite, and the flags decide what happens to a suite that says
    # nothing.
    local fresh=0 shared=0 reverse=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --fresh) fresh=1 ;;
            --shared) shared=1 ;;
            --reverse) reverse=1 ;;
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

    # The selected suites, in the order they will run. `--reverse` reverses the
    # selection rather than the machine: sharing is a claim about one suite not
    # contaminating the next, and only running the shared ones in both orders
    # asks the question.
    local files=() reversed=() file name i
    for file in "$REPO"/tests/t[0-9]*.sh; do
        [ -f "$file" ] || continue
        name=${file##*/}
        if [ -n "$pat" ] && [[ "$name" != *"$pat"* ]]; then
            continue
        fi
        if _is_host_only "$name"; then
            continue
        fi
        files+=("$file")
    done
    if [ "$reverse" = 1 ]; then
        for ((i = ${#files[@]} - 1; i >= 0; i--)); do
            reversed+=("${files[$i]}")
        done
        files=("${reversed[@]}")
    fi

    local total=0 failures=0 cuts=0 overridden=0

    # One machine for the shared suites, cut once before the first of them and
    # kept for the rest. A suite that needs one of its own closes the group: the
    # next shared suite gets a clean machine rather than the one the fresh suite
    # just changed.
    local shared_open=0

    for file in "${files[@]}"; do
        name=${file##*/}
        total=$((total + 1))

        local want_fresh
        if [ "$shared" = 1 ]; then
            want_fresh=0
        elif [ "$fresh" = 1 ]; then
            want_fresh=1
            _needs_fresh "$file" && overridden=$((overridden + 1))
        else
            want_fresh=1
            _needs_fresh "$file" || want_fresh=0
        fi

        if [ "$want_fresh" = 1 ]; then
            if ! _reset; then
                printf 'FAIL %s\n' "$name"
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

        _run_suite "$name" || failures=$((failures + 1))
    done

    if [ "$fresh" = 1 ] && [ "$overridden" -gt 0 ]; then
        printf 'note: --fresh cuts a machine per file and overrode the shared declaration of %d suite(s)\n' \
            "$overridden"
    fi
    printf '\n%d suites, %d failures, %d machines cut\n' "$total" "$failures" "$cuts"
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
        printf 'usage: %s {provision|run [pat] [--fresh|--shared|--reverse]|shell|destroy|clean}\n' \
            "$0" >&2
        exit 2
        ;;
esac
