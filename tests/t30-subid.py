#!/usr/bin/env python3
"""Whether a delegated subid range is one no other line in the file claims.

    t30-subid.py <subuid file> <service name>

Exits 0 when the named service has a line and no other line in the file claims a
uid inside it, and 1 with one `error:` line naming what it found.

This is a reader of a host file and nothing else. The claim belongs to the file
rather than to the program: a range another user already holds maps every
container of either service to the same host uid, which `weedr` refuses as exit
`1` for an exact repeat but which is reached here from the fallback allocator
rather than from `useradd`. The fallback picks the first *free* block at the
system's base, and "free" is the whole of what went wrong: the test it was under
asked whether the base fell inside a line already taken, which once it did
stayed true of every later block too, so the walk never advanced past it and a
host with one ordinary range in `/etc/subuid` never got a range at all.

The file arrives as an argument rather than on stdin, like `tests/snapfield.py`
reads the document the program under test captured.
"""

from __future__ import annotations

import sys
from pathlib import Path


def spans(path: Path) -> dict[str, tuple[int, int]]:
    out: dict[str, tuple[int, int]] = {}
    for line in path.read_text().splitlines():
        parts = line.split(":")
        if len(parts) != 3 or not parts[0]:
            continue
        try:
            out[parts[0]] = (int(parts[1]), int(parts[2]))
        except ValueError:
            continue
    return out


def overlaps(here: tuple[int, int], there: tuple[int, int]) -> bool:
    return here[0] < there[0] + there[1] and here[0] + here[1] > there[0]


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        sys.stderr.write("usage: t30-subid.py <subuid file> <service name>\n")
        return 2
    where = Path(argv[1])
    name = argv[2]
    try:
        lines = spans(where)
    except OSError as exc:
        sys.stderr.write(f"error: {where} could not be read: {exc.strerror}\n")
        return 1

    held = lines.get(name)
    if held is None:
        sys.stderr.write(
            f"error: {where} has no line for {name}, so a container of its service could not "
            f"map its own root; the lines are: {', '.join(sorted(lines)) or 'none'}\n"
        )
        return 1

    # A uid claimed by two lines is the defect, and a wider line covers a narrower
    # one without ever repeating a start, so the comparison is on ranges and not
    # on the first field.
    offenders = sorted(
        f"{other}:{start}-{start + count - 1}"
        for other, (start, count) in lines.items()
        if other != name and overlaps(held, (start, count))
    )
    if offenders:
        sys.stderr.write(
            f"error: the range {held[0]}-{held[0] + held[1] - 1} of {name} in {where} is "
            f"claimed in full or in part by {', '.join(offenders)}, so every container of "
            f"either maps its root to the same host uid\n"
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))