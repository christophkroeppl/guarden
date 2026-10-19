"""The sudoers rules the spec writes out, and the capability split they must keep.

The rules are the one thing in the security model that was written in prose
and implemented nowhere: the spec's capability table (docs/spec.md:1166) says
which verbs a poke may reach, and nine source files rest their argument on it
("a sudoers rule cannot tell one argument from another, so a flag on a granted
verb would grant the capability with it", weedr.py:5).

**There are TWO rules, because the poke path has two hops and the hops grant
different things to different identities.**

- The FIRST is the poke's: it grants the `hose` account the mutator's deploy
  verbs, running as `guarden`. The verbs are named WHOLE — a program and a
  verb — because a sudoers rule cannot tell one argument from another.
- The SECOND is the mutator's, reached by `furrow`: it grants the `guarden`
  account the mutator, running as root. It CANNOT name the verbs, because the
  real invocation carries a service name and a sha and a rule cannot name
  those — so the rule names the program and the MUTATOR enforces the list.

These tests pin:

  1. the first rule names every verb the spec names, and names a VERB rather
     than a bare program;
  2. the second rule grants the mutator to `guarden` and to nobody else;
  3. the mutator's policy (`GUARDEN_MAY`) is the spec's §6.6 list, and it
     excludes the destructive and the granting verbs — because a push may
     deploy and may not destroy, publish or grant;
  4. the mutator refuses a verb outside that list **when the caller is
     `guarden`**, and refuses nothing when the call did not come through sudo.
"""

from __future__ import annotations

import os
import unittest
from unittest import mock

from guarden import sudoers, weedr


class SudoersRuleTest(unittest.TestCase):
    def setUp(self) -> None:
        self.text = sudoers.rule_text()
        self.lines = [
            line.strip()
            for line in self.text.splitlines()
            if line.strip() and not line.strip().startswith("#")
        ]
        self.poke_lines = [
            line for line in self.lines if line.startswith(f"{sudoers.GRANTEE} ")
        ]
        self.mutator_lines = [
            line for line in self.lines if line.startswith(f"{sudoers.GUARDEN_USER} ")
        ]

    def test_the_rule_names_every_verb_the_spec_names(self) -> None:
        """The spec's list (hose.py:5) is the rule's list."""
        for program, verb in sudoers.VERBS:
            self.assertIn(
                f"{sudoers.BIN / program} {verb}",
                self.text,
                f"the rule does not name {program} {verb}",
            )

    def test_every_poke_entry_names_a_verb_and_not_a_bare_program(self) -> None:
        """A bare program matches any arguments, and an argument is a capability."""
        for line in self.poke_lines:
            self.assertTrue(
                line.endswith(tuple(verb for _, verb in sudoers.VERBS)),
                f"the rule entry {line!r} does not name a whole verb",
            )

    def test_the_poke_rule_grants_the_deploy_verbs_and_nothing_more(self) -> None:
        """The grant verbs stay out of a push's reach."""
        for verb in (
            "add",
            "create",
            "purge",
            "rollback",
            "port open",
            "firewall open",
        ):
            self.assertNotIn(
                f"weedr {verb}",
                self.text,
                f"the rule grants the mutating verb {verb!r}, which a push must not reach",
            )

    def test_the_poke_rule_runs_as_the_mutator_and_not_as_root(self) -> None:
        """The grant is to run as the mutator's identity, not to be root."""
        for line in self.poke_lines:
            self.assertIn(f"ALL=({sudoers.RUN_AS})", line)
            self.assertNotIn("ALL=(ALL)", line)
            self.assertNotIn("ALL=(root)", line)

    def test_the_poke_grantee_is_the_poke_and_nothing_else(self) -> None:
        """Only the poke's own account is granted the deploy verbs."""
        grantees = {line.split()[0] for line in self.poke_lines}
        self.assertEqual(grantees, {sudoers.GRANTEE})

    def test_the_second_rule_grants_the_mutator_to_the_mutator_identity(self) -> None:
        """`furrow` runs as `guarden` and calls the mutator as root."""
        self.assertEqual(len(self.mutator_lines), 1, self.mutator_lines)
        line = self.mutator_lines[0]
        self.assertIn(f"{sudoers.GUARDEN_USER} ALL=(root) NOPASSWD:", line)
        self.assertIn(str(sudoers.BIN / "weedr"), line)

    def test_the_rule_is_stable_across_calls(self) -> None:
        """The rule does not depend on anything mutable, so it converges."""
        self.assertEqual(self.text, sudoers.rule_text())

    def test_every_entry_is_absolute(self) -> None:
        """A program named without a path is resolved through the caller's PATH."""
        for line in self.lines:
            path = line.split("NOPASSWD: ")[1]
            self.assertTrue(
                path.startswith("/"),
                f"the rule entry names {path!r} without an absolute path",
            )


class MutatorPolicyTest(unittest.TestCase):
    """The list the mutator enforces, and the refusal it makes.

    **The list is the spec's §6.6 list**, and the reason it lives in the
    mutator rather than in a sudoers rule is measured: a rule naming
    `weedr service ingest` admits the bare command and refuses the real
    invocation, because the real one carries a service name and a sha.
    """

    def test_the_policy_is_the_specs_list(self) -> None:
        """Every verb the spec's §6.6 names is in the policy."""
        for verb in (
            "weedr service ingest",
            "weedr service remove",
            "weedr service gate",
            "weedr service start",
            "weedr service stop",
            "weedr service restart",
            "weedr service snapshot",
            "weedr service build",
            "weedr secret list",
            "weedr port list",
            "weedr firewall list",
            "weedr service list",
            "weedr service status",
            "weedr module list",
        ):
            self.assertIn(verb, sudoers.GUARDEN_MAY)

    def test_the_destructive_and_the_granting_verbs_are_absent(self) -> None:
        """A push may deploy and may not destroy, publish or grant."""
        for verb in (
            "weedr service purge",
            "weedr service rollback",
            "weedr service add",
            "weedr service create",
            "weedr port open",
            "weedr firewall open",
            "weedr secret set",
        ):
            self.assertNotIn(verb, sudoers.GUARDEN_MAY)

    def test_a_guarden_caller_is_refused_a_verb_outside_the_list(self) -> None:
        """The refusal is the one every other refusal is."""
        with mock.patch.dict(os.environ, {"SUDO_USER": sudoers.GUARDEN_USER}):
            with self.assertRaises(Exception) as caught:
                weedr._guarden_may("weedr service purge")
        self.assertIn("may not run", str(caught.exception))

    def test_a_guarden_caller_may_run_a_verb_inside_the_list(self) -> None:
        """The permitted half."""
        with mock.patch.dict(os.environ, {"SUDO_USER": sudoers.GUARDEN_USER}):
            weedr._guarden_may("weedr service ingest")

    def test_a_root_call_is_unrestricted(self) -> None:
        """A call that did not come through sudo is root's own call.

        That is the case the VM harness exercises, and the case the operator's
        own `sudo weedr …` is not: sudo sets SUDO_USER to the account the rule
        ran as, and root's own call has none.
        """
        with mock.patch.dict(os.environ, {}, clear=True):
            weedr._guarden_may("weedr service purge")

    def test_another_account_is_unrestricted(self) -> None:
        """Only the mutator's own identity is narrowed."""
        with mock.patch.dict(os.environ, {"SUDO_USER": "somebody-else"}):
            weedr._guarden_may("weedr service purge")


if __name__ == "__main__":
    unittest.main()
