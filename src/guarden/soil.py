"""soil — the host converger.

spec 6.1. The only program with two modes and the only other one with a
`--check`. It creates no service user, a service directory, or any identity
belonging to a service: the two program users belong to `install`, and a
service's own user belongs to `weedr service add`. There is no `soil users`
phase, and `soil` must not grow one.

The phases live in `hostprep`, and this file is only the shape of the interface
and the difference between the two modes. `--check` asks every item whether it
already holds and reports the ones that do not; `--apply` asks every item to
make itself hold. Neither mode has its own idea of what converged means, which
is the only way to keep `--check` from describing a state `--apply` does not
produce.

**`--apply` also runs the one step a phase may have before its items, and
`--check` never does.** A step is not an item: it is not a fact about the host
with a "does it already hold" question, so there is nothing for `--check` to ask
it and asking anyway would be a check that changed something. The only step that
exists is the package index, and the whole of the difference between the two
modes is that one of them refreshes it.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

from guarden import errors, hostprep, packagelist, userdata
from guarden.hostprep import PHASES
from guarden.hosttool import Item, drift_line, error

EXIT_OK = 0
EXIT_NOT_CONVERGED = 1
EXIT_REJECTED = 2

COMMANDS = (*PHASES, "list")

EPILOG = f"""\
phases, in order: {", ".join(PHASES)}

  soil <phase> --check      report drift, change nothing, exit 1 with the word "drift"
  soil <phase> --apply      converge
  soil firewall --apply --deadman   arm the lockout timer for this run
  soil --check              every phase
  soil list                 the phases and what each owns

--deadman is the firewall's alone: it arms a timer whose effect is to open the
firewall, so it is never something a converge does on its own. The armed timer
is fifteen minutes, fires by stopping ferm and putting the distribution's own
firewall back, is one-shot, and a plain `soil firewall --apply` disarms it.

