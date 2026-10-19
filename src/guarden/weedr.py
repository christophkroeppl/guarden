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
import shutil
import sys
import time

from guarden import (
    basicauth,
    cli,
    conf,
    credentials,
    edgeconf,
    errors,
    exposure,
    firewall,
    firewallrules,
    gate,
    lineage,
    modules,
    names,
    overrides,
    paths,
    ports,
    projects,
    reconcile,
    registry,
    render,
    report,
    service,
    snapper,
    snapshotid,
    tool,
    units,
    users,
    volumes,
)
from guarden import config as config_mod
from guarden import hosttool as h
from guarden import images as images_mod
from guarden import (
    manifest as manifest_mod,
)
from guarden import (
    share as share_mod,
)

EDGE_GROUP = "edge"
EDGE_MODE = 0o2750
# The module whose installation generates the basic-auth policy marker (ticket
# 292). Named here beside the other module-name constants rather than inline in
# two functions that must agree about which module it is.
GATE_MODULE = "gate-traefik"

DASHBOARD_MODE = 0o755
DASHBOARD_MODULE = "homepage"

# The reference prefix a built image is tagged with, and the name it is tagged
# after (spec 6.6 step 2, spec 6.2). `localhost/` says the image is local and
# needs no registry, which is the one thing a rootless `podman build` in a
# service's own store guarantees; the tag is the service, so two services' images
# cannot collide and a redeploy overwrites the one it is replacing. Both halves
# are pinned here because the mutator's build and the renderer's `Image=` have to
# name the same image, and two literals would be the copy that drifts.
LOCAL_REFERENCE = "localhost"
BUILD_TAG = "latest"

