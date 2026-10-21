#!/usr/bin/env bash
# The harness's apt-lock wait needs fuser, and fuser needs psmisc.
#
# (ticket 322)
#
# **The wait is the harness's own claim and not the product's.** `tests/lxc.sh`
# refuses to cut a box whose image lacks fuser, because the wait that closes
# the apt race cannot run without it and a wait that does not run is the race
# the wait exists to close. Nothing under `src/guarden` calls fuser, so psmisc
# belongs to the harness role of the one package list and to the harness's own
# cut list -- the document every cut boots -- and to neither host's substrate.
#
# **This machine is not the symptom, and a suite that asserted it would be
# green before the fix and after it.** The golden carries psmisc today
# because ubuntu-standard pulls it in (measured: `apt-cache rdepends
# --installed psmisc` lists ubuntu-standard; procps only Recommends it), so
# "fuser is on this box" is a fact about the image and not about the lists.
# What decides whether a cut has fuser is the two lists that say what a
# machine gets, and those are what this file holds.
#
# machine: shared
# it renders a document and reads two files; it converges nothing and starts no
# machine.

. "$(dirname "$0")/lib.sh"

guarden_prefix

RUNNER=$GUARDEN_ROOT/tests/lxc.sh

# The rendered document is the package list's second consumer, so the claims
# are made against the rendered bytes rather than against the TOML: the
# document is what a machine boots, and a package in a list that never reaches
# a document is a package no machine gets.
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
    # belongs (packages/packages.toml's own header: keeping the role separate
    # is what stops the harness's tools from becoming every host's
    # dependency).
    grep -qxF 'psmisc' "$GUARDEN_FIXTURES/harness.$family" \
        || _fail "the $family harness package list does not carry psmisc; the harness's apt-lock wait needs fuser"

    # And the substrate block does not. A harness tool on every host is the
    # failure the other direction causes, and the product never calls fuser --
    # so a psmisc in the substrate would be a dependency nothing uses.
    if grep -qxF 'psmisc' "$GUARDEN_FIXTURES/substrate.$family"; then
        _fail "the $family substrate carries psmisc; it is a harness tool and no host's dependency"
    fi
done

# The cut list is the harness's own cloud-init document -- the one every cut
# boots and the one the wait runs on -- and it is a mirror of the substrate
# rather than the substrate itself. The heredoc is counted because a second
# one would need this anchor widened, which is why the count is asserted
# rather than assumed.
[ "$(grep -c "<<'CLOUD'" "$RUNNER")" = 1 ] \
    || _fail "tests/lxc.sh no longer carries exactly one cloud-init heredoc"
sed -n "/<<'CLOUD'/,/^CLOUD\$/p" "$RUNNER" | sed -n 's/^  - //p' \
    >"$GUARDEN_FIXTURES/cutlist-packages"
grep -qxF 'psmisc' "$GUARDEN_FIXTURES/cutlist-packages" \
    || _fail "the cut list does not bake psmisc; a cut boots this document and the wait runs on the cut"

# The guard stays -- it fails closed rather than entering the race believing it
# was protected -- and what it says points at the list that carries the
# package rather than at a hand-install on the golden.
assert_file_lacks "$RUNNER" "install psmisc on the golden"
assert_file_has "$RUNNER" "psmisc provides fuser"

echo "t322-psmisc: ok"
