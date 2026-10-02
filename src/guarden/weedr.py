"""weedr — the privileged mutator.

spec 6.2, and the only program that mutates anything as root. Every verb named
here is written whole or not at all: the grants in spec 5.1 are verbs because a
sudoers rule cannot tell one argument from another, so a flag on a granted verb
would grant the capability with it. There is no `weedr redeploy` — deploying is
`furrow deploy` — and `remove` is the only verb with an alias.
"""

from __future__ import annotations

import argparse
import json
import sys
import time

from guarden import (
    cli,
    conf,
    credentials,
    errors,
    gate,
    lineage,
    names,
    paths,
    reconcile,
    registry,
    report,
    service,
    snapper,
    snapshotid,
    users,
)
from guarden import config as config_mod

SERVICE = (
    ("ingest", "create or reconcile a service from a poke's staged tree"),
    ("add", "create or reconcile a service from another service's tree"),
    ("remove", "remove a service, or one instance of one; alias: rm"),
    ("purge", "delete a service's volumes; the only path in guarden that destroys data"),
    ("gate", "evaluate the credential gate; change nothing else, and take no /<ref>"),
    ("start", "start a service or one instance; re-evaluates the gate"),
    ("stop", "stop a service or one instance"),
    ("restart", "restart a service or one instance"),
    ("list", "every service, its identity, its ports, its volumes and its instances"),
    ("status", "one service, its unit state, its publications and its snapshots"),
    ("snapshot", "take a routine snapshot of every state volume, without stopping anything"),
    ("fork", "replace a service's state volumes with clones of a snapshot"),
    ("rollback", "replace a service's state volumes with clones of a snapshot"),
    ("immutable", "set chattr +i on a snapshot and record it, in one act"),
    ("mutable", "clear chattr +i on a snapshot and its record, in one act"),
    ("build", "podman build, as the service user"),
)

SECRET = (
    ("set", "plant a value, encrypted, with the terminal's echo off"),
    ("list", "the key names and whether each is set; never a value"),
    ("materialise", "the one place a blob is decrypted, into a service's podman store"),
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
        ("gate", "the service whose credential gate is evaluated"),
        ("start", "the service, or one instance"),
        ("stop", "the service, or one instance"),
        ("restart", "the service, or one instance"),
    ):
        _add_service_name(top["service"]["verbs"][verb], help_text)

    cli.add_json(top["service"]["verbs"]["list"])

    status = top["service"]["verbs"]["status"]
    _add_service_name(status, "the service to report on")
    cli.add_json(status)

    snapshot = top["service"]["verbs"]["snapshot"]
    snapshot.add_argument(
        "name",
        metavar="NAME",
        nargs="?",
        help="the service to snapshot; or --all for every service with a state volume",
    )
    snapshot.add_argument(
        "--all",
        action="store_true",
        help="every service with a state volume, which is what the nightly timer uses",
    )

    fork = top["service"]["verbs"]["fork"]
    cli.add_name(fork, "the service that receives the clone")
    fork.add_argument(
        "--from",
        dest="from_service",
        metavar="SERVICE[@TIME]",
        help="the service to clone from, and optionally the moment to clone as of",
    )

    rollback = top["service"]["verbs"]["rollback"]
    cli.add_name(rollback, "the service to roll back")
    rollback.add_argument(
        "--to",
        dest="when",
        metavar="TIME",
        required=True,
        help="the moment to restore, never a number: a number cannot name a set",
    )

    immutable = top["service"]["verbs"]["immutable"]
    immutable.add_argument("id", metavar="SNAPSHOT", help="<service>:<volume>@<number>")
    immutable.add_argument("reason", metavar="REASON", help="why, in the operator's words")
    top["service"]["verbs"]["mutable"].add_argument(
        "id", metavar="SNAPSHOT", help="<service>:<volume>@<number>"
    )

    build = top["service"]["verbs"]["build"]
    cli.add_name(build, "the service whose own tree the build runs on")

    secret_set = top["secret"]["verbs"]["set"]
    secret_set.add_argument("name", metavar="NAME", help="the service that owns the value")
    secret_set.add_argument("key", metavar="KEY", help="the schema's key")
    secret_list = top["secret"]["verbs"]["list"]
    secret_list.add_argument("name", metavar="NAME", help="the service")
    cli.add_json(secret_list)
    top["secret"]["verbs"]["materialise"].add_argument(
        "name",
        metavar="NAME",
        nargs="?",
        help="one service, or every service that has a blob; the units pass none",
    )

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