SERVICE = (
    ("ingest", "create or reconcile a service from a poke's staged tree"),
    ("add", "create or reconcile a service from another service's tree"),
    ("create", "manually create a new service from a template"),
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

PROGRAM_GROUP = "guarden"

SECRET = (
    ("set", "plant a value, encrypted, with the terminal's echo off"),
    ("list", "the key names and whether each is set; never a value"),
    ("materialise", "decrypt the blobs into a service's podman store"),
)

EXPOSE = (
    ("set", "record a service's exposure for its environment: loopback, tunnel or public"),
    ("unset", "return a service to its default exposure"),
    ("list", "every service's recorded exposure and what it resolves to"),
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

SHARE = (
    ("issue", "record a time-bounded grant to reach a tunnel route"),
    ("revoke", "end one issuance immediately"),
    ("list", "every issuance, live, expired and revoked, with its deadline"),
    ("reconcile", "recompute the vendor's Access policies from the record"),
)

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
    ("share", "the time-bounded grants that reach a tunnel route", SHARE),
    ("module", "the shipped bundles of services and shared programs", MODULE),
    ("firewall", "the firewall rules a service asks for", FIREWALL),
    ("expose", "the per-service exposure record: loopback, tunnel or public", EXPOSE),
    ("project", "repositories, their refs and their poke keys", PROJECT),
)

EPILOG = """\
`remove` is the only verb with an alias, and it is `rm`: weedr service rm,
weedr project rm. Nothing else in guarden has one, and nothing else will.

Not on the guarden sudoers rule, and not reachable from a deploy:
`weedr port open`, `weedr port close`, `weedr firewall open`,
`weedr firewall close`, `weedr service purge`,
`weedr service rollback`, `weedr service add`, `weedr service create`,
`weedr module add`, `weedr expose set`, `weedr expose unset`,
`weedr project add`,
`weedr project grant`, `weedr project revoke`, and every `weedr share`
verb. A customer-facing grant is safe to have precisely because a poke
can deploy to a preview and cannot mint, extend or revoke access to one.
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
        from_help = (
            "`poke <project>@<sha>`"
            if verb == "ingest"
            else "the service to copy from"
        )
        creator.add_argument(
            "--from",
            dest="source",
            metavar="SOURCE",
            nargs="+",
            required=True,
            help=from_help,
        )

    create = top["service"]["verbs"]["create"]
    cli.add_name(create, "the service to create; a name with no environment resolves a default")
    create.add_argument(
        "--env",
        dest="environments",
        metavar="ENVIRONMENTS",
        default="production",
        help="comma-separated environments to create the service in (default: production)",
    )
    create.add_argument(
        "--template",
        dest="template",
        metavar="TEMPLATE",
        default=None,
        help="the template to create from; asked for at a terminal when omitted",
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

    expose_set = top["expose"]["verbs"]["set"]
    _add_service_name(expose_set, "the service whose exposure is recorded")
    expose_set.add_argument(
        "value",
        metavar="VALUE",
        help="loopback, tunnel or public; public is refused off a gated track",
    )
    _add_service_name(
        top["expose"]["verbs"]["unset"], "the service returned to its default exposure"
    )
    cli.add_json(top["expose"]["verbs"]["list"])

    cli.add_json(top["module"]["verbs"]["list"])
    for verb in ("add", "remove"):
        top["module"]["verbs"][verb].add_argument("name", metavar="NAME", help="the module")

    share_issue = top["share"]["verbs"]["issue"]
    _add_service_name(share_issue, "the service, or one instance, whose route is shared")
    share_issue.add_argument(
        "email", metavar="EMAIL", help="the address the customer signs in with"
    )
    share_issue.add_argument(
        "--until",
        metavar="DURATION",
        required=True,
        help="how long the grant lasts, as `<number><unit>` (`7d`, `12h30m`); there is no "
        "spelling of \"never\"",
    )
    top["share"]["verbs"]["revoke"].add_argument(
        "id", metavar="ID", help="the issuance to end, as `weedr share list` prints it"
    )
    cli.add_json(top["share"]["verbs"]["list"])

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


def _create(args, allow_default: bool, verb: str) -> int:
    config = config_mod.load()
    source = service.parse_from(args.source, verb)
    resolved = names.resolve(args.name, list(config.tracks), allow_default)
    now = _now()
    outcome = service.create(resolved, source, config, now)
    if outcome.fresh_instance:
        outcome.notes += lineage.seed_instance(resolved, now)
    _filter_set(resolved.name)
    _edge_units(resolved.name)
    _sync_dashboard()
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
        if registry.load(entry.name) is None:
            return
        units.report(units.install(modules.source_of(module, entry.name), entry.name))
        return


def _filter_set(name: str) -> None:
    """Re-render the uid-matched filter set for a service the registry holds.

    The set is not only publications and edges: every registry uid also carries
    the two owner-matched `127.0.0.53:53` accepts for the host's stub resolver,
    above the loopback deny (spec 7.6) — without them that uid's first
    `podman pull` meets the deny and no first deploy of a new workload can
    complete. So a service with neither a publication nor an edge still
    changes the set, and creation has to reach this render: a service created
    from a template asks for nothing at all, and before ticket 296 its uid
    had no accept.

    An edge counts on its own account as well: the publication it dials belongs
    to the provider, but the consumer's **uid** joins that publication's accept
    set, so a consumer with no publication of its own still changes the set.

    A service that brings only its uid renders whenever the host holds a
    rendered set — the firewall installed **or** `50-services.conf` already
    written by another verb — because that is when there is a set to be
    missing from: the deny and every accept are files, and whatever exists is
    what the first `soil firewall --apply` loads, so a uid absent from an
    existing file meets the deny from the moment it does (spec 7.6).
    """
    record = registry.load(name)
    if record is None:
        return
    if (
        not (record.publication or record.edges)
        and not firewall.unit_installed()
        and not firewall.SERVICES_CONF.exists()
    ):
        # Nothing to be missing from: this host holds no rendered set — no
        # file, so no `soil firewall --apply` that could later load one without
        # this uid — and no ruleset loaded, so no deny is refusing this uid's
        # resolver. The FILE counts as much as the unit because other verbs
        # write it unconditionally (`weedr port open`, a granted rule): a set
        # that exists while the unit does not is a set the first apply loads
        # whole, and a uid absent from it meets the deny the moment it does
        # (spec 7.6, review finding 4).
        return
    firewall.print_diff(firewall.install(config_mod.load()))


def _ingest(args) -> int:
    # spec 5.1: the default-environment exception belongs to `add` alone, so a
    # poke can never choose the track its service lands in.
    return _create(args, allow_default=False, verb="ingest")


def _add(args) -> int:
    # `add` is not on the sudoers rule — it needs a real root shell. What is
    # gathered first is the configuration and the entry (spec 5.1): both read
    # and validated while nothing has changed, so the credential is asked for
    # only once the request is known to be well-formed.
    config = config_mod.load()
    service.parse_from(args.source, "add")
    names.resolve(args.name, list(config.tracks), allow_default=True)
    if os.geteuid() != 0:
        _become_root("add", ["service", "add", args.name, "--from", *args.source])
    return _create(args, allow_default=True, verb="add")


def _become_root(verb: str, words: list[str]) -> None:
    """Ask for root here, then re-exec as root to apply what has been gathered.

    Configuration and the operator's own answers come before this is called, so
    what sudo grants is a request already known to be well-formed, and it grants
    it just before the change and nothing before that. `sudo -v` refreshes a
    cached credential or asks for one — at a terminal, and only when stdin is
    one, so nothing ever waits on a pipe that cannot answer; `sudo -n` afterwards
    cannot prompt at all, which is why a non-root caller used to get sudo's own
    words printed over a process guarden no longer controlled. `sudo -n -l` then
    proves that **this** command is one the caller may run: `add` and `create`
    are on no sudoers rule, and without that proof `os.execvp` would replace this
    process and the diagnostic would be sudo's (spec 1.2: one line, prefixed,
    naming what it is about).
    """
    command = [str(paths.BIN / "weedr"), *words]
    refresh = ["sudo", "-v"] if sys.stdin.isatty() else ["sudo", "-n", "-v"]
    for argv in (refresh, ["sudo", "-n", "-l", "--", *command]):
        try:
            result = tool.call(argv)
        except OSError as exc:
            raise errors.GuardenError(
                f"{verb} requires root: {argv[0]} could not be run: {exc.strerror}",
                errors.HOST_NOT_AS_ASSUMED,
            ) from exc
        if not result.ok:
            detail = errors.oneline((result.stderr or result.stdout).strip()) or (
                f"{argv[0]} exited {result.returncode}"
            )
            raise errors.GuardenError(
                f"{verb} requires root: {detail}", errors.HOST_NOT_AS_ASSUMED
            )
    os.execvp("sudo", ["sudo", "-n", "--", *command])


def _create_service(args) -> int:
    """`weedr service create` — manually create a new service from a template.

    Everything is gathered and validated before root is asked for: the
    configuration, the environments, the names they resolve to, and the
    template the operator chooses here. Root is obtained after all of that, so
    sudo grants a request that is already well-formed and the answer given at
    this terminal is the one applied — the chosen template travels with the
    re-exec rather than being asked a second time.

    What it creates is the identity, the service tree, a copy of the template's
    quadlet files and the registry record. It creates **no manifest and no
    volume**: a template ships neither, and the volumes a manifest declares are
    created by `create` when a poke or an `add` brings a manifest in. The
    template itself is installed root-owned in
    `/usr/lib/guarden/templates/services/`.

    It creates a name that does not exist yet, and refuses one that does
    (`service.refuse_existing`, exit 1): `create` is the verb that makes a
    service, never the verb that overwrites one.

    Two refusals of the **input** come first -- before the template is chosen,
    before root is asked for and before anything is written, so each is exit 2
    with one line (spec 1.2) and neither can reach a machine. A name carrying
    a `/<ref>` is one, asked before the configuration is read: spec 5.1 and
    the verb table in 5.3 give the ref to `ingest` and `add`, and
    `create <name>` takes a plain name -- accepting one appended `-ENV` to the
    whole argument, so the suffix landed in the ref, `--env` was ignored for
    the track before the slash, the ref was rewritten and the template's units
    were copied into `home/<ref>/` while the parent's record was saved. An
    `--env` naming one service twice is the other, and it is asked of the
    **resolved** names because that is where the collision lives: two
    different values can resolve to one name -- `svc-foo-staging` ends in both
    `-foo-staging` and `-staging`, so neither value appends a suffix and both
    leave the same name -- and counting the raw strings cannot see that.
    Left uncaught, one name resolved twice passed the whole-list check that
    saw no entry yet: the first create succeeded and printed, and the second
    refused the record it had just written -- a run exiting 1 for work it
    reported as done.
    """
    if "/" in args.name:
        raise errors.GuardenError(
            f"create takes a plain service name, so {args.name!r} takes no /<ref>",
            errors.REJECTED_INPUT,
        )
    envs = [env.strip() for env in args.environments.split(",") if env.strip()] or ["production"]
    config = config_mod.load()
    resolved = [
        names.resolve(
            f"{args.name}-{env}" if not args.name.endswith(f"-{env}") else args.name,
            list(config.tracks),
            allow_default=False,
        )
        for env in envs
    ]
    resolved_names = [entry.name for entry in resolved]
    repeated = sorted({name for name in resolved_names if resolved_names.count(name) > 1})
    if repeated:
        raise errors.GuardenError(
            f"--env names {', '.join(repr(name) for name in repeated)} for more than one "
            "environment; a create request names each environment once",
            errors.REJECTED_INPUT,
        )
    # An absent flag asks the chooser; an empty value is an answer and reaches
    # `require_template` as "no name", where a set to choose from makes naming
    # nothing the input's fault (exit 2, spec 1.2) — `or` swallowed it and
    # handed over the set's only entry.
    template = service.require_template(
        args.template if args.template is not None else _choose_template()
    ).name
    if os.geteuid() != 0:
        _become_root(
            "create",
            ["service", "create", args.name, "--env", args.environments, "--template", template],
        )
    now = _now()
    # Every name at once, and only now that root is held: a `--env` list that
    # names one service the registry already holds refuses **before** any of
    # them is created, rather than creating the rest and stopping halfway. The
    # mutator asks the same question for its own name on the way in, so the
    # refusal cannot be reached by a caller that skips this verb.
    service.refuse_existing([entry.name for entry in resolved])
    for entry in resolved:
        outcome = service.create_service(entry, config, now, template)
        # The same render `_create` reaches after `ingest` and `add`: the new
        # uid's stub-resolver accepts have to be in force before anything of
        # this service is started, and nothing else renders them (ticket 296).
        _filter_set(entry.name)
        sys.stdout.write(f"created {entry.name} uid {outcome.uid} from {template}\n")
    return 0


def _choose_template() -> str | None:
    """The template the operator picks from the installed set; `None` is an empty set.

    `None` rather than a refusal: `service.require_template` is where the
    missing-template line lives, so the verb validating its answer before it
    asks for anything and the mutator about to copy it answer the same question
    with one line and one code.
    """
    templates_dir = paths.TEMPLATES / "services"
    available = (
        sorted(entry.name for entry in templates_dir.iterdir() if entry.is_dir())
        if templates_dir.is_dir()
        else []
    )
    if not available:
        return None
    if len(available) == 1:
        return available[0]
    if not sys.stdin.isatty():
        raise errors.GuardenError(
            "create needs a terminal to answer its prompts; run it interactively",
            errors.HOST_NOT_AS_ASSUMED,
        )
    sys.stdout.write("available templates:\n")
    for i, name in enumerate(available, 1):
        sys.stdout.write(f"  {i}. {name}\n")
    try:
        choice = input("template (name or number): ").strip()
    except EOFError:
        # stdin ended where a terminal was promised: an `input()` that raised
        # here would have left a traceback on stderr instead of the one line
        # the contract promises.
        raise errors.GuardenError(
            "create needs a terminal to answer its prompts; stdin ended before one",
            errors.HOST_NOT_AS_ASSUMED,
        ) from None
    if choice.isdigit() and 1 <= int(choice) <= len(available):
        return available[int(choice) - 1]
    return choice or None


def _remove(args) -> int:
    config = config_mod.load()
    resolved = names.resolve(args.name, list(config.tracks), allow_default=False)
    for line in service.remove(resolved, config, _now()):
        sys.stdout.write(f"{line}\n")
    # Spec 5.3: a removal releases every grant the service held and the
    # firewall is re-rendered (§7.7) — the record is out of the registry by
    # now, so this render drops the removed uid's accepts and any forwarded
    # port (and, for one instance, its released publication's accepts) instead
    # of leaving them for a recycled uid to inherit (review finding 6).
    firewall.print_diff(firewall.install(config))
    _sync_dashboard()
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
        if volume.kind == volumes.SUBVOLUME:
            # The snapper configuration goes first, exactly as instance
            # removal does it (`previews.forget`): `delete-config` removes the
            # configuration and its `.snapshots` subtree, and that subtree can
            # hold read-only snapshot subvolumes a plain `rmtree` cannot touch
            # -- measured 2026-10-12 after the distribution's timeline timer
            # was found writing snapshots guarden never made.
            config = paths.snapper_config(resolved.name, volume.name)
            if snapper.configuration_exists(config):
                tool.run(["snapper", "--config", config, "delete-config"])
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
    _refuse_slot_start(resolved, record)
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
    # ADR-0019: the probe, the record and guarden's own `UserNS=keep-id` line
    # come before the units are handed to systemctl — the line has to be in
    # the file the generator reads, and `start_units` reloads the manager
    # after it is written. The line is a drop-in in the uid-scoped search
    # path, not a line in the base unit.
    service.ensure_owner_line(resolved.name, resolved.escaped_ref)
    service.start_units(resolved.name, resolved.escaped_ref)
    sys.stdout.write(f"started {resolved.name}\n")
    return 0


def _refuse_slot_start(resolved, record) -> None:
    """A bare `<name>` on an instance track names no instance, and is refused.

    An instance track holds one service per workload and one INSTANCE per ref
    (spec 5.2). A name with no `/<ref>` therefore names the SLOT — and the slot
    of an instance track holds no unit of its own: every render on that track
    is an instance's, and the slot's own quadlet directory holds only the
    entries the search path needs (`<unit>-<escaped-ref>`, one per instance).

    So a bare start on such a track had two ways to go wrong, and both were
    live at once (review r2, finding F3):

    - the "has no unit to start" guard read the SLOT's directory, which holds
      those per-instance entries, so it passed and the start went on;
    - `start_units(name, None)` then iterated that same directory and started
      **every instance**, and keep-id's `ensure_owner_line` first re-rendered
      the SLOT — a render that has no business existing on an instance track —
      into it as `web.container`, which the start then started too.

    A fan-out that starts every preview, plus a phantom unit nobody declared,
    is not a start. The refusal names the instances, so the operator is told
    which ones to name — the same shape as the refusal `weedr service remove
    <name>` gives while instances exist (spec 5.3).

    Exit `2`: the argument named something the track does not have, and it is
    rejected input rather than a host that is not in the expected state
    (spec 1.2).
    """
    if resolved.ref or resolved.track.kind != "instance":
        return
    live = ", ".join(
        instance.ref for _, instance in sorted(record.instances.items())
    )
    raise errors.GuardenError(
        f"the track {resolved.track.name!r} is kind = \"instance\", so every start names "
        f"one instance: {resolved.name}/<ref>"
        + (f" (the instances are: {live})" if live else ""),
        errors.REJECTED_INPUT,
    )


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


def _build(args) -> int:
    """`podman build` as the service user, from the service's own tree.

    The image is tagged with the reference the unit source declares for each
    container (spec 6.6 step 2). The build context is the service's home, which
    holds the unit source tree — exactly the tree the renderer reads.
    `runuser -u <service>` runs podman with the service's uid and subuid range,
    so the container can map root. A failure exits `1` and names the verb; a
    success prints the image reference(s) built.
    """
    config = config_mod.load()
    resolved = names.resolve(args.name, list(config.tracks), allow_default=False)
    record = registry.load(resolved.name)
    if record is None:
        raise errors.GuardenError(
            f"{resolved.name} has no registry entry, so there is nothing to build",
            errors.HOST_NOT_AS_ASSUMED,
        )

    # The service's home is the build context: it holds the unit source tree.
    home = paths.service_home(resolved.name)
    if not home.is_dir():
        raise errors.GuardenError(
            f"{resolved.name} has no home at {home}, so there is no tree to build",
            errors.HOST_NOT_AS_ASSUMED,
        )

    # Read the manifest to find the unit source and the containers it declares.
    manifest = manifest_mod.read(home / manifest_mod.MANIFEST_REL)
    source = render.resolve_unit_source(home, manifest)

    built: list[str] = []
    for container in source.containers():
        # A container builds when its own tree carries a Containerfile. The
        # reference it is tagged with is the one the unit source declares (spec
        # 6.6 step 2), so a declared `Image=` is the TAG and not a claim that
        # this is a pull: the renderer writes the same value into `Image=`, and
        # the two halves agree because both read it from the source.
        #
        # A tree with no Containerfile is a pull whatever the unit declares,
        # and skipping it is right — but skipping a tree that HAS one because
        # its unit also declares an image would make the whole verb useless for
        # the one shape guarden allows: a unit that declares Image= AND carries
        # a Containerfile.
        context_file = next(
            (home / name for name in ("Containerfile", "Dockerfile") if (home / name).is_file()),
            None,
        )
        if context_file is None:
            continue

        # Get the reference the build should tag — the one the unit source
        # declares, or the local one for a pure build with no image:.
        image_ref = images_mod.declared_or_built(home, resolved.name, container)

        podman = [
            "runuser",
            "-u",
            resolved.name,
            "--",
            "podman",
            "build",
            "--tag",
            image_ref,
            "-f",
            str(context_file),
            ".",
        ]
        result = tool.call(podman, cwd=home)
        if not result.ok:
            detail = errors.oneline(result.stderr.strip() or result.stdout.strip())
            raise errors.GuardenError(
                f"build {resolved.name}: podman build exited {result.returncode}: {detail}",
                errors.HOST_NOT_AS_ASSUMED,
            )
        built.append(image_ref)

    if not built:
        raise errors.GuardenError(
            f"{resolved.name} has no unit source with a build instruction, "
            "so there is nothing to build",
            errors.HOST_NOT_AS_ASSUMED,
        )

    # A rebuilt reference is a different image under the same tag, and the
    # pair the record holds is only true of the image it was read from: left
    # answered, the next render writes the OLD user's pair into a unit whose
    # container now runs the NEW user, and that uid's writes land in the
    # service's subuid band (ticket 277) while the record and ADR-0019's
    # "an image that changed is the probe's condition again" both claim the
    # opposite. The image changes here, so the answer goes here.
    _invalidate_owner(resolved.name, built)

    for ref in built:
        sys.stdout.write(f"{ref}\n")
    return 0


def _invalidate_owner(name: str, references: list[str]) -> None:
    """Take the probe's answer away from a rebuilt image, so the next start is
    the probe's condition again for the units that name it.

    `owner_image` records the REFERENCE and the build re-tags it, which is
    why the reference is not an anchor: whatever the record holds for one of
    `references` was read from the image that tag used to point at. Under the
    registry lock and re-read inside it, the way every other registry writer
    does it (spec 3.5) — a start probing this record must not have its answer
    overwritten by a copy read before the build finished.

    Two shapes, matching what the record holds. The scalar anchor goes whole:
    `owner_uid`, `owner_gid` and `owner_image` are ONE answer, and a record
    missing the uid is the probe's condition for every image. A per-unit entry
    goes only for the image it names, so a service whose other unit names an
    untouched image keeps that pair — and the probe's plan then asks for the
    rebuilt one alone.
    """
    with conf.lock("registry"):
        record = registry.load(name)
        if record is None:
            return
        stale = set(references)
        touched = False
        if record.owner_image in stale:
            record.owner_uid = None
            record.owner_gid = None
            record.owner_image = None
            touched = True
        for stem, entry in list(record.owner_units.items()):
            if entry.image in stale:
                del record.owner_units[stem]
                touched = True
        if touched:
            registry.save(record, (0, users.group_id(service.GUARDEN_GROUP)))


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
    _sync_dashboard()
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
    _sync_dashboard()
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


def _share_issue(args) -> int:
    """Record one issuance. Every refusal happens before anything is written."""
    config = config_mod.load()
    now = int(time.time())
    issuance = share_mod.issue(args.name, args.email, args.until, config, now)
    sys.stdout.write(
        f"issued {issuance.id} for {issuance.email} until "
        f"{share_mod.rfc3339(issuance.deadline)}\n"
    )
    for host in issuance.hosts:
        sys.stdout.write(f"  {host}\n")
    sys.stdout.write(
        "the vendor's policy is a projection of this record; `weedr share reconcile` puts it "
        "in force\n"
    )
    return 0


def _share_revoke(args) -> int:
    issuance, changed = share_mod.revoke(args.id, int(time.time()))
    if issuance is None:
        raise errors.GuardenError(
            f"there is no issuance {args.id!r}; `weedr share list` names the ones this host holds",
            errors.HOST_NOT_AS_ASSUMED,
        )
    if not changed:
        sys.stdout.write(f"{issuance.id} was already revoked\n")
        return 0
    sys.stdout.write(f"revoked {issuance.id} for {issuance.email}\n")
    sys.stdout.write("`weedr share reconcile` removes the address from the vendor's policy\n")
    return 0


def _share_list(args) -> int:
    now = int(time.time())
    entries = share_mod.listing(share_mod.load_all(), now)
    if args.json:
        sys.stdout.write(json.dumps({"issuances": entries}, separators=(",", ":")) + "\n")
        return 0
    if not entries:
        sys.stdout.write("no issuances; nothing has been granted access to a tunnel route\n")
        return 0
    for entry in entries:
        hosts = ", ".join(entry["hosts"])
        sys.stdout.write(
            f"{entry['id']}  {entry['state']}  {entry['email']}  {hosts}  "
            f"until {entry['deadline']}\n"
        )
    return 0


def _share_reconcile(args) -> int:
    del args
    config = config_mod.load()
    code, out, warnings = share_mod.reconcile(config, int(time.time()))
    for line in out:
        sys.stdout.write(f"{line}\n")
    for line in warnings:
        sys.stderr.write(f"{line}\n")
    return code


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
    if module.name == "cloudflared" and not config.tunnel_domain:
        raise errors.GuardenError(
            "tunnel_domain is empty in [ingress], so the tunnel is not configured; "
            "set it to the zone delegated to the tunnel's provider before adding "
            "the cloudflared module",
            errors.REJECTED_INPUT,
        )
    with conf.lock("modules"):
        merged = list(dict.fromkeys([*config.modules, module.name]))
        if merged != list(config.modules):
            gid = users.group_id(PROGRAM_GROUP)
            conf.write_file(
                paths.GUARDEN_TOML,
                h.set_string_list(paths.GUARDEN_TOML.read_text(encoding="utf-8"), "modules",
                                  "enabled", merged),
                0o640,
                (0, gid),
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
    # Ticket 292: installing the gate generates the basic-auth policy, before
    # any of the module's services is created — the marker is the reason a
    # service created afterwards carries the credential, so it must exist first.
    # The edge's own service declares no `routes:`, so this act mints nothing
    # for it; the directory the edge unit mounts is created here as well, for
    # the host whose `soil install` predates the unit that mounts it.
    if module.name == GATE_MODULE:
        basicauth.ensure_directory()
        if not basicauth.in_force():
            sys.stdout.write(f"basic auth policy in {basicauth.POLICY}\n")
            basicauth.write_policy()
        # Re-adding the module dropped every entry with the policy while the
        # registries kept their flags (ticket 292), so each flagged service's
        # entry is put back from its own minted blob before any unit reads it:
        # a flagged service whose htpasswd is missing is a login nobody can
        # use and nothing else in guarden reports it.
        for name in registry.names():
            record = registry.load(name)
            if record is not None and basicauth.restore(record):
                sys.stdout.write(f"restored the basic-auth login for {record.service}\n")
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
    provider = modules.write_auth_provider(module)
    if provider:
        sys.stdout.write(f"auth provider {provider} in {edgeconf.MARKER}\n")
    firewall.print_diff(firewall.install(config))
    firewall.load_set()
    _edge_directory(module)
    _dashboard_directory(module)
    _tunnel_directory(module)
    _converge_ingress()
    _sync_routes()
    _sync_dashboard()
    return 0


def _dashboard_directory(module: modules.Module) -> None:
    """`/var/lib/guarden/shared/dashboard`, `guarden:guarden 0755`.

    The one directory `twig` may write, and this verb is what creates it: the
    shared directory is root-owned and read-only to `guarden`, so before this
    existed `twig sync` could not run at all. Only the `homepage` module's add
    creates it, and only that module's remove takes it away, so a host with no
    dashboard module has no dashboard directory either.
    """
    if module.name != DASHBOARD_MODULE:
        return
    path = paths.DASHBOARD
    path.mkdir(parents=True, exist_ok=True)
    gid = users.group_id(units.GUARDEN_GROUP)
    conf.set_owner(path, (users.passwd_entries()[units.GUARDEN_USER][0], gid))
    os.chmod(path, DASHBOARD_MODE)
    sys.stdout.write(f"{path} is guarden:guarden {DASHBOARD_MODE:04o}\n")


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
        # Only the service that declares ingress is the edge. A module may ship
        # services that are ordinary services — `homepage` is — and adding those
        # to `edge` would hand them a read on /var/lib/guarden/edge/dynamic.
        if not entry.ingress:
            continue
        if registry.load(entry.name) is None:
            continue
        tool.run(["usermod", "--append", "--groups", EDGE_GROUP, entry.name])
        sys.stdout.write(f"added {entry.name} to the {EDGE_GROUP} group\n")
        # A systemd user manager's supplementary groups are fixed at its
        # creation time. If the manager was started before the user was added
        # to `edge` (e.g. by `loginctl enable-linger` during `service.create`),
        # it never picks up the group, and a container launched with
        # `--group-add keep-groups` inherits no `edge` — so it is denied a read
        # on /var/lib/guarden/edge/dynamic and the file provider never loads.
        # The restart is skipped when the manager already carries the group, so
        # a converged host is not disturbed.
        _restart_user_manager(entry.name)


def _restart_user_manager(name: str) -> None:
    """Restart the user manager when it is missing a group its user now holds.

    A systemd user manager inherits its supplementary groups from the session
    that started it and never updates them. After `usermod --append --groups
    edge <user>`, the manager still has its old set, so a container launched
    with `--group-add keep-groups` inherits no `edge` and is denied a read on
    `/var/lib/guarden/edge/dynamic`.

    Restarting `user@<uid>.service` makes the manager re-read `/etc/group`.
    The restart is skipped when the manager already carries the group, so a
    converged host is not disturbed.

    **When no manager is running this STARTS one**, and that is deliberate
    rather than incidental: `systemctl restart` starts a unit that is not
    running. Starting it with the current group set is what the service needs
    anyway — a manager that does not exist cannot carry `edge` either — so the
    two cases want the same action and no branch is needed. An earlier version
    of this docstring claimed the opposite ("a no-op when no manager is
    running"), which is false of `systemctl restart` and would have misled
    anyone who relied on it.
    """
    uid = users.passwd_entries()[name][0]
    wanted = users.group_id(EDGE_GROUP)
    if _manager_has_group(uid, wanted):
        return
    tool.run(["systemctl", "restart", f"user@{uid}.service"])
    sys.stdout.write(f"restarted user@{uid}.service to pick up the {EDGE_GROUP} group\n")


def _manager_has_group(uid: int, gid: int) -> bool:
    """Whether the running user manager for `uid` carries `gid`.

    The manager's PID comes from systemd itself, and its groups come from
    `/proc/<pid>/status`, which is the process's own word for them. `id -nG
    <user>` asks the user database and cannot answer this: the user is in the
    group there while the manager is not.

    A manager that is not running has no groups to carry, so the answer is
    `False` and the caller restarts — which starts it with the current group
    set, which is what the service needs anyway.
    """
    result = tool.call(
        ["systemctl", "show", f"user@{uid}.service", "--property=MainPID", "--value"]
    )
    if not result.ok or not result.stdout.strip().isdigit():
        return False
    pid = result.stdout.strip()
    if pid == "0":
        return False
    try:
        with open(f"/proc/{pid}/status", encoding="utf-8") as handle:
            status = handle.read()
    except OSError:
        return False
    for line in status.splitlines():
        if line.startswith("Groups:"):
            return str(gid) in line.split()[1:]
    return False


def _edge_directory(module: modules.Module) -> None:
    """`/var/lib/guarden/edge/dynamic`, `guarden:edge 2750`.

    `roots` runs as `guarden` and writes it; the edge's user is in `edge` and
    reads it. Neither can write where the other writes, which is the whole of
    the writer/reader split this directory draws.

    The owner is the `guarden` **user**, so the owner bits carry the write:
    `roots` writes through §3.5's protocol, which makes its temporary file in
    this directory, and a setgid directory the owner cannot write is one whose
    temp file cannot be created.
    """
    del module
    path = paths.EDGE_DYNAMIC
    path.mkdir(parents=True, exist_ok=True)
    uid = users.passwd_entries()[units.GUARDEN_USER][0]
    conf.set_owner(path, (uid, users.group_id(EDGE_GROUP)))
    os.chmod(path, EDGE_MODE)
    sys.stdout.write(f"{path} is guarden:{EDGE_GROUP} {EDGE_MODE:04o}\n")


def _tunnel_directory(module: modules.Module) -> None:
    """`/var/lib/guarden/tunnel`, `guarden:guarden 0755`.

    `roots` runs as `guarden` and writes the tunnel's config into it; the tunnel
    service's own unit mounts it read-only. It is not the edge's directory and
    does not share its group: the reader here is a container mount, not a service
    user that needs the write bit's neighbour.
    """
    del module
    path = paths.TUNNEL
    path.mkdir(parents=True, exist_ok=True)
    uid = users.passwd_entries()[units.GUARDEN_USER][0]
    conf.set_owner(path, (uid, users.group_id(units.GUARDEN_USER)))
    os.chmod(path, DASHBOARD_MODE)
    sys.stdout.write(f"{path} is {units.GUARDEN_USER}:{units.GUARDEN_USER} {DASHBOARD_MODE:04o}\n")


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
                        str(paths.BIN / "roots"), "sync"], cwd="/tmp")
    if not result.ok:
        detail = errors.oneline(result.stderr.strip() or result.stdout.strip())
        sys.stderr.write(
            errors.warn(f"roots sync exited {result.returncode}: {detail}") + "\n"
        )


def _sync_dashboard() -> None:
    """`twig sync`, as `guarden`, and only when the dashboard module is on.

    A card appears and disappears with its service with no manual step and no
    restart of the dashboard (spec 6.9), so this runs at the end of every verb
    that changes which services exist. On a host with no dashboard module there
    is no directory to write and nothing to warn about.
    """
    config = config_mod.load()
    if DASHBOARD_MODULE not in config.modules or not paths.DASHBOARD.is_dir():
        return
    result = tool.call(["runuser", "-u", units.GUARDEN_USER, "--",
                        str(paths.BIN / "twig"), "sync"], cwd="/tmp")
    if not result.ok:
        detail = errors.oneline(result.stderr.strip() or result.stdout.strip())
        sys.stderr.write(
            errors.warn(f"twig sync exited {result.returncode}: {detail}") + "\n"
        )


def _remove_module(config, module: modules.Module) -> None:
    """Take the module out of `[modules] enabled`, through the protocol.

    The `modules` lock is released before `soil firewall --apply` takes the
    `firewall` lock: two locks in sequence and never nested (spec 6.2).
    """
    remaining = [name for name in config.modules if name != module.name]
    with conf.lock("modules"):
        gid = users.group_id(PROGRAM_GROUP)
        conf.write_file(
            paths.GUARDEN_TOML,
            h.set_string_list(paths.GUARDEN_TOML.read_text(encoding="utf-8"), "modules",
                              "enabled", remaining),
            0o640,
            (0, gid),
        )
    if module.name in config_mod.load().modules:
        raise errors.GuardenError(
            f"{paths.GUARDEN_TOML} still records the module {module.name!r} after the write, so "
            f"the module would be removed with its ingress and its switches still on",
            errors.HOST_NOT_AS_ASSUMED,
        )


def _owned_by(module: modules.Module) -> list[modules.Service]:
    """The module's services, and a refusal naming one that is not its own.

    spec 6.2 step 1: a module never removes a service it did not create, and
    `installed_by` is the record of what did.
    """
    out: list[modules.Service] = []
    for entry in module.services:
        record = registry.load(entry.name)
        if record is None:
            continue
        if record.installed_by != module.name:
            raise errors.GuardenError(
                f"the module {module.name!r} declares the service {entry.name!r}, and its "
                f"registry says installed_by = {record.installed_by!r}; a module removes "
                f"exactly the services it installed",
                errors.HOST_NOT_AS_ASSUMED,
            )
        out.append(entry)
    return out


def _module_remove(args) -> int:
    config = config_mod.load()
    module = modules.read(args.name)
    if module.name not in config.modules:
        sys.stdout.write(f"{module.name} is not enabled; nothing to remove\n")
        return 0
    removed = _owned_by(module)
    now = _now()
    for entry in removed:
        resolved = names.resolve(entry.name, list(config.tracks), allow_default=False)
        try:
            for line in service.remove(resolved, config, now):
                sys.stdout.write(f"{line}\n")
            if resolved.track.gated:
                sys.stdout.write(
                    f"{entry.name} was on the gated track {resolved.track.name!r} and was "
                    f"removed because the module that installed it is being removed\n"
                )
        except errors.GuardenError as failure:
            sys.stderr.write(failure.report("weedr") + "\n")
            return failure.code

    # If removing the cloudflared module, delete the Access application
    if module.name == "cloudflared":
        from guarden import vendor as vendor_mod
        status, lines = vendor_mod.delete_application(config)
        for line in lines:
            if status == vendor_mod.FAILED:
                sys.stderr.write(line + "\n")
                return errors.HOST_NOT_AS_ASSUMED
            else:
                sys.stdout.write(line + "\n")

    _remove_module(config, module)
    if module.name == GATE_MODULE:
        # Ticket 292: the policy goes with the module that generated it, and
        # the entries with it — a host with no edge has no login in front of
        # nothing. The records keep their flags; re-adding the module restores
        # each flagged service's entry from its own minted blob
        # (`basicauth.restore`), and a service that no longer exists has no
        # record, so nothing is restored for it.
        basicauth.drop_policy()
        sys.stdout.write(f"removed the basic auth policy from {basicauth.POLICY}\n")
    remaining = config_mod.load()
    firewall.print_diff(firewall.install(remaining))
    firewall.load_set()
    _converge_ingress()
    _sync_routes()
    if module.name == DASHBOARD_MODULE:
        _drop_dashboard()
    _sync_dashboard()
    _switches(module, remaining)
    sys.stdout.write(f"removed the module {module.name}\n")
    return 0


def _drop_dashboard() -> None:
    """The dashboard's configuration directory, and nothing outside it.

    It is guarden's own and `twig` regenerates every byte of it from the
    installed tree, so removing it removes no card that a later `twig sync`
    would not write again.
    """
    if paths.DASHBOARD.is_dir():
        shutil.rmtree(paths.DASHBOARD)
        sys.stdout.write(f"removed {paths.DASHBOARD}\n")


def _switches(module: modules.Module, config) -> None:
    """Reference-count `[[switches]]` by module name (spec 6.2 step 7).

    Two modules may switch the same program on — `gate-traefik` and `auth-authelia` both switch
    on `roots` — so removing one must not switch it off under the other. A
    program another enabled module still names stays, with a `warning:` naming
    the module that still wants it.
    """
    if not module.switches:
        return
    wanted: dict[str, list[str]] = {}
    for name in config.modules:
        if name == module.name:
            continue
        try:
            other = modules.read(name)
        except errors.GuardenError:
            continue
        for program in other.switches:
            wanted.setdefault(program, []).append(name)
    for program in module.switches:
        holders = wanted.get(program, [])
        if holders:
            sys.stderr.write(
                errors.warn(
                    f"the program {program} stays switched on: "
                    f"{', '.join(repr(name) for name in holders)} still names it"
                ) + "\n"
            )


def _firewall_open(args) -> int:
    return firewallrules.open_rule(args.name, args.rule)


def _firewall_close(args) -> int:
    return firewallrules.close_rule(args.name, args.rule)


def _firewall_list(args) -> int:
    return firewallrules.list_rules(args.json)


def _exposure_record(config, name: str):
    """The service's record and its track, or the refusal that names one."""
    record = registry.load(name)
    if record is None:
        raise errors.GuardenError(
            f"{name} has no registry entry, so it has no environment to record an "
            f"exposure against; `weedr service list` reports the services that exist",
            errors.HOST_NOT_AS_ASSUMED,
        )
    track = config.track(record.environment)
    if track is None:
        raise errors.GuardenError(
            f"{record.service} is in the environment {record.environment!r}, which names "
            f"no track in {paths.GUARDEN_TOML}; the tracks are what the "
            f"[[environments]] table holds",
            errors.HOST_NOT_AS_ASSUMED,
        )
    return record, track


def _write_exposure(config, record, track, value: str | None) -> None:
    """One record written, and every decision it makes re-resolved with it.

    The destinations are rewritten in the same act as the record so the
    registry never carries a record and a stale answer beside it; the firewall
    re-renders for the same reason `weedr port open` re-renders — the accept
    set is a consequence of the record, and a consequence that lags is drift
    the check would then report. The rendered slice is the *next render*'s
    (ticket 294): this verb changes one record and nothing a repository owns.
    """
    record.exposure = value
    granted = overrides.load(record.service)
    record.route_destinations = exposure.destinations(
        record,
        track,
        config.modules,
        set(granted.expose_tunnel) if granted else set(),
        list(record.route_hosts),
    )
    with conf.lock("registry"):
        registry.save(record, (0, users.group_id(PROGRAM_GROUP)))
    firewall.print_diff(firewall.install(config))
    firewall.load_set()


def _expose_set(args) -> int:
    config = config_mod.load()
    record, track = _exposure_record(config, args.name)
    if args.value not in exposure.RECORD_VALUES:
        raise errors.GuardenError(
            f"{args.value!r} is not an exposure; the values are "
            f"{', '.join(exposure.RECORD_VALUES)}",
            errors.REJECTED_INPUT,
        )
    if args.value == "public" and not track.gated:
        raise errors.GuardenError(
            f"{record.service} is on the track {track.name!r}, and public exposure is "
            f"selectable only on a gated track; {track.name} stays loopback or tunnel",
            errors.REJECTED_INPUT,
        )
    if args.value == "tunnel" and not exposure.tunnel_enabled(config.modules):
        raise errors.GuardenError(
            f"the {exposure.CF_MODULE} module is not enabled, so a tunnel route would "
            f"have nothing to carry it; `weedr module add {exposure.CF_MODULE}` first",
            errors.REJECTED_INPUT,
        )
    _write_exposure(config, record, track, args.value)
    sys.stdout.write(f"{record.service} exposure {args.value}\n")
    return 0


def _expose_unset(args) -> int:
    config = config_mod.load()
    record, track = _exposure_record(config, args.name)
    if record.exposure is None:
        sys.stdout.write(f"{record.service} is already at its default exposure\n")
        return 0
    _write_exposure(config, record, track, None)
    sys.stdout.write(f"{record.service} exposure default\n")
    return 0


def _expose_list(args) -> int:
    config = config_mod.load()
    services = []
    for name in registry.names():
        record = registry.load(name)
        if record is None:
            continue
        track = config.track(record.environment)
        services.append(
            {
                "service": record.service,
                "exposure": record.exposure or "default",
                "destination": exposure.resolve(record, track, config.modules),
            }
        )
    if args.json:
        sys.stdout.write(json.dumps({"services": services}) + "\n")
        return 0
    for row in services:
        sys.stdout.write(f"{row['service']} {row['exposure']} {row['destination']}\n")
    return 0


HANDLERS = {
    "weedr project list": projects.list_json,
    "weedr project add": projects.do_add,
    "weedr project remove": projects.do_remove,
    "weedr project keys": projects.list_keys,
    "weedr project grant": projects.do_grant,
    "weedr project revoke": projects.do_revoke,
    "weedr firewall open": _firewall_open,
    "weedr firewall close": _firewall_close,
    "weedr firewall list": _firewall_list,
    "weedr expose set": _expose_set,
    "weedr expose unset": _expose_unset,
    "weedr expose list": _expose_list,
    "weedr service ingest": _ingest,
    "weedr service add": _add,
    "weedr service create": _create_service,
    "weedr service remove": _remove,
    "weedr service purge": _purge,
    "weedr service gate": _gate,
    "weedr service start": _start,
    "weedr service stop": _stop,
    "weedr service build": _build,
    "weedr service list": _list,
    "weedr service snapshot": _snapshot,
    "weedr service fork": _fork,
    "weedr service rollback": _rollback,
    "weedr service immutable": _immutable,
    "weedr service mutable": _mutable,
    "weedr secret set": _secret_set,
    "weedr secret list": _secret_list,
    "weedr secret materialise": _secret_materialise,
    "weedr port list": _port_list,
    "weedr port open": _port_open,
    "weedr port close": _port_close,
    "weedr module list": _module_list,
    "weedr module add": _module_add,
    "weedr module remove": _module_remove,
    "weedr pin sync": _pin_sync,
    "weedr share issue": _share_issue,
    "weedr share revoke": _share_revoke,
    "weedr share list": _share_list,
    "weedr share reconcile": _share_reconcile,
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
