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
#   tests/lxc.sh run [pat]   cut a fresh VM per test file and run it there
#   tests/lxc.sh shell       a fresh VM you can poke at
#   tests/lxc.sh prove       a fresh VM, and what its boot cost
#   tests/lxc.sh destroy     remove the golden
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
    $LXC config show "$1" 2>/dev/null |
        sed -n '/^  root:/,/^[a-z]/p' |
        awk '/^[[:space:]]+pool:/ {print $2; exit}'
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
    # **Both of apt's locks, and the lists one first.** The boot document used to
    # carry `package_update: true`, which holds `/var/lib/apt/lists/lock` on its own
    # and a `packages:` install holds `lock-frontend` afterwards, and the lock that
    # lost a `soil packages` refresh on the golden VM was the lists one — so a
    # fallback that asked only about the frontend lock would return while the
    # refresh was still the thing running.
    #
    # The document installs nothing now, so cloud-init answers almost at once and
    # this is what is left to wait for. That is the ticket's win and it is also the
    # claim: a machine whose cloud-init returns promptly and whose locks are free is
    # a machine that ran no package transaction during boot.
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

# What the image carries, and this is the only place in this file that names a
# package.
#
# **The image is provisioned at build time, so a cut machine runs no package
# transaction.** A copy of the golden is a new instance to cloud-init, and the
# document below used to be `package_update: true` and nineteen packages: every
# suite paid for an `apt-get update` and an `apt-get install` holding apt's locks,
# measured on a cut machine at 12.5 s to 23.5 s of uptime. `cmd_provision` now
# installs everything here once, before the snapshot, and leaves the document
# saying so. That is not only a clock question — `apt-daily-upgrade.service` runs
# `unattended-upgrade`, whose post-invoke hook answers this machine's
# `/etc/ufw/ufw.conf` by running `systemctl enable ufw`, so a boot that runs a
# package transaction can re-enable the distribution's firewall underneath a suite
# that has already disabled it. `t20-firewall.sh` failed on exactly that on
# 2026-10-03, and seven suites lost the same apt-lock race on 2026-10-01.
#
# Two halves, and they are different in kind. The first is guarden's own
# dependency **and the harness's**, read out of `packages/packages.toml` through
# the same renderer that writes a host's cloud-init document — so the golden ships
# exactly what that document would have installed, and a package added to the list
# reaches the machine without anyone editing this file. The second is the
# machinery that builds *this machine*: what `lxc-btrfs-convert` needs, and the
# base-image packages this harness invokes by name. Those are named here because
# they are the harness's and no guarden host wants them, which is the same reason
# `packages.toml` keeps its `harness` role in a table of its own.
#
# **It is apt only, and it must stay apt only.** `soil packages --apply` is not
# this function's caller and must not become one: it fetches the pinned podlet
# release, and `t20-podlet.sh` asserts that binary is absent on a machine
# `soil install` has not run. A golden that ran the phase would quietly answer
# both of those suites' questions for them.
_image_packages() {
    local rendered
    rendered=$(mktemp)
    if ! PYTHONPATH="$REPO/src" python3 -m guarden.soil packages \
        --render-user-data "$rendered" >/dev/null 2>&1; then
        rm -f "$rendered"
        die "the image's package list could not be rendered from packages/packages.toml"
    fi
    sed -n 's/^  - //p' "$rendered"
    rm -f "$rendered"
}

_build_tools() {
    cat <<'TOOLS'
btrfs-convert
cloud-guest-utils
dracut-core
kmod
passwd
procps
sudo
uidmap
util-linux
TOOLS
}

