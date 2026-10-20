#!/usr/bin/env bash
# The poke path, end to end, as the UNPRIVILEGED account.
#
# ticket 331. The chain a poke takes is `hose` -> `furrow` -> `weedr`, and it
# had no rule for its last hop: `furrow` runs as `guarden` and calls the
# mutator through `sudo -n weedr …`, and the rule that would allow it was
# written out in spec 6.6 and by nothing in the repository.
#
# **The VM suites could not see this, because they all run as root** — and
# `furrow` calls `weedr` directly when its euid is 0. So the gitops path was
# green in every suite and broken on every real host.
#
# This suite runs the chain as the accounts it actually runs as, with
# `setpriv` — the same mechanism t502 uses for the service user. That is the
# point of the suite: **a suite that cannot run the unprivileged path cannot
# prove anything about it**, and this is the first one that can.
#
# The rule the mutator enforces is `sudoers.GUARDEN_MAY` (spec 6.6's list), and
# the two halves are asserted here separately:
#   · the poke reaches the deploy verbs, running as the mutator's identity;
#   · the mutator is reachable as `guarden` — so the deploy path WORKS;
#   · and the mutator refuses the destructive and the granting verbs when the
#     caller is `guarden` — so the grant stays narrow.

. "$(dirname "$0")/lib.sh"

stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_not_rejected

rule=/etc/sudoers.d/guarden
assert_file_exists "$rule"

# --- the two rules, as root reads them ----------------------------------------
echo "MEASURE: the rules: $(grep -c NOPASSWD "$rule") grants"
# The poke's rule names whole verbs and runs as the mutator's identity.
grep -q "^hose ALL=(guarden) NOPASSWD: .*/furrow deploy \*$" "$rule" \
    || _fail "the rule does not grant the poke the deploy verb"
# The mutator's rule names the PROGRAM, because the real invocation carries a
# service name and a sha and a rule cannot name those.
grep -q "^guarden ALL=(root) NOPASSWD: .*/bin/weedr\$" "$rule" \
    || _fail "the rule does not grant the mutator to the guarden account"

# --- the POKE's own hop: `hose` reaches `furrow` -------------------------------
#
# **This hop was never tested, and it was DEAD.** Every other assertion in
# this file is a grep on the rule's TEXT; none of them asked whether the rule
# MATCHES the invocation. A sudoers command with associated arguments must
# match them EXACTLY (`man sudoers`), and the poke's real invocation is
# `furrow deploy <service> --from poke <project>@<sha>` — so a rule naming the
# bare verb admitted only the bare verb.
#
# MEASURED on a live host before the fix:
#
#     $ sudo -n -u hose sudo -n -u guarden …/bin/furrow deploy svc --from poke p@s
#     sudo: I'm sorry hose. I'm afraid I can't do that
#
# So the whole gitops path was dead on every real host, and every suite was
# green because every suite ran as root. **The rule now carries `*` for the
# arguments**, and the per-project binding is in the SSH forced command `hose`
# reads — with `furrow` re-deriving the project from the key file.
#
# The check below is the hop AS IT RUNS: as the `hose` account, with the
# arguments. A grep cannot catch this; only an invocation can.
as_hose() {
    setpriv --reuid=hose --regid=hose --init-groups env -u OLDPWD \
        env -u PWD "$@"
}
as_hose_sudo() {
    setpriv --reuid=hose --regid=hose --init-groups env -u OLDPWD \
        env -u PWD sudo -n "$@"
}

# The rule ADMITS the invocation with its arguments — the refusal would be
# sudo's own words, and the whole point is that it is not.
out=$(as_hose_sudo -u guarden /usr/lib/guarden/bin/furrow status 2>&1 || true)
echo "MEASURE: the poke's own hop, the bare verb: $(echo "$out" | head -1)"
case "$out" in
    *"I'm sorry"*|*"not permitted"*)
        _fail "the poke's account cannot reach the mutator; the gitops path is dead" ;;
esac

# And the invocation that carries arguments — the one a poke really makes.
# `furrow` refuses it on its own terms (no such project, no such service),
# and NOT with sudo's refusal, which is what "the rule matched" looks like.
out=$(as_hose_sudo -u guarden /usr/lib/guarden/bin/furrow deploy nosuchservice \
    --from poke nosuchproject@9f2c1ab 2>&1 || true)
