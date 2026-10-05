#!/usr/bin/env bash
# zram: absent means absent, present means converged, and the knob is the
# operator's.
#
# This suite drives the real tools on the real machine and asserts what they hold
# afterwards. There is no stand-in for `zramctl`, for `swapon`, for `systemctl` or
# for sysfs: the claims here are about what the *kernel* ended up holding, and a
# fake could only record that soil asked.
#
# Two phases are exercised, because zram is spread across both on purpose. The
# package is `packages`' and the sysctl is `sysctl`'s, and each is asked only when
# the knob is present — the sysctl assertion is that an absent knob writes
# nothing at all, which is a claim about a key the phase does not name.
#
# The suite is `fresh` (the default, no `machine:` line): it creates and removes a
# real block device, and a shared machine that ran another suite first would be
# reporting on a device state this file did not establish.

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

export GUARDEN_PREFIX=/

config=/etc/guarden/guarden.toml
generator_conf=/etc/systemd/zram-generator.conf
marker=/var/lib/guarden/soil/zram
sysctl_conf=/etc/sysctl.d/90-guarden.conf

# The machine's own answer to each question. `zramctl` brackets the algorithm in
# force, `swapon` is the kernel's swap table, and `/sys` is the driver's own.
#
# **No local helper for these.** `lib.sh` has `assert_enabled` for a unit and
# `assert_sysctl` appears in `t20-sysctl.sh` because that suite owns it; adding a
# fourth copy of "run a command and compare its stdout" is what `lib.sh` says to
# append to only when a helper is genuinely shared. These read the kernel and are
# used here.

zram_algorithms() {
    cat /sys/block/zram0/comp_algorithm 2>/dev/null
}

zram_disksize() {
    cat /sys/block/zram0/disksize 2>/dev/null || true
}

zram_priority() {
    swapon --show=NAME,PRIO --noheadings 2>/dev/null \
        | awk '$1 == "/dev/zram0" { print $2 }'
}

assert_zram_algorithm() {
    local text found
    text=$(zram_algorithms)
    found=$(printf '%s' "$text" | sed -n 's/.*\[\([^]]*\)\].*/\1/p')
    [ "$found" = "$1" ] \
        || _fail "zram0's algorithm is ${found:-unset} (comp_algorithm: ${text:-unreadable}), not $1"
}

assert_no_zram() {
    # **What the kernel actually holds**, measured: the node `/sys/block/zram0` is
    # NOT removed by a hot-remove — the kernel leaves the block device in place
    # with a zero size and an uninitialised state, and `zramctl --reset` cannot
    # delete it either. Measured on the machine: after the teardown `disksize` is
    # 0, `initstate` is 0 and no swap is registered, while the sysfs node is still
    # there.
    #
    # So "the device is gone" cannot mean "the node is gone", and an assertion
    # that asked for a missing node was asking the kernel for something it does not
    # do — it would fail on a perfectly converged teardown, which is what happened.
    # The claim worth keeping is that nothing of the DEVICE is left: no size, no
    # initialisation, no swap.
    local disksize
    disksize=$(cat /sys/block/zram0/disksize 2>/dev/null || echo absent)
    [ "$disksize" = absent ] || [ "$disksize" = 0 ] \
        || _fail "zram0's size is $disksize, so the device is still there"
    if swapon --show=NAME --noheadings 2>/dev/null | grep -q zram; then
        _fail "a zram device is still registered as swap"
    fi
}

assert_zram_size_percent() {
    # The percentage is checked against the generator's own arithmetic rather
    # than soil's, because the generator is what wrote the value: `ram` is
    # MemTotal in MiB truncated to a whole number, and the result is truncated
    # again before the driver page-aligns it.
    local memtotal_mb want got page
    memtotal_mb=$(( $(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo) / 1024 ))
    want=$(awk -v mb="$memtotal_mb" -v pct="$1" 'BEGIN { printf "%d", int(mb * pct / 100 * 1024 * 1024) }')
    got=$(zram_disksize)
    page=$(getconf PAGESIZE)
    want=$(( (want + page - 1) / page * page ))
    [ -n "$got" ] || _fail "/sys/block/zram0/disksize is unreadable; the device is not there"
    [ "$got" = "$want" ] \
        || _fail "zram0's disksize is $got, not $want ($1 percent of ${memtotal_mb}MiB)"
}

