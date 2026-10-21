#!/usr/bin/env bash
# psmisc is in the package list, the golden-VM document carries it, and the cut
# list bakes it.
#
# (ticket 322)
#
# **The list has two consumers, and the second one is the one that failed.**
# `soil packages` converges `packages/packages.toml` and `tools/render-user-data`
# renders that same file into the cloud-init document a machine boots from. A
# package in one and forgotten in the other is a host that installs three things
# and converges on a fourth, and both machines report success — so psmisc is
# asserted in BOTH places below, read out of the two real outputs rather than
# against a third copy written in this file.
#
# **`fuser` is the tool, and the wait is the harness's.** The cut's apt-lock
# wait asks the machine whether apt's locks are free, and `fuser` is how it
# asks: `fuser`'s own man page says a non-zero exit covers "none of the
# specified files is accessed *or a fatal error*", so the guest decides what
# the answer means (tests/aptlock.sh). Without `fuser` the wait cannot run at
# all, and the runner refuses to cut a box rather than enter the race
# believing it was protected.
#
# **The golden carried psmisc by accident, and the accident is not the claim.**
# `ubuntu-standard` depends on it and `procps` merely recommends it, so an
# image that drops the metapackage loses `fuser` and every suite that needs
# the wait cannot cut. A dependency that arrives because an unrelated
# metapackage pulled it in is a dependency nobody declared.
#
# machine: shared
# it reads the one list and renders the document; it converges nothing, starts
# no machine, installs no package and touches no host state.

. "$(dirname "$0")/lib.sh"

LIST=$GUARDEN_ROOT/packages/packages.toml
RUNNER=$GUARDEN_ROOT/tests/lxc.sh

# --- the one list names it --------------------------------------------------

# The file an operator edits, and the program's own answer about the role it
# sits in. `soil packages --list` prints the SUBSTRATE — what a host converges
# — and the conditional roles under their own headings; it never prints the
# harness role, which `soil packages` does not converge on a host.
assert_file_has "$LIST" '"psmisc"'

run soil packages --list
assert_exit 0
assert_stdout_lacks "psmisc"

run soil packages --list --family debian
assert_exit 0
assert_stdout_lacks "psmisc"

# --- and the rendered document carries it ----------------------------------

# The golden-VM document: the substrate AND the harness tools. This is the
# document a throwaway machine boots, and the harness tools are in it because
# a throwaway machine is what they are for.
golden=$GUARDEN_FIXTURES/user-data.golden-vm.yaml
run soil packages --render-user-data "$golden" --profile golden-vm
assert_exit 0
assert_file_has "$golden" "#cloud-config"
assert_file_has "$golden" "- psmisc"

# The vps document: the substrate and nothing else. **This is the one that
# settles the role.** A package in the harness role appears in the golden-VM
# document and NOT in the vps one, so a psmisc that is in the golden-VM
# document and absent from this one is in the harness role rather than in the
# substrate — which is what it must be, because nothing under `src/guarden`
# calls fuser and the product does not wait for apt's locks at all.
vps=$GUARDEN_FIXTURES/user-data.vps.yaml
run soil packages --render-user-data "$vps" --profile vps
assert_exit 0
assert_file_has "$vps" "#cloud-config"
assert_file_lacks "$vps" "- psmisc"

# --- and the cut list bakes it ---------------------------------------------

# The cut's cloud-init document is the HARNESS's own list (the heredoc in
# tests/lxc.sh), not guarden's: the harness must not test its own list against
# itself. The substrate rides in it because a suite that uses a substrate
# package before its own apply is riding the golden (ticket 200), and
# `t15-cutlist.sh` is the keeper of that.
#
# **The wait needs fuser BEFORE any suite runs**, and the wait is the runner's
# own, before the checkout is even pushed into the cut — so a package the
# packages phase would install later is not enough. The cut has to carry it
# from the boot, or the runner refuses the machine and every suite that needed
# the wait is skipped for a reason that names a package nobody installed.
[ "$(grep -c "<<'CLOUD'" "$RUNNER")" = 1 ] \
    || _fail "tests/lxc.sh no longer carries exactly one cloud-init heredoc"
sed -n "/<<'CLOUD'/,/^CLOUD\$/p" "$RUNNER" \
    | sed -n 's/^  - //p' | sort >"$GUARDEN_FIXTURES/cutlist-packages"
grep -qx 'psmisc' "$GUARDEN_FIXTURES/cutlist-packages" \
    || _fail "the cut list does not bake psmisc, so a cut has no fuser and the apt-lock wait cannot run"

# --- and the guard points at the place that fixes it -----------------------

# The runner's guard is correct and stays: it fails closed, with a named
# error, rather than entering the race believing it was protected. What it
# said while psmisc was in no list at all — "install psmisc on the golden" —
# is advice for a dev image and not for a host, and the list is where the
# dependency is declared. The message names the list now.
runner_text=$(grep -vE '^[[:space:]]*#' "$RUNNER")
if printf '%s\n' "$runner_text" | grep -qF -- "install psmisc on the golden"; then
    _fail "the runner still tells the reader to install psmisc on the golden by hand; the package list is where it is declared"
fi
printf '%s\n' "$runner_text" | grep -qF -- "packages.toml" \
    || _fail "the runner's fuser guard does not name the package list, so it tells a reader nothing actionable"

echo "t322-psmisc-package-list: ok"
