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
"""

from __future__ import annotations

import argparse
import sys

from guarden import hostprep
from guarden.hostprep import PHASES
from guarden.hosttool import Item, error

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
    return parser


def _list() -> int:
    width = max(len(phase) for phase in PHASES)
    for phase in PHASES:
        sys.stdout.write(f"{phase.ljust(width)}  {hostprep.what_for(phase)}\n")
    return EXIT_OK


def _reject(message: str) -> int:
    error(message)
    return EXIT_REJECTED


def _collect(phases: list[str], deadman: bool) -> list[Item]:
    items: list[Item] = []
    for phase in phases:
        items.extend(hostprep.items_for(phase, deadman))
    return items


def _check(phases: list[str], deadman: bool) -> int:
    drifted = 0
    for item in _collect(phases, deadman):
        if not item.holds():
            error(f"drift: {item.what}")
            drifted += 1
    return EXIT_NOT_CONVERGED if drifted else EXIT_OK


def _apply(phases: list[str], deadman: bool) -> int:
    unmet = 0
    for item in _collect(phases, deadman):
        if item.holds():
            continue
        try:
            item.converge()
        except hostprep.IncompleteRecord as exc:
            return _reject(f"a pinned artefact is not installable: {exc}")
        if item.correctable and not item.holds():
            error(f"drift: {item.what}")
            unmet += 1
    return EXIT_NOT_CONVERGED if unmet else EXIT_OK


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.command == "list":
        if args.check or args.apply or args.deadman:
            return _reject("soil list takes no mode.")
        return _list()

    if args.command is None:
        if args.deadman:
            return _reject("--deadman is `soil firewall --apply`'s alone.")
        if not (args.check or args.apply):
            return _reject("one of --check or --apply is required.")
        return _check(list(PHASES), False) if args.check else _apply(list(PHASES), False)

    if args.deadman and not (args.command == "firewall" and args.apply):
        return _reject("--deadman is `soil firewall --apply`'s alone.")
    if not (args.check or args.apply):
        return _reject("one of --check or --apply is required.")

    if args.check:
        return _check([args.command], args.deadman)
    return _apply([args.command], args.deadman)


if __name__ == "__main__":
    raise SystemExit(main())