# The document a cut machine boots from. It installs nothing, and it says so: a
# machine whose boot document is empty is indistinguishable from one whose
# cloud-init silently did not run, and telling those two apart is the whole
# measurement this change claims. The per-boot marker is written on every boot,
# so its presence is the proof that cloud-init ran and found nothing to do.
#
# `#cloud-config` must be the first line or the document is ignored in silence,
# which is why readiness has always been proven by asking the machine rather than
# by reading its state.
_user_data() {
    cat <<'CLOUD'
#cloud-config
#
# This image is already provisioned. Its packages were installed at build time by
# `tests/lxc.sh provision`, from packages/packages.toml, before the snapshot was
# taken — so there is nothing to update and nothing to install here, and
# cloud-init reaching `done` on a cut machine is the evidence that no package
# transaction ran during boot.
#
# `soil packages --apply` still installs everything on a real host. This is the
# machine the harness cuts, not a host, and the difference is that its packages
# are already on the image.
write_files:
  - path: /var/lib/guarden-harness
    permissions: "0755"

runcmd:
  # `write_files` content is not templated, so the uptime is read here rather than
  # written as a literal `$UPTIME`. This runs on every boot of every cut machine,
  # which is what makes its presence the proof that cloud-init ran and found
  # nothing to install.
  - printf 'provisioned at build time; this boot installed nothing; uptime %ss\n' "$(cut -d. -f1 /proc/uptime)" >/var/lib/guarden-harness/BOOT

final_message: "guarden harness image already provisioned, nothing installed, $UPTIME seconds"
CLOUD
}

_ensure_pool() {
    if $LXC storage show "$POOL" >/dev/null 2>&1; then
        return 0
    fi
    mkdir -p "$POOL_SOURCE" || die "cannot create $POOL_SOURCE"
    $LXC storage create "$POOL" btrfs source="$POOL_SOURCE" >/dev/null ||
        die "cannot create the btrfs pool $POOL; a dir pool makes a restore take 101s"
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
    vm_exec_t "$instance" 'python3 -c "import yaml, jinja2"' ||
        die "$instance lacks python3-yaml or python3-jinja2"
    vm_exec_t "$instance" 'btrfs subvolume show / >/dev/null && btrfs subvolume list / | grep -q "@var"' ||
        die "$instance has no btrfs root with @ and @var; soil storage will never converge on it"
    vm_exec_t "$instance" 'btrfs subvolume create /var/lib/guarden/.probe >/dev/null 2>&1 &&
        btrfs subvolume delete /var/lib/guarden/.probe >/dev/null 2>&1' ||
        die "$instance cannot create a btrfs subvolume under /var/lib/guarden"
    vm_exec_t "$instance" 'getent passwd nobody >/dev/null' ||
        die "$instance has no real user database"
    vm_exec_t "$instance" 'command -v iptables >/dev/null && command -v snapper >/dev/null' ||
        die "$instance lacks iptables or snapper"
}

