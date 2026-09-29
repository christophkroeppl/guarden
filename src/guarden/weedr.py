"""weedr — the privileged mutator.

spec 6.2, and the only program that mutates anything as root. Every verb named
here is written whole or not at all: the grants in spec 5.1 are verbs because a
sudoers rule cannot tell one argument from another, so a flag on a granted verb
would grant the capability with it. There is no `weedr redeploy` — deploying is
`furrow deploy` — and `remove` is the only verb with an alias.
"""

from __future__ import annotations

import argparse
import sys
import time

from guarden import cli, errors, names, paths, registry, report, service
from guarden import config as config_mod

SERVICE = (
    ("ingest", "create or reconcile a service from a poke's staged tree"),
    ("add", "create or reconcile a service from another service's tree"),
    ("remove", "remove a service, or one instance of one; alias: rm"),
    ("purge", "delete a service's volumes; the only path in guarden that destroys data"),
    ("start", "start a service or one instance"),
    ("stop", "stop a service or one instance"),
    ("restart", "restart a service or one instance"),
    ("list", "every service, its identity, its ports, its volumes and its instances"),
    ("status", "one service, its unit state, its publications and its snapshots"),
    ("snapshot", "take a routine snapshot of every state volume, without stopping anything"),
    ("fork", "replace a service's state volumes with clones of a snapshot"),
    ("rollback", "replace a service's state volumes with clones of a snapshot"),
    ("build", "podman build, as the service user"),
)

SECRET = (
    ("set", "plant a value, encrypted, with the terminal's echo off"),
    ("list", "the key names and whether each is set; never a value"),
)

PORT = (
    ("list", "requested, granted and pending, per service"),
    ("open", "grant a public port the manifest requested"),
    ("close", "revoke a granted public port"),
)

PIN = (("sync", "recompute the snapper marks from the pin files and the registries"),)

MODULE = (
    ("list", "the enabled modules and the available ones"),
    ("add", "install a module's services, groups and grants"),
    ("remove", "the inverse, in the order spec 6.2 states"),
)

PROJECT = (
    ("list", "every project and the tracks its refs may deploy to"),
    ("add", "register a project and its repository"),
    ("remove", "forget a project; alias: rm"),
    ("keys", "the poke keys installed for a project"),
    ("grant", "install one poke key, bound to this project by a forced command"),
    ("revoke", "remove one poke key"),
)

GROUPS = (
    ("service", "identities, volumes, units, snapshots, forks and rollbacks", SERVICE),
    ("secret", "the values a service's containers are given", SECRET),
    ("port", "the public ports an admin has granted", PORT),
    ("pin", "the privileged bridge into snapper", PIN),
    ("module", "the shipped bundles of services and shared programs", MODULE),
    ("project", "repositories, their refs and their poke keys", PROJECT),
)

EPILOG = """\
`remove` is the only verb with an alias, and it is `rm`: weedr service rm,
weedr project rm. Nothing else in guarden has one, and nothing else will.

Not on the guarden sudoers rule, and not reachable from a deploy:
`weedr port open`, `weedr port close`, `weedr service purge`,
`weedr service rollback`, `weedr module add`, `weedr project add`,
`weedr project grant`, `weedr project revoke`.
"""


def _add_service_name(parser: argparse.ArgumentParser, help_text: str) -> None:
    cli.add_name(parser, help_text)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="weedr",
        description="The privileged mutator.",
        epilog=EPILOG,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    top = cli.add_groups(parser, "group", GROUPS)

    for verb, help_text in (
        ("ingest", "the service to create, with a ref on an instance track"),
        ("add", "the service to create; a name with no environment resolves a default"),
    ):
        creator = top["service"]["verbs"][verb]
        cli.add_name(creator, help_text)
        creator.add_argument(
            "--from",
            dest="source",
            metavar="SOURCE",
            nargs="+",
            required=True,
            help="`<service>`, or `poke <project>@<sha>`; never a path",
        )

    for verb, help_text in (
        ("remove", "a whole service, or one instance with /<ref>"),
        ("purge", "the service whose volumes are destroyed"),
        ("start", "the service, or one instance"),
        ("stop", "the service, or one instance"),
        ("restart", "the service, or one instance"),
    ):
        _add_service_name(top["service"]["verbs"][verb], help_text)

    cli.add_json(top["service"]["verbs"]["list"])

    status = top["service"]["verbs"]["status"]
    _add_service_name(status, "the service to report on")
    cli.add_json(status)

    cli.add_name(top["service"]["verbs"]["snapshot"], "the service to snapshot")
    top["service"]["verbs"]["snapshot"].add_argument(
        "--all",
        action="store_true",
        help="every service with a state volume, which is what the nightly timer uses",
    )

    fork = top["service"]["verbs"]["fork"]
    cli.add_name(fork, "the service that receives the clone")
    fork.add_argument(
        "--from",
        dest="from_service",
        metavar="SERVICE[@NUMBER]",
        help="the service, and optionally the snapshot, to clone from",
    )

    rollback = top["service"]["verbs"]["rollback"]
    cli.add_name(rollback, "the service to roll back")
    rollback.add_argument(
        "--to", dest="number", metavar="NUMBER", required=True, help="the snapshot number"
    )

    build = top["service"]["verbs"]["build"]
    cli.add_name(build, "the service whose own tree the build runs on")

    secret_set = top["secret"]["verbs"]["set"]
    secret_set.add_argument("name", metavar="NAME", help="the service that owns the value")
    secret_set.add_argument("key", metavar="KEY", help="the schema's key")
    secret_list = top["secret"]["verbs"]["list"]
    secret_list.add_argument("name", metavar="NAME", help="the service")
    cli.add_json(secret_list)

    cli.add_json(top["port"]["verbs"]["list"])
    for verb in ("open", "close"):
        verb_parser = top["port"]["verbs"][verb]
        verb_parser.add_argument("name", metavar="NAME", help="the service")
        verb_parser.add_argument("public_port", metavar="PUBLIC_PORT", help="the public port")

    cli.add_json(top["module"]["verbs"]["list"])
    for verb in ("add", "remove"):
        top["module"]["verbs"][verb].add_argument("name", metavar="NAME", help="the module")

    cli.add_json(top["project"]["verbs"]["list"])
    project_add = top["project"]["verbs"]["add"]
    project_add.add_argument("name", metavar="NAME", help="the project")
    project_add.add_argument(
        "--repository",
        required=True,
        metavar="URL",
        help="the repository a poke's source comes from",
    )
    project_add.add_argument(
        "--environments",
        metavar="MAPPING",
        help="which tracks a ref may deploy to, as `ref=track` pairs",
    )

    for verb, help_text in (("remove", "the project"), ("keys", "the project to list keys for")):
        top["project"]["verbs"][verb].add_argument("name", metavar="NAME", help=help_text)
    cli.add_json(top["project"]["verbs"]["keys"])

    for verb in ("grant", "revoke"):
        verb_parser = top["project"]["verbs"][verb]
        verb_parser.add_argument("name", metavar="NAME", help="the project")
        verb_parser.add_argument("pubkey", metavar="PUBKEY", help="an ed25519 public key")

    return parser


