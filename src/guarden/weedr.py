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
import os
import sys
import time

from guarden import (
    cli,
    conf,
    credentials,
    edgeconf,
    errors,
    firewall,
    firewallrules,
    gate,
    lineage,
    modules,
    names,
    paths,
    ports,
    projects,
    reconcile,
    registry,
    report,
    service,
    snapper,
    snapshotid,
    tool,
    units,
    users,
)
from guarden import config as config_mod
from guarden import hosttool as h

EDGE_GROUP = "edge"
EDGE_MODE = 0o2750

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

FIREWALL = (
    ("list", "every requested rule, deduplicated by content, with its services"),
    ("open", "install a requested rule the manifest asked for"),
    ("close", "revoke a granted rule"),
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
    ("firewall", "the firewall rules a service asks for", FIREWALL),
    ("pin", "the privileged bridge into snapper", PIN),
    ("module", "the shipped bundles of services and shared programs", MODULE),
    ("project", "repositories, their refs and their poke keys", PROJECT),
)

EPILOG = """\
`remove` is the only verb with an alias, and it is `rm`: weedr service rm,
weedr project rm. Nothing else in guarden has one, and nothing else will.

Not on the guarden sudoers rule, and not reachable from a deploy:
`weedr port open`, `weedr port close`, `weedr firewall open`,
`weedr firewall close`, `weedr service purge`,
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

    cli.add_json(top["firewall"]["verbs"]["list"])
    for verb in ("open", "close"):
        verb_parser = top["firewall"]["verbs"][verb]
        verb_parser.add_argument("name", metavar="NAME", help="the service")
        verb_parser.add_argument("rule", metavar="RULE", help="the name it asked for")

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
    for note in outcome.notes:
        sys.stdout.write(f"{note}\n")
    for message in outcome.warnings:
        sys.stderr.write(f"{errors.warn(message)}\n")
    sys.stdout.write(f"{verb} {outcome.resolved.name} uid {outcome.uid}\n")
    return 0


def _create(args, allow_default: bool) -> int:
    config = config_mod.load()
    source = service.parse_from(args.source)
    resolved = names.resolve(args.name, list(config.tracks), allow_default)
    now = _now()
    outcome = service.create(resolved, source, config, now)
    if outcome.fresh_instance:
        outcome.notes += lineage.seed_instance(resolved, now)
    _filter_set(resolved.name)
    _edge_units(resolved.name)
    return _emit(outcome, "created" if not outcome.converged else "converged")


def _edge_units(name: str) -> None:
    """Re-render the edge's own units when this service gave it something to name.

    A route target is `<service>:<publication>`, so a service that gains a route
    is a new name the edge has to resolve — an `AddHost=` line in the edge's
    units. Nothing else re-renders it: the deploy path renders the service
    being deployed, and this is the one file that changes because of another
    service.
    """
    record = registry.load(name)
    if record is None or not record.route_hosts:
        return
    config = config_mod.load()
    for module in config.modules:
        try:
            entry = modules.read(module).edge()
        except errors.GuardenError:
            continue
        if entry is None:
            continue
        units.report(units.install(modules.source_of(module, entry.name), entry.name))
        return


def _filter_set(name: str) -> None:
    """Re-render the uid-matched filter set when the service gained a publication
    or an edge.

    A service with neither contributes no line to it, so a service that asks for
    neither — a database, a queue — leaves the set alone and no firewall write
    happens on its account. An edge counts even though the publication it dials
    belongs to the provider: the consumer's **uid** joins that publication's
    accept set, so a consumer with no publication of its own still changes the
    rendered set and still has to cause it to be re-rendered.
    """
    record = registry.load(name)
    if record is None or not (record.publication or record.edges):
        return
    firewall.print_diff(firewall.install(config_mod.load()))


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


def _stop(args) -> int:
    """Stop a service's units, and say what it was asked to stop.

    The deploy order stops between the gate and the install (ADR-0011), so this
    is the verb that half of it calls; `service.remove` and the fork reach the
    same function rather than a second stop path.
    """
    config = config_mod.load()
    resolved = names.resolve(args.name, list(config.tracks), allow_default=False)
    service.stop_units(resolved.name, resolved.escaped_ref)
    sys.stdout.write(f"stopped {resolved.name}\n")
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


def _port_open(args) -> int:
    return ports.open_port(args.name, args.public_port)


def _port_close(args) -> int:
    return ports.close_port(args.name, args.public_port)


def _port_list(args) -> int:
    return ports.list_ports(args.json)


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


def _module_list(args) -> int:
    config = config_mod.load()
    listing = modules.listing(config)
    if args.json:
        sys.stdout.write(json.dumps(listing, separators=(",", ":")) + "\n")
        return 0
    sys.stdout.write(f"enabled   {', '.join(listing['enabled']) or 'none'}\n")
    sys.stdout.write(f"available {', '.join(listing['available']) or 'none'}\n")
    return 0


def _module_add(args) -> int:
    config = config_mod.load()
    module = modules.read(args.name)
    _requirements(module, config)
    with conf.lock("modules"):
        merged = list(dict.fromkeys([*config.modules, module.name]))
        if merged != list(config.modules):
            conf.write_file(
                paths.GUARDEN_TOML,
                h.set_string_list(paths.GUARDEN_TOML.read_text(encoding="utf-8"), "modules",
                                  "enabled", merged),
                0o644,
            )
        # Re-read under the lock: `soil install` writes this file too, and a
        # merge from a copy read before the lock was taken would drop whatever
        # it appended in the meantime.
        config = config_mod.load()
        if module.name not in config.modules:
            raise errors.GuardenError(
                f"{paths.GUARDEN_TOML} does not record the module {module.name!r} after the "
                f"write, so the module's services would exist with nothing forwarding them",
                errors.HOST_NOT_AS_ASSUMED,
            )
    return _install_module(module, config)


def _requirements(module: modules.Module, config) -> None:
    missing = [name for name in module.requires if name not in config.modules]
    if missing:
        raise errors.GuardenError(
            f"the module {module.name!r} requires {', '.join(repr(name) for name in missing)}, "
            f"which is not enabled; `weedr module add {' '.join(missing)}` first",
            errors.HOST_NOT_AS_ASSUMED,
        )


def _install_module(module: modules.Module, config) -> int:
    found: dict[str, dict] = {}
    for entry in module.services:
        source = modules.source_of(module.name, entry.name)
        # Only the service that declares ingress has traefik entrypoints to check:
        # a module that ships a service which is not the edge must not have to
        # declare one for `module add` to succeed.
        if entry.ingress:
            found[entry.name] = edgeconf.of_source(source, entry.name)
            modules.check_entrypoints(module, entry.name, found[entry.name])
        resolved = names.resolve(entry.name, list(config.tracks), allow_default=False)
        outcome = service.create(
            resolved,
            service.Source(kind="module", module=module.name, service=entry.name),
            config,
            _now(),
        )
        sys.stdout.write(f"{entry.name} uid {outcome.uid}\n")
        for allowed in units.allow_mounts(source, entry.name):
            sys.stdout.write(f"{entry.name} may bind {allowed}\n")
        units.report(units.install(source, entry.name))
    _edge_group(module)
    firewall.print_diff(firewall.install(config))
    firewall.load_set()
    _edge_directory(module)
    _converge_ingress()
    _sync_routes()
    return 0


def _edge_group(module: modules.Module) -> None:
    """The `edge` group, and the edge's own user in it.

    Created here and not by `soil install`, which creates the `guarden` group
    and no other: a host with no edge module has no `edge` group, because
    nothing on it has anything to read.
    """
    if not tool.check(["getent", "group", EDGE_GROUP]):
        tool.run(["groupadd", "--system", EDGE_GROUP])
        sys.stdout.write(f"created the {EDGE_GROUP} group\n")
    for entry in module.services:
        if registry.load(entry.name) is None:
            continue
        tool.run(["usermod", "--append", "--groups", EDGE_GROUP, entry.name])
        sys.stdout.write(f"added {entry.name} to the {EDGE_GROUP} group\n")


def _edge_directory(module: modules.Module) -> None:
    """`/var/lib/guarden/edge/dynamic`, `guarden:edge 2750`.

    `roots` runs as `guarden` and writes it; the edge's user is in `edge` and
    reads it. Neither can write where the other writes, which is the whole of
    the writer/reader split this directory draws.
    """
    del module
    path = paths.EDGE_DYNAMIC
    path.mkdir(parents=True, exist_ok=True)
    conf.set_owner(
        path,
        (
            users.passwd_entries()[units.GUARDEN_USER][0],
            users.group_id(EDGE_GROUP),
        ),
    )
    os.chmod(path, EDGE_MODE)
    sys.stdout.write(f"{path} is guarden:{EDGE_GROUP} {EDGE_MODE:04o}\n")


def _converge_ingress() -> None:
    """`soil firewall --apply`, because `soil` is the only writer of the nat file.

    The mutator never writes `20-ingress-nat.conf`: the module change is what
    makes the rules stale, and `soil` re-reads `guarden.toml` and the module
    directory itself rather than trusting what this verb saw.
    """
    result = tool.call([str(paths.BIN / "soil"), "firewall", "--apply"])
    if not result.ok:
        detail = errors.oneline(result.stderr.strip() or result.stdout.strip())
        sys.stderr.write(
            errors.warn(
                f"soil firewall --apply exited {result.returncode} and the edge's forwarding "
                f"rules are stale: {detail}"
            ) + "\n"
        )


def _sync_routes() -> None:
    """`roots sync`, as `guarden`: a route change the edge reads without a restart."""
    result = tool.call(["runuser", "-u", units.GUARDEN_USER, "--",
                        str(paths.BIN / "roots"), "sync"])
    if not result.ok:
        detail = errors.oneline(result.stderr.strip() or result.stdout.strip())
        sys.stderr.write(
            errors.warn(f"roots sync exited {result.returncode}: {detail}") + "\n"
        )


def _module_remove(args) -> int:
    return cli.pending("weedr module remove")


def _firewall_open(args) -> int:
    return firewallrules.open_rule(args.name, args.rule)


def _firewall_close(args) -> int:
    return firewallrules.close_rule(args.name, args.rule)


def _firewall_list(args) -> int:
    return firewallrules.list_rules(bool(getattr(args, "json", False)))


HANDLERS = {
    "weedr project list": projects.list_json,
    "weedr project add": projects.do_add,
    "weedr project remove": projects.do_remove,
    "weedr project keys": projects.list_keys,
    "weedr project grant": projects.do_grant,
    "weedr project revoke": projects.do_revoke,
    "weedr service ingest": _ingest,
    "weedr service add": _add,
    "weedr service remove": _remove,
    "weedr service purge": _purge,
    "weedr service gate": _gate,
    "weedr service start": _start,
    "weedr service stop": _stop,
    "weedr service list": _list,
    "weedr service snapshot": _snapshot,
    "weedr service fork": _fork,
    "weedr service rollback": _rollback,
    "weedr service immutable": _immutable,
    "weedr service mutable": _mutable,
    "weedr secret set": _secret_set,
    "weedr secret list": _secret_list,
    "weedr secret materialise": _secret_materialise,
    "weedr firewall open": _firewall_open,
    "weedr firewall close": _firewall_close,
    "weedr firewall list": _firewall_list,
    "weedr port list": _port_list,
    "weedr port open": _port_open,
    "weedr port close": _port_close,
    "weedr module list": _module_list,
    "weedr module add": _module_add,
    "weedr module remove": _module_remove,
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
