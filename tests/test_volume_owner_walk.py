"""The `[ownership]` walk chowns as root, so it must refuse to leave the tree.

`own_tree` is the one place guarden hands a volume's tree to a host uid, and it
runs as the mutator -- root. Its input is `<tree>/<kind>/<vol>`, and `<tree>/bulk`
is the service's OWN 0700 directory: the service user, or its container under the
keep-id pin, can free well and leave a symlink there. So the walk's safety is not
"the volume is where we think" -- it is "the volume is a directory, and resolving
it does not leave the service's tree".

Measured before these checks existed, with `pathlib` alone:

    link = tmp/link -> tmp/real        link.is_dir()      True
                                       link.rglob("*")    real's entries
    link = tmp/rootlink -> /           link.rglob("*")    /bin  /boot  /dev  /etc  ...

and `own_tree` ran `set_owner` on every one of those entries, as root. A volume
root that is a symlink to `/` therefore chowned `/`.

A unit test rather than a suite because the subject is a decision taken before
any system call that needs privilege: both refusals fire before `set_owner`, so
this runs anywhere `just unit` runs. `t277-volume-owner` covers the granted path
end to end on a real machine.
"""

import os
import pathlib
import shutil
import tempfile
import unittest
from unittest import mock

from guarden import errors, volumes


class OwnTreeStaysInsideTheTreeTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self._tmp.name)
        self.base = self.root / "services" / "myapp-staging"
        self.vol = self.base / "bulk" / "data"
        self.vol.mkdir(parents=True)
        (self.vol / "nested").mkdir()
        (self.vol / "nested" / "deep").write_text("payload")
        self.pair = (65534, 65534)

    def tearDown(self):
        self._tmp.cleanup()

    def test_a_symlinked_volume_root_is_refused(self):
        """The volume itself is a link: following it is the whole attack."""
        elsewhere = self.root / "elsewhere"
        elsewhere.mkdir()
        (elsewhere / "victim").write_text("x")
        link = self.base / "bulk" / "data"
        for entry in sorted(self.vol.rglob("*"), reverse=True):
            entry.unlink() if entry.is_file() else entry.rmdir()
        self.vol.rmdir()
        link.symlink_to(elsewhere)

        with self.assertRaises(errors.GuardenError) as caught:
            volumes.own_tree(link, self.pair, base=self.base)
        self.assertIn("is a symlink", str(caught.exception))
        # and nothing under the link was touched
        self.assertEqual((elsewhere / "victim").stat().st_uid, os.getuid())

    def test_a_symlink_to_root_is_refused(self):
        """The reported case: a link to `/` would have chowned the filesystem."""
        link = self.base / "bulk" / "rootlink"
        link.symlink_to("/")
        with self.assertRaises(errors.GuardenError) as caught:
            volumes.own_tree(link, self.pair, base=self.base)
        self.assertIn("is a symlink", str(caught.exception))

    def test_a_link_above_the_volume_is_refused(self):
        """`bulk` itself replaced by a link: the volume looks real, and is not ours."""
        outside = self.root / "outside"
        (outside / "data").mkdir(parents=True)
        (outside / "data" / "victim").write_text("x")
        bulk = self.base / "bulk"
        shutil.rmtree(bulk)
        bulk.symlink_to(outside)

        with self.assertRaises(errors.GuardenError) as caught:
            volumes.own_tree(bulk / "data", self.pair, base=self.base)
        self.assertIn("outside the service's own tree", str(caught.exception))

    def test_a_real_volume_inside_the_tree_is_walked(self):
        """The ordinary path is unchanged, and it is the only one that walks."""
        with mock.patch.object(volumes.conf, "set_owner") as chown:
            notes = volumes.own_tree(self.vol, self.pair, base=self.base)
        self.assertTrue(notes, "a walked tree reports what it did")
        self.assertGreater(chown.call_count, 1, "the root and its entries, not just the root")

    def test_a_volume_already_carrying_the_pair_costs_one_stat(self):
        """Convergence: no walk when the root already has the granted pair."""
        held = self.vol.lstat()
        with mock.patch.object(volumes.conf, "set_owner") as chown:
            notes = volumes.own_tree(self.vol, (held.st_uid, held.st_gid), base=self.base)
        self.assertEqual(notes, [])
        self.assertEqual(chown.call_count, 0, "a converged deploy must not walk the tree")


if __name__ == "__main__":
    unittest.main()
