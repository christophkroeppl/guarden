"""The origin-range refresher: one rename, and a failure leaves the file alone.

An empty or partial allowlist locks the tunnel's own traffic out of 443, so the
failure mode this file exists for is the boring one: nothing was written.
"""

from __future__ import annotations

import io
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from unittest import mock

from guarden import cfranges


class _Response(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class RefreshTest(unittest.TestCase):
    def run_main(self, v4: str, v6: str = ""):
        bodies = {"ips-v4": v4, "ips-v6": v6}

        def fake_urlopen(url, timeout=0):
            return _Response(bodies[url.rsplit("/", 1)[-1]].encode("utf-8"))

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "cloudflare-ips.conf"
            with (
                mock.patch.object(cfranges.paths, "CLOUDFLARE_IPS", path),
                mock.patch.object(cfranges.urllib.request, "urlopen", side_effect=fake_urlopen),
            ):
                stderr = io.StringIO()
                with redirect_stderr(stderr):
                    code = cfranges.main([])
                body = path.read_text(encoding="utf-8") if path.exists() else None
        return code, body, stderr.getvalue()

    def test_a_successful_refresh_writes_both_families(self) -> None:
        code, body, _ = self.run_main("173.245.48.0/20\n", "2606:4700::/32\n")
        self.assertEqual(code, 0)
        self.assertIn("173.245.48.0/20", body)
        self.assertIn("2606:4700::/32", body)

    def test_a_body_with_no_ipv4_prefix_writes_nothing(self) -> None:
        code, body, stderr = self.run_main("2606:4700::/32\n")
        self.assertEqual(code, 1)
        self.assertIsNone(body)
        self.assertIn("no IPv4 prefix", stderr)

    def test_a_malformed_prefix_writes_nothing(self) -> None:
        code, body, stderr = self.run_main("not-a-cidr\n")
        self.assertEqual(code, 1)
        self.assertIsNone(body)
        self.assertIn("not a CIDR prefix", stderr)


if __name__ == "__main__":
    unittest.main()
