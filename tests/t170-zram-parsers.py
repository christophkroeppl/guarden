#!/usr/bin/env python3
"""The zram knob and its refusals, tested directly.

spec 11 permits exactly this exception — "the manifest and registry parsers, are
tested directly, because their failure is invisible from outside until it
silently drops a service's configuration" — and the `[zram]` table is a parser in
that sense: a table whose type or range guarden cannot read is a value it would
otherwise have to guess at, and the guess is written into a file the kernel
acts on.

Two things are load-bearing here and neither is reachable by running a converge
on a box:

- **the two exit codes**, because a `[zram] level` that is a string is the host
  (exit 1) while a level of 40 is a rejected input (exit 2), and a converge that
  collapsed them would send an operator to edit the wrong thing;
- **the size arithmetic**, because it is the generator's arithmetic and not
  guarden's, and a check that computed it any other way would report drift on a
  device that is exactly the size it was asked for.

The stub `/proc/meminfo` below is **not a fixture for a system tool**: it is the
host's own fact, staged into a scratch prefix so the arithmetic is checked against
a known `MemTotal` rather than against whatever machine this runs on. Nothing
here stands in for anything.

Run by tests/t170-zram-parsers.sh.
"""

from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path

PREFIX = tempfile.mkdtemp()
os.environ["GUARDEN_PREFIX"] = PREFIX
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

from guarden import errors, zram  # noqa: E402

FAILURES: list[str] = []

# A MemTotal in kilobytes, chosen so the megabyte truncation the generator does is
# not a no-op: 3_145_728 kB is 3072 MB exactly, and 3_145_800 kB is not, which is
# the case an integer implementation gets wrong.
MEMINFO = """MemTotal:        3145828 kB
MemFree:         2012344 kB
"""


def check(condition: bool, what: str) -> None:
    if not condition:
        FAILURES.append(what)


def refuse(table: object, code: int, contains: str, what: str) -> None:
    try:
        zram.knob({"zram": table})
    except errors.GuardenError as exc:
        check(exc.code == code, f"{what}: exit {exc.code}, expected {code}")
        check(contains in exc.message, f"{what}: {exc.message!r} does not name {contains!r}")
    else:
        FAILURES.append(f"{what}: accepted")


def accepts(table: object, what: str):
    try:
        return zram.knob({"zram": table})
    except errors.GuardenError as exc:
        FAILURES.append(f"{what}: refused with {exc.message!r}")
        return None


def absent() -> None:
    """Absent is the default, and it is nothing rather than a value."""
    check(zram.knob({}) is None, "a configuration with no [zram] yields no device")
    check(zram.knob({"host": {"domain": "x"}}) is None, "other tables do not make one")

    # And the whole of "absent means absent": on a host with no knob and no
    # marker, the install phase builds **no items at all**. That is the property
    # every other absence in the ticket reduces to, so it is asserted here
    # rather than inferred from five separate files.
    check(zram.items({}) == [], "no knob and no marker builds no items")


def the_defaults() -> None:
    device = accepts({"algorithm": "zstd", "level": 6, "size_percent": 50}, "a stated device")
    check(device is not None, "a stated device is accepted")
    if device is None:
        return
    check(device.algorithm_value == "zstd(level=6)", f"algorithm is {device.algorithm_value}")
    check(
        device.size_expression == "ram * 50 / 100",
        f"size expression is {device.size_expression}",
    )

    # `algorithm` and `level` may be omitted; `size_percent` may not, because
    # "no zram device" and "a zram device of no stated size" are different states
    # and only the operator knows which was meant.
    bare = accepts({"size_percent": 25}, "algorithm and level omitted")
    check(bare is not None and bare.algorithm == "zstd", "the algorithm defaults to zstd")
    check(bare is not None and bare.level == 6, f"the level defaults to {zram.LEVEL_DEFAULT}")


