#!/usr/bin/env python3
"""Read one field out of a JSON document on stdin, for the fast harness.

The one seam is the command line, and `--json` output is part of that surface:
spec 1.2 closes the field set, so a test has to be able to name a field and a
value without parsing prose. A path is a dotted list with numeric parts for list
indices, and `-` in a name is written `_` because a dot cannot appear in a
service name anyway.

Prints the value as JSON on one line, and exits 1 with a one-line diagnostic
naming the path it could not reach, so a failure says which field went missing
rather than only that something did.
"""

from __future__ import annotations

import json
import sys


def walk(document, path: list[str]):
    for part in path:
        if isinstance(document, list):
            try:
                document = document[int(part)]
            except (ValueError, IndexError):
                raise KeyError(part) from None
        elif isinstance(document, dict):
            if part not in document:
                raise KeyError(part)
            document = document[part]
        else:
            raise KeyError(part)
    return document


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        sys.stderr.write("error: usage: jsonfield <dotted.path>\n")
        return 2
    try:
        document = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        sys.stderr.write(f"error: stdin is not JSON: {exc.msg}\n")
        return 1
    try:
        value = walk(document, argv[1].split("."))
    except KeyError:
        sys.stderr.write(f"error: {argv[1]} is not a field of this document\n")
        return 1
    print(json.dumps(value, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