def _now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _emit(outcome: service.Outcome, verb: str) -> int:
    """What a create verb says, on stdout, and what it does not.

    A default environment is **printed**, because the caller asked for a service
    and got one under a name it did not type, and an operator who cannot see that
    has been given a name by something other than themselves.
    """
    if outcome.converged:
        sys.stdout.write("converged\n")
        return 0
    if outcome.resolved.defaulted:
        sys.stdout.write(f"{outcome.resolved.name}\n")
    for message in outcome.warnings:
        sys.stderr.write(f"{errors.warn(message)}\n")
    sys.stdout.write(f"{verb} {outcome.resolved.name} uid {outcome.uid}\n")
    return 0


def _create(args, allow_default: bool) -> int:
    config = config_mod.load()
    source = service.parse_from(args.source)
    resolved = names.resolve(args.name, list(config.tracks), allow_default)
    outcome = service.create(resolved, source, config, _now())
    return _emit(outcome, "created" if not outcome.converged else "converged")


def _ingest(args) -> int:
    # spec 5.1: the default-environment exception belongs to `add` alone, so a
    # poke can never choose the track its service lands in.
    return _create(args, allow_default=False)


def _add(args) -> int:
    return _create(args, allow_default=True)


def _remove(args) -> int:
    config = config_mod.load()
    resolved = names.resolve(args.name, list(config.tracks), allow_default=False)
    for line in service.remove(resolved, config, _now()):
        sys.stdout.write(f"{line}\n")
    return 0


def _purge(args) -> int:
    config = config_mod.load()
    resolved = names.resolve(args.name, list(config.tracks), allow_default=False)
    if resolved.ref:
        raise errors.GuardenError(
            f"{resolved.name}/{resolved.ref} is an instance, and an instance's volumes are "
            f"the service's data, so purging one would destroy it"
        )
    record = registry.load(resolved.name)
    if record is None:
        raise errors.GuardenError(
            f"{resolved.name} has no registry entry, so there is nothing to destroy",
            errors.HOST_NOT_AS_ASSUMED,
        )
    if resolved.track.gated:
        service._gated_refusal(resolved.name, resolved.track.name)

    # Every volume is named before any of it is destroyed, and the confirmation
    # is at a terminal: this is the only path in guarden that deletes data, and
    # it is not reachable from a sudoers rule at all.
    sys.stdout.write(f"about to destroy every volume of {resolved.name}:\n")
    for volume in record.volume_list():
        where = paths.volume(resolved.name, volume.kind, volume.name)
        sys.stdout.write(f"  {volume.kind} {volume.name} {where}\n")
    if not sys.stdin.isatty():
        raise errors.GuardenError(
            "weedr service purge needs a terminal to confirm at, and stdin is not one",
            errors.HOST_NOT_AS_ASSUMED,
        )
    for volume in record.volume_list():
        service._drop(paths.volume(resolved.name, volume.kind, volume.name))
    sys.stdout.write(f"destroyed every volume of {resolved.name}\n")
    return 0


def _list(args) -> int:
    listing = report.build()
    sys.stdout.write(report.as_json(listing) + "\n" if args.json else report.as_text(listing))
    return 0


HANDLERS = {
    "weedr service ingest": _ingest,
    "weedr service add": _add,
    "weedr service remove": _remove,
    "weedr service purge": _purge,
    "weedr service list": _list,
}


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    call = " ".join(part for part in ("weedr", args.group, args.verb) if part)
    handler = HANDLERS.get(call)
    if handler is None:
        return cli.pending(call)
    try:
        return handler(args)
    except errors.GuardenError as exc:
        sys.stderr.write(f"{exc.report(call)}\n")
        return exc.code


if __name__ == "__main__":
    raise SystemExit(main())
