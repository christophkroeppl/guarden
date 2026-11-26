"""Refresh the Cloudflare origin ranges that `[edge] origin_allowlist` reads.

One run is one fetch of Cloudflare's published v4 and v6 ranges, written to
`/etc/guarden/cloudflare-ips.conf` in a single rename. A fetch that fails, or a
body that names no IPv4 prefix, leaves the file exactly as it was: an empty
allowlist would lock the tunnel's own traffic out of 443, and a partial one is
worse than a stale one.

The firewall renders IPv4 prefixes only (`iptables-legacy` on this host), but the
file keeps both families so the reason for a v6 entry is visible next to it
rather than silently dropped at fetch time.
"""

from __future__ import annotations

import ipaddress
import os
import sys
import urllib.request

from guarden import errors, paths

URLS = (
    "https://www.cloudflare.com/ips-v4",
    "https://www.cloudflare.com/ips-v6",
)

# Cloudflare's edge answers a bare `Python-urllib/3` client with 403. The
# request identifies the caller and the project, nothing more.
USER_AGENT = "guarden-cfranges/1 (+https://github.com/christophkroeppl/guarden)"

HEADER = (
    "# Cloudflare origin ranges for [edge] origin_allowlist.\n"
    "# Refreshed by guarden-cloudflare-ips.timer; a failed refresh leaves this\n"
    "# file untouched. Only IPv4 prefixes are rendered into the firewall.\n"
)


def _fetch(url: str) -> list[str]:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=30) as response:
        body = response.read().decode("utf-8")
    found = []
    for raw in body.splitlines():
        line = raw.strip()
        if not line:
            continue
        try:
            ipaddress.ip_network(line, strict=False)
        except ValueError as exc:
            raise errors.GuardenError(
                f"{url}: {line!r} is not a CIDR prefix",
                errors.HOST_NOT_AS_ASSUMED,
            ) from exc
        found.append(line)
    return found


def _write(body: str) -> None:
    path = paths.CLOUDFLARE_IPS
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(body, encoding="utf-8")
    os.chmod(temporary, 0o644)
    os.replace(temporary, path)


def main(argv: list[str] | None = None) -> int:
    ranges: list[str] = []
    for url in URLS:
        try:
            ranges.extend(_fetch(url))
        except (OSError, errors.GuardenError) as exc:
            sys.stderr.write(errors.warn(f"cannot refresh the origin ranges: {exc}") + "\n")
            return 1
    ipv4 = [
        line
        for line in ranges
        if ipaddress.ip_network(line, strict=False).version == 4
    ]
    if not ipv4:
        sys.stderr.write(
            errors.warn("the refresh named no IPv4 prefix; the ranges file is unchanged")
            + "\n"
        )
        return 1
    _write(HEADER + "\n".join(ranges) + "\n")
    sys.stdout.write(
        f"origin ranges: {len(ipv4)} IPv4, {len(ranges) - len(ipv4)} IPv6\n"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
