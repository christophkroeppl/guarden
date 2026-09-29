"""stakes — the pin registry, and nothing else.

spec 6.8. It runs unprivileged and a service's tree is `0700` to that service,
so it cannot read a service's snapshots and does not pretend to: it reports the
pin files it owns and, for each, which services name it as a seed. Every figure
that needs a state volume comes from a root read instead — `weedr service list
--json` — and the division is stated there so a monitoring script is not
surprised by it.

A snapshot id is `<service>:<volume>@<number>` and nothing else. A colon cannot
appear in a service name or a volume name, so the id is unambiguous in a way a
dash is not.
"""

from __future__ import annotations

import argparse

from guarden import cli

GROUPS = (
    ("pin", "protect one snapshot, by creating its pin file", None),
    ("unpin", "stop protecting it, by removing the pin file", None),
    ("list", "the pin files it owns, and which services name each as a seed", None),
    ("query", "one snapshot, read from the host rather than from a state volume", None),
)

EPILOG = """\
A pin is a priority with a budget and not a promise: under real disk pressure a
marked snapshot can be reaped, oldest first. `weedr pin sync` is the privileged
bridge that turns the pin files into snapper's marks.
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
    pin.add_argument("snapshot_id", metavar="SNAPSHOT-ID", help="<service>:<volume>@<number>")
    pin.add_argument(
        "note", metavar="NOTE", nargs="?", help="why, for the operator reading it later"
    )

    top["unpin"]["parser"].add_argument(
        "snapshot_id", metavar="SNAPSHOT-ID", help="<service>:<volume>@<number>"
    )

    cli.add_json(top["list"]["parser"])

    query = top["query"]["parser"]
    query.add_argument("snapshot_id", metavar="SNAPSHOT-ID", help="<service>:<volume>@<number>")
    cli.add_json(query)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return cli.pending(cli.invocation("stakes", args.group, args.verb))


if __name__ == "__main__":
    raise SystemExit(main())
