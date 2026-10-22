#!/usr/bin/env python3
"""The golden's package set, read from the one list, in the machine.

`tests/lxc.sh provision` installs this on the image every suite is cut from.
`packages/packages.toml` is authoritative: the `packages` role is the substrate
and the `golden` role is what the LXD golden adds on top, so a package added to
the one list cannot miss the image and a package on the image is in the list.
One name per line on stdout, in file order, without repeats.

It reads the file rather than importing `guarden.packagelist` because it runs on
the bare image before the substrate the product imports exists.
"""

from __future__ import annotations

import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def names(document: dict, family: str) -> list[str]:
    substrate = document.get("families", {}).get(family, {}).get("packages", [])
    golden = document.get("golden", {}).get(family, {}).get("golden", [])
    if not substrate:
        raise SystemExit(f"error: packages.toml states no substrate for the family {family}")
    if not golden:
        raise SystemExit(
            f"error: packages.toml states no golden role for the family {family}; "
            "the image every suite is cut from would carry the substrate and nothing else"
        )
    ordered: list[str] = []
    for package in [*substrate, *golden]:
        if package not in ordered:
            ordered.append(package)
    return ordered


def main(argv: list[str]) -> int:
    family = argv[1] if len(argv) > 1 else "debian"
    path = ROOT / "packages" / "packages.toml"
    try:
        document = tomllib.loads(path.read_text(encoding="utf-8"))
    except (OSError, tomllib.TOMLDecodeError) as exc:
        print(f"error: cannot read the one package list at {path}: {exc}", file=sys.stderr)
        return 2
    for package in names(document, family):
        print(package)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
