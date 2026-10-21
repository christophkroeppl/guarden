#!/usr/bin/env bash
# psmisc is in the harness role of the one package list, the golden-VM document
# carries it, the cut list bakes it, and the guard names the list.
#
# (ticket 322)
#
# **The wait is the harness's own claim and not the product's.** `tests/lxc.sh`
# refuses to cut a box whose image lacks `fuser`, because the wait that closes
# the apt race cannot run without it and a wait that does not run is the race
# the wait exists to close. `fuser` comes from `psmisc`, and `psmisc` was in no
# package list at all -- not the substrate, not the harness -- so a machine that
# does not get it from `ubuntu-standard` lost the wait entirely.
#
# **This machine is not the symptom, and a suite that asserted it would be
# green before the fix and after it.** The golden carries psmisc today only
# because `ubuntu-standard` DEPENDS on it (`procps` merely RECOMMENDS it --
# measured on the golden: `apt-cache rdepends --installed psmisc` lists
# ubuntu-standard). So "fuser is on this box" is a fact about the image and not
# about the lists, and what decides whether a cut has fuser is the two lists
# that say what a machine gets. Those are what this file holds.
#
# **The list has two consumers, and the second one is the one that failed.**
# `soil packages` converges the substrate of `packages/packages.toml`, and
# `tools/render-user-data` renders that same file into the cloud-init document
# a machine boots from. A package in one and forgotten in the other is a host
# that installs three things and converges on a fourth, and both machines
# report success -- so the assertions below are made against the two real
# outputs rather than against a third copy written in this file.
#
# machine: shared
# it reads the one list, renders two documents and reads the runner; it
# converges nothing, starts no machine, installs no package and touches no
# host state.

. "$(dirname "$0")/lib.sh"

guarden_prefix

LIST=$GUARDEN_ROOT/packages/packages.toml
RUNNER=$GUARDEN_ROOT/tests/lxc.sh

# --- the one list names it, in the harness role ----------------------------

# The file an operator edits, and the program's own answer about the role it
# sits in. `soil packages --list` prints the SUBSTRATE -- what a host
# converges -- and the conditional roles under their own headings; it never
# prints the harness role, which `soil packages` does not converge on a host.
assert_file_has "$LIST" '"psmisc"'

run soil packages --list
assert_exit 0
assert_stdout_lacks "psmisc"

run soil packages --list --family debian
assert_exit 0
assert_stdout_lacks "psmisc"

# --- and the ROLE is the harness role, per family -------------------------

# **The role is what settles it, and the rendered document is what proves
# it.** The harness role is "what a throwaway machine needs on top, and no
# real host wants"; the substrate is "what a guarden host needs". The consumer
# of `fuser` is the harness alone -- `grep -rn fuser src/ tools/` returns
# nothing, and the three places that use it are `tests/lxc.sh`'s cut-time
# wait, `tests/aptlock.sh`'s probe and evidence, and `tests/lib.sh`'s
# `apt_waits`. The product does not wait for apt's locks at all: spec 6.1
# says waiting for the lock "is not available, because `apt-get` does not do
# it", and the packages phase disables the distribution's own timers instead.
# So a psmisc in the substrate would install a tool on every real host that no
# host-side program calls -- the mirror of the mistake the package list's own
# header warns about.
for family in debian fedora arch; do
    document=$GUARDEN_FIXTURES/user-data.$family.yaml
    run soil packages --render-user-data "$document" --profile golden-vm --family "$family"
    assert_exit 0
    assert_file_has "$document" "#cloud-config"

    # The packages block, and the two halves of it. The block is cut at
    # `write_files:` because that section carries `  - path:` entries, which
    # are not packages and would be read as ones.
    sed -n '/^packages:/,/^write_files:/p' "$document" \
        >"$GUARDEN_FIXTURES/block.$family"
    # The substrate is what comes before the harness comment and the harness
    # is what comes after it -- the template's own cut.
    sed -n '/^  # harness:/,$! { s/^  - //p }' "$GUARDEN_FIXTURES/block.$family" \
        >"$GUARDEN_FIXTURES/substrate.$family"
    sed -n '/^  # harness:/,$ { s/^  - //p }' "$GUARDEN_FIXTURES/block.$family" \
        >"$GUARDEN_FIXTURES/harness.$family"

    # The harness block carries the package: this is the half a throwaway
    # machine gets and a real host does not, and it is where a harness tool
    # belongs.
    grep -qxF 'psmisc' "$GUARDEN_FIXTURES/harness.$family" \
        || _fail "the $family harness package list does not carry psmisc; the harness's apt-lock wait needs fuser"

    # And the substrate block does not. A harness tool on every host is the
    # failure the other direction causes, and the product never calls fuser.
    if grep -qxF 'psmisc' "$GUARDEN_FIXTURES/substrate.$family"; then
        _fail "the $family substrate carries psmisc; it is a harness tool and no host's dependency"
    fi
done

# --- and the rendered documents agree with the role ------------------------

# The golden-VM document: the substrate AND the harness tools. This is the
# document a throwaway machine boots, and the harness tools are in it because
# a throwaway machine is what they are for.
golden=$GUARDEN_FIXTURES/user-data.golden-vm.yaml
run soil packages --render-user-data "$golden" --profile golden-vm
assert_exit 0
assert_file_has "$golden" "#cloud-config"
assert_file_has "$golden" "- psmisc"

# The vps document: the substrate and nothing else. **This is the one that
# settles the role from the outside.** A package in the harness role appears
# in the golden-VM document and NOT in the vps one, so a psmisc that is in
# the golden-VM document and absent from this one is in the harness role
# rather than in the substrate.
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
# own, before the checkout is even pushed into the cut -- so a package the
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
# said while psmisc was in no list at all -- "install psmisc on the golden" --
# is advice for a dev image and not for a host, and the list is where the
# dependency is declared. The message names the list now.
assert_file_lacks "$RUNNER" "install psmisc on the golden"
assert_file_has "$RUNNER" "psmisc provides fuser"

echo "t322-psmisc: ok"