def _record_for(name: str):
    record = registry.load(name)
    if record is None:
        raise errors.GuardenError(
            f"{name} has no registry entry, so there is nothing to ask about",
            errors.HOST_NOT_AS_ASSUMED,
        )
    return record


def _gate(args) -> int:
    """Evaluate and record, and change nothing else (spec 6.6 step 3).

    It is a mutator verb because the blobs and the store are inside `0700` trees
    only root can read, and it is on the `guarden` sudoers rule precisely because
    it is safe: a wrong verdict recorded here cannot start anything, because
    `weedr service start` re-evaluates every time.
    """
    config = config_mod.load()
    resolved = names.resolve(args.name, list(config.tracks), allow_default=False)
    if resolved.ref:
        raise errors.GuardenError(
            f"the gate verdict is per SERVICE, because every instance of {resolved.name} shares "
            f"the service's one secret store; weedr service gate takes no /<ref>"
        )
    record = _record_for(resolved.name)
    now = _now()
    verdict = gate.evaluate(
        resolved.name, gate.schema_for(resolved.name), resolved.track.gated, now
    )
    gate.write(record, verdict, now)
    for warning in verdict.warnings:
        sys.stderr.write(f"{warning}\n")
    if verdict.state == gate.BLOCKED:
        raise errors.GuardenError(
            f"{resolved.name} is on the gated track {resolved.track.name!r} and cannot start: "
            f"{verdict.reason}",
            errors.HOST_NOT_AS_ASSUMED,
        )
    sys.stdout.write(f"{resolved.name} gate {verdict.state}\n")
    return 0


def _start(args) -> int:
    """The gate is re-evaluated here every time, so an operator who planted the
    credential and ran this starts the service with no second push (spec 6.6)."""
    config = config_mod.load()
    resolved = names.resolve(args.name, list(config.tracks), allow_default=False)
    record = _record_for(resolved.name)
    now = _now()
    verdict = gate.evaluate(
        resolved.name, gate.schema_for(resolved.name), resolved.track.gated, now
    )
    gate.write(record, verdict, now)
    for warning in verdict.warnings:
        sys.stderr.write(f"{warning}\n")
    if verdict.state == gate.BLOCKED:
        raise errors.GuardenError(
            f"{resolved.name} cannot start: {verdict.reason}", errors.HOST_NOT_AS_ASSUMED
        )
    # `started <name>` is a claim about the host, so it needs a unit to be true of.
    # A quadlet directory with nothing in it is a service whose units were never
    # installed, and reporting success there is the false report spec 1.2 forbids.
    if not service.units_of(resolved.name, resolved.escaped_ref):
        directory = service.units_dir(resolved.name, resolved.escaped_ref)
        raise errors.GuardenError(
            f"{resolved.name} has no unit to start: {directory} declares no container, so "
            "nothing was installed for it and there is nothing that could be running",
            errors.HOST_NOT_AS_ASSUMED,
        )
    service.start_units(resolved.name, resolved.escaped_ref)
    sys.stdout.write(f"started {resolved.name}\n")
    return 0


def _secret_set(args) -> int:
    key = credentials.validate_key(args.key)
    names.validate(args.name)
    _record_for(args.name)
    stored = credentials.prompt(f"{args.name} {key}")
    if not stored:
        raise errors.GuardenError(
            f"nothing was typed for {key} of {args.name}, so there is nothing to encrypt"
        )
    blob = credentials.plant(args.name, key, stored)
    # The line is printed before the materialiser is asked, because it is true
    # either way: the value is encrypted on the box from this moment on, and an
    # operator told only that this verb failed would re-type a credential that is
    # already written. What the ask adds is immediacy — the blob reaches the
    # service's podman store without waiting for the path unit to notice the
    # change (spec 6.2) — and a box that cannot make that happen is told which
    # unit is missing or which one failed.
    sys.stdout.write(f"planted {key} of {args.name} in {blob}\n")
    credentials.ask_materialiser(args.name, key, blob)
    return 0