# _prove_inventory <instance>: every package the image is supposed to carry, asked
# of dpkg in one call.
#
# This is the answer ticket 200 asks to be re-derived rather than remembered. It
# used to be two suites asserting `ferm`, `fail2ban` and `podman` are **absent** on
# a fresh cut, which was a fact about an image that installed nineteen packages
# and no more. The image now carries the whole list, so an absence assertion can
# no longer distinguish "the image does not ship it" from "the phase did not
# install it", and the presence of the image's own inventory is the check that
# replaced it.
#
# `podman` is reported on its own line because it is the package the image was
# missing on 2026-10-03, and its absence is what made `t70-fork.sh` unable to
# reach a single one of its data-movement success paths.
_prove_inventory() {
    local instance=$1 wanted present missing
    wanted=$(_image_packages | sort)
    present=$(vm_exec_t "$instance" "dpkg-query -W -f='\${db:Status-Status} \${Package}\n' 2>/dev/null \
        | awk '\$1 == \"installed\" {print \$2}' | sort")
    missing=$(comm -23 <(printf '%s\n' "$wanted") <(printf '%s\n' "$present"))
    [ -z "$missing" ] ||
        die "$instance is not provisioned; these are not installed: $(printf '%s' "$missing" | tr '\n' ' ')"
    printf '  image inventory proven: %s packages, podman %s, pasta %s\n' \
        "$(printf '%s\n' "$wanted" | wc -l)" \
        "$(vm_exec_t "$instance" 'podman --version' 2>/dev/null || echo MISSING)" \
        "$(vm_exec_t "$instance" 'pasta --version 2>&1 | head -1' 2>/dev/null || echo MISSING)"
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
            $LXC delete "$GOLDEN" --force >/dev/null 2>&1 ||
                die "cannot delete $GOLDEN; remove it by hand"
        elif _has_snapshot "$GOLDEN"; then
            # Nothing to do, but the golden must be running for `lxc copy` to
            # work from its snapshot. A stopped golden makes every _reset fail.
            [ "$(_state "$GOLDEN")" = RUNNING ] || $LXC start "$GOLDEN" >/dev/null
            return 0
        fi
    fi

    if ! _exists "$GOLDEN"; then
        $LXC init "$IMAGE" "$GOLDEN" --vm --storage "$POOL" >/dev/null ||
            die "cannot create $GOLDEN from $IMAGE on pool $POOL"
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

    # cloud-init on a machine cut from this image installs nothing, so this returns
    # as soon as cloud-init has finished saying so. It stays because it is the only
    # thing that knows when apt is no longer holding the dpkg lock, and it is the
    # instrument ticket 200's claim is measured with.
    _wait_cloud_init "$GOLDEN"

    if [ "${_needs_build:-0}" = 0 ] && [ "$(_conversion_state "$GOLDEN")" != done ]; then
        printf 'replacing %s: no snapshot and its conversion state is not done\n' "$GOLDEN"
        $LXC stop "$GOLDEN" --force >/dev/null 2>&1 || true
        $LXC delete "$GOLDEN" --force >/dev/null 2>&1 ||
            die "cannot delete $GOLDEN; remove it by hand"
        cmd_provision
        return 0
    fi

    # **The image is provisioned here, once, and never again.** A cut machine is a
    # new instance to cloud-init, so a package list in the boot document is a list
    # installed once per suite; installing it before the snapshot is the whole of
    # this change, and it is also what puts `podman` and `pasta` on the image.
    #
    # `--no-install-recommends` because Recommends on `podman` is where hundreds of
    # megabytes would otherwise appear, and `pasta` must not be left to a
    # Recommends change — the same reason `src/guarden/userdata.py` names it
    # explicitly.
    #
    # **Fatal on failure, and there is no second attempt.** The old code re-asserted
    # eight packages with `|| true` because cloud-init silently skips a package whose
    # install fails — snapper was missing from one golden that way, and a capability
    # gate downstream caught it. A gate is the wrong place to find out, and the
    # whole list is asked at once.
    local list install
    list=$(mktemp)
    _image_packages "$list"
    install=$(tr '\n' ' ' <"$list")
    printf 'provisioning %s with %s packages\n' "$GOLDEN" "$(wc -l <"$list")"
    vm_exec_t "$GOLDEN" "export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq --no-install-recommends $install" ||
        die "$GOLDEN could not be provisioned from packages/packages.toml"
    rm -f "$list"
    _prove_inventory "$GOLDEN"

    # LXD grows the block device; the guest has to grow the partition and the
    # filesystem. Left undone, btrfs-convert refuses for want of headroom and
    # the refusal reads as a conversion problem rather than a disk-size one.
    #
    # This runs **after** the install above because `growpart` is
    # `cloud-guest-utils` and that is one of the packages being installed, and the
    # install costs a few hundred megabytes of a filesystem that is only about 9 GiB
    # to begin with — so the headroom the conversion needs is measured after both.
    vm_exec_t "$GOLDEN" 'growpart /dev/sda 1 >/dev/null 2>&1 || true
        resize2fs /dev/sda1 >/dev/null 2>&1 || true
        partprobe /dev/sda 2>/dev/null || true' >/dev/null 2>&1 || true
    printf 'image %s\n' \
        "$(vm_exec_t "$GOLDEN" 'df -h / | awk "NR==2 {print \$2\" total, \"\$4\" free\"}"')"

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
    vm_exec_t "$GOLDEN" 'growpart /dev/sda 1 >/dev/null 2>&1 || true
        resize2fs /dev/sda1 >/dev/null 2>&1 || true
        partprobe /dev/sda 2>/dev/null || true' >/dev/null 2>&1 || true
    vm_exec_t "$GOLDEN" 'avail=$(df -Pk / | awk "NR==2 {print \$4}")
        [ "${avail:-0}" -ge 4194304 ] || {
            echo "only ${avail}KB free on /; refusing to convert" >&2; exit 1; }' ||
        die "$GOLDEN has less than 4GiB free on /; btrfs-convert needs headroom"

    printf 'converting the golden root to btrfs (this reboots it twice)...\n'
    _convert "$GOLDEN"
    _prove "$GOLDEN"

    if _has_snapshot "$GOLDEN"; then
        $LXC delete "$GOLDEN/$SNAPSHOT" >/dev/null 2>&1 || true
    fi
    $LXC stop "$GOLDEN" --force >/dev/null 2>&1 || true
    $LXC snapshot "$GOLDEN" "$SNAPSHOT" >/dev/null ||
        die "cannot snapshot $GOLDEN"

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
    # boot.
    #
    # That document used to be `package_update: true` and nineteen packages, so
    # every cut paid for an `apt-get update` followed by an `apt-get install`
    # holding apt's locks. Measured on a cut machine: the lists lock was held from
    # 12.5 s of uptime to 23.5 s, and `_wait_ready` above has already returned by
    # 12 s, so a suite that calls `soil packages --apply` in its first seconds lost
    # the race and got `E: Could not get lock /var/lib/apt/lists/lock. It is held by
    # process N (apt-get)`. `apt-get` does not wait: two concurrent real
    # `apt-get update` runs on this machine, one exit 0 and one exit 100 with that
    # diagnostic, both inside five seconds.
    #
    # It also re-enabled the distribution's firewall underneath a suite that had
    # already disabled it: `apt-daily-upgrade.service` runs `unattended-upgrade`,
    # whose post-invoke hook answers this machine's `/etc/ufw/ufw.conf` by running
    # `systemctl enable ufw`, at 31.7 s of uptime. That is how `t20-firewall.sh`
    # failed on 2026-10-03, and it was the same cause as the seven suites that lost
    # the apt-lock race on 2026-10-01.
    #
    # **None of that is the product's and none of it is the harness's any more.**
    # The packages are on the image and the document installs nothing, so the wait
    # below returns as soon as cloud-init has finished saying so. It stays because a
    # cut that starts a suite before cloud-init is finished is a cut whose boot
    # state a suite cannot reason about, and because it is what
    # `tests/lxc.sh prove` measures the claim with.
    _wait_cloud_init "$RUNNER"
    _push "$RUNNER" "$REPO" "$VM_REPO"
}

cmd_run() {
    local pat="" file name failures=0 total=0
    local fresh="--fresh" reverse=0 no_cache=0

    while [ $# -gt 0 ]; do
        case "$1" in
            --fresh|--shared) fresh="$1" ;;
            --reverse) reverse=1 ;;
            --no-cache) no_cache=1 ;;
            --*) die "unknown option: $1" ;;
            *) pat="$1" ;;
        esac
        shift
    done

    cmd_provision || exit 1

    # A run that is interrupted must not leave a running VM behind holding 8 GiB
    # of the host's memory until someone notices. The golden survives; the
    # runner does not.
    trap '_teardown_runner' EXIT INT TERM

    # A fresh machine per test file. The tests write real /etc/guarden, real
    # /var/lib/guarden, real users and real btrfs subvolumes now that nothing is
    # faked, so a shared machine is not isolation — it is the next test inheriting
    # this one's system users and deleted snapshots. Pass `--shared` to cut one
    # machine for the whole run, which is only sound while every test still
    # relocates the host with GUARDEN_PREFIX.
    local shared=0
    if [ "$fresh" != "--fresh" ]; then
        _reset || die "cannot cut a clean $RUNNER"
        shared=1
    fi

    for file in "$REPO"/tests/t[0-9]*.sh; do
        [ -f "$file" ] || continue
        name=${file##*/}
        if [ -n "$pat" ] && [[ "$name" != *"$pat"* ]]; then
            continue
        fi
        if _is_host_only "$name"; then
            continue
        fi
        total=$((total + 1))

        if [ "$shared" = 0 ]; then
            if ! _reset; then
                printf 'FAIL %s\n' "$name"
                printf 'error: cannot cut a clean %s\n' "$RUNNER" >&2
                failures=$((failures + 1))
                continue
            fi
        fi

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
        else
            rc=$?
            if [ "$rc" -eq 137 ]; then
                printf 'FAIL %s\n' "$name"
                printf 'error: %s exceeded %ss and was killed; a suite that hangs reports nothing\n' \
                    "$name" "$SUITE_TIMEOUT" >&2
            else
                printf 'FAIL %s\n' "$name"
            fi
            failures=$((failures + 1))
        fi
    done

    printf '\n%d suites, %d failures\n' "$total" "$failures"
    [ "$failures" -eq 0 ]
}

