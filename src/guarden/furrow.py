"""furrow — the deploy queue.

spec 6.6. Unprivileged, and the only program that calls weedr on a schedule. The
order is the point (ADR-0011): ensure, render, build, gate, stop, install, start.
The build and the gate both land before the stop, so a failed one leaves the
running container running.

It never touches podman. `weedr service build` is a mutator verb because furrow
cannot become the service user, and because the subuid range belongs to the
service user and only it may map container-root into it.
"""

from __future__ import annotations

import argparse

from guarden import cli

QUEUE = (
    ("list", "the waiting requests, in order"),
    ("show", "one service's requests and their last failure"),
)

PREVIEW = (("drop", "remove one instance of a preview service"),)

GROUPS = (
    ("deploy", "queue a deploy: ensure, render, build, gate, stop, install, start", None),
    ("preview", "drop a preview instance", PREVIEW),
    ("queue", "what is waiting", QUEUE),
    ("status", "lanes, in flight, deployed and queued", None),
)

EPILOG = """\
`--from` is required when the service does not exist, and forbidden outside
staging: it must resolve, after realpath, to somewhere under
/var/lib/guarden/staging/. The same check is in `weedr service add`, and the one
there is the control, because guarden can write into the queue directory and the
mutator installs what it is handed as root.
"""


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="furrow",
        description="The deploy queue.",
        epilog=EPILOG,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    top = cli.add_groups(parser, "group", GROUPS)

    deploy = top["deploy"]["parser"]
    cli.add_name(deploy, "the service, or one instance with /<ref>")
    deploy.add_argument(
        "--from", dest="from_dir", metavar="DIR", help="the staged source directory"
    )
    deploy.add_argument("--sha", metavar="SHA", help="what is being deployed")
    deploy.add_argument(
        "--now", action="store_true", help="skip queue position for this request only"
    )

    drop = top["preview"]["verbs"]["drop"]
    drop.add_argument("name", metavar="NAME", help="the preview service")
    drop.add_argument("ref", metavar="REF", help="the ref, taken raw")

    cli.add_json(top["queue"]["verbs"]["list"])
    top["queue"]["verbs"]["show"].add_argument(
        "service", metavar="SERVICE", help="the service to report on"
    )

    cli.add_json(top["status"]["parser"])
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return cli.pending(cli.invocation("furrow", args.group, args.verb))


if __name__ == "__main__":
    raise SystemExit(main())