def the_typed_and_the_broken() -> None:
    # exit 1: the host, and spec 1.2's dividing line. A table of the wrong shape
    # is a file on the filesystem nobody filled in.
    refuse("zstd", errors.HOST_NOT_AS_ASSUMED, "a table", "a string instead of a table")
    refuse(
        {"size_percent": 50, "level": "6"},
        errors.HOST_NOT_AS_ASSUMED,
        "level is an integer",
        "a string level",
    )
    refuse(
        {"size_percent": 50, "size_pct": 50},
        errors.HOST_NOT_AS_ASSUMED,
        "size_pct",
        "a misspelled key",
    )

    # exit 2: a rejected input. A well-formed value that breaks a rule the table
    # states, each naming what the rule is.
    refuse(
        {"size_percent": 50, "algorithm": "lz4"},
        errors.REJECTED_INPUT,
        "the algorithms guarden offers are zstd",
        "an algorithm guarden does not offer",
    )
    refuse(
        {"size_percent": 50, "level": 40},
        errors.REJECTED_INPUT,
        "zstd runs 1-22",
        "a level outside zstd's range",
    )
    refuse(
        {"size_percent": 150},
        errors.REJECTED_INPUT,
        "larger than the memory backing it",
        "a percentage over 100",
    )
    refuse(
        {"size_percent": 0},
        errors.REJECTED_INPUT,
        "percentage of this host's RAM",
        "a percentage of zero",
    )


def the_size_arithmetic() -> None:
    """The generator's arithmetic, not a tidier one.

    `read_device` computes `memtotal_kb as f64 / 1024`, truncates that to `u64`
    megabytes, evaluates the expression in `f64`, multiplies by 1024 twice and
    truncates again. With 3 145 828 kB, the megabyte figure is 3072.0976…, the
    `u64` is 3072, and 50 percent of that is 1 610 612 736 bytes. The integer
    reading — `3145828 * 50 // 100 * 1024` — gives 1 610 671 616, and a check
    built on it would report drift on every host, forever.
    """
    path = Path(PREFIX) / "proc" / "meminfo"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(MEMINFO, encoding="utf-8")

    device = zram.Zram(algorithm="zstd", level=6, size_percent=50)
    check(
        device.expected_bytes == 1_610_612_736,
        f"expected_bytes is {device.expected_bytes}, not 1610612736",
    )

    # The page-alignment the driver applies is a real term: the generator's
    # megabyte figure is not always a whole number of pages once a percentage
    # lands on it, and the unaligned figure would be off by a page.
    odd = zram.Zram(algorithm="zstd", level=1, size_percent=33)
    check(
        odd.expected_bytes % 4096 == 0,
        f"expected_bytes {odd.expected_bytes} is not page-aligned",
    )

    # An unreadable `/proc/meminfo` is the host and is exit 1 in every other
    # place; here it is a zero, and a zero is checked rather than divided by.
    path.unlink()
    check(zram._memtotal_kb() == 0, "an unreadable meminfo reads as zero")
    path.write_text(MEMINFO, encoding="utf-8")


def the_files() -> None:
    """The two files, and what each of them is for."""
    device = zram.Zram(algorithm="zstd", level=3, size_percent=75)
    conf = zram.generator_conf(device)
    for wanted in (
        "[zram0]",
        "zram-size = ram * 75 / 100",
        "compression-algorithm = zstd(level=3)",
        "swap-priority = 100",
        "fs-type = swap",
        "host-memory-limit = none",
    ):
        check(wanted in conf, f"the generator configuration does not carry {wanted!r}")

    # `fs-type = swap` is stated rather than left to the default because the
    # generator's other mode is a compressed filesystem mounted at a directory,
    # and the reader of this file should not have to know which one was meant.
    check(
        "mount-point" not in conf, "the generator configuration asks for no mount point"
    )

    # The marker records what soil converged and nothing an operator alone set:
    # it is there so the teardown knows the device is guarden's.
    written = zram.marker(device)
    for wanted in ("device = zram0", "algorithm = zstd", "level = 3", "size_percent = 75"):
        check(wanted in written, f"the marker does not carry {wanted!r}")


def main() -> int:
    absent()
    the_defaults()
    the_typed_and_the_broken()
    the_size_arithmetic()
    the_files()
    for failure in FAILURES:
        sys.stderr.write(f"error: {failure}\n")
    return 1 if FAILURES else 0


if __name__ == "__main__":
    raise SystemExit(main())
