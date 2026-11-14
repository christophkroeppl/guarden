#!/usr/bin/env bash
# Which iptables table guarden's firewall rules land in, and that the host's own
# iptables can read them.
#
# The subject is not what the rules say -- `t20-firewall.sh` and
# `t180-firewall-rules.sh` own that, and the sibling working on the loopback deny
# owns the contents of `guarden-svc`. This is about WHICH table, and the
# measured reason it has to be stated rather than inherited:
#
#   **ferm 2.7 does not use update-alternatives at all.** `find_tool` in
#   /usr/sbin/ferm matches `^(.*tables)(.*)$` and looks for `$1-legacy$2` FIRST
#   across /usr/sbin, /sbin and $PATH, falling back to the unsuffixed name only
#   when no `-legacy` binary is installed. Measured on the golden, `ferm --shell`
#   emitted `/usr/sbin/iptables-legacy-restore` while `update-alternatives
#   --query iptables` said `Value: /usr/sbin/iptables-nft`. **The two halves
#   disagree on a healthy host, and that disagreement is the fail-open**: ferm
#   writes the table it resolves, and an operator reads the table their own
#   binary names. Setting the alternative to nft does not move ferm, so a fix
#   that only touched the alternatives would leave the box exactly as broken and
#   look like it had worked.
#
# So guarden converges ONE named variant -- the table ferm actually writes -- and
# points the host's own `iptables` at that same table. The item that decides
# convergence reads the RULES, not the alternatives, because only the rules say
# where the firewall actually is.
#
# machine: fresh
# A real host. The check asks the kernel what is in a table, and this file moves
# the host's alternatives selection twice, so it needs a machine of its own.

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GUARDEN_PREFIX=/

chain=guarden-in

# **Put the host's own iptables back the way this file found it.** A suite that
# left alternatives moved would change what every suite after it reads, and the
# harness's default for an unstated suite is its own machine only when the suite
# says so; the restore makes this file safe to share.
restore_variant() {
    update-alternatives --set iptables /usr/sbin/iptables-nft >/dev/null 2>&1 || :
}
trap restore_variant EXIT

# The two halves are recorded before anything is converged, because the whole
# claim is that they can disagree and the disagreement is invisible without both.
# Recorded, not asserted: this block is the precondition statement of what the
# machine came with, so a golden that changed its variant shows up here rather
# than as a confusing assertion failure six lines later.
printf 'alternatives names: %s\n' \
    "$(update-alternatives --query iptables 2>/dev/null | sed -n 's/^Value: //p' || echo none)"
printf 'host iptables:      %s\n' "$(iptables --version 2>&1 || echo absent)"

# ferm's own answer, read from the argv it would run. This is the measurement the
# defect turns on and it belongs on the record every run: if a future ferm changes
# which binary it prefers, this line moves and the assertions below say why.
combined=$GUARDEN_FIXTURES/combined.conf
cat /etc/guarden/firewall/10-framework.conf /etc/guarden/firewall/20-ingress-nat.conf \
    >"$combined" 2>/dev/null || true
if [ -s "$combined" ]; then
    run ferm --shell "$combined"
    printf 'ferm would load:    %s\n' "$(head -1 "$GUARDEN_STDOUT" 2>/dev/null || echo unknown)"
fi

stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_not_rejected

# --- the phase converges a named variant -------------------------------------

# The starting state is the fail-open, asserted rather than assumed: alternatives
# names nft while ferm writes legacy, so this host's own `iptables` cannot see
# guarden's rules. **The phase must report that, not accept it.**
update-alternatives --set iptables /usr/sbin/iptables-nft
run iptables --version
assert_exit 0
assert_stdout_has "nf_tables"

run soil firewall --check
assert_exit 1
assert_stderr_has "drift: this host's own iptables is the legacy variant"

run soil firewall --apply
assert_exit 0

# Both halves of the convergence are visible from outside. `iptables --version`
# prints `(legacy)` for legacy and `(nf_tables)` for nft, so this is the tool's
# own word rather than a spelling of ours.
run update-alternatives --query iptables
assert_exit 0
assert_stdout_has "/usr/sbin/iptables-legacy"
run iptables --version
assert_exit 0
assert_stdout_has "legacy"