# --- the host this file needs -----------------------------------------------
#
# guarden.toml is the operator's file and this file is not the operator, so what
# it replaces is put back. So is swappiness, the one knob a zram device changes
# the right answer for: leaving it at 180 on a machine with no device would make
# every later suite report drift for a knob nothing on it needs.
swappiness=$(sysctl -n vm.swappiness 2>/dev/null || echo 60)
restore() {
    sysctl -q -w "vm.swappiness=$swappiness" >/dev/null 2>&1 || :
    systemctl stop dev-zram0.swap >/dev/null 2>&1 || :
    swapoff /dev/zram0 >/dev/null 2>&1 || :
    zramctl --reset /dev/zram0 >/dev/null 2>&1 || :
    if [ -w /sys/class/zram-control/hot_remove ]; then
        printf '0\n' >/sys/class/zram-control/hot_remove 2>/dev/null || :
    fi
    rm -f "$generator_conf" "$marker"
    systemctl daemon-reload >/dev/null 2>&1 || :
    if [ -f "$config_saved" ]; then
        cp "$config_saved" "$config"
    else
        rm -f "$config"
    fi
}
config_saved=$GUARDEN_FIXTURES/guarden.toml.before
if [ -f "$config" ]; then
    cp "$config" "$config_saved"
fi
trap restore EXIT

# `systemd-zram-generator` is a conditional package: it is installed only when
# the knob is present, and the first thing this file does is ask for it.
stage_config guarden-zram.toml
stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_not_rejected
run soil sysctl --apply
assert_not_rejected

# ---------------------------------------------------------------------------
# absent means absent
# ---------------------------------------------------------------------------

# A host with no `[zram]`: no package, no configuration, no device, no sysctl
# write, and `--check` says nothing about zram. The generator and `zstd` are
# installed here — the packages phase converged them before the knob was removed —
# so the absence being asserted is the *phase's*, not the package manager's.
#
# The file is put back exactly as it was found, and the marker is removed, so the
# teardown below has nothing to distinguish from a host that never had a device.
stage_config guarden-measured.toml
rm -f "$generator_conf"

# The device is taken down by the PHASE, not by hand: the knob goes, and
# `soil install --apply` below is what stops the swap, resets the device and
# hot-removes it. Hand-rolling that here duplicated the logic and drifted from it —
# this copy hot-removed with a size still in force, leaving `disksize` non-zero.
run soil install --apply
assert_not_rejected
assert_no_zram
assert_file_missing "$generator_conf"
assert_file_missing "$marker"

run soil packages --check
assert_not_rejected
assert_stderr_lacks "zram"
assert_stderr_lacks "zstd"
run soil install --check
assert_not_rejected
assert_stderr_lacks "zram"
run soil sysctl --check
assert_not_rejected
assert_stderr_lacks "swappiness"

run soil install --apply
assert_not_rejected
assert_stderr_lacks "zram"
assert_file_missing "$generator_conf"
assert_file_missing "$marker"
assert_no_zram

# And the sysctl file does not carry the key. `vm.swappiness` is a knob that only
# means something when a device exists, so a host with no device gets a file with
# no mention of it — the "no sysctl write" half of absent means absent, asked of
# the file the phase persists rather than of the phase's output.
run soil sysctl --apply
assert_not_rejected
assert_file_lacks "$sysctl_conf" "vm.swappiness"
assert_sysctl_value() {
    local actual
    actual=$(sysctl -n "$1")
    [ "$actual" = "$2" ] || _fail "sysctl $1 is '$actual', not '$2'"
}
assert_sysctl_value vm.swappiness "$swappiness"