echo "MEASURE: the poke's own hop, with arguments: $(echo "$out" | head -1)"
case "$out" in
    *"I'm sorry"*|*"not permitted"*)
        _fail "the rule does not match the invocation a poke makes; the gitops path is dead" ;;
esac

# --- the mutator is REACHABLE as the guarden account --------------------------
# This is the half that was broken: the rule existed nowhere, and even the
# spec's version of it refused the real invocation.
as_guarden() {
    setpriv --reuid=guarden --regid=guarden --init-groups env -u OLDPWD \
        env -u PWD "$@"
}
as_guarden_sudo() {
    setpriv --reuid=guarden --regid=guarden --init-groups env -u OLDPWD \
        env -u PWD sudo -n "$@"
}

out=$(as_guarden_sudo /usr/lib/guarden/bin/weedr service list 2>&1 || true)
echo "MEASURE: the mutator as guarden: $(echo "$out" | head -1)"
case "$out" in
    *"may not run"*) _fail "the guarden account cannot reach the mutator at all; the poke path is broken" ;;
    *"not permitted"*|*"may not run sudo"*) _fail "the guarden account cannot reach the mutator at all" ;;
esac

# A PERMITTED verb runs. `service list` reads the registries, so it answers
# without a service existing.
out=$(as_guarden_sudo /usr/lib/guarden/bin/weedr service list 2>&1 || true)
echo "MEASURE: the mutator's answer: $(echo "$out" | head -1)"

# --- and the mutator refuses the rest ------------------------------------------
# **The destructive and the granting verbs are refused BY THE MUTATOR**, which
# is where the policy lives — because a sudoers rule cannot say "these verbs,
# with any arguments".
# **Each verb is called with the arguments it needs**, because argparse runs
# before the policy does: a verb whose required argument is missing is
# refused by the PARSER ("usage: …"), not by the mutator, and a test that
# read that as the policy's answer would be testing argparse. `rollback`
# needs `--to TIME`; `port open` and `firewall open` need their own.
for verb in "service purge someapp" \
            "service rollback someapp --to 20260101T000000Z" \
            "port open someapp 8080/tcp" \
            "firewall open someapp some-rule"; do
    out=$(as_guarden_sudo /usr/lib/guarden/bin/weedr $verb 2>&1 || true)
    echo "MEASURE: the guarden account running '$verb': $(echo "$out" | head -1)"
    case "$out" in
        *"may not run"*) : ;;
        *"usage:"*) _fail "the guarden account ran '$verb' and the refusal was argparse's, not the policy's" ;;
        *) _fail "the guarden account ran '$verb', which the spec's §6.6 list does not name" ;;
    esac
done

# And the refusal names the verb, so an operator who reaches it the wrong way
# learns why.
#
# **The answer is read from the command, not from `$GUARDEN_STDERR`** — that
# variable belongs to the `run` helper, and this call is a direct invocation,
# so the assertion was reading an empty string and failing on a refusal that
# had in fact happened.
out=$(as_guarden_sudo /usr/lib/guarden/bin/weedr service purge someapp 2>&1 || true)
case "$out" in
    *"may not run"*) : ;;
    *) _fail "the guarden account ran 'service purge': $out" ;;
esac
case "$out" in
    *"service purge"*) : ;;
    *) _fail "the refusal does not name the verb it refused: $out" ;;
esac
echo "MEASURE: the refusal names the verb: $(echo "$out" | head -1 | cut -c1-60)"

# --- and a root call is unrestricted --------------------------------------------
# The call that did not come through sudo is root's own call: there is no
# SUDO_USER to narrow it by, and that is the case the VM harness exercises.
out=$(/usr/lib/guarden/bin/weedr service purge someapp 2>&1 || true)
echo "MEASURE: a root call of the same verb: $(echo "$out" | head -1)"
case "$out" in
    *"may not run"*) _fail "a root call was refused; the policy narrows the guarden account, not root" ;;
esac

echo "ok   t132-poke-chain.sh"
