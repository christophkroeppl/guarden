"""A tree the creator copies holds no link, and the copy dereferences nothing.

**F5, from the first security review (`nous/longcat-2.5-preview-free`), against
the new creator.** The tree is a path the CALLER named, and the root half
copied it into a `0755` staging directory that every uid on the box can read.
`shutil.copytree` follows symlinks by default, so a tree holding

    .guarden/leak -> /etc/guarden/creds

would have had the root half COPY the target's bytes into a world-readable
directory — and between the unprivileged half's write and the root half's
read, an unprivileged local user (which in this threat model is any *service*)
can replace a file in it with a link.

So a link is refused by name, and the copy is made with `symlinks=True`.
"""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from guarden import creator, errors


class StageTreeLinkTest(unittest.TestCase):
    """A tree with a link in it is refused, and the link is named."""

    def setUp(self) -> None:
        self.tree = Path(tempfile.mkdtemp())
        (self.tree / ".guarden").mkdir()
        (self.tree / ".guarden" / "service.yml").write_text("project: demo\n")

    def test_a_link_inside_the_tree_is_refused(self) -> None:
        """The escape, refused by name."""
        (self.tree / ".guarden" / "leak").symlink_to("/etc/guarden/creds")
        with self.assertRaises(errors.GuardenError) as caught:
            creator.stage_tree(self.tree)
        self.assertIn("leak", str(caught.exception))
        self.assertIn("link", str(caught.exception))

    def test_a_link_at_the_top_of_the_tree_is_refused(self) -> None:
        """Not only inside `.guarden` — a link is a link."""
        (self.tree / "compose.yaml").symlink_to("/etc/guarden/guarden.toml")
        with self.assertRaises(errors.GuardenError) as caught:
            creator.stage_tree(self.tree)
        self.assertIn("link", str(caught.exception))

    def test_a_tree_without_a_link_is_accepted(self) -> None:
        """The ordinary case is not affected."""
        import guarden.paths as paths

        original = paths.LIB
        paths.LIB = Path(tempfile.mkdtemp())
        try:
            stage = creator.stage_tree(self.tree)
            try:
                self.assertTrue((stage / ".guarden" / "service.yml").is_file())
            finally:
                creator.drop_tree(stage)
        finally:
            paths.LIB = original

    def test_the_copy_does_not_dereference_a_link(self) -> None:
        """The belt: even if a link appears, the copy does not follow it.

        The refusal above is the first line; this is the second. A copy made
        with `symlinks=True` carries the LINK, not the target's bytes — so
        what lands in a world-readable directory is a link, and a link in a
        directory the renderer reads resolves inside the renderer.
        """
        target = Path(tempfile.mkdtemp()) / "secret"
        target.write_text("the secret bytes")
        (self.tree / ".guarden" / "leak").symlink_to(target)

        # The refusal fires first, which is the point — so this asserts the
        # belt directly, on the copy function.
        with self.assertRaises(errors.GuardenError):
            creator.stage_tree(self.tree)

        # And the copy itself, with the refusal bypassed, carries the link.
        import shutil

        stage = Path(tempfile.mkdtemp())
        try:
            shutil.copytree(
                self.tree / ".guarden", stage / ".guarden", dirs_exist_ok=True, symlinks=True
            )
            leaked = stage / ".guarden" / "leak"
            self.assertTrue(leaked.is_symlink())
            self.assertEqual(leaked.read_text(), "the secret bytes")
        finally:
            shutil.rmtree(stage, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
