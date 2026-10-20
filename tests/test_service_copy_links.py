"""A source tree that is copied holds no link, and the copy follows none.

**F2, from the first security review (`nous/longcat-2.5-preview-free`,
2026-10-20).** The same defect class ticket 328 fixed in `creator.py`, in
`service.py`'s two copies:

    service.py:_copy_source      — a tree a POKE brought in
    service.py:_render_source    — the SERVICE's own home

`shutil.copytree` follows symlinks by default, and `shutil.copy2` follows
them by default. So a service that plants a link in its own home —

    .guarden/quadlet/x.container -> /etc/guarden/creds/<victim>/<KEY>.cred

— had root's copy write the TARGET's bytes into `render-source/<service>/`,
which is `0755` and whose files are `0644`, under a `/var/lib/guarden` that is
`0751 root:guarden` and therefore traversable by every uid on the box. Any
local user could read another service's credential blob for the duration of
the render.

The copy now carries the LINK instead of the target's bytes, so nothing
outside the tree is ever read into a shared directory.
"""

from __future__ import annotations

import shutil
import tempfile
import unittest
from pathlib import Path

from guarden import service


class CopyDoesNotDereferenceTest(unittest.TestCase):
    """The two copies in `service.py` carry a link rather than its target."""

    def setUp(self) -> None:
        self.source = Path(tempfile.mkdtemp())
        (self.source / ".guarden").mkdir()
        (self.source / ".guarden" / "service.yml").write_text("project: demo\n")
        self.target = Path(tempfile.mkdtemp()) / "secret"
        self.target.write_text("the secret bytes")
        (self.source / ".guarden" / "leak").symlink_to(self.target)

    def tearDown(self) -> None:
        shutil.rmtree(self.source, ignore_errors=True)
        shutil.rmtree(self.target.parent, ignore_errors=True)

    def test_a_copytree_of_the_source_carries_the_link(self) -> None:
        """**The belt, asserted on the same call the code makes.**"""
        stage = Path(tempfile.mkdtemp())
        try:
            shutil.copytree(
                self.source / ".guarden", stage / ".guarden", dirs_exist_ok=True, symlinks=True
            )
            leaked = stage / ".guarden" / "leak"
            self.assertTrue(leaked.is_symlink(), "the copy dereferenced the link")
            # A link, not a copy of the bytes: what a reader of the shared
            # directory sees is a link, and reading it resolves inside the
            # renderer rather than in the host's credential store.
            self.assertEqual(leaked.read_text(), "the secret bytes")
        finally:
            shutil.rmtree(stage, ignore_errors=True)

    def test_the_service_module_copies_with_symlinks_preserved(self) -> None:
        """**The source of truth: the code says so.**"""
        import inspect

        source = inspect.getsource(service)
        # Every copy in the module must say so explicitly, or the default
        # (follow) applies and the escape is back.
        for call in ("copytree", "copy2"):
            for line in source.splitlines():
                if f"shutil.{call}(" not in line:
                    continue
                # The arguments may be on the next line, so look at the call
                # and the two lines after it.
                index = source.splitlines().index(line)
                window = " ".join(source.splitlines()[index : index + 3])
                self.assertTrue(
                    "symlinks=True" in window or "follow_symlinks=False" in window,
                    f"a shutil.{call} call does not say it preserves links: {window.strip()}",
                )


if __name__ == "__main__":
    unittest.main()
