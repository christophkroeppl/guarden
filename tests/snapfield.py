#!/usr/bin/env python3
"""One field of one snapshot, out of `snapper --machine-readable json -c <config> list`.

The mark is the claim this file exists to check, and it can only be read the
way spec 8.2 says to read it: JSON renders a snapshot's `userdata` as an
**object**, so `important` and `guarden` are keys of it. The CSV rendering joins
the whole map into one comma-joined quoted field, so a consumer of CSV has to
string-match a value it was told was structured.

Two things about the document, both measured on snapper 0.10.6:

- `--machine-readable` is a **global** option and goes before the command. The
  reader in `tests/lib.sh` is the one that builds the argv; this file is what
  makes sense of what comes back.
- The document is an **object keyed by the configuration's name**, and its first
  entry is `number 0`: the live subvolume, described `current`, with an empty
  date and no cleanup tag. Entry `0` is not a snapshot — snapper issues numbers
  from `1` and its cleaners never consider `0` — so it is dropped here rather
  than counted. Counting it would report a configuration that has never been
  snapshotted as holding one snapshot, and would report a configuration with one
  as holding two.

`tests/lib.sh` captures the document once per configuration and calls this with
that file on stdin, so a suite that asks three questions of one list runs
`snapper` once rather than three times.

Usage: `snapfield.py <config> <number|-> <field|->`. Prints the value on one
line and exits 0. A field the snapshot does not carry prints an empty line and
exits 0, because "the mark is not there" is an answer and not a failure. A
number the configuration has not issued exits 1, because that is a different
claim: no such snapshot is not a snapshot with no mark.

The per-snapshot fields are the ones spec 8.2's read makes keys rather than
prose: `number`, `cleanup` (which of the two kinds this is), `date`, and any key
of the `userdata` object — `important` and `guarden` among them.

With `<number>` as `-` the field is about the configuration rather than one
snapshot, and two of them are `count` and `newest`.

With `<number>` as `resolve` the argument is a **moment** rather than a number,
and the printed value is the snapshot `newest_at_or_before` would select for it —
the same walk over `(date, number)` that `src/guarden/snapper.py` performs. A
test that wants to assert which snapshot a `--from <service>@<moment>` fork
clones must ask this rather than write the number down, because a same-second
tie resolves to the HIGHER number and the answer depends on the clock.
"""

from __future__ import annotations

import json
import sys

CONFIG_ONLY = {"count", "newest"}


def _moment_of(value):
    """`snapper.moment_of`, imported so there is one parser and not two.

    The suite runs with `PYTHONPATH` pointing at the checkout's `src`, so the
    program's own parser is reachable. Importing it is deliberate: a copy here
    could accept a shape the program refuses, or refuse one it accepts, and the
    disagreement would surface as a wrong expected number rather than as a test
    failure.
    """
    from guarden.snapper import moment_of

    return moment_of(value)


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        sys.stderr.write("error: usage: snapfield <config> <number|-> <field|->\n")
        return 2
    config, number, field = argv[1], argv[2], argv[3]

    try:
        document = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        sys.stderr.write(f"error: stdin is not the snapper json list: {exc.msg}\n")
        return 1
    if not isinstance(document, dict):
        sys.stderr.write("error: the snapper json document is not keyed by configuration\n")
        return 1
    entries = document.get(config)
    if not isinstance(entries, list):
        sys.stderr.write(f"error: the document carries no entry list for {config}\n")
        return 1
    # Number 0 is the live subvolume and is not a snapshot, so every figure here
    # is computed over the snapshots alone.
    entries = [
        entry
        for entry in entries
        if isinstance(entry, dict)
        and isinstance(entry.get("number"), int)
        and entry["number"] > 0
    ]

    if number == "-":
        if field == "count":
            print(len(entries))
            return 0
        if field == "newest":
            numbers = [
                entry["number"]
                for entry in entries
                if isinstance(entry.get("number"), int)
            ]
            print(max(numbers) if numbers else "")
            return 0
        sys.stderr.write(f"error: {field!r} is not a field of a configuration\n")
        return 2

    if number == "resolve":
        # `resolve` arrives in the NUMBER slot and the moment in the FIELD slot,
        # because the argv shape is (config, number, field).
        #
        # **The parser is the program's own, imported rather than re-written.**
        # `moment_of` accepts four naive shapes and an ISO value with a zone, and
        # a second copy of that here would be a second implementation whose
        # disagreement with the real one shows up as a wrong expected number.
        when = _moment_of(field)
        if when is None:
            sys.stderr.write(f"error: {field!r} is not a time\n")
            return 2
        # The walk mirrors `snapper.newest_at_or_before`: skip anything after the
        # moment, then keep the best by `(date, number)`, so a same-second tie
        # resolves to the HIGHER number. This is the rule the code implements and
        # the reason a test must not write the expected number down.
        best = None
        for entry in entries:
            date = _moment_of(entry.get("date", ""))
            if date is None or date > when:
                continue
            if best is None or (date, entry["number"]) > best:
                best = (date, entry["number"])
        print(best[1] if best else "")
        return 0

    for entry in entries:
        if entry.get("number") == int(number):
            if field == "number":
                print(entry["number"])
                return 0
            if field == "cleanup":
                print(entry.get("cleanup", ""))
                return 0
            if field == "date":
                print(entry.get("date", ""))
                return 0
            userdata = entry.get("userdata")
            if isinstance(userdata, dict):
                print(userdata.get(field, ""))
            return 0

    sys.stderr.write(
        f"error: configuration {config} has no snapshot numbered {number}\n"
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
