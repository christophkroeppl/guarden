"""twig — the dashboard.

spec 6.5. It merges every service's widget files into
`/var/lib/guarden/shared/dashboard/`, and that is the one place it may write:
`shared/<name>/` is root-owned and read-only to it, so the dashboard's own
directory is `guarden`-owned. It parses no widget content — it validates the
`widgets:` entries against the container set and copies the files the manifest
names.
"""

from __future__ import annotations

import argparse

from guarden import cli

GROUPS = (("sync", "merge every service's widgets into the dashboard's directory", None),)

EPILOG = """\
Widget files are copied through unparsed. `twig` generates only the grouping
and the per-project links, from projects.toml.
"""


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="twig",
        description="The dashboard.",
        epilog=EPILOG,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    cli.add_groups(parser, "group", GROUPS)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return cli.pending(cli.invocation("twig", args.group, args.verb))


if __name__ == "__main__":
    raise SystemExit(main())
