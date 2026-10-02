#!/usr/bin/env python3
"""What one snapper configuration actually holds, for t30-list's comparisons.

`weedr service list` reports a volume's snapshot counts, its oldest date and its
newest out of `snapper --machine-readable json -c <config> list` (spec 8.2), and
the claim the caller makes of it is that it reports **this machine's** entries
rather than something a test planted. So the values printed here are read out of
the document the real `snapper` wrote, and the test sets the program's own output
against them.

The document is an object keyed by the configuration's name, and entry `number 0`
in it is the live subvolume — described `current`, with no date and no cleanup
tag — rather than a snapshot, so it is dropped here for the same reason it is
dropped in `tests/snapfield.py`: counting it would make this file's figures
disagree with the program's by exactly one on every configuration.

Three lines: the newest number, the oldest date, the newest date. A date is
printed exactly as the machine rendered it and is never parsed or reformatted
here — the shape of that string is snapper's to choose, and a helper that
normalised it would compare two renderings instead of one.

The document arrives on stdin, like `tests/jsonfield.py`, because the program
under test captured it to a file and a second reader is a second command.

Usage: `t30-list-snapshots.py <config>`.
"""

from __future__ import annotations

import json
import sys


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        sys.stderr.write("error: usage: t30-list-snapshots <config>\n")
        return 2
    config = argv[1]
    document = json.load(sys.stdin)
    if not isinstance(document, dict) or not isinstance(document.get(config), list):
        sys.stderr.write(f"error: the document carries no entry list for {config}\n")
        return 1
    entries = [
        entry
        for entry in document[config]
        if isinstance(entry, dict)
        and isinstance(entry.get("number"), int)
        and entry["number"] > 0
    ]
    if not entries:
        sys.stderr.write("error: the configuration holds no snapshot\n")
        return 1
    numbers = [entry["number"] for entry in entries]
    dates = sorted(entry["date"] for entry in entries)
    print(max(numbers))
    print(dates[0])
    print(dates[-1])
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
