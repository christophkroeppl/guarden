"""soil — the host converger.

spec 6.1. The only program with two modes and the only one besides nothing
else with a `--check`. It creates no service user, no service directory and no
identity belonging to a service: the two program users belong to `install`, and
a service's own user belongs to `weedr service add`.

`soil list` is real here because it names the phases, which is the one thing
about the interface that has to be true before any phase body exists.
"""

from __future__ import annotations

import argparse
import sys

from guarden import cli

PHASES: tuple[tuple[str, str], ...] = (
    ("packages", "the distribution packages, and the one pinned podlet release"),
    ("storage", "btrfs layout, the snapper value set, root and home, the cleanup timer"),
    ("sysctl", "route_localnet on the ingress interface, IPv6 off, the port threshold"),
    ("firewall", "ferm, fail2ban, 10-framework.conf, 20-ingress-nat.conf, the dead-man timer"),
    ("install", "guarden into /usr/lib/guarden, the two program users, the alias probe"),
    ("units", "the system units of the unprivileged programs"),
)

PHASE_NAMES = tuple(name for name, _ in PHASES)
COMMANDS = (*PHASE_NAMES, "list")

EPILOG = f"""\
phases, in order: {", ".join(PHASE_NAMES)}

  soil <phase> --check      report drift, change nothing, exit 1 with the word "drift"
  soil <phase> --apply      converge
  soil firewall --apply --deadman   arm the lockout timer for this run
  soil --check              every phase
  soil list                 the phases and what each owns

--deadman is the firewall's alone: it arms a timer whose effect is to open the
firewall, so it is never something a converge does on its own.
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
    width = max(len(name) for name in PHASE_NAMES)
    for name, owns in PHASES:
        sys.stdout.write(f"{name.ljust(width)}  {owns}\n")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.command == "list":
        if args.check or args.apply or args.deadman:
            sys.stderr.write("error: soil list takes no mode.\n")
            return 2
        return _list()

    if args.command is None:
        if args.deadman:
            sys.stderr.write("error: --deadman is `soil firewall --apply`'s alone.\n")
            return 2
        if not (args.check or args.apply):
            sys.stderr.write("error: one of --check or --apply is required.\n")
            return 2
        return cli.pending("soil --check" if args.check else "soil --apply")

    if args.deadman and not (args.command == "firewall" and args.apply):
        sys.stderr.write("error: --deadman is `soil firewall --apply`'s alone.\n")
        return 2
    if not (args.check or args.apply):
        sys.stderr.write("error: one of --check or --apply is required.\n")
        return 2

    mode = "--check" if args.check else "--apply"
    return cli.pending(f"soil {args.command} {mode}")


if __name__ == "__main__":
    raise SystemExit(main())
