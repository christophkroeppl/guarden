#!/usr/bin/env python3
"""One publication out of a service's registry, by instance.

usage: registryfield.py <registry> <escaped-ref|-> <container>

The registry is TOML and an instance's publication is an INLINE TABLE inside
the instance's own table:

    [instances."feature-a"]
    publication = { web = 20006 }

so it is read with a TOML parser and not with `sed`. A `sed` over the file
finds whatever line happens to carry the name, and an inline table is one
line — which is exactly the shape a grep for a flat sub-table never matches.

The key is the **escaped** ref, which is what the registry is keyed by
(spec 5.2): `feature-a` and `feature/x` are `feature-a` and `feature\\x2fx`
on disk, and a lookup that guessed the raw form would read the wrong
instance's row or none.

`-` is the service's own publication, which is the slot's and not any
instance's — the two are different numbers and a suite that confuses them is
asserting about the wrong port.

Exits 0 and prints the number, or 1 with one `error:` line naming what was
missing.
"""

from __future__ import annotations

import sys
import tomllib
from pathlib import Path

SERVICE = "-"


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        sys.stderr.write(f"usage: {argv[0]} <registry> <escaped-ref|-> <container>\n")
        return 2
    path, ref, container = Path(argv[1]), argv[2], argv[3]
    try:
        with open(path, "rb") as handle:
            document = tomllib.load(handle)
    except (OSError, tomllib.TOMLDecodeError) as exc:
        sys.stderr.write(f"error: {path} could not be read as TOML: {exc}\n")
        return 1
    if ref == SERVICE:
        publications = document.get("publication")
    else:
        instance = document.get("instances", {}).get(ref)
        if not isinstance(instance, dict):
            sys.stderr.write(f"error: {path} holds no instance {ref!r}\n")
            return 1
        publications = instance.get("publication")
    if not isinstance(publications, dict):
        where = "the service" if ref == SERVICE else f"the instance {ref!r}"
        sys.stderr.write(f"error: {where} holds no publication table in {path}\n")
        return 1
    value = publications.get(container)
    if not isinstance(value, int) or isinstance(value, bool):
        sys.stderr.write(
            f"error: the publication for the container {container!r} is not a number in {path}\n"
        )
        return 1
    sys.stdout.write(f"{value}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
