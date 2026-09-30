"""hose — the gitops receiver.

spec 6.7. The only network-facing program, and the only one that reaches a poke.
It keeps no git state and holds no privilege beyond a sudoers rule naming
`furrow deploy`, `furrow preview drop`, `furrow queue list`, `furrow status`,
`weedr service list` and `weedr project list`.

**There is no `<project>` argument, and its absence is the whole of the
per-project binding.** The project arrives in the forced command
`weedr project grant` writes and nowhere else. sshd *appends* the client's own
command to the forced command, so a key holder for one project could send
`--project other …` and every conventional parser takes the last occurrence of a
repeated option — the client would have won. A `--project` this program accepted
would therefore be a flag the client supplies. It is not in the parser below, so
an invocation carrying one is argparse's exit `2`, which is what spec 6.7
requires.
"""

from __future__ import annotations

import argparse
import sys

from guarden import cli

GROUPS = (
    ("poke", "deploy the tree on stdin to the track the ref maps to", None),
    ("drop", "remove the instance the ref names, on a track that permits it", None),
    ("check", "say what this program does not do, and exit 0", None),
)

EPILOG = """\
The project is a property of the key, not of the request: it comes from the
forced command in /etc/ssh/authorized_keys.d/hose. A `--project` argument is
refused with exit 2, because sshd appends the client's own command to the forced
one and the client would win.
"""

NOT_IMPLEMENTED = "not implemented: events only"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="hose",
        description="The gitops receiver.",
        epilog=EPILOG,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    top = cli.add_groups(parser, "group", GROUPS)

    poke = top["poke"]["parser"]
    poke.add_argument("ref", metavar="REF", help="the ref, taken raw")
    poke.add_argument("sha", metavar="SHA", help="the commit, and the staging directory's name")

    top["drop"]["parser"].add_argument("ref", metavar="REF", help="the ref, taken raw")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.verb == "check":
        sys.stdout.write(f"{NOT_IMPLEMENTED}\n")
        return 0
    return cli.pending(cli.invocation("hose", args.group, args.verb))


if __name__ == "__main__":
    raise SystemExit(main())
