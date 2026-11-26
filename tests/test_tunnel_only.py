"""`[expose] tunnel_only` survives a read/modify/write round trip.

The key sits in the same `[expose]` table as `tunnel`, so `to_document()` must
emit the table when either key is present. A `tunnel_only`-only file used to be
lost because emission keyed off `tunnel` alone.
"""

from __future__ import annotations

import unittest

from guarden import overrides


class TunnelOnlyDocumentTest(unittest.TestCase):
    def test_both_keys_emit_in_one_table(self) -> None:
        document = overrides.Overrides(
            expose_tunnel=["staging.klimafit"],
            expose_tunnel_only=["staging.api.klimafit"],
        ).to_document()
        self.assertEqual(
            document["expose"],
            {
                "tunnel": ["staging.klimafit"],
                "tunnel_only": ["staging.api.klimafit"],
            },
        )

    def test_tunnel_only_alone_still_emits_the_table(self) -> None:
        document = overrides.Overrides(
            expose_tunnel_only=["staging.api.klimafit"]
        ).to_document()
        self.assertEqual(
            document["expose"], {"tunnel_only": ["staging.api.klimafit"]}
        )

    def test_no_keys_emits_no_table(self) -> None:
        self.assertNotIn("expose", overrides.Overrides().to_document())


if __name__ == "__main__":
    unittest.main()
