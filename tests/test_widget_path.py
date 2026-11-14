"""A widget's file is a name inside the tree, and not a path on this host.

**F1, from the first security review (`kilocode/step-5-free`).** A manifest's
`widgets: file:` was an unvalidated path, and the renderer reads it as the
`guarden` account — which is in the `guarden` group and can read the host's
configuration. So a repository (the untrusted actor) could name a host path and
have it read into a file a service's container can read.

The escape is a Python fact rather than a guess:

    >>> Path("/a/b") / "/etc/passwd"
    PosixPath('/etc/passwd')
    >>> (Path("/a/b") / "../../etc/passwd").resolve()
    PosixPath('/etc/passwd')

An absolute right operand discards the left one, and a `..` component climbs
out. **Both are refused**, at parse time (so a refused widget costs a manifest
parse and not a read) and again in the renderer (the belt: the renderer is the
thing that opens the file, so the renderer is the thing that checks where it
is).
"""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from guarden import errors, manifest, render


def _manifest_with_widget(file_name: str) -> Path:
    """A manifest whose only widget names `file_name`."""
    directory = Path(tempfile.mkdtemp())
    path = directory / "service.yml"
    path.write_text(
        "project: demo\n"
        "widgets:\n"
        "  - container: web\n"
        f"    file: {file_name}\n",
        encoding="utf-8",
    )
    return path


class WidgetFilePathTest(unittest.TestCase):
    """The manifest refuses a widget's file that is not a name in the tree."""

    def test_an_absolute_path_is_refused(self) -> None:
        """`/etc/guarden/guarden.toml` — the host's own configuration."""
        path = _manifest_with_widget("/etc/guarden/guarden.toml")
        with self.assertRaises(errors.GuardenError) as caught:
            manifest.read(path)
        self.assertIn("absolute path", str(caught.exception))

    def test_a_traversal_is_refused(self) -> None:
        """The same file, reached without being absolute."""
        path = _manifest_with_widget("../../../../../../etc/guarden/guarden.toml")
        with self.assertRaises(errors.GuardenError) as caught:
            manifest.read(path)
        self.assertIn("climbs out of the tree", str(caught.exception))

    def test_a_relative_name_inside_the_tree_is_accepted(self) -> None:
        """The ordinary case still works — this is not a blanket refusal."""
        path = _manifest_with_widget("widgets/web.toml")
        document = manifest.read(path)
        self.assertEqual([w.file for w in document.widgets], ["widgets/web.toml"])

    def test_a_name_with_a_dot_inside_it_is_accepted(self) -> None:
        """A dot in a NAME is not a traversal; only a `..` COMPONENT is."""
        path = _manifest_with_widget("web..toml")
        document = manifest.read(path)
        self.assertEqual([w.file for w in document.widgets], ["web..toml"])


class WidgetReadContainmentTest(unittest.TestCase):
    """The renderer refuses to read outside the tree, whatever the manifest said.

    **This is the belt.** The manifest check is the first line; this is the one
    that matters if a manifest reaches the renderer by another road, because
    the renderer is the thing that opens the file.
    """

    def setUp(self) -> None:
        self.directory = Path(tempfile.mkdtemp())
        (self.directory / "web.toml").write_text("ok", encoding="utf-8")

    def test_a_file_inside_the_tree_is_read(self) -> None:
        """The ordinary case still works."""
        self.assertEqual(
            render._widget_file(self.directory, "web.toml"),
            "ok",
        )

    def test_an_absolute_path_is_refused(self) -> None:
        """The escape, at the read."""
        with self.assertRaises(errors.GuardenError) as caught:
            render._widget_file(self.directory, "/etc/guarden/guarden.toml")
        self.assertIn("outside the tree", str(caught.exception))

    def test_a_traversal_is_refused(self) -> None:
        """The same file, reached without being absolute."""
        with self.assertRaises(errors.GuardenError) as caught:
            render._widget_file(self.directory, "../../../../etc/guarden/guarden.toml")
        self.assertIn("outside the tree", str(caught.exception))

    def test_a_missing_file_is_one_line_and_not_a_traceback(self) -> None:
        """Spec 1.2: one line, prefixed, naming what is wrong."""
        with self.assertRaises(errors.GuardenError) as caught:
            render._widget_file(self.directory, "absent.toml")
        self.assertIn("does not exist", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
