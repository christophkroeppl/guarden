#!/bin/bash
# machine: fresh
# The cut list and the one package list agree on the substrate.
#
# `_user_data` in `tests/lxc.sh` is the cloud-init document every cut re-runs,
# and it must bake every package `soil packages --list` names: a suite that
# uses one of them before its own apply is riding the golden, which is the
# premise ticket 200 states. Measured 2026-10-12, on the first rebuilt golden:
# the cut list carried none of `ferm`, `fail2ban` and `podman`, and
# `t100-homepage` and `t150-auth` detonated before anything had applied the
# phase that installs them. The rendered document has its own keeper
# (`t130-packages.sh` renders it and holds it to this same command);
# this is that keeper for the harness's cut list, and in the one direction that
# matters: every substrate package must be baked, while the cut list may carry
# the harness's own extras on top.

. "$(dirname "$(readlink -f "$0")")/lib.sh"

# The family is the machine's own, which is what `_user_data` installs for.
run soil packages --list
assert_exit 0
grep -vE '^(family|install|query) ' "$GUARDEN_STDOUT" \
    | sed '/^conditional /,/^[^ ]/d' | sort >"$GUARDEN_FIXTURES/list-substrate"

# The heredoc's package lines, and only theirs: `<<'CLOUD'` to the closing word.
# The file carries one such heredoc; a second would need this anchor widened,
# which is why the count is asserted rather than assumed.
[ "$(grep -c "<<'CLOUD'" "$GUARDEN_ROOT/tests/lxc.sh")" = 1 ] \
    || _fail "tests/lxc.sh no longer carries exactly one cloud-init heredoc"
sed -n "/<<'CLOUD'/,/^CLOUD\$/p" "$GUARDEN_ROOT/tests/lxc.sh" \
    | sed -n 's/^  - //p' | sort >"$GUARDEN_FIXTURES/cutlist-packages"

comm -23 "$GUARDEN_FIXTURES/list-substrate" "$GUARDEN_FIXTURES/cutlist-packages" \
    >"$GUARDEN_FIXTURES/not-baked"
[ ! -s "$GUARDEN_FIXTURES/not-baked" ] \
    || _fail "substrate the cut list does not bake: $(tr '\n' ' ' <"$GUARDEN_FIXTURES/not-baked")"
