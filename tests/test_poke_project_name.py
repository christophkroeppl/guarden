"""A poke names a project and a commit, and never a place.

**F2, from the first security review (`kilocode/step-5-free`).** The sha in a
`--from poke <project>@<sha>` pair was refused a `/` and a `..`, and the
PROJECT was not — and the project is the half that becomes a directory:

    paths.STAGING / project / sha

So `--from poke ../../tmp/evil@9f2c1ab` assembled a path outside the staging
area, and root — reached through the mutator's sudoers rule — then read and
rendered from a tree the caller chose.

The module's own docstring claims the opposite: *"nothing here distinguishes a
path from a name, because no caller can name a path."* A caller could.
"""

from __future__ import annotations

import unittest

from guarden import errors, furrow, service


class PokeProjectNameTest(unittest.TestCase):
    """The project half of the pair is a name, and is checked as one."""

    def test_a_traversal_project_is_refused(self) -> None:
        """The escape, as the mutator sees it."""
        with self.assertRaises(errors.GuardenError) as caught:
            service.parse_from(["poke", "../../tmp/evil@9f2c1ab"], "ingest")
        self.assertIn("is not a name", str(caught.exception))

    def test_an_absolute_project_is_refused(self) -> None:
        """An absolute path is a path too."""
        with self.assertRaises(errors.GuardenError) as caught:
            service.parse_from(["poke", "/tmp/evil@9f2c1ab"], "ingest")
        self.assertIn("is not a name", str(caught.exception))

    def test_a_well_formed_project_is_accepted(self) -> None:
        """The ordinary case still works — this is not a blanket refusal."""
        source = service.parse_from(["poke", "myapp@9f2c1ab"], "ingest")
        self.assertEqual(source.project, "myapp")
        self.assertEqual(source.sha, "9f2c1ab")

    def test_the_furrow_side_refuses_it_too(self) -> None:
        """`furrow` assembles the same pair and must refuse it as well."""
        with self.assertRaises(errors.GuardenError) as caught:
            furrow._poke(["poke", "../../tmp/evil@9f2c1ab"], None, True, "svc")
        self.assertIn("is not one", str(caught.exception))

    def test_the_furrow_side_accepts_a_well_formed_project(self) -> None:
        """The ordinary case still works on that side too."""
        project, sha = furrow._poke(["poke", "myapp@9f2c1ab"], None, True, "svc")
        self.assertEqual(project, "myapp")
        self.assertEqual(sha, "9f2c1ab")


class StagingContainmentTest(unittest.TestCase):
    """The resolved staging path is inside the staging area.

    **The belt.** The name checks above mean this cannot be reached with a
    path today; the point is that the next caller need not know that.
    """

    def test_a_source_outside_the_staging_area_is_refused(self) -> None:
        """A source that points outside the system's own directory.

        The project is what becomes a directory, so the project is what has to
        climb. The name checks in `parse_from` and `furrow._poke` refuse a
        project with a `/` or a `..`, so this cannot be reached through those —
        and the point of the belt is that the next caller need not know that.
        """
        from guarden import service as service_mod

        source = service_mod.Source(kind="poke", project="../../etc", sha="9f2c1ab")
        with self.assertRaises(errors.GuardenError) as caught:
            source.directory()
        self.assertIn("outside the staging area", str(caught.exception))

    def test_a_source_inside_the_staging_area_is_accepted(self) -> None:
        """The ordinary case still works — this is not a blanket refusal."""
        from guarden import service as service_mod

        source = service_mod.Source(kind="poke", project="myapp", sha="9f2c1ab")
        path = source.directory()
        self.assertTrue(str(path).endswith("myapp/9f2c1ab"))


if __name__ == "__main__":
    unittest.main()
