#!/usr/bin/env python3
"""One route host out of a service's registry.

usage: registryhost.py <registry> <label>

The registry is TOML and a route's allocated name lives in the `[route_hosts]`
table as `label -> name` (spec 3.4). It is read with a TOML parser and not
with `sed`: the table is a set of quoted assignments, and a `sed` over the file
finds whatever line happens to carry the name — which for a name that is also a
substring of another is a way of reading the wrong service's row.

The name is the whole of what this file answers, and it is answered exactly:
the value under the label, with nothing added and nothing removed. A suite
asserting on it is asserting on what `roots` renders, what `weedr share issue`
grants and what `weedr service list` reports, because all three read this one
value.

Exits 0 and prints the name, or 1 with one `error:` line naming what was
missing.
"""

from __future__ import annotations

import sys
import tomllib
from pathlib import Path


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        sys.stderr.write(f"usage: {argv[0]} <registry> <label>\n")
        return 2
    path, label = Path(argv[1]), argv[2]
    try:
        with open(path, "rb") as handle:
            document = tomllib.load(handle)
    except (OSError, tomllib.TOMLDecodeError) as exc:
        sys.stderr.write(f"error: {path} could not be read as TOML: {exc}\n")
        return 1
    hosts = document.get("route_hosts")
    if not isinstance(hosts, dict):
        sys.stderr.write(f"error: {path} holds no route_hosts table\n")
        return 1
    value = hosts.get(label)
    if not isinstance(value, str) or not value:
        sys.stderr.write(
            f"error: {path} holds no route host for the label {label!r}\n"
        )
        return 1
    sys.stdout.write(f"{value}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
