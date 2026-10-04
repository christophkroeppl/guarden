"""twig — the dashboard's configuration.

spec 6.5. Merges every service's widget files, copied through from the shared
directory **unparsed**, into `/var/lib/guarden/shared/dashboard/`, and that is
the one place it may write: `shared/<name>/` is root-owned and read-only to it,
so the dashboard's own directory is `guarden`-owned and `weedr module add
homepage` is what creates it.

It parses no widget content. A widget file is a card the dashboard reads, and a
renderer that understood it would be a second thing to keep in step with the
dashboard itself, so what it validates is the rendered slice beside the file —
which container the entry named and which containers the unit source defined —
and what it writes is the file's own bytes.

One directory per service and one card per container, so a widget change is one
file changing and the dashboard picks it up from its own watch, and a service
that is removed takes its cards with it. That is what makes "a card appears
when a service appears and disappears when it is removed" a property of the
layout rather than something an operator does.

**A card is keyed by its container, and that is the whole of "one widget per
container".** Two entries for one container are two files claiming one key, so
they are refused rather than resolved: which of them would win is a question the
repository should never have to answer by accident.

It generates only the grouping and the per-project links, from `projects.toml`.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from guarden import cli, conf, errors, paths, registry, render
from guarden import config as config_mod

GROUPS = (("sync", "merge every service's widgets into the dashboard's directory", None),)

# The one slice `twig` reads beside the copied files; `loom` renders it and the
# mutator installs it, and `twig` is its only reader.
SLICE = "widgets.toml"
GROUPS_TEMPLATE = "dashboard-groups.yml.j2"
LINKS_TEMPLATE = "dashboard-links.yml.j2"
GROUPS_FILE = "layout.yml"
LINKS_FILE = "links.yml"
WIDGETS_DIR = "widgets"

# `twig` runs as `guarden` and the dashboard is a service in neither group, and
# the design keeps two groups, so the directory is world-readable (spec 2.1).
FILE_MODE = 0o644

MODULE = "homepage"

EPILOG = """\
Widget files are copied through unparsed. `twig` generates only the grouping
and the per-project links, from projects.toml.

`twig sync` writes one directory per service into the dashboard's
configuration directory and nowhere else, and removes the directory of a
service that is gone, so a card appears and disappears with its service.
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


def service_slice(service: str) -> dict:
    """One service's rendered widget slice: the entries and the container set.

    The container set is in the slice because the unit source is not readable
    from here: a service's tree is `0700` to that service and `twig` runs as
    `guarden`. `loom` saw the unit source when it rendered, and this is the one
    reader of what it saw.
    """
    return conf.read_toml(paths.SHARED / service / SLICE)


def services() -> list[str]:
    """Every service with a card, in service-name order.

    A service that declares no `widgets:` has an empty slice and produces no
    card and no group. The great majority of services declare none, and a group
    with nothing in it is an empty heading on the dashboard rather than a card.
    """
    if not paths.SHARED.is_dir():
        return []
    out = []
    for path in sorted(paths.SHARED.glob(f"*/{SLICE}")):
        if not path.is_file():
            continue
        service = path.parent.name
        if entries(conf.read_toml(path), service):
            out.append(service)
    return out


def entries(document: dict, service: str) -> list[dict]:
    """The `widgets:` entries, each checked against the slice's container set.

    Every refusal here is exit `2` (spec 1.2): the slice is a rendering of a
    manifest and a unit source, so a shape it cannot have, a key that is not one
    of the two, and a container it does not define are all **input**, whatever
    program reads it. `loom` refuses the same things at render time; this is the
    second reader, and a slice installed from an older render is the case it
    catches.
    """
    rows = document.get("widgets") or []
    if not isinstance(rows, list):
        raise errors.GuardenError(
            f"{paths.SHARED / service / SLICE}: widgets is not a list of [[widgets]] tables"
        )
    defined = [str(name) for name in (document.get("containers") or [])]
    out: list[dict] = []
    claimed: dict[str, str] = {}
    for row in rows:
        if not isinstance(row, dict):
            raise errors.GuardenError(
                f"{paths.SHARED / service / SLICE}: a widgets entry is not a table"
            )
        container = row.get("container")
        file = row.get("file")
        if not isinstance(container, str) or not isinstance(file, str):
            raise errors.GuardenError(
                f"{paths.SHARED / service / SLICE}: a widgets entry names a container "
                f"{container!r} and a file {file!r}, and both are strings; a widget names a "
                f"container in its own service, and only `needs` names another service"
            )
        if container not in defined:
            raise errors.GuardenError(
                f"{paths.SHARED / service / SLICE}: the widgets entry for the file {file!r} "
                f"names the container {container!r}, and the service's unit source defines "
                f"{', '.join(defined) or 'no container'}"
            )
        first = claimed.get(container)
        if first is not None:
            raise errors.GuardenError(
                f"{paths.SHARED / service / SLICE}: the container {container!r} has a widget "
                f"in {first!r} and another in {file!r}, and one card is one container: the "
                f"dashboard's own configuration gives them one key"
            )
        claimed[container] = file
        out.append({"container": container, "file": file})
    return out


