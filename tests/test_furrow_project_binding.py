"""A narrowed caller is held to the key file's binding; a root call is not.

**The per-project binding is checked in the privileged program**, because the
sudoers rule grants a VERB with `*` for the arguments — a sudoers command with
arguments must match them EXACTLY, and the poke's real invocation carries a
service name, a `--from` and a sha, so a rule naming the bare verb was INERT
and no poke could deploy anything at all.

A `*` is safe because the binding was never in the rule: it is in the SSH
forced command `weedr project grant` wrote, and the key file that carries it
is world-readable — so the privileged program can read the binding and check
the request against it.

**And the check applies to a NARROWED caller only.** An operator's own
`furrow deploy` — root's own call, with no SSH and no key — may deploy any
project they have registered. What is narrowed is the call that arrives
THROUGH the poke's account, because that is the one whose project comes from a
key.
"""

from __future__ import annotations

import os
import unittest
from unittest import mock

from guarden import errors, furrow


class RootCallTest(unittest.TestCase):
    """What counts as root's own call."""

    def test_a_plain_root_call_is_root_own(self) -> None:
        """No sudo in the picture: root's own."""
        with mock.patch.dict(os.environ, {}, clear=True):
            with mock.patch.object(os, "geteuid", return_value=0):
                self.assertTrue(furrow._is_root_call())

    def test_a_sudo_that_ran_as_root_is_root_own(self) -> None:
        """`sudo weedr …` by the operator: still root's own."""
        with mock.patch.dict(os.environ, {"SUDO_UID": "0"}, clear=True):
            with mock.patch.object(os, "geteuid", return_value=0):
                self.assertTrue(furrow._is_root_call())

    def test_a_sudo_that_ran_as_another_user_is_not_root_own(self) -> None:
        """`sudo -u guarden …`: the poke's account's call."""
        with mock.patch.dict(os.environ, {"SUDO_UID": "997"}, clear=True):
            with mock.patch.object(os, "geteuid", return_value=0):
                self.assertFalse(furrow._is_root_call())

    def test_a_non_root_process_is_not_root_own(self) -> None:
        """A process that is not root is not root's own call."""
        with mock.patch.dict(os.environ, {}, clear=True):
            with mock.patch.object(os, "geteuid", return_value=994):
                self.assertFalse(furrow._is_root_call())


class GrantedProjectTest(unittest.TestCase):
    """The binding is checked for a narrowed caller, and only for one."""

    def test_a_root_call_may_deploy_any_project(self) -> None:
        """The operator's own deploy, with no key in the picture."""
        with mock.patch.dict(os.environ, {}, clear=True):
            with mock.patch.object(os, "geteuid", return_value=0):
                furrow._require_granted_project("anyproject")

    def test_a_narrowed_caller_may_deploy_a_granted_project(self) -> None:
        """The poke's account, deploying the project its key holds."""
        with mock.patch.dict(os.environ, {"SUDO_UID": "997"}, clear=True):
            with mock.patch.object(os, "geteuid", return_value=0):
                with mock.patch.object(
                    furrow.projects, "key_projects", return_value={"myapp": "ssh-ed25519 AAAA"}
                ):
                    furrow._require_granted_project("myapp")

    def test_a_narrowed_caller_may_not_deploy_another_project(self) -> None:
        """**The binding, checked.** A key for one project cannot deploy
        another, whatever the argument says."""
        with mock.patch.dict(os.environ, {"SUDO_UID": "997"}, clear=True):
            with mock.patch.object(os, "geteuid", return_value=0):
                with mock.patch.object(
                    furrow.projects, "key_projects", return_value={"myapp": "ssh-ed25519 AAAA"}
                ):
                    with self.assertRaises(errors.GuardenError) as caught:
                        furrow._require_granted_project("otherproject")
        self.assertIn("not one any key is granted", str(caught.exception))
        self.assertIn("myapp", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
