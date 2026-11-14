"""loom — the renderer.

spec 6.3. Unprivileged and pure: the same manifest, registry, overrides and
configuration always produce the same bytes. It runs the pinned `podlet` over a
Compose file and treats the result as untrusted input, because who runs the
converter is what ADR-0012 is about, not whether the renderer writes the unit
itself.

`render` needs a service, because an edge's provider, an allocated publication
and the track's weight are all answers from the host. `check` does not, and
therefore cannot check them: it validates the two inputs the repository controls —
the manifest and the unit source — and writes nothing at all.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from guarden import cli, errors
from guarden import render as render_mod

GROUPS = (
    ("render", "render a manifest into quadlet units and the shared slices", None),
    ("check", "validate a manifest and its unit source, writing nothing", None),
)

EPILOG = """\
`render` takes the source directory, the service it is for, and the unit
directory to render into. A repository ships either compose.yaml at its root or
.guarden/quadlet/, never both and never neither.

`check` takes the source directory alone and writes nothing: the manifest and
the unit source are the repository's, and whether an edge's provider exists is
the host's answer, which is why that half is `render`'s to ask for.
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


def _lines(plan: render_mod.Plan) -> str:
    printed = [f"rendered {len(plan.files)} files"]
    for relative in plan.sorted_paths():
        printed.append(f"  {relative}")
    return "\n".join(printed) + "\n"


def do_render(args: argparse.Namespace) -> int:
    source = Path(args.source_dir)
    out = Path(args.out)
    document = render_mod.load_manifest(source)
    # The two inputs are read and checked before the host is asked anything: a
    # rejected input is rejected whatever state the host is in, and a developer
    # whose manifest has a typo should hear about the typo rather than about a
    # service that has not been created yet.
    unit_source = render_mod.resolve_unit_source(source, document)
    context = render_mod.resolve_context(args.service, args.instance)
    plan = render_mod.build(source, document, unit_source, context)
    render_mod.write(plan, out)
    _report(plan)
    sys.stdout.write(_lines(plan))
    return 0


def do_check(args: argparse.Namespace) -> int:
    source = Path(args.source_dir)
    document = render_mod.load_manifest(source)
    unit_source = render_mod.resolve_unit_source(source, document)
    plan = render_mod.build(source, document, unit_source, None)
    _report(plan)
    sys.stdout.write(f"{source} is renderable\n")
    return 0


def _report(plan: render_mod.Plan) -> None:
    for warning in plan.warnings:
        sys.stderr.write(errors.warn(warning) + "\n")


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if args.group == "render":
            return do_render(args)
        return do_check(args)
    except errors.GuardenError as failure:
        sys.stderr.write(failure.report("loom") + "\n")
        return failure.code


if __name__ == "__main__":
    raise SystemExit(main())
