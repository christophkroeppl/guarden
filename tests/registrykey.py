#!/usr/bin/env python3
"""One instance's registry KEY, added. For a suite that plants a key.

usage: registrykey.py <registry> <old-escaped-ref> <new-escaped-ref>

The registry is TOML and the instance's key is the ESCAPED ref (spec 5.2):
`feature/x` is the key `feature\\x2fx` on disk. The key is a TOML table name,
so it is quoted — and the backslash is escaped by the TOML string quoting, so
the line on disk reads `[instances."feature\\x2fx"]`.

**The document is rewritten by guarden's OWN TOML writer and not by a second
one.** `conf.toml_dumps` is the code that writes every registry guarden has
ever written, and it knows the two things a hand-rolled writer gets wrong:
a key that is not a bare key has to be QUOTED, and the backslash in an
escaped ref has to be ESCAPED inside that quoting. A writer that quotes the
key but not the backslash produces a document that is not TOML at all — and
the failure shows up as the mutator refusing to read its own registry, which
is a diagnostic about the registry and not about the suite that planted the
key. So the helper parses the document and hands it back to the program's
own writer, and the document it writes is one guarden can read.

**The new key is ADDED beside the old one, and the old one is kept**, and
that is the point: a suite that plants a key wants the deploy to STAY
converged, and the convergence check asks whether the ref being deployed is
among the registry's instances. A registry whose only instance carries a
different key is not converged, and the verb under test would take another
branch entirely. So the new key is ADDED beside the old one, and the old one
is left in place.

Exits 0, or 1 with one `error:` line naming what was missing.
"""

from __future__ import annotations

import sys
import tomllib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

from guarden import conf  # noqa: E402


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
    path.write_text(conf.toml_dumps(document), encoding="utf-8")
    # The document is read back with a parser, because a writer that produces
    # something the parser refuses is a writer that planted a broken file.
    try:
        with open(path, "rb") as handle:
            tomllib.load(handle)
    except (OSError, tomllib.TOMLDecodeError) as exc:
        sys.stderr.write(f"error: {path} was not TOML after the rewrite: {exc}\n")
        return 1
    sys.stdout.write(f"{old} -> {new}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
