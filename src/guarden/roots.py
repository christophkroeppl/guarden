"""roots — the edge's routes.

spec 6.4. Traefik-specific by decision and with no intermediate route format:
if the edge is ever replaced, `roots` is replaced. It reads the rendered route
slices of every service and writes the edge's file-provider configuration into
`/var/lib/guarden/edge/dynamic/`, which is the one directory it may write.
"""

from __future__ import annotations

import argparse

from guarden import cli

GROUPS = (("sync", "render every service's routes into the edge's directory", None),)

EPILOG = """\
With the auth module installed, a route declaring `auth: true` gets the
forward-auth rule aimed at the service named in /etc/guarden/edge/auth-provider.
With it not installed, `roots` emits the route without a middleware and writes
one warning naming the service and the route, on every sync.
"""


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="roots",
        description="The edge's routes.",
        epilog=EPILOG,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    cli.add_groups(parser, "group", GROUPS)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return cli.pending(cli.invocation("roots", args.group, args.verb))


if __name__ == "__main__":
    raise SystemExit(main())