def _secret_list(args) -> int:
    """Names and booleans, and never a value (spec 1.2, 6.2)."""
    names.validate(args.name)
    record = _record_for(args.name)
    schema = gate.schema_for(args.name)
    declared = {key.name: key for key in schema.keys}
    wanted = list(dict.fromkeys([*declared, *credentials.keys(args.name)]))
    secrets = []
    for key_name in sorted(wanted):
        stored = credentials.value(args.name, key_name)
        key = declared.get(key_name)
        is_example = bool(
            stored is not None
            and key is not None
            and credentials.placeholder(key, stored)
        )
        secrets.append(
            {
                "name": key_name,
                "set": stored is not None,
                "source": "generated" if key_name in record.generated else "planted",
                "example": is_example,
            }
        )
    if args.json:
        sys.stdout.write(json.dumps({"secrets": secrets}, separators=(",", ":")) + "\n")
        return 0
    if not secrets:
        sys.stdout.write("no credentials declared\n")
        return 0
    for entry in secrets:
        state = "set" if entry["set"] else "not set"
        marks = [entry["source"]]
        if entry["example"]:
            marks.append("still the example")
        sys.stdout.write(f"{entry['name']}\t{state}\t{', '.join(marks)}\n")
    return 0


def _secret_materialise(args) -> int:
    for line in credentials.materialise(args.name):
        sys.stdout.write(f"{line}\n")
    return 0


def _snapshot(args) -> int:
    now = _now()
    if args.all and args.name:
        raise errors.GuardenError(
            "`weedr service snapshot` takes a service or `--all`, and not both: `--all` is "
            "every service, so naming one of them would be a service the caller has to "
            "believe was excluded"
        )
    if args.all:
        lines = lineage.snapshot_all(now)
    else:
        if not args.name:
            raise errors.GuardenError(
                "`weedr service snapshot` takes a service or `--all`; the nightly timer uses "
                "`--all` and a script that means one service should name it"
            )
        config = config_mod.load()
        resolved = names.resolve(args.name, list(config.tracks), allow_default=False)
        record = registry.load(resolved.name)
        if record is None:
            raise errors.GuardenError(
                f"{resolved.name} has no registry entry, so there is nothing to snapshot",
                errors.HOST_NOT_AS_ASSUMED,
            )
        lines = lineage.snapshot(record, now)
        with conf.lock("registry"):
            registry.save(record, (0, users.group_id(service.GUARDEN_GROUP)))
    for line in lines:
        sys.stdout.write(f"{line}\n")
    return 0


def _fork(args) -> int:
    config = config_mod.load()
    resolved = names.resolve(args.name, list(config.tracks), allow_default=False)
    if resolved.ref:
        source = lineage.Source(service=resolved.name)
    elif args.from_service:
        source = lineage.parse_source(args.from_service)
    else:
        source = lineage.lineage_of(resolved)
    for line in lineage.fork(resolved, source, _now()):
        sys.stdout.write(f"{line}\n")
    return 0


def _rollback(args) -> int:
    config = config_mod.load()
    resolved = names.resolve(args.name, list(config.tracks), allow_default=False)
    when = snapper.moment_of(args.when)
    if when is None:
        raise errors.GuardenError(
            f"--to {args.when!r} is not a time. A snapshot number never names a set, because "
            f"a service with several state volumes has a different number in each "
            f"configuration; a time does."
        )
    for line in lineage.rollback(resolved, when, _now()):
        sys.stdout.write(f"{line}\n")
    return 0


def _immutable(args) -> int:
    snapshot = snapshotid.parse(args.id)
    if not args.reason.strip():
        raise errors.GuardenError(
            "the reason is what makes an escalation findable a year later, and an empty one "
            "is not a reason"
        )
    sys.stdout.write(f"{lineage.immutable(snapshot, args.reason)}\n")
    return 0


def _mutable(args) -> int:
    snapshot = snapshotid.parse(args.id)
    sys.stdout.write(f"{lineage.mutable(snapshot)}\n")
    return 0


def _pin_sync(args) -> int:
    for line in reconcile.run():
        sys.stdout.write(f"{line}\n")
    return 0


HANDLERS = {
    "weedr service ingest": _ingest,
    "weedr service add": _add,
    "weedr service remove": _remove,
    "weedr service purge": _purge,
    "weedr service gate": _gate,
    "weedr service start": _start,
    "weedr service list": _list,
    "weedr service snapshot": _snapshot,
    "weedr service fork": _fork,
    "weedr service rollback": _rollback,
    "weedr service immutable": _immutable,
    "weedr service mutable": _mutable,
    "weedr secret set": _secret_set,
    "weedr secret list": _secret_list,
    "weedr secret materialise": _secret_materialise,
    "weedr pin sync": _pin_sync,
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