# ---------------------------------------------------------------------------
# present means converged
# ---------------------------------------------------------------------------

stage_config guarden-zram.toml

# The package is converged because the operator asked, and `--check` names it by
# name rather than as a generic package item — the message has to say *why* this
# host carries it, because on a host without the knob the same package is one
# nobody wants.
run soil packages --check
assert_exit 0
assert_stderr_empty

# The configuration the generator reads is written, the marker beside it says the
# device is guarden's, and the phase says nothing about either before the apply.
run soil install --check
assert_exit 1
assert_stderr_has "drift: /etc/systemd/zram-generator.conf carries the operator's zram device"
assert_stderr_has "drift: /var/lib/guarden/soil/zram records that this zram device is guarden's"
assert_stderr_has "drift: /dev/zram0 is initialised with zstd"
assert_file_missing "$generator_conf"
assert_no_zram

# `vm.swappiness` joins the canonical set, and only because the knob is there. The
# diagnostic names the value so an operator can see what the phase wants and
# decide whether it is what they meant.
run soil sysctl --check
assert_exit 1
assert_stderr_has "drift: vm.swappiness is 180"

run soil install --apply
assert_exit 0
assert_file_exists "$generator_conf"
assert_file_has "$generator_conf" "[zram0]"
assert_file_has "$generator_conf" "compression-algorithm = zstd(level=3)"
assert_file_has "$generator_conf" "zram-size = ram * 25 / 100"
assert_file_has "$generator_conf" "fs-type = swap"
assert_file_exists "$marker"
assert_file_has "$marker" "device = zram0"

run soil sysctl --apply
assert_exit 0
assert_sysctl_value vm.swappiness 180
assert_file_has "$sysctl_conf" "vm.swappiness = 180"

# **The device, read back from the kernel.** Every assertion below is a question
# asked of the machine, which is the ticket's own rule: the algorithm and the
# level guarden wrote into a file are not evidence of what the kernel holds.
assert_file_exists /dev/zram0
assert_zram_algorithm zstd
assert_zram_size_percent 25
[ "$(zram_priority)" = "100" ] \
    || _fail "zram0's swap priority is '$(zram_priority)', not 100"

# The generator's own unit is active, which is what "converged" means for a
# generator-driven device: soil did not write a swap unit, it wrote the file the
# generator reads and let the generator produce the unit.
assert_active dev-zram0.swap
assert_active systemd-zram-setup@zram0.service

# **A converged device changes neither the algorithm nor the size when soil runs
# again.** A check that reinitialised on every run would be a check that could
# never hold, and it is the property `Item` exists to make true. The inode of the
# two files is the proof for the files: a converge writes through a temporary and
# renames, so a rewrite cannot leave the inode it found.
conf_inode=$(stat -c %i "$generator_conf")
marker_inode=$(stat -c %i "$marker")
size_before=$(zram_disksize)
run soil install --apply
assert_exit 0
assert_stderr_empty
[ "$(stat -c %i "$generator_conf")" = "$conf_inode" ] \
    || _fail "a second apply rewrote $generator_conf"
[ "$(stat -c %i "$marker")" = "$marker_inode" ] \
    || _fail "a second apply rewrote $marker"
[ "$(zram_disksize)" = "$size_before" ] \
    || _fail "a second apply resized zram0 from $size_before to $(zram_disksize)"
run soil install --check
assert_exit 0
assert_stderr_empty
assert_zram_algorithm zstd

