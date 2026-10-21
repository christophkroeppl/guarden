#!/usr/bin/env python3
"""One instance's registry KEY, renamed or added. For a suite that plants a key.

usage: registrykey.py <registry> <old-escaped-ref> <new-escaped-ref>

The registry is TOML and the instance's key is the ESCAPED ref (spec 5.2):
`feature/x` is the key `feature\\x2fx` on disk. The key is a TOML table name,
so it is quoted — and the backslash is doubled by the TOML string quoting, so
the line on disk reads `[instances."feature\\x2fx"]`.

**The document is rewritten by a TOML PARSER and not by `sed`.** A `sed` over
the file guesses the spelling of the key, and the spelling has two escapes in
it; a parser knows the key as a value and writes it back with the quoting it
needs. The rewrite keeps the document's shape — the same tables, the same
values — and changes the one key.

**Renaming keeps the ORIGINAL key as well**, and that is the point: a suite
that plants a key wants the deploy to STAY converged, and the convergence
check asks whether the ref being deployed is among the registry's instances.
A registry whose only instance carries a different key is not converged, and
the verb under test would take another branch entirely. So the new key is
ADDED beside the old one, and the old one is left in place.

Exits 0, or 1 with one `error:` line naming what was missing.
"""

from __future__ import annotations

import sys
import tomllib
from pathlib import Path


def dump(document: dict) -> str:
    """The document back out, with the instance tables as TOML."""
    lines: list[str] = []
    scalars = {
        key: value
        for key, value in document.items()
        if key != "instances" and not isinstance(value, dict)
    }
    for key, value in scalars.items():
        lines.append(f"{key} = {value!r}" if not isinstance(value, str) else f'{key} = "{value}"')
    for name, value in document.items():
        if not isinstance(value, dict):
            continue
        if name == "instances":
            for key, entry in value.items():
                lines.append(f'[instances."{key}"]')
                for field, item in entry.items():
                    if isinstance(item, dict):
                        inner = ", ".join(f"{k} = {v}" for k, v in item.items())
                        lines.append(f"{field} = {{ {inner} }}")
                    elif isinstance(item, str):
                        lines.append(f'{field} = "{item}"')
                    else:
                        lines.append(f"{field} = {item!r}")
            continue
        lines.append(f"[{name}]")
        for field, item in value.items():
            if isinstance(item, dict):
                inner = ", ".join(f"{k} = {v}" for k, v in item.items())
                lines.append(f"{field} = {{ {inner} }}")
            elif isinstance(item, str):
                lines.append(f'{field} = "{item}"')
            else:
                lines.append(f"{field} = {item!r}")
    return "\n".join(lines) + "\n"


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        sys.stderr.write(f"usage: {argv[0]} <registry> <old-escaped-ref> <new-escaped-ref>\n")
        return 2
    path, old, new = Path(argv[1]), argv[2], argv[3]
    try:
        with open(path, "rb") as handle:
            document = tomllib.load(handle)
    except (OSError, tomllib.TOMLDecodeError) as exc:
        sys.stderr.write(f"error: {path} could not be read as TOML: {exc}\n")
        return 1
    instances = document.get("instances")
    if not isinstance(instances, dict) or old not in instances:
        sys.stderr.write(f"error: {path} holds no instance {old!r}\n")
        return 1
    # The new key is ADDED beside the old one, and the old one is kept: the
    # convergence check asks whether the ref being deployed is among the
    # registry's instances, and a registry whose only instance carries a
    # different key is not converged at all.
    document["instances"] = {**instances, new: instances[old]}
    path.write_text(dump(document), encoding="utf-8")
    sys.stdout.write(f"{old} -> {new}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
