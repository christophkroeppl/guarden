"""The control surface is an identity, not a publication name.

`api` is the edge's control-surface publication. It used to be recognised by
name alone, which meant any app container called `api` was silently granted
admin-only access and never forwarded. These tests pin the replacement: the
record says whether it is the control surface, and an app's `api` publication
is an ordinary publication.
"""

from __future__ import annotations

import unittest

from guarden import errors, registry


def record(**overrides) -> registry.Registry:
    values = {
        "service": "example",
        "workload": "example",
        "project": "",
        "environment": "staging",
        "uid": 1000,
        "created": "2026-11-26T00:00:00Z",
    }
    values.update(overrides)
    return registry.Registry(**values)


class IsControlSurfaceTest(unittest.TestCase):
    def test_a_flagged_record_is_the_control_surface(self) -> None:
        self.assertTrue(registry.is_control_surface(record(control_surface=True)))

    def test_an_app_publication_named_api_is_not_the_control_surface(self) -> None:
        app = record(installed_by=None, control_surface=False)
        app.publication = {"api": 20001}
        self.assertFalse(registry.is_control_surface(app))

    def test_a_missing_record_is_not_the_control_surface(self) -> None:
        self.assertFalse(registry.is_control_surface(None))

    def test_an_unreadable_legacy_module_fails_closed(self) -> None:
        legacy = record(installed_by="no-such-module", control_surface=False)
        self.assertTrue(registry.is_control_surface(legacy))

    def test_the_flag_is_a_strict_boolean(self) -> None:
        with self.assertRaises(errors.GuardenError):
            registry.Registry.from_document(
                {"service": "example", "uid": 1000, "control_surface": "yes"}
            )

    def test_the_flag_round_trips(self) -> None:
        document = record(control_surface=True).to_document()
        self.assertIs(document.get("control_surface"), True)
        self.assertTrue(registry.Registry.from_document(document).control_surface)


if __name__ == "__main__":
    unittest.main()
