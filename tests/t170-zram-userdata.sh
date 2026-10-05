#!/usr/bin/env bash
# zram on the cloud-init path: the rendered document and `tools/golden-vm --print`
# agree, and the generator is not baked into a provisioned machine.
#
# (ticket 130 for the render, ticket 170 for the omission)
#
# **A machine being provisioned is not yet a configured host.** That is the whole
# of why the generator is a `conditional` role in the package list rather than a
# substrate one: `soil packages` installs it the moment guarden.toml asks for a
# device, and a document that put it in the machine's `packages:` would give
# every golden-VM image the generator and make "absent means absent: no package"
# untestable on the one machine whose job is to test it. So the document names no
# zram package, and the phase installs one the moment the knob is there — which is
# the same path a real host takes and is what `t170-zram.sh` drives.
#
# machine: shared
# `guarden_prefix` stages the host, and everything this file reads is the
# rendered document under `$GUARDEN_FIXTURES` or the committed artefact
# `tools/golden-vm --print` names. No device is created and no sysctl is written.

. "$(dirname "$0")/lib.sh"

guarden_prefix

document=$GUARDEN_FIXTURES/user-data.yaml
run soil packages --render-user-data "$document"
assert_exit 0
assert_file_has "$document" "#cloud-config"

# The conditional role is not in the document. This is the negative that matters:
# it is what keeps a provisioned machine and a configured host distinguishable,
# and it is asserted of the rendered bytes rather than of the list.
assert_file_lacks "$document" "systemd-zram-generator"
assert_file_lacks "$document" "zram"

# The substrate and the harness tools are still there, so the omission is the
# role's and not the renderer's having stopped working. A document with no
# packages at all would satisfy the two assertions above and prove nothing.
assert_file_has "$document" "btrfs-progs"
assert_file_has "$document" "substrate: what"
assert_file_has "$document" "harness: the throwaway machine"

# The document converges every phase in `soil list`'s order, and a zram host's
# converge needs `packages` to have run before `install`: the generator is what
# turns the configuration into `dev-zram0.swap`, and a document that installed
# first would start a device whose generator is not there yet. The order is
# rendered from the program, so this compares the document against `soil list`
# rather than against a third copy written here.
run soil list
assert_exit 0
phases=$(awk '{print $1}' "$GUARDEN_STDOUT" | tr '\n' ' ')
document_order=$(grep -oE 'soil (packages|storage|sysctl|firewall|install|units) --apply' \
    "$document" | sed 's/soil //; s/ --apply//' | tr '\n' ' ')
[ "$document_order" = "$phases" ] \
    || _fail "the document converges [$document_order], soil list says [$phases]"

# `soil list` is where an operator reads what each phase owns, and the two phases
# zram touches have to say so — otherwise the knob exists and the phase that
# installs its package and the phase that writes its sysctl both claim to own
# something else.
assert_stdout_has "and vm.swappiness when this host asked for a zram device"
assert_stdout_has "and the zram device when this host asked for one"

# `--list` names the conditional role under its own heading rather than mixing it
# in with the substrate: the packages a host "needs" and the packages it installs
# because somebody asked are two different claims, and a flat list would make the
# second look like the first.
run soil packages --list --family debian
assert_exit 0
assert_stdout_has "conditional zram: installed only when the configuration asks"
assert_stdout_has "systemd-zram-generator"
assert_stdout_has "btrfs-progs"

# And the plan agrees with the document. `tools/golden-vm --print` renders from
# the same file and refuses a committed artefact that does not match it, so the
# plan naming a document that disagrees is a plan that cannot be booted.
tool golden-vm --print
assert_exit 0
assert_stdout_has "soil packages --check"
planned=$(awk '$1 == "user-data" { print $2 }' "$GUARDEN_STDOUT")
[ -n "$planned" ] || _fail "the plan names no user-data path"
assert_file_has "$planned" "#cloud-config"
assert_file_lacks "$planned" "systemd-zram-generator"
# The plan's phases are `soil list`'s phases, read from the program at print time.
planned_phases=$(awk '$1 == "phases" { $1 = ""; sub(/^ +/, ""); print }' "$GUARDEN_STDOUT" | tr '\n' ' ')
[ "$planned_phases" = "$phases" ] \
    || _fail "the plan runs [$planned_phases], soil list says [$phases]"

# The committed document is what a reviewer reads and what the machine boots, and
# it is the rendered one — so a zram package that leaked into the list would show
# up here rather than only on a rebuilt machine.
committed=$GUARDEN_ROOT/tools/cloud-init/user-data.yaml
assert_file_has "$committed" "#cloud-config"
assert_file_lacks "$committed" "systemd-zram-generator"
assert_file_lacks "$committed" "zram"