# **And this is the assertion the whole ticket exists for.** `iptables -S`
# answering exit 0 for guarden's own chain, through the host's OWN binary, is the
# difference between a firewall an operator can see and one they cannot. It is the
# only claim here that says where the rules ARE rather than what they are called.
run iptables -S "$chain"
assert_exit 0
assert_stdout_has "-N $chain"

# The other variant must NOT answer, or both tables hold guarden's rules and this
# file's claim about which one is meaningless. Stated as "the other binary either
# does not exist or cannot see the chain" rather than as an absolute, because a
# host shipping only one variant has no other binary to ask.
if command -v iptables-nft >/dev/null 2>&1; then
    run iptables-nft -S "$chain"
    assert_exit 1
    assert_stderr_has "No chain/target/match by that name"
fi

# The default deny is in force in the table the host reads, so the firewall does
# something rather than merely existing: `-A INPUT ... -j DROP` with the jump
# through guarden's own chain above it.
run iptables -S INPUT
assert_exit 0
assert_stdout_has "-A INPUT"
assert_stdout_has "guarden-in"
run iptables -S INPUT
assert_exit 0
assert_stdout_has "DROP"

# --- a converged host reports no drift ---------------------------------------

# Asked on the machine the apply just converged, because reasoning about which
# items converged is how a suite ends up green against code that was never run.
run soil firewall --check
assert_exit 0
assert_stderr_empty

# Re-applying is a no-op, which is what makes the phase idempotent: a converge
# that re-selected the variant every run would report work it did not do.
run soil firewall --apply
assert_exit 0
run iptables --version
assert_exit 0
assert_stdout_has "legacy"

# --- a host whose binary names the wrong variant is drift --------------------

# **The mismatch, made into an assertion.** Alternatives moved off the variant
# the list states is not hypothetical: it is one `update-alternatives --set`, and
# it is the state any host an operator touched ends up in. With it moved the host's
# own `iptables` reads a table guarden's rules are not in -- precisely the
# condition under which the firewall "appears absent while the traffic it was
# written to stop still flows".
run update-alternatives --set iptables /usr/sbin/iptables-nft
assert_exit 0
run iptables --version
assert_exit 0
assert_stdout_has "nf_tables"
run iptables -S "$chain"
assert_exit 1

# `--check` says so, and says which table it wants. It does not silently accept
# the host's choice, and it does not report a converged firewall here.
run soil firewall --check
assert_exit 1
assert_stderr_has "drift: this host's own iptables is the legacy variant"

# **Two drift lines, not one, and the second is the one that matters.** The
# variant item reports the selection and the readability item reports the
# consequence: the host's own `iptables` cannot see the rules. A fix that
# corrected only the first would leave the second, and the second is the
# fail-open -- so the phase refuses to converge while either is untrue.
assert_stderr_has "readable through this host's own iptables rather than in another table"

# **And the apply puts it back.** A variant that is reported but never converged is
# the same silent mismatch with a diagnostic on top of it.
run soil firewall --apply
assert_exit 0
run iptables --version
assert_exit 0
assert_stdout_has "legacy"
run iptables -S "$chain"
assert_exit 0
assert_stdout_has "-N $chain"

# The firewall unit is enabled, so the converged table survives a reboot: a
# variant that is right until the next boot is not a converged firewall.
assert_enabled guarden-firewall.service

# --- the refusal for a family with no stated variant is NOT reachable here ----

# **A family whose row states no `variant` is exit 2, and that path cannot be
# exercised on this host.** `--family` is `soil packages`'s and only with `--list`
# or `--render-user-data`; `soil firewall --family fedora` is refused before the
# firewall phase builds a single item. And `soil packages --list --family fedora`
# succeeds, because the list reader resolves the family without ever asking which
# iptables variant it converges. So the refusal needs a Fedora host, and there is
# no honest way to reach it from a Debian one.
#
# What is asserted instead is the refusal that IS reachable, so the seam is not
# left untested: the flag belongs to `soil packages`, and handing it to a phase
# names the gap rather than quietly answering for the wrong family.
run soil packages --list --family fedora
assert_exit 0
assert_stdout_has "family   fedora"

run soil firewall --check --family fedora
assert_exit 2
assert_stderr_has "--family is \`soil packages\`'s"

# The list reader answers for fedora, so the row exists and is readable -- it just
# does not state a variant. Proving the phase would then refuse needs that host;
# see the "Not yet measured" section of
# docs/notes/iptables-variant-must-be-stated.md.