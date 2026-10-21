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
from pathlib import Path

from guarden import (
    basicauth,
    cli,
    conf,
    creator,
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
    sudoers,
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

BASICAUTH = (
    ("off", "turn the default basic-auth middleware off for one service"),
    ("on", "put the middleware back; the same login is re-attached"),
    ("list", "every service's basic-auth posture: the mint and the operator's setting"),
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
    ("basicauth", "the per-service opt-out from the default basic-auth middleware",
     BASICAUTH),
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
`weedr basicauth off`, `weedr basicauth on`,
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
    create.add_argument(
        "--guided",
        dest="guided",
        action="store_true",
        help="ask the operator the questions and build the tree (ticket 328)",
    )
    create.add_argument(
        "--tree",
        dest="tree",
        metavar="TREE",
        default=None,
        help="the tree the guided mode writes; a directory of the operator's own",
    )
    create.add_argument(
        "--plant",
        dest="plant",
        metavar="KEY",
        nargs="*",
        default=None,
        help="the credential keys to plant; the values are read at the terminal",
    )
    create.add_argument(
        "--start",
        dest="start",
        action="store_true",
        help="start the service after it is created, and verify it",
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

    for verb, help_text in (
        ("off", "the service whose edge routers lose the middleware"),
        ("on", "the service whose middleware comes back"),
    ):
        _add_service_name(top["basicauth"]["verbs"][verb], help_text)
    cli.add_json(top["basicauth"]["verbs"]["list"])

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

    **The notes are printed BEFORE the `converged` line, and not after it.**
    A converged create can still REPAIR the tree (ticket 334), and a repair
    that is not said is a repair the operator cannot see — so the lines that
    report it have to be on stdout even when the verb's answer is `converged`.
    The order is the notes first and the verdict last, because the verdict is
    the verb's answer and a caller reads the last line as the answer.
    """
    for note in outcome.notes:
        sys.stdout.write(f"{note}\n")
    for message in outcome.warnings:
        sys.stderr.write(f"{errors.warn(message)}\n")
    if outcome.converged:
        sys.stdout.write("converged\n")
        return 0
    if outcome.resolved.defaulted:
        sys.stdout.write(f"{outcome.resolved.name}\n")
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

    **The guided mode is a mode of this verb, and it is the same shape.**
    `--guided` asks the operator the questions HERE — at this terminal, by this
    unprivileged process — and the answers travel with the re-exec as
    arguments, so the root half receives a request that is already
    well-formed. `create` is root-only and off the sudoers rule, so a mode of
    it is too, and the platform's doctrine — "a flag on a granted verb would
    grant the capability with it" — does not apply: it is not a granted verb.

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
    if getattr(args, "guided", False):
        # The guided mode has two halves, and the split is by ROLE and not by
        # privilege: this half asks the questions and writes the tree, the root
        # half creates the service from it.
        #
        # **The questions are asked BEFORE root is asked for**, which is the
        # whole of the security argument — and it holds whether the operator
        # was already root or not. `create` is root-only and off the sudoers
        # rule, so a mode of it is too, and the platform's doctrine ("a flag on
        # a granted verb would grant the capability with it") does not apply
        # to it because it is not a granted verb.
        #
        # **The root half is recognised by `--plant` or `--start`, and not by
        # the tree's existing.** A tree directory that exists says nothing
        # about whether the questions were asked — the creator makes the
        # directory itself — so keying the dispatch on it would skip the
        # questions entirely and read an empty tree. The two flags are the
        # root half's own: they carry the answers that the re-exec brought.
        if os.geteuid() == 0 and (
            getattr(args, "plant", None) is not None or getattr(args, "start", False)
        ):
            return _create_guided_root(args)
        return _create_guided(args)
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


def _create_guided(args) -> int:
    """`weedr service create --guided`: ask the operator, then build the tree.

    **The questions are asked by the UNPRIVILEGED process, before root is
    asked for.** That is the whole of the security argument: the answers are
    gathered and validated here, at the operator's terminal, and the root half
    receives an already-well-formed request. The flow is the same one
    `create` already keeps — gather, then `_become_root`, then apply — and the
    design's earlier draft inverted it, so the order here is deliberate.

    **What the creator RECORDS is what the service ASKS for.** A manifest asks
    for a public port and for a firewall rule; it does not grant either. The
    creator prints the commands the operator has to run and never runs them:
    `weedr port open` and `weedr firewall open` are root and on no sudoers
    rule, so nothing that answers a push can reach them, and a creator that
    granted in the same breath would collapse the request/grant split.

    **A secret is read at a terminal, with the echo off, through the existing
    `credentials.prompt()`** — never from a command line, a flag or a file, and
    never written into the tree. The value is planted with the existing
    `credentials.plant()` into the root-owned blob, and the tree carries the
    credential's NAME and nothing else.

    **The network is not asked.** The renderer owns `Network=` and refuses
    anything that is not `pasta:`, so there is exactly one legal answer and a
    question would offer a choice that does not exist. The creator states it.

    The tree the creator writes is a tree like any other: `.guarden/service.yml`
    and `.guarden/quadlet/*.container`, which is what `weedr service add
    --from <tree>` consumes. The quadlet is a STARTING POINT — the renderer
    owns `PublishPort=`, `Network=` and `Volume=` and overwrites them.
    """
    if "/" in args.name:
        raise errors.GuardenError(
            f"create takes a plain service name, so {args.name!r} takes no /<ref>",
            errors.REJECTED_INPUT,
        )
    creator.require_terminal("the guided creator")
    tree = Path(args.tree).expanduser() if args.tree else Path.cwd() / args.name
    if tree.exists() and any(tree.iterdir()):
        raise errors.GuardenError(
            f"the tree {tree} is not empty, and the creator writes into it; a tree that holds "
            "something already is not a tree the creator may take over",
            errors.REJECTED_INPUT,
        )

    # The name first: it is the value every other answer is filed under, and a
    # name that does not fit is refused before anything is asked after it. The
    # environment is the verb's own `--env` flag rather than a second question
    # about the same thing.
    name = creator.validate_name(args.name)
    environment = args.environments.split(",")[0].strip() or "production"
    creator.validate_name(environment, "environment")

    # The image and the tag, and then the pull starts — as soon as those two
    # are known, not at the end, so the image is downloading while the operator
    # answers the rest.
    image = creator.ask_validated("image", creator.validate_image, "", "the image")
    tag = creator.ask_validated("tag", creator.validate_tag, "latest", "the tag")
    pull = creator.pull_background(f"{image}:{tag}")
    sys.stdout.write(f"pulling {image}:{tag} in the background\n")
    try:
        answers = creator.Answers(
            name=name,
            environment=environment,
            image=image,
            tag=tag,
        )
        answers.provides = creator.ask_provides()
        answers.ports = creator.ask_ports()
        answers.volumes = creator.ask_volumes()
        answers.firewall = creator.ask_firewall()
        answers.secrets = creator.ask_secrets()
        answers.start = creator.ask_start()
        creator.write_tree(tree, answers)
    except BaseException:
        # The pull is aborted on the way out, whatever ended the run: an
        # exception, a refusal, or a Ctrl-C. The abort cannot be guaranteed
        # against a SIGKILL, and the cost of an uncleaned pull is DISK.
        creator.abort_pull(pull)
        raise
    creator.abort_pull(pull)

    # The requests the service ASKS for, and the commands the operator runs to
    # grant them. Printed, never run.
    creator.report_grants(name, answers)

    # The re-exec. The answers travel as arguments, so the root half receives
    # a request that is already well-formed — this is the same shape every
    # other verb keeps, and the flow the design's earlier draft had inverted.
    words = [
        "service",
        "create",
        args.name,
        "--env",
        args.environments,
        "--guided",
        "--tree",
        str(tree),
    ]
    if answers.start:
        words.append("--start")
    # `--plant` is carried even when there is no key to plant, because it is
    # what tells the root half that the questions have ALREADY been asked. A
    # re-exec without it would ask them again — and the second round would
    # happen after the re-exec, at a terminal that may not be one.
    words.append("--plant")
    words.extend(secret.key for secret in answers.secrets)
    if os.geteuid() == 0:
        # Already root: there is no re-exec to do and no second round of
        # questions to ask. The tree is written, so the root half runs here —
        # and it is recognised by the same flags the re-exec would have
        # carried, so the two paths are the same code.
        args.tree = str(tree)
        args.start = answers.start
        args.plant = [secret.key for secret in answers.secrets]
        return _create_guided_root(args)
    _become_root("create", words)
    return 0


def _create_guided_root(args) -> int:
    """The ROOT half of the guided mode: the tree is built, the service is made.

    **This half receives an already-validated request.** The questions were
    asked by the unprivileged process before `_become_root` was called, and the
    answers travel with the re-exec. Nothing is asked here except the SECRET
    VALUES, which are read at this terminal with the echo off, through the
    existing `credentials.prompt()` — never from an argument, a flag or a
    file.

    **The creator does not grant a port and does not grant a firewall rule.**
    The manifest RECORDS the request; the operator's `weedr port open` and
    `weedr firewall open` are the grant, and they are a separate act that this
    verb does not perform.
    """
    tree = Path(args.tree)
    if not tree.is_dir():
        raise errors.GuardenError(
            f"the tree {tree} does not exist, so there is nothing to create the service from",
            errors.HOST_NOT_AS_ASSUMED,
        )
    manifest_path = tree / manifest_mod.MANIFEST_REL
    if not manifest_path.is_file():
        raise errors.GuardenError(
            f"the tree {tree} carries no {manifest_mod.MANIFEST_REL}, so there is nothing to "
            "create the service from",
            errors.HOST_NOT_AS_ASSUMED,
        )
    # The manifest is READ, and the read is the validation: a manifest that does
    # not parse, names a volume that is not a name, or carries a `provides:`
    # that is not a kind is refused here, before the service exists.
    manifest_mod.read(manifest_path)

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
    service.refuse_existing([entry.name for entry in resolved])
    now = _now()
    # The tree is the operator's own, and the RENDERER runs as `guarden` — so
    # the tree is staged where the renderer can read it, and the staged copy
    # is this invocation's own and goes away with it.
    stage = creator.stage_tree(tree)
    try:
        source = service.Source(kind="tree", tree=stage)
        for entry in resolved:
            outcome = service.create(entry, source, config, now)
            sys.stdout.write(f"created {entry.name} uid {outcome.uid} from {tree}\n")
            _filter_set(entry.name)

            # The secrets are planted HERE, at this terminal, with the echo
            # off, through the existing `credentials.prompt()` and the existing
            # `credentials.plant()`. The value never reaches the tree, an
            # argument or a file: it goes straight into the root-owned
            # encrypted blob.
            for key in args.plant or []:
                creator.plant_secret(entry.name, key)

            if not args.start:
                continue
            # The start, and then the verification: EXACTLY three checks — the
            # unit is active, the container is running, and the publication is
            # listening. There is no fourth check: "the service answers" is not
            # implementable for an arbitrary image without a per-service probe,
            # and a false positive there is the exact failure the verification
            # exists to catch.
            _start_guided(entry.name)
    finally:
        creator.drop_tree(stage)
    return 0


def _start_guided(name: str) -> None:
    """Start the service and run the three checks, and report them."""
    record = registry.load(name)
    if record is None:
        raise errors.GuardenError(
            f"there is no registry entry for {name}, so there is nothing to start",
            errors.HOST_NOT_AS_ASSUMED,
        )
    units_of = service.units_of(name)
    if not units_of:
        raise errors.GuardenError(
            f"{name} has no unit to start: its quadlet directory declares no container",
            errors.HOST_NOT_AS_ASSUMED,
        )
    service.ensure_owner_line(name)
    service.start_units(name)
    sys.stdout.write(f"started {name}\n")
    unit = units_of[0]
    container = f"{name}-{units_of[0]}"
    port = sorted(record.publication.values())
    checks = creator.verify(
        name, unit, container, port[0] if port else None, record
    )
    creator.report_checks(checks)


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
    # The SLOT first: a name that names no instance on an instance track has
    # no unit to start at all, and a unit that does not exist cannot ask for a
    # credential either. (review r2, finding F3)
    _refuse_slot_start(resolved, record)

    # **A credential the units ask for and nothing planted stops the start on
    # an ungated track too.** The gate's state on that track is `not-required`
    # and the gate's own phase does not block — but the START refuses, because
    # a container whose unit carries `Secret=<KEY>` and whose store has no
    # `<KEY>` is refused by podman with a raw `125 no such secret`: a runtime
    # error, naming a podman message, where the operator needs the key (tickets
    # 305 and 313). The difference between the tracks is what the *deploy* does
    # with the gate's state (spec 6.6 step 3), and it is not what changes here.
    #
    # **The refusal is one line and it names the keys**, so the operator knows
    # what to plant. It is the host not being in the state the request assumed
    # — the podman secret does not exist — so it is exit `1` and not `2` (spec
    # 1.2), the same code a blocked gate's start answers with.
    if verdict.unsatisfied:
        keys = ", ".join(verdict.unsatisfied)
        # One command per key, because `weedr secret set` takes ONE key and a
        # comma-joined list would be a command that does not parse.
        plants = " then ".join(
            f"`weedr secret set {resolved.name} {key}`" for key in verdict.unsatisfied
        )
        raise errors.GuardenError(
            f"{resolved.name} cannot start: the unit asks for {keys} and no value is "
            f"planted for it; {plants} plants it, and the start re-checks",
            errors.HOST_NOT_AS_ASSUMED,
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
    # ADR-0019: the probe, the record and guarden's own `UserNS=keep-id` line
    # come before the units are handed to systemctl — the line has to be in
    # the file the generator reads, and `start_units` reloads the manager
    # after it is written. The line is a drop-in in the uid-scoped search
    # path, not a line in the base unit.
    service.ensure_owner_line(resolved.name, resolved.escaped_ref)
    service.start_units(resolved.name, resolved.escaped_ref)
    sys.stdout.write(f"started {resolved.name}\n")
    return 0


def _refuse_slot_start(resolved, record, verb: str = "start") -> None:
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
        f"the track {resolved.track.name!r} is kind = \"instance\", so every {verb} names "
        f"one instance: {resolved.name}/<ref>"
        + (f" (the instances are: {live})" if live else ""),
        errors.REJECTED_INPUT,
    )


def _restart(args) -> int:
    """Stop a service's units and start them again.

    **A restart is a stop and a start, and it is BOTH of them.** The two
    refusals the halves make are the restart's refusals: a bare `<name>` on an
    instance track names the SLOT, and the slot holds no unit of its own — so
    the refusal that stops the start from fanning out to every instance also
    stops the restart from stopping every instance, and the stop half runs
    first so a restart never leaves a service down when it was refused.

    The gate is re-evaluated on the way in, exactly as `start` does, because a
    restart after planting a credential is the operator's way of saying "now it
    can start" — and a restart that re-evaluated nothing would refuse a
    service whose credential has since been planted.

    The verb was advertised in the table, in `--help` and in the spec, and had
    no handler at all: every invocation fell to `cli.pending` and answered
    "not implemented". An advertised verb that does not exist is worse than an
    absent one, because the operator is told it exists.
    """
    config = config_mod.load()
    resolved = names.resolve(args.name, list(config.tracks), allow_default=False)
    record = _record_for(resolved.name)
    # The SLOT first, and before the stop: a refusal that arrives after the
    # units are down leaves a service stopped when the operator asked for a
    # restart and got a refusal.
    _refuse_slot_start(resolved, record, "restart")
    service.stop_units(resolved.name, resolved.escaped_ref)
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
    service.ensure_owner_line(resolved.name, resolved.escaped_ref)
    service.start_units(resolved.name, resolved.escaped_ref)
    sys.stdout.write(f"restarted {resolved.name}\n")
    return 0


def _stop(args) -> int:
    """Stop a service's units, and say what it was asked to stop.

    The deploy order stops between the gate and the install (ADR-0011), so this
    is the verb that half of it calls; `service.remove` and the fork reach the
    same function rather than a second stop path.

    A bare `<name>` on an instance track names the SLOT, and the slot holds no
    unit of its own — so a stop that went on would iterate the slot's quadlet
    directory and stop EVERY instance, which is a fan-out, not a stop. The
    same refusal the start gives (spec 5.2) applies here.
    """
    config = config_mod.load()
    resolved = names.resolve(args.name, list(config.tracks), allow_default=False)
    record = registry.load(resolved.name)
    if record is not None:
        _refuse_slot_start(resolved, record, "stop")
    service.stop_units(resolved.name, resolved.escaped_ref)
    sys.stdout.write(f"stopped {resolved.name}\n")
    return 0


def _build(args) -> int:
    """`podman build` as the service user, from the service's own tree.

    The image is tagged with the reference the unit source declares for each
    container (spec 6.6 step 2). The build context is the service's home, which
    holds the staged source tree — the unit source, the compose file, the
    Containerfile and the application's own files. A `COPY` resolves against
    the context directory, so a Containerfile that says
    `COPY Cargo.toml Cargo.lock ./` needs those files IN the home: the home
    holds the whole staged tree, and the tree's own ignore file decides what
    the build does not see (spec 6.6) — with guarden's own exclusion written
    into that file below, because the repository's may be absent.
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

    # The service's home is the build context: it holds the staged source tree.
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

        # **Guarden's exclusion goes into the context's own ignore file before
        # the build reads it.** The podman store — which holds the per-user
        # secret database in cleartext — is in the home by now, and a context
        # carrying it leaks the credential material into an image layer. The
        # source's own patterns are kept and guarden's come after them, so the
        # source still owns what the build does not see (spec 6.6).
        service.write_build_exclusions(home, (record.uid, record.uid))

        podman = tool.runuser_as(
            resolved.name,
            "podman",
            "build",
            "--tag",
            image_ref,
            "-f",
            str(context_file),
            ".",
        )
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
    result = tool.call(tool.runuser_as(units.GUARDEN_USER, str(paths.BIN / "roots"), "sync"),
                       cwd="/tmp")
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
    result = tool.call(tool.runuser_as(units.GUARDEN_USER, str(paths.BIN / "twig"), "sync"),
                       cwd="/tmp")
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
    if args.value == exposure.TUNNEL and record.basicauth:
        sys.stdout.write(exposure.tunnel_credential_note(record.service) + "\n")
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


def _basicauth_record(name: str):
    """The service's registry record, or the refusal naming what is missing.

    A name with no record has no posture to report and no middleware to turn
    off: the record IS the mint (spec 3.4), so an absent one is the host not
    being in the state the verb assumed rather than a service awaiting a
    setting.
    """
    record = registry.load(name)
    if record is None:
        raise errors.GuardenError(
            f"{name} has no registry entry, so it has no basic-auth posture to report; "
            f"`weedr service list` reports the services that exist",
            errors.HOST_NOT_AS_ASSUMED,
        )
    return record


def _basicauth_set(args, required: bool) -> int:
    """`weedr basicauth off|on`: one setting, into the root-owned file.

    **The setting goes into `overrides.toml` and nothing else is written.** The
    credential is not un-minted and no htpasswd entry is touched: the mint is a
    fact about the past (spec 3.4) and the opt-out is a decision about the
    present (ADR-0024), so turning the middleware off leaves the operator's
    login where it is and turning it back on re-attaches the same one.

    **A service that was never minted one is already in the requested state.**
    It was created before the policy was in force, or it declares no routes, so
    there is no middleware to switch — exit `0`, and nothing is written. A file
    that gained a setting would be a file claiming a posture the service never
    had.

    **The edge is synced in the same act**, because the setting is read where
    the edge's own file is written (`roots`, spec 6.4): a verb that wrote the
    file and left the edge serving the old one would report a change it had not
    made yet.
    """
    record = _basicauth_record(args.name)
    posture = "on" if required else "off"
    if not record.basicauth:
        sys.stdout.write(
            f"{record.service} has no basic-auth login: it was created before the policy was "
            f"in force, or it declares no routes, so there is no middleware to turn "
            f"{posture}; the state is already the requested one\n"
        )
        return 0

    path = paths.overrides(record.service)
    with conf.lock("overrides"):
        granted = overrides.load(record.service)
        opted_out = granted.basicauth_required is False
        already = opted_out if not required else not opted_out
        if not already:
            granted.basicauth_required = required
            overrides.save(record.service, granted, (0, users.group_id(PROGRAM_GROUP)))

    if already:
        sys.stdout.write(f"{record.service} basic-auth middleware is already {posture}\n")
        return 0
    _sync_routes()
    sys.stdout.write(
        f"{record.service} basic-auth middleware {posture}; the setting is in {path}, and the "
        f"edge has been asked to re-sync\n"
    )
    return 0


def _basicauth_off(args) -> int:
    return _basicauth_set(args, False)


def _basicauth_on(args) -> int:
    return _basicauth_set(args, True)


def _basicauth_list(args) -> int:
    """The two facts, reported separately because they are separate.

    `minted` is the record's (was a login ever minted here) and `opt_out` is the
    operator's setting. A service that was never minted one has no middleware
    and no opt-out, and a service whose middleware is off by the setting still
    holds its login — so `middleware` is derived from both, and neither fact is
    folded into the other.
    """
    rows = []
    for name in registry.names():
        record = registry.load(name)
        if record is None:
            continue
        minted = bool(record.basicauth)
        opted_out = minted and basicauth.opted_out(record.service)
        rows.append(
            {
                "service": record.service,
                "middleware": "off" if not minted or opted_out else "on",
                "minted": minted,
                "opt_out": opted_out,
            }
        )
    if args.json:
        sys.stdout.write(json.dumps({"services": rows}) + "\n")
        return 0
    for row in rows:
        note = ""
        if not row["minted"]:
            note = " (no login minted)"
        elif row["opt_out"]:
            note = " (opted out; the login is still there)"
        sys.stdout.write(f"{row['service']} {row['middleware']}{note}\n")
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
    "weedr basicauth off": _basicauth_off,
    "weedr basicauth on": _basicauth_on,
    "weedr basicauth list": _basicauth_list,
    "weedr service ingest": _ingest,
    "weedr service add": _add,
    "weedr service create": _create_service,
    "weedr service remove": _remove,
    "weedr service purge": _purge,
    "weedr service gate": _gate,
    "weedr service start": _start,
    "weedr service stop": _stop,
    "weedr service restart": _restart,
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


def _guarden_may(call: str) -> None:
    """Whether the `guarden` account may run this verb, when it is the caller.

    **The second sudoers rule grants the mutator WHOLE, and the mutator
    decides.** The rule has to be one line — `guarden ALL=(root) NOPASSWD:
    /usr/lib/guarden/bin/weedr` — because sudoers matches a command's ARGUMENTS
    as written, and the real invocation carries a service name and a sha:

        $ sudo -n -u guarden sudo -n -l …/weedr service ingest
        …/weedr service ingest                              <- the rule matches
        $ sudo -n -u guarden sudo -n …/weedr service ingest someapp --from poke p@s
        sudo: I'm sorry guarden. I'm afraid I can't do that  <- THE REAL CALL

    So the rule cannot name the verbs, and the verbs have to be named HERE —
    in the one program that knows what a verb means. `purge` destroys data and
    `port open` publishes a port; a list of program names cannot say that, and a
    program can.

    **The caller is read from `SUDO_USER` AND from the real uid**, and the
    check is INVERTED: a call is unrestricted when it is ROOT'S OWN, and
    narrowed when it is anything else.

    The earlier shape asked "is the caller `guarden`?" and returned
    unrestricted when the answer was no. **That is fail-open**, and a review
    named it: `weedr` is `0755 root:root`, so ANY account can run a verb with
    `SUDO_USER` unset — the environment carries no proof of who called, and a
    program that runs as root because its CALLER had root is not the same as a
    program whose caller is root.

    So the narrowness is decided by the two facts that cannot be forged by
    the caller: **the real uid the process runs as**, and **the uid sudo
    says ran it** (`SUDO_UID`). A call is root's own when the real uid is 0
    AND sudo did not name another user; anything else is a narrowed caller
    and is held to the list.

    What that changes: `sudo -u guarden weedr …` (the mutator's own rule) is
    narrowed, and `sudo weedr …` by the operator is root's own and is
    unrestricted. And a service user running `weedr` directly — which is
    already refused by the filesystem's modes — is narrowed rather than
    waved through.
    """
    real_uid = os.geteuid()
    sudo_uid = os.environ.get("SUDO_UID")
    # Root's own call: the process IS root and sudo did not name another
    # user. `SUDO_UID` absent means sudo was not in the picture.
    if real_uid == 0 and (sudo_uid is None or sudo_uid == "0"):
        return
    # A narrowed caller: it runs as somebody, and somebody is not root.
    if call in sudoers.GUARDEN_MAY:
        return
    raise errors.GuardenError(
        f"the {sudoers.GUARDEN_USER} account may not run {call}; the verbs it may run are "
        + ", ".join(sorted(sudoers.GUARDEN_MAY)),
        errors.REJECTED_INPUT,
    )


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    call = " ".join(part for part in ("weedr", args.group, args.verb) if part)
    handler = HANDLERS.get(call)
    if handler is None:
        return cli.pending(call)
    try:
        _guarden_may(call)
        return handler(args)
    except errors.GuardenError as exc:
        sys.stderr.write(f"{exc.report(call)}\n")
        return exc.code


if __name__ == "__main__":
    raise SystemExit(main())
