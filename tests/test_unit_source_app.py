"""`_unit_source` finds a multi-app service's manifest, not only a single-app one.

A service that deploys ONE app of a multi-app repository holds the whole tree in
its home — the home is the build context (§6.6) — and its manifest is at
`home/apps/web/.guarden/service.yml`. The lookup in `_unit_source` tried
`<home>/.guarden/service.yml` and the module's shipped tree, and then raised
"no manifest in <home> and no module source".

That raise is on the **first `start`** path: `ensure_owner_line` re-renders the
units with the probed keep-id line, so every multi-app service whose image
declares a non-root `USER` — or hands off to a named user, the postgres/gosu
shape `probe_image` resolves — met it before its container ever ran. No suite
started such a service, so nothing was red.

A unit test rather than a suite because the subject is a path decision: the home
is patched to a temporary tree and `_render_source` (which stages a tree the
renderer cannot enter) is replaced with a pass-through, so this runs wherever
`just unit` runs. `tests/t307-multi-app.sh` covers the app model end to end on a
machine.
"""

import contextlib
import pathlib
import tempfile
import unittest
from unittest import mock

from guarden import errors, paths, service

MANIFEST = ".guarden/service.yml"


@contextlib.contextmanager
def passthrough(directory):
    """Stand-in for `_render_source`: the tree is already readable here."""
    yield directory


class Record:
    def __init__(self, app: str = "", installed_by: str | None = None):
        self.app = app
        self.installed_by = installed_by


class UnitSourceFindsTheAppTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self._tmp.name)
        self.home = self.root / "services" / "shop-web-staging" / "home"
        self.instance_home = self.root / "services" / "shop-web-staging" / "instances" / "a"

    def tearDown(self):
        self._tmp.cleanup()

    def seed(self, base: pathlib.Path, app: str = ""):
        directory = paths.app_root(base, app)
        (directory / MANIFEST).parent.mkdir(parents=True, exist_ok=True)
        (directory / MANIFEST).write_text("project: shop\n")
        return directory

    def source_of(self, record, name="shop-web-staging", escaped_ref=None):
        with mock.patch.object(paths, "service_home", return_value=self.home), \
             mock.patch.object(paths, "instance_home", return_value=self.instance_home), \
             mock.patch.object(service, "_render_source", passthrough):
            with service._unit_source(name, record, escaped_ref) as root:
                return root

    def test_a_multi_app_service_finds_its_app_manifest(self):
        """The defect: recorded app `apps/web`, manifest under the home's subdirectory."""
        expected = self.seed(self.home, "apps/web")
        got = self.source_of(Record(app="apps/web"))
        self.assertEqual(got, expected)

    def test_a_single_app_service_is_unchanged(self):
        """`app` empty is the tree root, which is every single-app repository."""
        expected = self.seed(self.home)
        got = self.source_of(Record(app=""))
        self.assertEqual(got, expected)

    def test_an_instance_finds_its_app_manifest(self):
        """An instance's home holds the same tree shape."""
        expected = self.seed(self.instance_home, "apps/web")
        got = self.source_of(Record(app="apps/web"), escaped_ref="a")
        self.assertEqual(got, expected)

    def test_no_manifest_anywhere_still_raises_by_name(self):
        """The refusal survives, and it still names the home it looked in."""
        with self.assertRaises(errors.GuardenError) as caught:
            self.source_of(Record(app="apps/web"))
        self.assertIn("no manifest in", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