cmd_shell() {
    cmd_provision || exit 1
    _reset || die "cannot cut a clean $RUNNER"
    exec $LXC exec "$RUNNER" --cwd / -- bash
}

# cmd_prove: the measurement ticket 200's claim is made with, and no suite can
# make it. A suite runs after `_reset` has already waited for cloud-init, so by the
# time a suite could ask whether apt was busy during boot the answer has been
# waited out — the question is unanswerable from inside a suite and only from
# here, where the cut is timed.
#
# It cuts a machine, records how long the cut took, and asks four things: was
# cloud-init reached, did it install anything, are apt's locks free, and is any
# `apt-get` still running. The per-boot marker the document writes is the fourth
# answer from the machine's own side, so "nothing was installed" is not only this
# script's opinion.
cmd_prove() {
    cmd_provision || exit 1
    trap '_teardown_runner' EXIT INT TERM

    local started elapsed
    started=$(date +%s)
    _reset || die "cannot cut a clean $RUNNER"
    elapsed=$(($(date +%s) - started))
    printf 'cut and ready in %ss\n' "$elapsed"

    printf 'cloud-init   %s\n' \
        "$(vm_exec_t "$RUNNER" 'cloud-init status --long 2>&1 | tr "\n" ";"')"
    printf 'boot marker  %s\n' \
        "$(vm_exec_t "$RUNNER" 'cat /var/lib/guarden-harness/BOOT 2>/dev/null || echo ABSENT')"
    printf 'apt running  %s\n' \
        "$(vm_exec_t "$RUNNER" 'pgrep -a apt-get 2>/dev/null || echo none')"
    printf 'dpkg log     %s\n' \
        "$(vm_exec_t "$RUNNER" 'tail -1 /var/log/dpkg.log 2>/dev/null || echo none')"
    printf 'inventory    %s\n' \
        "$(vm_exec_t "$RUNNER" 'dpkg-query -W 2>/dev/null | wc -l') packages installed"

    # `_reset` already waited for cloud-init, so both locks being free here is the
    # end of the wait rather than the whole of it. The cut's own clock is what says
    # nothing happened during boot: 39 cuts at the old 25 s of apt is minutes, and
    # the same 39 cuts now is what the wall clock above is for.
    vm_exec_t "$RUNNER" 'fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock \
        >/dev/null 2>&1 && echo "HELD" || echo free'
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
        $LXC delete "$GOLDEN" --force >/dev/null 2>&1 &&
            printf 'deleted %s\n' "$GOLDEN"
    fi
    if $LXC storage show "$POOL" >/dev/null 2>&1; then
        $LXC storage delete "$POOL" >/dev/null 2>&1 &&
            printf 'deleted pool %s (%s)\n' "$POOL" "$POOL_SOURCE"
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
provision)
    shift
    cmd_provision "$@"
    ;;
run)
    shift
    cmd_run "$@"
    ;;
shell)
    shift
    cmd_shell "$@"
    ;;
prove)
    shift
    cmd_prove "$@"
    ;;
destroy)
    shift
    cmd_destroy "$@"
    ;;
clean)
    shift
    cmd_clean "$@"
    ;;
*)
    printf 'usage: %s {provision|run|shell|prove|destroy|clean}\n' "$0" >&2
    exit 2
    ;;
esac
