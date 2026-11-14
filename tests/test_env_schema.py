"""The root `.env.schema` is tracked, carries no value, and resolves.

The schema is the tracked half of the varlock contract: names, types and
example values, never a value, so it is safe in git and required to be there.
This file is that claim's only test, and it is a **unit test** rather than a
suite because its subject is the checkout and not a machine: `git ls-files`
and `git check-ignore` need the repository's own metadata, and a cut machine
never carries it — `tests/lxc.sh` pushes the tree into the guest and a linked
worktree's `.git` is a file naming a host path that does not exist there. A
VM suite for this claim was skipped by the runner and run by nothing
(ticket 266's ledger line, closed by ticket 304); `just unit` is the tier that
already runs where the checkout is.

The claims, in the order they fail:

  1. `.env.schema` is not ignored, and the negation that admits it is
     **unanchored** so the fixture repositories' schemas survive the same rule;
  2. it is tracked — `ls-files --error-unmatch` rather than `status`, because a
     committed file is correctly absent from status and the status form
     asserted a pre-commit moment that stopped meaning anything the moment the
     schema landed;
  3. no declaration line carries a value, and no `@sensitive` marker claims
     one — a credential in this design is a systemd-encrypted blob under
     `/etc/guarden/creds`, and nothing reads a secret from the environment;
  4. `varlock` resolves the schema, lists every declared key, accepts the file
     as well as the directory, and its audit is in sync. `varlock` is not a
     declared dependency, so that half reports rather than fails when the tool
     is absent, the way `just lint` reports a missing `ruff` and `just env`
     reported before it.

The real `git` is named outright. The harness once put a fake `git` first on
`PATH` that exited 0 for everything (fixtures/bin, deleted with the fake tier —
ticket 35, ADR-0014), and a stand-in of that shape would make every assertion
here pass whatever the ignore rules say.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import unittest

GIT = "/usr/bin/git"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# The declarations a value would have to be on: a key at the start of a line,
# an `=`, and something after it. Commented decorator lines are not values, so
# the assertion is on a declaration line rather than on the character "="
# appearing anywhere in the file.
DECLARATION = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=.+", re.MULTILINE)


def _git(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [GIT, *args], cwd=ROOT, capture_output=True, text=True, check=False
    )


class TrackedSchemaTest(unittest.TestCase):
    def setUp(self) -> None:
        self.path = os.path.join(ROOT, ".env.schema")
        with open(self.path, encoding="utf-8") as handle:
            self.text = handle.read()

    def test_git_is_the_real_binary(self) -> None:
        self.assertTrue(os.access(GIT, os.X_OK), f"{GIT} is missing or not executable")

    def test_the_schema_is_not_ignored(self) -> None:
        # `check-ignore` exits 1 when nothing matched, which is the pass here.
        # `--no-index` is load-bearing: without it git skips a path that is
        # already in the index, so the rule this test exists for would pass
        # whether the negation is there or not — the assertion would be about
        # the file's tracked state and not about the pattern at all.
        result = _git("check-ignore", "--no-index", "-q", ".env.schema")
        self.assertEqual(
            result.returncode, 1, f"the schema is ignored: {result.stderr.strip()}"
        )

    def test_the_negation_still_admits_a_fixture_repositorys_schema(self) -> None:
        # A root-anchored rule instead of the unanchored one would drop every
        # fixture repository's schema silently, and nothing else here notices.
        result = _git(
            "check-ignore",
            "--no-index",
            "-q",
            "fixtures/projects/quadlet-app/.guarden/.env.schema",
        )
        self.assertEqual(
            result.returncode,
            1,
            "the unanchored negation no longer admits a nested .guarden/.env.schema",
        )

    def test_the_schema_is_tracked(self) -> None:
        result = _git("ls-files", "--error-unmatch", ".env.schema")
        self.assertEqual(
            result.returncode, 0, f"the schema is not tracked: {result.stderr.strip()}"
        )
        self.assertIn(".env.schema", result.stdout)

    def test_no_declaration_carries_a_value(self) -> None:
        found = DECLARATION.search(self.text)
        self.assertIsNone(
            found,
            "a declaration carries a value, and this file is safe in git only "
            f"because none does: {found.group(0) if found else ''}",
        )

    def test_no_sensitive_marker(self) -> None:
        # The absence is a finding, not an oversight: nothing in guarden reads
        # a credential from the environment.
        self.assertNotRegex(self.text, r"(?m)^# @sensitive")


class ResolvedSchemaTest(unittest.TestCase):
    def setUp(self) -> None:
        if shutil.which("varlock") is None:
            self.skipTest("varlock not installed; the schema was not resolved")

    def _varlock(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["varlock", *args], cwd=ROOT, capture_output=True, text=True, check=False
        )

    def test_the_schema_resolves_and_every_declared_key_is_listed(self) -> None:
        # `--agent` emits RESOLVED values, so it exits 0 on an empty directory
        # as well as on a resolved schema; the human form lists every declared
        # key with its value (`undefined` included), so the declaration is
        # asserted there rather than against a machine's environment.
        agent = self._varlock("load", "--agent", "-p", ROOT)
        self.assertEqual(agent.returncode, 0, agent.stderr)

        plain = self._varlock("load", "-p", ROOT)
        self.assertEqual(plain.returncode, 0, plain.stderr)
        for key in (
            "GUARDEN_TEMPLATES",
            "GUARDEN_VM_TARGET",
            "GUARDEN_FIXTURES",
            "GUARDEN_TEST_INSTALLED",
        ):
            self.assertIn(key, plain.stdout)

        single = self._varlock("load", "--agent", "-p", os.path.join(ROOT, ".env.schema"))
        self.assertEqual(single.returncode, 0, single.stderr)

    def test_the_schema_and_the_code_agree(self) -> None:
        # `varlock audit` scans JS `process.env` and not Python `os.environ`, so
        # against this codebase it reports every key as unused unless each item
        # carries `@auditIgnore`. Removing one turns this into a false positive.
        result = self._varlock(
            "audit", "-p", os.path.join(ROOT, ".env.schema"), os.path.join(ROOT, "src")
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
