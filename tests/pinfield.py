#!/usr/bin/env python3
"""One field out of the pinned podlet record.

usage: pinfield.py <record> <arch|-> <key>

`<arch>` is a row of the record's `[artefacts]` table — `x86_64`, `aarch64` — and
`-` is the record's own top level, which is where `version` lives. `key` is
`version`, `format`, `url`, `sha256` or `binary_sha256`.

This is a helper and not a fixture: it reads a file the machine already holds and
prints one line. It exists because the record carries a row per architecture, so
"sed the `sha256 =` line" is a value from whichever row happens to come first
rather than the one this host installs, and a test that measured the wrong row
would compare the right shape and say nothing.

Exits 0 and prints the value, or 1 with one `error:` line naming what was
missing.
"""

from __future__ import annotations

import sys
import tomllib
from pathlib import Path

TOP = "-"


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        sys.stderr.write(f"usage: {argv[0]} <record> <arch|-> <key>\n")
        return 2
    record, arch, key = Path(argv[1]), argv[2], argv[3]
    try:
        with open(record, "rb") as handle:
            document = tomllib.load(handle)
    except (OSError, tomllib.TOMLDecodeError) as exc:
        sys.stderr.write(f"error: {record} could not be read as TOML: {exc}\n")
        return 1
    if arch == TOP:
        value = document.get(key)
    else:
        row = document.get("artefacts", {}).get(arch)
        value = row.get(key) if isinstance(row, dict) else None
    if not isinstance(value, str) or not value.strip():
        where = "the record's top level" if arch == TOP else f"[artefacts.{arch}]"
        sys.stderr.write(f"error: {where} carries no {key}: {record}\n")
        return 1
    sys.stdout.write(f"{value.strip()}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