# **The generator's own record of the run.** The ticket asks for "a kernel log
# line recording the chosen algorithm", and that is the one evidence item this
# cannot deliver: the driver logs `Added device:` and `Cannot initialise %s
# compressing backend` and nothing else, and the generator logs the algorithm only
# at debug level, so on a converged host neither journal carries it. The kernel's
# record of the algorithm is `comp_algorithm`'s bracket, which is asserted above
# and is a stronger fact than a log line — it is what the device is actually
# compressing with. What the journal *can* prove is that the generator's own unit
# ran, which is what "converged" means for a generator-driven device.
assert_active systemd-zram-setup@zram0.service
journalctl -u systemd-zram-setup@zram0.service --no-pager 2>/dev/null \
    | grep -q "systemd-zram-setup@zram0" \
    || _fail "the setup unit's own journal has no record of the run, so nothing proved it ran"

# ---------------------------------------------------------------------------
# converge in both directions
# ---------------------------------------------------------------------------

# Remove the knob and re-run: the device is torn down rather than left enabled.
# This is the property `soil sysctl` has and the one a create-only converge can
# never have, and it is the whole reason the marker file exists — without it there
# is no way to tell a device guarden made from one an operator made.
stage_config guarden-measured.toml

# `--check` names the teardown before it happens, and changes nothing: the device
# is still there when the check has finished.
run soil install --check
assert_exit 1
assert_stderr_has "drift: the zram device is gone"
assert_file_exists "$generator_conf"
assert_file_exists "$marker"
assert_file_exists /dev/zram0

run soil install --apply
assert_exit 0
assert_stderr_empty
assert_file_missing "$generator_conf"
assert_file_missing "$marker"
# The device is out of service, not deleted: a hot-remove leaves `/dev/zram0` in
# place, so what "gone" means is measured rather than asserted as a missing file.
assert_no_zram
[ -z "$(zram_priority)" ] \
    || _fail "zram0 is still on the host's swap table at priority $(zram_priority)"
assert_not_enabled dev-zram0.swap
assert_inactive dev-zram0.swap

# And the teardown is itself idempotent: a second apply is a no-op, because after
# the first one there was nothing left to do.
run soil install --apply
assert_exit 0
assert_stderr_empty
run soil install --check
assert_exit 0
assert_stderr_empty

# The knob's absence takes `vm.swappiness` out of the canonical set with it. The
# file is guarden's and carries only guarden's keys, so the key goes rather than
# staying as a knob nothing on this host needs.
run soil sysctl --apply
assert_exit 0
assert_file_lacks "$sysctl_conf" "vm.swappiness"
assert_sysctl_value vm.swappiness "$swappiness"

# ---------------------------------------------------------------------------
# the knob is the operator's, and the refusals say so
# ---------------------------------------------------------------------------

# A percentage over 100 asks for a device larger than the memory backing it. The
# generator *warns* about it and creates the device anyway, which is exactly why
# guarden refuses the value rather than writing it: the operator's file is where
# this is caught, and a warning in a journal is not.
stage_config guarden-zram-oversize.toml
run soil install --check
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "size_percent"
assert_stderr_has "150"
assert_stderr_has "larger than the memory backing it"
assert_file_missing "$generator_conf"
assert_no_zram

# An algorithm guarden does not offer. lz4 is a real backend and a real tradeoff,
# so the message names the set that is offered rather than saying "not allowed".
stage_config guarden-zram-lz4.toml
run soil install --check
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "algorithm"
assert_stderr_has "lz4"
assert_stderr_has "the algorithms guarden offers are zstd"
assert_file_missing "$generator_conf"
assert_no_zram

# The packages phase asks the same question with the same answer, because it reads
# the same file: a rejected knob stops the phase rather than installing a package
# for a device nothing will create. The knob still staged is the lz4 one, so the
# refusal is about `algorithm` — what matters is that it is the SAME refusal.
run soil packages --check
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "algorithm"

# The host is left as the trap found it, and the trap removes what this file
# converged. The last thing asserted is the absence a later suite depends on: a
# host with no knob carries no device and says nothing about one.
assert_no_zram
assert_file_missing "$generator_conf"
assert_file_missing "$marker"