GUARDEN_PREFIX moves every host path soil touches under one directory. It is a
test seam: the fast harness points it at a scratch directory, and on a host it
is unset, so every path is the absolute one in spec 2. It is an environment
variable and not a flag because a flag on a phase is part of the interface the
spec and the sudoers lines both name, and a prefix can only narrow what a run
touches.
"""


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="soil",
        description="The host converger.",
        epilog=EPILOG,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "command",
        nargs="?",
        choices=COMMANDS,
        metavar="{" + ",".join(COMMANDS) + "}",
        help="a phase, or `list` to see the phases and what each owns",
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="report drift, change nothing")
    mode.add_argument("--apply", action="store_true", help="converge")
    parser.add_argument(
        "--deadman",
        action="store_true",
        help="arm the lockout timer for this run; `soil firewall --apply --deadman` only",
    )
    packages = parser.add_argument_group("package list", "where the one list lives")
    packages.add_argument(
        "--list",
        action="store_true",
        help="print this family's packages from packages/packages.toml and exit 0",
    )
    packages.add_argument(
        "--family",
        metavar="NAME",
        help="the distribution family to answer for; the host is asked when this is absent",
    )
    packages.add_argument(
        "--render-user-data",
        metavar="PATH",
        help="write the cloud-init user-data rendered from that list to PATH",
    )
    modules = parser.add_argument_group(
        "module selection",
        "what `soil install` records into guarden.toml's [modules] enabled",
    )
    modules.add_argument(
        "--modules",
        metavar="a,b",
        help="the modules to enable; recorded once and then left to `weedr module add`",
    )
    return parser


_MODULE_NAME = re.compile(r"[a-z][a-z0-9-]*")


def _module_selection(value: str | None) -> list[str] | None:
    """The modules the caller named, or a rejection.

    A selection is names in a comma-separated list and nothing else: it is going
    into `[modules] enabled`, which the config parser reads as a list of strings,
    so a value carrying a flag, a path or a space is a caller asking for
    something the key cannot hold and it is refused rather than written.
    """
    if value is None:
        return None
    if not value.strip():
        raise ValueError("--modules takes module names, and this one is empty")
    names = value.split(",")
    for name in names:
        if not _MODULE_NAME.fullmatch(name):
            raise ValueError(
                f"--modules takes names like gate and homepage, comma-separated; "
                f"{name!r} is not one"
            )
    return list(dict.fromkeys(names))


def _list() -> int:
    width = max(len(phase) for phase in PHASES)
    for phase in PHASES:
        sys.stdout.write(f"{phase.ljust(width)}  {hostprep.what_for(phase)}\n")
    return EXIT_OK


def _reject(message: str) -> int:
    error(message)
    return EXIT_REJECTED


def _package_list(family: str | None) -> int:
    """Print what this family needs, from the one list, and exit 0.

    A family the list does not carry is a rejected input: the caller named one
    that does not exist, and answering with a family that does would make the
    question unanswerable rather than answered wrongly.
    """
    try:
        name, row = packagelist.resolve(family)
        packages = packagelist.package_names(name)
    except packagelist.UnknownFamily as exc:
        return _reject(str(exc))
    sys.stdout.write(f"family   {name}\n")
    sys.stdout.write(f"install  {' '.join(str(part) for part in row.get('install', []))}\n")
    sys.stdout.write(f"query    {' '.join(str(part) for part in row.get('query', []))}\n")
    for package in packages:
        sys.stdout.write(f"{package}\n")
    return EXIT_OK


def _render_user_data(path: str, family: str | None) -> int:
    """Write the document a cloud-init machine boots from, rendered from the list.

    A path this program cannot write is a rejected input — the caller named one
    that does not exist or is not writable — and it says so rather than writing
    a document nobody will boot.
    """
    try:
        document = userdata.render(family)
    except packagelist.UnknownFamily as exc:
        return _reject(str(exc))
    target = Path(path)
    if target.exists() and target.is_dir():
        return _reject(f"{target} is a directory, not a file to write the user-data to")
    try:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(document, encoding="utf-8")
    except OSError as exc:
        return _reject(f"{target} could not be written: {exc.strerror}")
    sys.stdout.write(f"rendered {target}\n")
    sys.stdout.write(f"family   {family or 'this host'}\n")
    sys.stdout.write(f"phases   {' '.join(userdata.phases())}\n")
    return EXIT_OK


def _collect(
    phases: list[str], deadman: bool, family: str | None = None,
    modules: list[str] | None = None,
) -> list[Item]:
    items: list[Item] = []
    for phase in phases:
        items.extend(hostprep.items_for(phase, deadman, family, modules))
    return items


def _prepare(phase: str, family: str | None) -> tuple[bool, int | None]:
    """The phase's own step before any of its items, and what the run does about it.

    `(True, None)` is the ordinary case: the step is absent or it ran.

    `(False, None)` is a step that ran and failed because **the host is not in the
    state the request assumed** — the package index could not be refreshed, so the
    host cannot reach its own mirror. Nothing is refused and the run does not
    stop: the phase's items are reported rather than converged, and the next phase
    still gets its turn, so one unreachable mirror does not stop a host
    converging everything else. The run ends in exit `1`, which is the code
    spec 1.2 gives that condition.

    `(False, 2)` is a rejected input, and it stops the run: the next phase would be
    reading the same bad input, and carrying on past it would report a second,
    invented fault after the first.
    """
    try:
        prepare = hostprep.prepare_for(phase, family)
        if prepare is not None:
            prepare()
    except hostprep.IncompleteRecord as exc:
        return False, _reject(f"a pinned artefact is not installable: {exc}")
    except packagelist.UnknownFamily as exc:
        return False, _reject(str(exc))
    except errors.GuardenError as exc:
        if exc.code == errors.REJECTED_INPUT:
            return False, _reject(exc.message)
        error(exc.message)
        return False, None
    return True, None


def _check(
    phases: list[str], deadman: bool, family: str | None = None,
    modules: list[str] | None = None,
) -> int:
    # A host whose family the list carries no row for is **exit 2**, naming the
    # families it does have, in both modes: the list is repository input and there
    # is no row for it, which is spec 1.2's dividing line rather than a host fact.
    # `packages_items` resolves the family while it builds, so this is where it
    # escapes — and uncaught it was a traceback and an exit 1, which is the wrong
    # code for a rejected input and says nothing about which families exist. An
    # operator on an unsupported distribution gets one line and a fix instead of a
    # stack trace. `--apply` does not need the same guard: it calls `prepare_for`
    # before this phase's items and `_prepare` already answers 2 for it.
    try:
        items = _collect(phases, deadman, family, modules)
    except packagelist.UnknownFamily as exc:
        return _reject(str(exc))
    drifted = 0
    for item in items:
        if not item.holds():
            drift_line(item.what)
            drifted += 1
    return EXIT_NOT_CONVERGED if drifted else EXIT_OK


def _apply(
    phases: list[str], deadman: bool, family: str | None = None,
    modules: list[str] | None = None,
) -> int:
    unmet = 0
    for phase in phases:
        ready, reject = _prepare(phase, family)
        if reject is not None:
            return reject
        for item in hostprep.items_for(phase, deadman, family, modules):
            if item.holds():
                continue
            if ready:
                try:
                    item.converge()
                except hostprep.IncompleteRecord as exc:
                    return _reject(f"a pinned artefact is not installable: {exc}")
                except packagelist.UnknownFamily as exc:
                    return _reject(str(exc))
                if item.correctable and item.holds():
                    continue
            if item.correctable:
                drift_line(item.what)
                unmet += 1
        finish = hostprep.finish_for(phase)
        if finish is not None:
            finish()
    return EXIT_NOT_CONVERGED if unmet else EXIT_OK


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    try:
        modules = _module_selection(args.modules)
    except ValueError as exc:
        return _reject(str(exc))

    if args.command == "list":
        if args.check or args.apply or args.deadman or args.family or args.render_user_data:
            return _reject("soil list takes no mode.")
        if modules:
            return _reject("--modules is `soil install`'s.")
        return _list()

    # `--list` and `--render-user-data` report and exit; neither converges a
    # phase, so neither is a mode and neither changes the host. They are on the
    # `packages` command because that is the phase that owns the list, and the
    # renderer reads the same file the phase converges.
    if args.list or args.render_user_data:
        if args.deadman:
            return _reject("--deadman is `soil firewall --apply`'s alone.")
        if args.command not in (None, "packages"):
            return _reject("--list and --render-user-data are `soil packages`'s.")
        if args.list and args.render_user_data:
            return _reject("--list and --render-user-data are one or the other.")
        if modules:
            return _reject("--modules is `soil install`'s, and it converges nothing.")
        if args.list:
            return _package_list(args.family)
        return _render_user_data(args.render_user_data, args.family)

    if args.family:
        return _reject("--family is `soil packages`'s, and only with --list or "
                       "--render-user-data.")
    if modules and args.command not in (None, "install"):
        return _reject("--modules is `soil install`'s.")

    if args.command is None:
        if args.deadman:
            return _reject("--deadman is `soil firewall --apply`'s alone.")
        if not (args.check or args.apply):
            return _reject("one of --check or --apply is required.")
        if args.check:
            return _check(list(PHASES), False, modules=modules)
        return _apply(list(PHASES), False, modules=modules)

    if args.deadman and not (args.command == "firewall" and args.apply):
        return _reject("--deadman is `soil firewall --apply`'s alone.")
    if not (args.check or args.apply):
        return _reject("one of --check or --apply is required.")

    if args.check:
        return _check([args.command], args.deadman, modules=modules)
    return _apply([args.command], args.deadman, modules=modules)


if __name__ == "__main__":
    raise SystemExit(main())
