"""loom — the renderer.

spec 6.3. Unprivileged and pure: the same manifest, registry, overrides and
configuration always produce the same bytes. It runs the pinned `podlet` over a
Compose file and treats the result as untrusted input, because who runs the
converter is what ADR-0012 is about, not whether the renderer writes the unit
itself.
"""

from __future__ import annotations

import argparse

from guarden import cli

GROUPS = (
    ("render", "render a manifest into quadlet units and the shared slices", None),
    ("check", "validate a manifest and its unit source, writing nothing", None),
)

EPILOG = """\
`render` takes the source directory, the service it is for, and the unit
directory to render into. A repository ships either compose.yaml at its root or
.guarden/quadlet/, never both and never neither.
"""


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="loom",
        description="The renderer.",
        epilog=EPILOG,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    top = cli.add_groups(parser, "group", GROUPS)

    render = top["render"]["parser"]
    render.add_argument(
        "source_dir", metavar="SOURCE-DIR", help="the repository root holding the manifest"
    )
    render.add_argument(
        "--service", required=True, metavar="NAME", help="the service the units are for"
    )
    render.add_argument(
        "--out", required=True, metavar="UNIT-DIR", help="where the units are written"
    )
    render.add_argument(
        "--instance",
        metavar=cli.NAME_REF,
        help="the escaped ref, on an instance track",
    )

    top["check"]["parser"].add_argument(
        "source_dir", metavar="SOURCE-DIR", help="the repository root holding the manifest"
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return cli.pending(cli.invocation("loom", args.group, args.verb))


if __name__ == "__main__":
    raise SystemExit(main())