def write_card(service: str, container: str, path: Path) -> str:
    """One card, at `<dashboard>/widgets/<service>/<container><extension>`.

    The name is the container, so a card is identified by what it is about and
    two entries for one container are one file rather than two answers.
    """
    target = paths.DASHBOARD / WIDGETS_DIR / service / f"{container}{path.suffix}"
    conf.write_file(target, path.read_text(encoding="utf-8"), FILE_MODE)
    return str(target)


def sweep(written: set[str]) -> list[str]:
    """Remove the directory of a service that is gone, and nothing else.

    `widgets/` is `twig`'s directory outright and every file in it is a card
    some service declared, so a directory under it that no installed slice
    claims is a service that is gone and its card goes with it. The two
    generated files sit beside `widgets/` and are rewritten every run, so they
    need no sweep and a file an operator put beside them survives a sync.
    """
    removed: list[str] = []
    base = paths.DASHBOARD / WIDGETS_DIR
    if not base.is_dir():
        return removed
    for directory in sorted(path for path in base.iterdir() if path.is_dir()):
        if directory.name in written:
            continue
        for path in sorted(directory.rglob("*"), reverse=True):
            if path.is_file():
                path.unlink()
        directory.rmdir()
        removed.append(directory.name)
    return removed


def projects() -> list[dict]:
    """The per-project links, from `projects.toml` and the registries (spec 6.5).

    A project with no entry contributes nothing: the allowlist in that file is
    for dispatch, and a card whose project has never been pushed is still a
    card. The hosts are the ones the mutator allocated from each service's route
    labels, so a link here names a host the edge answers on.
    """
    document = conf.read_toml(paths.PROJECTS_TOML).get("projects")
    if not isinstance(document, dict):
        return []
    records = [record for record in map(registry.load, registry.names()) if record is not None]
    out: list[dict] = []
    for project in sorted(document):
        entry = document.get(project)
        if not isinstance(entry, dict):
            continue
        mine = [record for record in records if record.project == project]
        if not mine:
            continue
        out.append(
            {
                "project": project,
                "repository": str(entry.get("repository", "")),
                "groups": [
                    {
                        "service": record.service,
                        "hosts": sorted(record.route_hosts.values()),
                    }
                    for record in sorted(mine, key=lambda row: row.service)
                ],
            }
        )
    return out


def generate() -> list[str]:
    """The grouping and the per-project links, and nothing else.

    Two files rather than one so neither is half-written for the dashboard's
    watch, and so the grouping is a function of the installed tree alone while
    the links are a function of the root-owned project record.
    """
    rows = projects()
    written: list[str] = []
    for name, body in (
        (GROUPS_FILE, layout()),
        (LINKS_FILE, render.render_template(LINKS_TEMPLATE, rows=rows)),
    ):
        target = paths.DASHBOARD / name
        conf.write_file(target, body, FILE_MODE)
        written.append(str(target))
    return written


def layout() -> str:
    """One group per service that has a card, in service-name order."""
    return render.render_template(
        GROUPS_TEMPLATE, rows=[{"service": service} for service in services()]
    )


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.group != "sync":
        return cli.pending(cli.invocation("twig", args.group, None))
    try:
        return sync()
    except errors.GuardenError as failure:
        sys.stderr.write(failure.report("twig") + "\n")
        return failure.code


def sync() -> int:
    config = config_mod.load()
    if MODULE not in config.modules:
        raise errors.GuardenError(
            f"{paths.DASHBOARD} belongs to the {MODULE!r} module, which is not enabled, so "
            f"there is no directory this program may write; the enabled modules are: "
            f"{', '.join(config.modules) or 'none'}",
            errors.HOST_NOT_AS_ASSUMED,
        )
    if not paths.DASHBOARD.is_dir():
        raise errors.GuardenError(
            f"{paths.DASHBOARD} does not exist, so `twig sync` has nowhere to write; "
            f"`weedr module add {MODULE}` creates it guarden:guarden 0755",
            errors.HOST_NOT_AS_ASSUMED,
        )
    printed: list[str] = []
    written: set[str] = set()
    for service in services():
        document = service_slice(service)
        for entry in entries(document, service):
            source = paths.SHARED / service / "widgets" / Path(entry["file"]).name
            write_card(service, entry["container"], source)
        written.add(service)
        printed.append(f"{service} {len(entries(document, service))} widgets")
    for name in sweep(written):
        printed.append(f"removed {name}")
    for line in generate():
        printed.append(f"wrote {line}")
    for line in printed:
        sys.stdout.write(line + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
