"""Per-environment manifest selection (Option B)."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from guarden import apps, service


class ManifestEnvSelectionTest(unittest.TestCase):
    def _tree(self, files):
        d = Path(tempfile.mkdtemp())
        root = d / "myapp"
        (root / ".guarden").mkdir(parents=True)
        for name, body in files.items():
            (root / ".guarden" / name).write_text(body)
        return d, root

    def test_base_manifest_used_when_no_env_specific(self):
        d, root = self._tree({"service.yml": "project: myapp\n"})
        self.assertEqual(service._manifest_in(root, "staging"), root / ".guarden" / "service.yml")
        self.assertEqual([a.name for a in apps.discover(d, "staging")], ["myapp"])

    def test_env_suffix_form_selected_for_matching_env(self):
        d, root = self._tree(
            {"service.yml": "project: myapp\n", "service.staging.yml": "project: myapp\nunits: compose.yaml\n"}
        )
        selected = service._manifest_in(root, "staging")
        self.assertEqual(selected, root / ".guarden" / "service.staging.yml")
        self.assertEqual(service._manifest_in(root, "production"), root / ".guarden" / "service.yml")

    def test_env_prefix_form_selected_for_matching_env(self):
        d, root = self._tree(
            {"service.yml": "project: myapp\n", "staging.service.yml": "project: myapp\nunits: compose.yaml\n"}
        )
        selected = service._manifest_in(root, "staging")
        self.assertEqual(selected, root / ".guarden" / "staging.service.yml")

    def test_discover_prefers_env_specific_for_matching_env(self):
        d, root = self._tree(
            {"service.yml": "project: myapp\n", "service.staging.yml": "project: myapp\nunits: compose.yaml\n"}
        )
        apps_found = apps.discover(d, "staging")
        self.assertEqual(len(apps_found), 1)

    def test_env_specific_only_tree_discovered(self):
        d, root = self._tree({"service.staging.yml": "project: myapp\n"})
        self.assertEqual([a.name for a in apps.discover(d, "staging")], ["myapp"])
        self.assertEqual([a.name for a in apps.discover(d)], [])

    def test_no_duplicate_app_when_both_manifests_present(self):
        d, root = self._tree(
            {"service.yml": "project: myapp\n", "service.staging.yml": "project: myapp\n"}
        )
        self.assertEqual(len(apps.discover(d, "staging")), 1)


if __name__ == "__main__":
    unittest.main()