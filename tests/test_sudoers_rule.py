"""The sudoers rule the spec writes out, and the capability split it must keep.

The rule is the one thing in the security model that is written in prose and
implemented nowhere: the spec's capability table (docs/spec.md:1166) says
which verbs a poke may reach, and nine source files rest their argument on it
("a sudoers rule cannot tell one argument from another, so a flag on a granted
verb would grant the capability with it", weedr.py:5).

These tests pin three things:

  1. the rule exists, is written, and names the verbs the spec names;
  2. it names a VERB and never a bare program — a bare program matches any
     arguments, and an argument is a capability;
  3. no mutating `weedr` verb is in it — the request/grant split (a service
     asks for a port, an operator grants it) survives only if the grant verbs
     are NOT reachable from a push.
"""

from __future__ import annotations

import unittest

from guarden import sudoers


class SudoersRuleTest(unittest.TestCase):
    def setUp(self) -> None:
        self.text = sudoers.rule_text()
        self.lines = [
            line.strip()
            for line in self.text.splitlines()
            if line.strip() and not line.strip().startswith("#")
        ]

    def test_the_rule_names_every_verb_the_spec_names(self) -> None:
        """The spec's list (hose.py:5) is the rule's list."""
        for program, verb in sudoers.VERBS:
            self.assertIn(
                f"{sudoers.BIN / program} {verb}",
                self.text,
                f"the rule does not name {program} {verb}",
            )

    def test_every_entry_names_a_verb_and_not_a_bare_program(self) -> None:
        """A bare program matches any arguments, and an argument is a capability."""
        for line in self.lines:
            self.assertTrue(
                line.endswith(tuple(verb for _, verb in sudoers.VERBS)),
                f"the rule entry {line!r} does not name a whole verb",
            )

    def test_no_mutating_weedr_verb_is_granted(self) -> None:
        """The grant verbs stay out of a push's reach."""
        for verb in (
            "add",
            "create",
            "ingest",
            "fork",
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

    def test_the_rule_runs_as_the_mutator_and_not_as_root(self) -> None:
        """The grant is to run as the mutator's identity, not to be root."""
        for line in self.lines:
            self.assertIn(f"ALL=({sudoers.RUN_AS})", line)
            self.assertNotIn("ALL=(ALL)", line)
            self.assertNotIn("ALL=(root)", line)

    def test_the_grantee_is_the_poke_and_nothing_else(self) -> None:
        """Only the poke's own account is granted."""
        grantees = {line.split()[0] for line in self.lines}
        self.assertEqual(grantees, {sudoers.GRANTEE})

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


if __name__ == "__main__":
    unittest.main()
