"""`[providers.<track>]`: the logical name, and the concrete name it names.

**The tests are a `TestCase` and not module-level functions**, because
`just unit` runs `unittest discover`, and discover collects a `TestCase` and
nothing else: a file of plain functions reports "Ran 0 tests" and exits `0`,
which is a green that measured nothing. The five assertions this file carried
were exactly that — a test nobody could ever see fail.

The rules are the ones spec 3.1 states: the **concrete** name is a service name
in full, because it becomes a Linux user name; the **logical** name is the
manifest's own token and is held to the pattern alone, which is the rule the
manifest's `needs:` entry is held to. A track the host has, and a name the
table does not map, left alone.
"""

from __future__ import annotations

import pathlib
import tempfile
import unittest

from guarden import config as config_mod


def _write_config(text: str) -> pathlib.Path:
    tmp = pathlib.Path(tempfile.mkdtemp())
    path = tmp / "guarden.toml"
    path.write_text(text)
    return path


def _base(name: str = "staging") -> str:
    return (
        "[[environments]]\n"
        f'name = "{name}"\n'
        'kind = "slot"\n'
    )


class ProvidersTableTest(unittest.TestCase):
    """The table is a track's map of a logical provider name to a service."""

    def test_resolve_provider_identity_when_unmapped(self) -> None:
        path = _write_config(_base())
        cfg = config_mod.load(path)
        self.assertEqual(cfg.resolve_provider("staging", "postgres"), "postgres")

    def test_resolve_provider_maps_per_track(self) -> None:
        path = _write_config(
            _base("staging")
            + _base("production")
            + "[providers.staging]\n"
            'postgres = "postgres-staging"\n'
            + "[providers.production]\n"
            'postgres = "postgres-production"\n'
        )
        cfg = config_mod.load(path)
        self.assertEqual(cfg.resolve_provider("staging", "postgres"), "postgres-staging")
        self.assertEqual(cfg.resolve_provider("production", "postgres"), "postgres-production")

    def test_resolve_provider_full_name_passes_through(self) -> None:
        path = _write_config(
            _base("production")
            + "[providers.production]\n"
            'postgres = "postgres-production"\n'
        )
        cfg = config_mod.load(path)
        self.assertEqual(
            cfg.resolve_provider("production", "postgres-production"), "postgres-production"
        )

    def test_providers_not_a_table_refused(self) -> None:
        path = _write_config('providers = "nope"\n')
        with self.assertRaises(Exception) as caught:
            config_mod.load(path)
        self.assertIn("providers", str(caught.exception))

    def test_providers_value_not_a_string_refused(self) -> None:
        path = _write_config(
            _base("staging")
            + "[providers.staging]\n"
            "postgres = 5\n"
        )
        with self.assertRaises(Exception) as caught:
            config_mod.load(path)
        self.assertIn("postgres", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
