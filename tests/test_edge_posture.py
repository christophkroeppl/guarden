"""`[edge]` posture and the Cloudflare origin ranges.

The `[edge]` table is host policy: the dashboard is tunnel-only by default, and
the origin allowlist is off until an operator enables it with a ranges file.
"""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest import mock

from guarden import config, errors, firewall


class EdgeTableTest(unittest.TestCase):
    def test_defaults(self) -> None:
        edge = config._edge({}, "guarden.toml")
        self.assertEqual(edge.dashboard, "off")
        self.assertEqual(edge.origin_allowlist, "off")

    def test_values_are_accepted(self) -> None:
        edge = config._edge(
            {"dashboard": "off", "origin_allowlist": "cloudflare"}, "guarden.toml"
        )
        self.assertEqual(edge.dashboard, "off")
        self.assertEqual(edge.origin_allowlist, "cloudflare")

    def test_an_unknown_dashboard_is_refused(self) -> None:
        with self.assertRaises(errors.GuardenError):
            config._edge({"dashboard": "websecure"}, "guarden.toml")

    def test_an_unknown_allowlist_is_refused(self) -> None:
        with self.assertRaises(errors.GuardenError):
            config._edge({"origin_allowlist": "everyone"}, "guarden.toml")


class CloudflareRangesTest(unittest.TestCase):
    def ranges(self, text: str) -> list[str]:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "cloudflare-ips.conf"
            path.write_text(text, encoding="utf-8")
            with mock.patch.object(firewall.paths, "CLOUDFLARE_IPS", path):
                return firewall._cloudflare_ranges()

    def test_comments_and_blank_lines_are_ignored(self) -> None:
        self.assertEqual(
            self.ranges("# ranges\n\n173.245.48.0/20\n104.16.0.0/13\n"),
            ["104.16.0.0/13", "173.245.48.0/20"],
        )

    def test_ipv6_ranges_are_not_rendered(self) -> None:
        # iptables-legacy cannot load an IPv6 prefix; the host is IPv4-only.
        self.assertEqual(
            self.ranges("173.245.48.0/20\n2606:4700::/32\n"),
            ["173.245.48.0/20"],
        )

    def test_a_missing_file_is_a_refusal(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "missing.conf"
            with mock.patch.object(firewall.paths, "CLOUDFLARE_IPS", path):
                with self.assertRaises(errors.GuardenError):
                    firewall._cloudflare_ranges()

    def test_a_malformed_prefix_is_a_refusal(self) -> None:
        with self.assertRaises(errors.GuardenError):
            self.ranges("not-a-cidr\n")


if __name__ == "__main__":
    unittest.main()
