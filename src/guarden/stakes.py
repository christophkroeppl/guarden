"""stakes — the pin registry, and the only part of it that needs no privilege.

spec 6.8, 8.5 and ADR-0007. `stakes` records **intent** and nothing else: a pin
file under `/var/lib/guarden/stakes/`, one per snapshot, with no lock and no
aggregate file. That is not a simplification — a directory of independent files
has no read-modify-write to lose, and a program that maintained a shared index
would be a program whose index could disagree with the files it indexes.

**Nothing here is a promise that a snapshot will survive.** A pin is a priority
with a budget: it makes `weedr pin sync` write `important=yes` under the
`number` cleaner, and `NUMBER_LIMIT_IMPORTANT` is a range, so under real disk
pressure a marked snapshot can be reaped. What `stakes` reports is marked as a
statement about what the reconciler *will write* (spec 1.2), never as a fact
about the filesystem, because that fact is snapper's and the only program that
reads it as one is `weedr service list --json`.

**`stakes` never reads a service's state volume.** A service's tree is `0700` to
that service, so a per-volume snapshot count is not available to an unprivileged
program and is not asked for here. The per-volume figures come from
`weedr service list --json` as a root read, and that division is deliberate.

A pin may name any snapshot the host holds, and the id's `<service>` is the
service that **holds** it — not the service that wants it. `weedr service
fork` pins a source for the duration by creating this file and removing it
afterwards, which is why the file has no notion of a holder, a refcount or a
release order: a name in the directory is the whole of the state.
"""

from __future__ import annotations

import argparse
import json
import sys

from guarden import cli, errors, pins
from guarden import snapshotid as ids

GROUPS = (
    ("pin", "write a pin file for a snapshot", None),
    ("unpin", "remove a pin file", None),
    ("list", "the pin files this host holds and the services naming each", None),
    ("query", "what is wanted for one snapshot", None),
)

EPILOG = """\
A snapshot id is `<service>:<volume>@<number>` and nothing else: the service that
holds the snapshot, the volume's name, and the number. The colon is load-bearing
— `other-app-production-pgdata-41` could be a service called `other-app` with a
volume called `production-pgdata`.

A pin is a priority with a budget and not a promise. `NUMBER_LIMIT_IMPORTANT` is
a range, and under real disk pressure a marked snapshot can still be reaped. For
a denial that nothing overrides, use `weedr service immutable`, which is a
separate verb and a different mechanism.
"""


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="stakes",
        description="The pin registry.",
        epilog=EPILOG,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    top = cli.add_groups(parser, "group", GROUPS)

    pin = top["pin"]["parser"]
    pin.add_argument("id", metavar="SNAPSHOT", help="<service>:<volume>@<number>")
    pin.add_argument(
        "note", metavar="NOTE", nargs="?", default="", help="why it is being kept"
    )
    top["unpin"]["parser"].add_argument(
        "id", metavar="SNAPSHOT", help="<service>:<volume>@<number>"
    )
    cli.add_json(top["list"]["parser"])
    query = top["query"]["parser"]
    query.add_argument("id", metavar="SNAPSHOT", help="<service>:<volume>@<number>")
    cli.add_json(query)
    return parser


def _pin(args) -> int:
    snapshot = ids.parse(args.id)
    created = pins.write(snapshot, args.note)
    sys.stdout.write(
        f"{'pinned' if created else 'already pinned'} {snapshot}\n"
    )
    return 0


def _unpin(args) -> int:
    snapshot = ids.parse(args.id)
    if not pins.remove(snapshot):
        # Already true is not a failure: `unpin` on a snapshot nothing pins is
        # the state the caller asked for, and a nonzero exit would make a script
        # that unpins defensively look like it had found something.
        sys.stdout.write(f"{snapshot} is not pinned; nothing to do\n")
        return 0
    sys.stdout.write(f"unpinned {snapshot}\n")
    return 0


def _list(args) -> int:
    collected = pins.collect()
    _warn_stray(pins.stored()[1])
    if args.json:
        sys.stdout.write(
            json.dumps(
                {"pins": [pin.to_json() for pin in collected]}, separators=(",", ":")
            )
            + "\n"
        )
        return 0
    for pin in collected:
        by = ", ".join(pin.seeds) or "nothing"
        where = "a pin file" if pin.has_file else "a seed only"
        sys.stdout.write(f"{pin.snapshot}  {where}  wanted by {by}\n")
        if pin.note:
            sys.stdout.write(f"  {pin.note}\n")
    if not collected:
        sys.stdout.write("no pins; nothing wants a snapshot kept\n")
    return 0


def _query(args) -> int:
    snapshot = ids.parse(args.id)
    note = pins.note_of(snapshot)
    wanted = pins.seeds().get(snapshot, [])
    entry = pins.Pin(
        snapshot=snapshot,
        note=note or "",
        seeds=sorted(wanted),
        has_file=note is not None,
    )
    if args.json:
        sys.stdout.write(json.dumps(entry.to_json(), separators=(",", ":")) + "\n")
        return 0
    if note is None and not wanted:
        raise errors.GuardenError(
            f"{snapshot} is not pinned and no service names it as a seed",
            errors.HOST_NOT_AS_ASSUMED,
        )
    sys.stdout.write(f"{snapshot}\n")
    sys.stdout.write(f"  note       {note or 'none'}\n")
    sys.stdout.write(f"  pinned     {'yes' if note is not None else 'no'}\n")
    sys.stdout.write(f"  seeds      {', '.join(sorted(wanted)) or 'none'}\n")
    sys.stdout.write("  marked     will be written by weedr pin sync\n")
    return 0


HANDLERS = {
    "stakes pin": _pin,
    "stakes unpin": _unpin,
    "stakes list": _list,
    "stakes query": _query,
}


def _warn_stray(stray: list[str]) -> None:
    for name in stray:
        sys.stderr.write(
            f"warning: the pin file {name} is not a snapshot id, and protects nothing\n"
        )


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    verb = args.verb if args.verb and args.verb != args.group else None
    call = cli.invocation("stakes", args.group, verb)
    handler = HANDLERS.get(call)
    if handler is None:
        return cli.pending(call)
    try:
        return handler(args)
    except errors.GuardenError as exc:
        sys.stderr.write(f"{exc.report(call)}\n")
        return exc.code


if __name__ == "__main__":
    raise SystemExit(main())
