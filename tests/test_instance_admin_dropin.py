"""The instance's keep-id drop-in directory is removed with the instance.

The defect this covers: `_drop_instance_admin_dropins` guarded the directories
it swept with

    if entry_stem(unit, escaped_ref) != unit:
        continue

`entry_stem` appends `-<escaped-ref>` whenever the ref is non-empty, so the
two sides can never be equal when a ref IS present — every directory was
skipped, and the instance's keep-id drop-in stayed behind after the instance
was removed. The spec promises the opposite (docs/spec.md: "an instance that
is removed takes its own directory with it").

The instance's admin drop-in directory is named after the ENTRY STEM, so it is
`<unit>-<escaped-ref>.container.d`. The service's own is `<unit>.container.d`.
The guard therefore has to ask "is this directory the instance's?" — which is
"does its stem end with the ref suffix?" — not "is its stem the base unit?".
"""

from __future__ import annotations

import shutil
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from guarden import paths, units


class InstanceAdminDropinTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.uid = 4242
        self.service = "dropin-preview"
        self.ref = "feature/x"
        self.escaped = "feature\\x2fx"

    def _admin_root(self) -> Path:
        root = self.tmp / "admin" / str(self.uid)
        root.mkdir(parents=True, exist_ok=True)
        return root

    def _write_dropin(self, directory_name: str, filename: str, body: str) -> Path:
        directory = self._admin_root() / directory_name
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / filename
        path.write_text(body, encoding="utf-8")
        return path

    def test_the_instances_own_dropin_is_removed(self) -> None:
        """The instance's directory is the one named after the entry stem."""
        mine = self._write_dropin(
            f"app-{self.escaped}.container.d",
            paths.KEEPID_DROPIN,
            "[Container]\nUserNS=keep-id:uid=1,gid=1\n",
        )
        with mock.patch.object(paths, "ADMIN_UNITS", self.tmp / "admin"), mock.patch.object(
            units.registry, "load", return_value=mock.Mock(uid=self.uid)
        ):
            units._drop_instance_admin_dropins(self.service, self.escaped)
        self.assertFalse(mine.exists(), "the instance's own drop-in must be gone with the instance")

    def test_the_services_own_dropin_survives(self) -> None:
        """The service's own `<unit>.container.d` is not the instance's."""
        theirs = self._write_dropin(
            "app.container.d", paths.KEEPID_DROPIN, "[Container]\nUserNS=keep-id:uid=2,gid=2\n"
        )
        with mock.patch.object(paths, "ADMIN_UNITS", self.tmp / "admin"), mock.patch.object(
            units.registry, "load", return_value=mock.Mock(uid=self.uid)
        ):
            units._drop_instance_admin_dropins(self.service, self.escaped)
        self.assertTrue(
            theirs.exists(), "the service's own drop-in must survive an instance removal"
        )

    def test_another_instances_dropin_survives(self) -> None:
        """Two instances have two directories, and neither takes the other's."""
        other = self._write_dropin(
            "app-other.container.d",
            paths.KEEPID_DROPIN,
            "[Container]\nUserNS=keep-id:uid=3,gid=3\n",
        )
        with mock.patch.object(paths, "ADMIN_UNITS", self.tmp / "admin"), mock.patch.object(
            units.registry, "load", return_value=mock.Mock(uid=self.uid)
        ):
            units._drop_instance_admin_dropins(self.service, self.escaped)
        self.assertTrue(other.exists(), "another instance's drop-in must survive")

    def test_the_admins_own_file_in_the_instances_directory_survives(self) -> None:
        """Guarden takes the file it wrote and nothing else (ADR-0019)."""
        admin = self._write_dropin(
            f"app-{self.escaped}.container.d",
            "90-admin.conf",
            "[Container]\nUserNS=keep-id:uid=4,gid=4\n",
        )
        with mock.patch.object(paths, "ADMIN_UNITS", self.tmp / "admin"), mock.patch.object(
            units.registry, "load", return_value=mock.Mock(uid=self.uid)
        ):
            units._drop_instance_admin_dropins(self.service, self.escaped)
        self.assertTrue(admin.exists(), "the admin's own file must never be deleted by guarden")

    def test_an_empty_instance_directory_is_removed(self) -> None:
        """The directory goes too, once the admin left nothing in it."""
        directory = self._admin_root() / f"app-{self.escaped}.container.d"
        directory.mkdir(parents=True, exist_ok=True)
        with mock.patch.object(paths, "ADMIN_UNITS", self.tmp / "admin"), mock.patch.object(
            units.registry, "load", return_value=mock.Mock(uid=self.uid)
        ):
            units._drop_instance_admin_dropins(self.service, self.escaped)
        self.assertFalse(directory.exists(), "an emptied instance directory must be removed")


if __name__ == "__main__":
    unittest.main()
