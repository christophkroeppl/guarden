"""A service's lifecycle: create it, and take it away again.

A service's tree comes from exactly one of three places (spec 5.3). `ingest`
takes `poke <project>@<sha>` and the system resolves that pair to
`/var/lib/guarden/staging/<project>/<sha>` itself; `add` takes a service name
and copies that service's own manifest and unit source out of its home; and
`create` takes a name and a template and no `--from` at all. None of the three
takes a location: a service name is `^[a-z0-9][a-z0-9._-]*$`, a poke carries a
`<project>@<sha>` pair, and the system resolves both to directories it already
owns — so nothing here distinguishes a path from a name, because no caller can
name a path.

The rest is identity and roots — the registry record, the system user, the home,
the quadlet directory, and the subvolumes and snapper configurations for the
declared volumes. Everything downstream (the firewall, the credentials, the
rendered units, the fork) is a later ticket. Every step here is idempotent, so a
second `ingest` or `add` of a converged service exits `0`, says it converged, and
makes no call at all.

The ordering is deliberate in one place: the units are stopped **before** the
volumes move, because a running container writing into a subvolume that is being
renamed is a data problem and not a cosmetic one.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import tempfile
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass, field
from pathlib import Path

from guarden import basicauth as basicauth_mod
from guarden import (
    conf,
    edges,
    errors,
    exposure,
    gate,
    images,
    names,
    paths,
    previews,
    projects,
    publications,
    registry,
    render,
    tool,
    units,
    unitsource,
    users,
    volumes,
)
from guarden import config as config_mod
from guarden import manifest as manifest_mod
from guarden import modules as modules_mod
from guarden import overrides as overrides_mod

TREE_MODE = paths.TREE_MODE


def _in_podman_store(path: Path, root: Path) -> bool:
    """Whether `path` sits under podman's own store inside a service tree.

    The store is not guarden's to mode or to own: its overlay carries the
    image's own permissions, and a walk that imposed the tree's `0700` on it
    left the container unable to read its own entrypoint, because a container's
    root is subuid-mapped and not the service uid (measured 2026-10-18,
    `postgres:17-alpine` on app-vm, dying on
    `/usr/local/bin/docker-entrypoint.sh`). The store is podman's; the tree
    around it is guarden's.
    """
    store = root / paths.PODMAN_STORE
    return path == store or store in path.parents
ADMIN_UNITS_MODE = 0o755
GUARDEN_GROUP = "guarden"

# The files a RENDER reads besides the unit source.
#
# `_render_source` stages a tree the renderer (`loom`, running as `guarden`)
# can read, and it stages only what the renderer reads: the unit source, the
# compose file, and the two files a build needs. The Containerfile is the
# thing `weedr service build` exists to read and it is not the unit source,
# so a staged tree without it has no build context at all — `podman build .`
# in it answers `125` (no such file or directory) on every run. The file's own
# name is the one podman resolves when no `-f` is given, so it is the entry in
# this list. A `.dockerignore` is listed too, because a build that copies the
# whole home needs it to leave the rootless image store and the secret
# database out of the context — those are the two things in the home that are
# large and not the build's.
#
# **This is the RENDER's list and not the COPY's.** The build's context is the
# whole staged tree (spec 6.6), and the copy carries all of it — see
# `_copy_tree`. The two are different questions: the renderer reads a named
# few, and the build reads everything.
BUILD_INPUTS = (Path("Containerfile"), Path(".dockerignore"))

# **The two names podman reads a context's ignore rules from, and the
# exclusion guarden writes into them.**
#
# Measured on podman 5.7.0 (2026-10-20, `probe-t317`): buildah reads
# `.containerignore` **in preference to** `.dockerignore` — a context holding
# both is filtered by the `.containerignore` alone and the `.dockerignore` is
# never consulted. So an exclusion written to only one of the two names is
# read only when the repository shipped the other, and a repository that
# ships `.containerignore` would put the podman store into the context. Both
# names therefore carry guarden's exclusion, and the list is in the order
# podman reads them.
#
# The patterns are the ones that name the store, and the store holds the
# per-user secret database in cleartext
# (`<home>/.local/share/containers/storage/secrets/secrets.json`, measured),
# so one exclusion covers both of the things spec 6.6 names as never in the
# context. The rendered units are named too: they are the service's own
# declarations, not the build's, and `COPY .` would otherwise carry them into
# the image.
#
# **The patterns are appended LAST, and the last matching pattern wins**
# (measured: `*.txt` then `!plain.txt` re-includes the file; `!plain.txt` then
# `*.txt` excludes it). Guarden's lines are therefore last, so a source-side
# `!` negation cannot re-include the store — and because podman reads the
# context's own file rather than one named by `--ignorefile`, the source's
# own narrowing is honoured in the same file.
BUILD_EXCLUSIONS = (
    ".local/share/containers",
    ".config/containers",
)
# The names the exclusion is written under. Both, because podman reads the
# first that is present, and the order is podman's own preference.
BUILD_IGNORE_NAMES = (".containerignore", ".dockerignore")
# The line that separates the source's own patterns from guarden's, so a
# merge is idempotent and the source's part is recognisable as the source's.
BUILD_MARKER = "# guarden: the podman store and the rendered units are never in the build context"
# The mode the context's ignore file carries: the build runs as the service
# user, so it has to read it.
IGNORE_MODE = 0o644


@dataclass(frozen=True)
class Source:
    """`--from`, resolved to something guarden owns rather than to a location."""

    kind: str
    project: str | None = None
    sha: str | None = None
    service: str | None = None
    module: str | None = None
    # A tree the operator built by hand, or with the guided creator: an
    # absolute path to a directory that holds `.guarden/service.yml` and
    # `.guarden/quadlet/`. It is the third shape of `--from` and it is the one
    # `weedr service add --from <tree>` has always taken by path — the
    # difference is that the guided creator WRITES the tree and then hands it
    # over, so the mutator still reads it from a path it was given rather than
    # from a location the caller can influence.
    tree: Path | None = None

    def directory(self) -> Path:
        if self.kind == "poke":
            path = paths.STAGING / str(self.project) / str(self.sha)
            # **The path is contained, and the containment is asserted here.**
            # The project and the sha are both validated as NAMES by the
            # callers, so this cannot be reached with a path today — and the
            # point of the belt is that the next caller need not know that.
            # The staging area is the system's own directory, and a source
            # that points outside it is not a poke.
            root = paths.STAGING.resolve()
            try:
                resolved = path.resolve()
            except OSError:  # pragma: no cover - a resolve that cannot answer
                raise errors.GuardenError(
                    f"the poke's staging path {path} could not be read",
                    errors.HOST_NOT_AS_ASSUMED,
                ) from None
            if root not in resolved.parents and resolved != root:
                raise errors.GuardenError(
                    f"the poke's staging path {path} is outside the staging area "
                    f"{root}; a poke names a project and a commit and not a place",
                    errors.REJECTED_INPUT,
                )
            return path
        if self.kind == "module":
            return modules_mod.source_of(str(self.module), str(self.service))
        if self.kind == "tree":
            return Path(str(self.tree))
        return paths.service_home(str(self.service))


@dataclass
class Outcome:
    resolved: names.Resolved
    converged: bool = False
    uid: int = 0
    fresh_instance: bool = False
    warnings: list[str] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)


def parse_from(values: list[str], verb: str) -> Source:
    """`--from` for a specific verb, with verb-specific validation.

    `ingest` accepts only `poke <project>@<sha>` — a poke carries its own tree,
    and a poke that could promote another service's tree would be a poke
    choosing a track (spec 5.3).

    `add` accepts only `<service>` — a service name, not a path and not a poke.
    A path is the one argument in this interface that can mean something other
    than what it says, and the whole security argument is that no caller can
    name a location (spec 5.3).

    `create` takes no `--from` at all; it builds a service from a template.
    """
    if verb == "ingest":
        if len(values) == 2 and values[0] == "poke":
            project, at, sha = values[1].partition("@")
            if not project or not at or not sha or "/" in sha or ".." in sha:
                raise errors.GuardenError(
                    f"--from poke takes <project>@<sha>, and {values[1]!r} is not that"
                )
            # **The project is a NAME and not a path, and it is checked as one.**
            # The sha is refused a `/` and a `..`; the project was not, and the
            # project is the half that becomes a directory:
            #
            #     paths.STAGING / project / sha
            #
            # so `--from poke ../../tmp/evil@9f2c1ab` resolved to a tree
            # OUTSIDE the staging area, and root — reached through the mutator
            # rule — then read and rendered from a tree the caller chose. The
            # module's own docstring claims "nothing here distinguishes a path
            # from a name, because no caller can name a path", and a caller
            # could.
            #
            # The rule is the one a service name gets (`names.NAME_RE`), which
            # is closed and takes no `/` and no `..`.
            if not names.NAME_RE.match(project):
                raise errors.GuardenError(
                    f"--from poke takes <project>@<sha>, and the project {project!r} "
                    f"is not a name; a project is a name and not a path"
                )
            return Source(kind="poke", project=project, sha=sha)
        if len(values) == 1 and names.NAME_RE.match(values[0]):
            raise errors.GuardenError(
                "ingest takes a poke; to create a service from another service, "
                "use weedr service add (root)"
            )
        raise errors.GuardenError(
            "ingest takes a poke; to create a service from a directory, "
            "use weedr service create (root)"
        )
    if verb == "add":
        if len(values) == 2 and values[0] == "poke":
            raise errors.GuardenError(
                "add takes a service; to deploy from a poke, use weedr service ingest"
            )
        if len(values) == 1 and values[0] == "poke":
            raise errors.GuardenError(
                "add takes a service; to deploy from a poke, use weedr service ingest"
            )
        if len(values) == 1 and names.NAME_RE.match(values[0]):
            return Source(kind="service", service=names.validate(values[0], "--from service"))
        if len(values) == 1:
            raise errors.GuardenError(
                "add takes a service; to create a service from a directory, "
                "use weedr service create (root)"
            )
        raise errors.GuardenError(
            "add takes a service name, and "
            + (" ".join(repr(value) for value in values) or "nothing")
            + " is not one"
        )
    raise errors.GuardenError(f"unknown verb {verb!r}")


def _manifest_in(directory: Path) -> Path:
    return directory / manifest_mod.MANIFEST_REL


def _manifest_directory(source: Source, name: str) -> Path:
    """A fresh tree when there is one, and the service's own home otherwise.

    The home is where a service's manifest lives (spec 6.6), and a poke's staging
    tree is removed once the deploy returns — so a second `ingest` of a converged
    service has to be able to read its manifest with the staging directory gone.
    """
    if _manifest_in(source.directory()).is_file():
        return source.directory()
    return paths.service_home(name)


def _source_label(source: Source) -> tuple[str, list[str]]:
    """What the registry may claim about where this tree came from.

    spec 3.4 records `source` as `manual` or `gitops` and says it changes
    nothing, so the field's whole job is to be true — and `gitops` names one
    path: the receiver (spec 6.7), which refuses a project this host has never
    registered (`hose` -> `projects.get`) and can only stage into a directory
    `weedr project grant` created for a registered project. A poke naming no
    registered project cannot have come through it, so it records `manual`:
    seven records on one box claimed a gitops deploy that never ran because the
    label came from the `--from` shape alone (ticket 291).

    The alternative — refusing the poke — would give the label a force the
    spec denies it and add a precondition spec 5.3's step list does not carry;
    the registration check belongs to `hose` and to `furrow` (spec 6.6), and
    what the mutator owes here is an honest record.

    **The read is TOTAL, and that is what keeps the field a record.** A
    malformed `projects.toml` or a malformed file under `projects.d/` raises out
    of `projects.load()`, and the raise happened AFTER the system user, the
    home and the copied tree existed — so a broken root-owned configuration
    failed the ingest and left a service on the box that no registry entry
    named. That gave the label a veto it must not have (spec 3.4: "recorded,
    and it changes nothing"), and it made a provenance field decide whether a
    deploy succeeds.

    So the failure is absorbed here: the label falls back to `manual` — the
    direction that never claims a receiver path that may not have run — and
    the fault is REPORTED as a warning naming the file. The warning is not
    swallowed: a broken projects configuration is a host fact an operator has
    to fix, and `hose` (spec 6.7) and `weedr project list` refuse on it in
    their own right.

    The answer is a pair because the two halves travel apart: the label is
    written into the record, and the warning is written to stderr by the verb.
    """
    if source.kind != "poke":
        return (registry.SOURCE_MANUAL, [])
    try:
        registered = projects.load()
    except errors.GuardenError as exc:
        return (
            registry.SOURCE_MANUAL,
            [
                f"the projects configuration could not be read, so the source of this "
                f"service is recorded as {registry.SOURCE_MANUAL} rather than "
                f"{registry.SOURCE_GITOPS}: {exc.message}"
            ],
        )
    if str(source.project) in registered:
        return (registry.SOURCE_GITOPS, [])
    return (registry.SOURCE_MANUAL, [])


def create(resolved: names.Resolved, source: Source, config, now: str) -> Outcome:
    directory = _manifest_directory(source, resolved.name)
    # **The ACCEPTANCE, and it is `accept()` and not `read()`.** This is where
    # guarden takes a manifest as the shape of a service, and the `db`-provider
    # rule is about the declaration rather than about the document (spec 4):
    # a `db` provider declares a volume or it is refused. `read()` alone would
    # skip the rule here, because the directory is the source's home when the
    # source is another service (`weedr service add --from <service>`) or when
    # the poke's staging tree is gone — and both are acceptances, not
    # read-backs of a document guarden holds.
    #
    # **`held` is that case exactly**: the document is a held one, and it is
    # being taken as the declaration of a new service. A poke's staging tree
    # and a tree an operator wrote are declarations by where they live, and
    # the path says so.
    held = source.kind == "service"
    manifest = manifest_mod.accept(_manifest_in(directory), held=held)
    project = manifest.project or _project_from(source)
    outcome = Outcome(resolved=resolved)

    # Before identity, before the volumes, before the home: an edge the provider
    # does not offer, a route host another service already holds, and a tunnel
    # route with no zone to name it in, are the things in this ordering that
    # would otherwise leave a system user and a subvolume behind on the way out.
    # The hosts come back from the check because they are what the record has to
    # carry: a name an older guarden allocated without the tunnel's zone makes a
    # re-ingest deploy rather than converge, which is the only way such a record
    # is ever repaired.
    existing = registry.load(resolved.name)
    edges.check(resolved.name, manifest, resolved.track.name, config)
    destinations = _destinations(existing, resolved.track, manifest, config, resolved.name)
    hosts = check_hosts(resolved.name, manifest, resolved.track, config, destinations)
    # spec 5.3: "`add` requires `--from`, and is also the reconcile command: run
    # either again to apply an edited manifest", so the hash that makes an edit
    # visible to the convergence check is computed for `add` as well as for a
    # poke (ticket 297): without it an edited source still answered `converged`
    # and installed nothing. A module's source is guarden's own shipped tree and
    # no caller edits it, so it stays unhashed. Where the hash is RECORDED is
    # the deploy's own: the service's at the top of the record, an instance's
    # under its ref — the registry is one file per service, and one shared
    # field was a value an instance's ingest wrote over the service's own
    # (review finding 1).
    source_hash = _source_hash(directory) if source.kind in ("poke", "service", "tree") else ""
    if existing is not None and _converged(
        existing, resolved, manifest, project, source_hash, hosts
    ):
        outcome.converged = True
        outcome.uid = existing.uid
        # **A converged create still REPAIRS the tree (ticket 334).** The
        # convergence check answers "the deploy is what the record says it is",
        # and it says nothing about the host's modes: a host that ran an older
        # guarden carries unit directories that are root-owned with the
        # mutator's umask, and the create that reconciles the service is the
        # only thing that runs on every deploy.
        #
        # **The repair runs here and not at the end of the create**, because
        # the end of the create is where the units are INSTALLED, and a
        # converged deploy installs nothing — so a repair placed there would
        # never run on the deploy it is for.
        outcome.notes += _repair(existing, resolved)
        return outcome

    fresh = bool(resolved.escaped_ref) and (
        existing is None or resolved.escaped_ref not in existing.instances
    )
    if fresh and existing is not None:
        outcome.notes += previews.admit(resolved, existing, now)
    outcome.fresh_instance = fresh

    # **The LABEL is read HERE — after the converged return and before the
    # identity — and it is read only for a service that does not exist yet.**
    #
    # Two things are true of the label and this is where both of them hold.
    # It is written once, at record creation, and a later ingest does not
    # rewrite it — so a converged service never needs the projects
    # configuration read at all, and a re-ingest is not held up by a broken
    # one. And it is a RECORD (spec 3.4: "recorded, and it changes nothing"),
    # so it cannot be the thing that decides whether the deploy happens: read
    # at the record's own construction, it sat AFTER the system user, the home
    # and the copied tree, and a malformed projects configuration failed the
    # ingest and left a service on the box that no registry entry named.
    #
    # The read is total — a configuration that cannot be read records
    # `manual` and is reported as a warning — so the label never vetoes the
    # deploy in either direction.
    label, label_warnings = _source_label(source) if existing is None else (
        registry.SOURCE_MANUAL,
        [],
    )
    outcome.warnings += label_warnings

    identity = users.ensure(resolved.name, paths.service_home(resolved.name))
    outcome.uid = identity.uid
    owner = users.tree_owner(identity)
    root_owner = (0, users.group_id(GUARDEN_GROUP))

    _make_tree(resolved.name, owner, resolved.escaped_ref)
    _copy_source(directory, resolved.name, owner)

    granted = overrides_mod.seeded(resolved.track, overrides_mod.load(resolved.name))
    overrides_mod.save(resolved.name, granted, root_owner)
    # **The group warnings JOIN the label's and are not a replacement for
    # them.** This line assigned `outcome.warnings` outright, so a warning
    # raised before it — the label's, on a host whose projects configuration
    # could not be read — was discarded on the way out, and the operator saw
    # a deploy succeed with no word about the configuration that was broken.
    outcome.warnings += users.reconcile_groups(resolved.name, granted.groups)

    record = existing or registry.Registry(
        service=resolved.name,
        workload=names.workload_of(resolved.name, resolved.track.name),
        project=project,
        environment=resolved.track.name,
        uid=identity.uid,
        created=now,
        source=label,
    )
    record.project = project
    record.environment = resolved.track.name
    record.uid = identity.uid
    # `provides` is written by the mutator at creation from the manifest, and it
    # is the only copy a consumer can read: the provider's own tree is 0700 to
    # the provider and loom runs as guarden.
    record.provides = list(manifest.provides)
    if source_hash and not resolved.escaped_ref:
        record.source_hash = source_hash
    # spec 3.4: what the manifest asked for, in manifest order. A grant is matched
    # against this and against nothing else, so `weedr port open` can refuse a port
    # no repository asked for.
    record.ports_requested = [entry.port for entry in manifest.ports]
    # spec 5.3 step 7: requests only, so re-ingesting must not withdraw a grant.
    record.firewall_requested = [
        registry.RuleEntry(name=entry.name, chain=entry.chain, rule=entry.rule)
        for entry in manifest.firewall
    ]
    if source.kind == "module":
        record.installed_by = str(source.module)
    # Ticket 292: the basic-auth login is minted once, for a brand-new service,
    # while the gate module's policy marker exists. `existing is None` is the
    # grandfathering: a re-ingest or a redeploy of a running fleet mints
    # nothing, so no surprise auth arrives on a service created before the
    # policy — and a service without routes has nothing the edge would serve,
    # so it holds no login at all.
    if existing is None and manifest.routes and basicauth_mod.in_force():
        basicauth_mod.mint(record, now)
    _ensure_admin_units(identity.uid)

    if resolved.escaped_ref and resolved.escaped_ref not in record.instances:
        # Recorded before the volumes exist, not after: an instance that is not in
        # the registry cannot be counted against the cap, reported by `list`, or
        # have a seed written against it by the fork in spec 5.3 step 12. `seed`
        # stays empty here — no fork has taken yet — and the instance's
        # publications are allocated below, once it exists.
        previews.register(resolved, record, now)
    if source_hash and resolved.escaped_ref:
        # The instance's own tree, under its own ref, once the entry exists
        # (register, above, creates it on the first deploy): the service's top-
        # level hash stays the tree the SERVICE's deploys recorded, so the next
        # `add` of an unchanged service still converges instead of re-deploying
        # against a hash an instance's poke left behind (review finding 1,
        # spec 5.3's idempotency).
        record.instances[resolved.escaped_ref].source_hash = source_hash

    _allocate(resolved, record, manifest, config, source, destinations)

    # spec 5.3 step 9: on an ungated track every `@sensitive` key nothing has been
    # planted for gets a value minted once, so a poke is never blocked on a human.
    # A gated track gets none — there a missing key is a gate failure, and
    # generating one would hide exactly what the gate is for.
    if not resolved.track.gated:
        gate.mint_generated(record, gate.schema_for(resolved.name), now)

    retention = volumes.retention_from(resolved.track, granted)
    for vol in manifest.state:
        volumes.create_state(resolved.name, vol, retention, owner, resolved.escaped_ref)
        # The volume table is the SERVICE's: an instance's snapper
        # configuration is `<service>-<ref>-<vol>` and is derived from the ref
        # wherever it is needed (`paths.snapper_config`), so an instance's
        # deploy records nothing over the name the service's own deploys
        # wrote. Recording `None` here overwrote it, and the next
        # service-level `add` compared the service's volumes against an
        # instance's configuration — never equal — so a converged service
        # re-deployed in full (review finding 1, spec 5.3's idempotency:
        # observed red with only the per-ref hash fix in place).
        if not resolved.escaped_ref or vol not in record.volumes:
            _record(
                record,
                vol,
                "state",
                None if resolved.escaped_ref else paths.snapper_config(resolved.name, vol),
            )
    for vol in manifest.bulk:
        volumes.create_bulk(resolved.name, vol, owner, resolved.escaped_ref)
        _record(record, vol, "bulk", None)

    # spec 5.3 step 10, after step 9: a `@sensitive` key nothing has planted for is
    # minted first, so an edge adopting `DB_PASSWORD` reuses that value rather than
    # minting a second one over it. On a gated track step 9 mints nothing and the
    # edge's own value is what exists.
    outcome.warnings += edges.install(record, manifest, config)

    with conf.lock("registry"):
        registry.save(record, root_owner)

    # spec 5.3 step 11: the service's own units are installed, so a deploy has
    # something to start. Without this a service existed, was listed and held its
    # volumes, and `weedr service start` refused it with "has no unit to start".
    # **After** the registry is saved: `units.install` reads the record for the
    # uid it installs under, and rendering before the entry exists answered "there
    # is no registry entry for <service>".
    if source.kind != "module":
        # `_render_source`, not `directory`: `units.install` hands this to `loom`
        # as `guarden` (ADR-0012), and a home is `0700` to its own service. The
        # tree is the invocation's own and is taken away with it, so a second
        # run staging from the same source has nothing to delete out from under
        # this render (ticket 301).
        #
        # `resolved.escaped_ref` is the other half of the same call: without it
        # `loom` is never given `--instance`, so the render has no instance
        # context and lands in the service's shared quadlet directory instead of
        # the instance's own (spec 5.2) — `units_of(<name>, <ref>)` then finds
        # nothing and `weedr service start <name>/<ref>` answers 1 (ticket 295).
        with _render_source(directory) as staged:
            outcome.notes += units.install(staged, resolved.name, resolved.escaped_ref)
    return outcome


def require_template(template_name: str | None) -> Path:
    """The installed template's directory, or the one refusal that names one.

    Raised here and nowhere else, so the verb that validates its answer before
    it asks for anything and the mutator that is about to copy the template
    answer with the same line and the same code. Either way the refusal stops
    before it can name a directory outside the template set.

    **Two codes on spec 1.2's one line — "The dividing line is input against
    host" — and which one is asked is which thing is at fault.**

    `2`, the input rejected, when the argument itself breaks a rule: a value
    that does not match `names.NAME_RE` — `^[a-z0-9][a-z0-9._-]*$`, the whole
    of "a template name" — is not a template name at all and is §1.2's row
    "a name that breaks a rule"; it is `2` whatever the host holds, the same
    answer the same-shaped `add --from /tmp` gives (pinned by t250). An answer
    that names nothing where the installed set offered a choice is input too,
    so it is `2` as well.

    `1`, the host not in the state the request assumed, when the name breaks no
    rule and the host is what says no: a set that does not hold the name, and a
    set that is empty at all. §1.2 puts "the filesystem, the installed services
    and the remote" on the host's side, which is the same reason its `needs:`
    row answers `1` for a provider that does not exist.
    """
    templates = paths.TEMPLATES / "services"
    directory = None
    if template_name is not None and names.NAME_RE.match(template_name):
        directory = templates / template_name
    if directory is not None and directory.is_dir():
        return directory
    available = (
        sorted(entry.name for entry in templates.iterdir() if entry.is_dir())
        if templates.is_dir()
        else []
    )
    if not template_name:
        problem = "no template was chosen"
        code = errors.HOST_NOT_AS_ASSUMED if not available else errors.REJECTED_INPUT
    elif directory is None:
        problem = f"the template {template_name!r} is not a template name"
        code = errors.REJECTED_INPUT
    else:
        problem = f"the template {template_name!r} does not exist at {directory}"
        code = errors.HOST_NOT_AS_ASSUMED
    raise errors.GuardenError(
        problem
        + (
            f"; available templates: {', '.join(available)}"
            if available
            else f"; {templates} holds none"
        ),
        code,
    )


def refuse_existing(candidates: list[str]) -> None:
    """`create`'s one line when a name it was asked to create already is one.

    Asked for **every** name the request carries before any of them is created,
    so a `--env` list naming one service that exists refuses whole instead of
    creating the others and stopping; `create_service` asks again for its own
    name, because it is the mutator and this is the line it must not cross.

    Exit `1`, not `2` and not `0`. `2` is the input rejected and spec 1.2 writes
    it for nothing else — the name here is well formed — and `0` would report
    work that did not happen. What refuses it is the host's own state, the
    registry entry that already exists, which is how `weedr service remove`
    answers an instance list and `weedr service purge` an absent record: both
    `1`, the host is not in the state the request assumed.
    """
    taken = [name for name in candidates if registry.load(name) is not None]
    if not taken:
        return
    raise errors.GuardenError(
        f"{', '.join(taken)} already has a registry entry, and creating over it "
        f"would discard that service's volumes, provides and instances; remove it "
        f"first if replacing it is what you meant",
        errors.HOST_NOT_AS_ASSUMED,
    )


def create_service(
    resolved: names.Resolved,
    config,
    now: str,
    template_name: str,
) -> Outcome:
    """Create a new service from a template (spec 5.3, the `create` verb).

    Unlike `create` (which is called by `ingest` and `add`), this builds a
    service from scratch: no poke, no source service, just a name and a
    template. What it creates is the identity, the tree, a copy of the
    template's quadlet files in the service's own unit directory, the admin
    unit directory and the registry record. It creates **no manifest and no
    volume**: a template ships neither, so the declared volumes a manifest asks
    for are created by `create` when a poke or an `add` brings a manifest in.

    Requires root. The caller is responsible for sudo.

    **It refuses a name the registry already holds** (spec 5.1): a second
    `create` over a service would discard the record that name carries — its
    volumes, its `provides`, its instances — and copy the template's units into
    a live home, which is a data loss rather than a no-op.
    """
    refuse_existing([resolved.name])
    template_dir = require_template(template_name)

    # A service created from a template has no manifest yet — it gets one when
    # a poke or `add` brings one in. Create the tree and the identity now, and
    # leave the manifest, the volumes and the units for that later step.
    outcome = Outcome(resolved=resolved)

    identity = users.ensure(resolved.name, paths.service_home(resolved.name))
    outcome.uid = identity.uid
    owner = users.tree_owner(identity)
    root_owner = (0, users.group_id(GUARDEN_GROUP))

    _make_tree(resolved.name, owner, resolved.escaped_ref)

    # Copy the template's quadlet files into the service's own quadlet
    # directory, **as the service user and the tree's own `0700`** — the way
    # `units.install` lands every rendered unit. The template is root-owned and
    # installed, and a copy that kept its `root:root 0644` was a file inside a
    # `0700` home that the service could neither read, chown nor remove —
    # including from the service's own podman generator, which is the process
    # that has to read it (AGENTS.md: nothing root-owned inside a service's
    # home). This copy is what `weedr service start` finds.
    #
    # **The directory each file lands in is owned too.** A template that ships
    # `<unit>.container.d/<file>` has a directory in it, and `conf.write_file`
    # would create that directory with the mutator's umask and root's
    # ownership — the same defect the install path closes, in the one place
    # that writes a template's tree. The shipped templates are flat today, so
    # this is latent, and a latent hole in the same class is still the hole.
    quadlet_dir = units_dir(resolved.name, resolved.escaped_ref)
    quadlet_dir.mkdir(parents=True, exist_ok=True)
    for path in sorted(template_dir.rglob("*")):
        if path.is_file():
            target = quadlet_dir / path.relative_to(template_dir)
            units.own_directory(target.parent, owner)
            conf.write_file(target, path.read_text(encoding="utf-8"), TREE_MODE, owner)

    record = registry.Registry(
        service=resolved.name,
        workload=names.workload_of(resolved.name, resolved.track.name),
        project="",
        environment=resolved.track.name,
        uid=identity.uid,
        created=now,
        source=registry.SOURCE_MANUAL,
    )
    _ensure_admin_units(identity.uid)

    with conf.lock("registry"):
        registry.save(record, root_owner)

    return outcome


def _record(record, vol: str, kind: str, config_name: str | None) -> None:
    record.volumes[vol] = registry.Volume(name=vol, kind=kind, config=config_name)


def _wanted(manifest: manifest_mod.Manifest, source: Source) -> list[str]:
    """The containers that get a publication, in a fixed order.

    Every container named in a `routes:` or `ports:` entry, because a grant is
    a translation to a publication and a request naming no container names no
    destination. A module's service adds the entrypoints its own file declares
    and, when it declares an API, the API — which is a control surface on its own
    publication and is never forwarded.
    """
    out: list[str] = []
    for entry in [*manifest.routes, *manifest.ports]:
        if entry.container not in out:
            out.append(entry.container)
    if source.kind == "module":
        module = modules_mod.read(str(source.module))
        entry = module.service(str(source.service))
        if entry is not None:
            for endpoint, _, _ in module.ingress_for(entry.name):
                if endpoint not in out:
                    out.append(endpoint)
            if entry.api and publications.API not in out:
                out.append(publications.API)
    return out


def _allocate(resolved, record, manifest, config, source: Source,
              destinations: dict[str, str]) -> None:
    """Publications and route hosts, from the ranges the host declares.

    spec 7.4 and 4. One publication per container that gets one, allocated
    from `ingress.publication_range` and refused rather than shared, and one
    full host name per route label with the track's own prefix in front of it —
    and the tunnel's zone in front of that when the route's destination is the
    tunnel (ticket 324).
    An instance's publications are its own, so two previews of one service are
    both routable at once.

    `destinations` is what `check_hosts` resolved before identity was touched:
    the same answer, asked once, so the name a route is allocated cannot
    disagree with the posture the record carries.
    """
    records = _others(record.service)
    wanted = _wanted(manifest, source)
    # This service's own instances are in `used` as well as everybody else's: a
    # preview's publication is allocated in the same namespace as the rest of the
    # box, and `records` deliberately excludes this service, so without this a
    # second preview of one service is handed the number the first holds.
    taken = publications.held(records) | _instance_publications(record)

    record.publication = publications.allocate(
        wanted, record.publication, taken, config.publication_range, record.service,
    )
    # A label the manifest dropped stops being claimed — and stops being
    # carried. The table is rebuilt from the destinations, which are keyed to
    # the manifest's routes, so this record, the expose verbs and the drift item
    # (all of which key off `route_hosts`) compute over one host set rather than
    # an accumulating one that is a second place to be wrong (tickets 293/294).
    claim_route_hosts(
        record, resolved.track, destinations, config,
        holders=publications.host_holders(records),
    )
    # Ticket 293/294: the destinations are resolved and written into the
    # registry, and the slice and the firewall both read that record — one
    # answer, one writer (spec 3.4: only what cannot be derived is stored, and
    # once stored it is the record). The first answer **stands**: a host the
    # record already holds keeps the posture it was created under, so
    # installing a module or editing a track re-postures services that do not
    # exist yet and never a running fleet. A label the manifest dropped stops
    # being carried, because the answer is over the manifest's hosts.
    record.route_destinations = dict(destinations)

    if resolved.escaped_ref:
        instance = record.instances.get(resolved.escaped_ref)
        if instance is not None:
            instance.publication = publications.allocate(
                wanted, instance.publication,
                taken | set(record.publication.values()),
                config.publication_range, f"{record.service}/{resolved.ref}",
            )


def _others(service: str) -> list:
    return [
        entry
        for entry in (registry.load(name) for name in registry.names())
        if entry is not None and entry.service != service
    ]


def _instance_publications(record) -> set[int]:
    return {
        port for instance in record.instances.values() for port in instance.publication.values()
    }


def _destinations(
    record, track, manifest: manifest_mod.Manifest, config, name: str
) -> dict[str, str]:
    """Every route label's destination, resolved once, by the resolver.

    `exposure.destinations` is the one function the mutator, the renderer's
    slice, the firewall's accept set and `soil --check`'s drift item ask, so the
    name a route is allocated and the posture the record carries cannot be two
    answers. `record` may be `None` — a service that does not exist yet has no
    record, and the derived default is the answer there.

    **The first answer STANDS** (tickets 293/294): a label the record already
    carries keeps the destination it was created under, so installing a module
    or editing a track re-postures services that do not exist yet and never a
    running fleet. It matters here and not only in the record, because the NAME
    is derived from the destination: a grandfathered loopback route that now
    resolves to the tunnel must keep its bare name — qualifying it would put a
    tunnel-zone name on a route the edge serves.
    """
    granted = overrides_mod.load(name)
    resolved = exposure.destinations(
        record,
        track,
        config.modules,
        set(granted.expose_tunnel) if granted else set(),
        [route.host for route in manifest.routes],
    )
    recorded = getattr(record, "route_destinations", None) or {}
    return {host: recorded.get(host, destination) for host, destination in resolved.items()}


def _zone(track, destination: str, tunnel_domain: str, service: str) -> str:
    """The zone a route's allocated name is published in: `""` or `.`+domain.

    **A tunnel route is a name in the TUNNEL's zone, and nothing else puts it
    there** (ticket 324). `roots` publishes a tunnel route at the name the
    record holds, and the record held a bare label — `web` — which is a name in
    no zone at all, so no DNS could answer it, no edge file served it and
    nothing said so. `[ingress] tunnel_domain` is the zone the tunnel serves,
    and it was consulted for previews only.

    **A preview instance is the exception, and it is spec 9's.** Every preview
    of every project shares one host — `preview.<tunnel_domain>` — and the ref
    is a path on it, so an instance's own name is never zone-qualified: it is
    `preview.web`, and the tunnel publishes the shared host with the ref's path.
    Qualifying it would give every preview a hostname of its own and undo the
    one host the design spends spec 9 on.

    **An empty `tunnel_domain` with a tunnel route is a refusal** rather than a
    name in no zone: the same defect, arrived at by configuration rather than
    by the allocator. It is exit `1` — the host is not in the state the request
    assumed — and it names the key an operator has to set, which is the "or the
    host says why it cannot" half of ticket 324's acceptance.
    """
    if destination != exposure.TUNNEL:
        return ""
    if not tunnel_domain:
        raise errors.GuardenError(
            f"{service}: the route is published through the tunnel, and [ingress] "
            f"tunnel_domain is empty in {paths.GUARDEN_TOML}, so the name it would be "
            f"allocated is in no zone and no DNS could answer it; set tunnel_domain to "
            f"the zone the tunnel's provider serves",
            errors.HOST_NOT_AS_ASSUMED,
        )
    if getattr(track, "kind", "") == config_mod.INSTANCE:
        return ""
    return f".{tunnel_domain}"


def check_hosts(
    name: str, manifest: manifest_mod.Manifest, track, config, destinations: dict[str, str]
) -> dict[str, str]:
    """Every route host this manifest would claim, checked before identity.

    Same reason `edges.check` runs where it does: a claim refused after the user
    and the tree exist leaves a system account and a home behind on the way out,
    and the diagnostic the caller gets is the same either way. The empty
    `tunnel_domain` refusal is here for exactly that reason — a service that
    cannot be named is not a service to create half of.

    The names are RETURNED, not merely tried: `_converged` compares the record
    against them, so a record whose route host an older guarden allocated
    without the tunnel's zone is repaired by the next ingest rather than
    republished bare at every sync.
    """
    holders = publications.host_holders(_others(name))
    hosts: dict[str, str] = {}
    for route in manifest.routes:
        hosts[route.host] = publications.claim_host(
            route.host,
            track.host_prefix,
            _zone(track, destinations[route.host], config.tunnel_domain, name),
            holders,
            name,
        )
    return hosts


def claim_route_hosts(
    record, track, destinations: dict[str, str], config, holders: dict[str, str] | None = None
) -> None:
    """Allocate every route host the record's destinations imply, in place.

    **One writer for the name.** The record is the authority (spec 3.4): it is
    what `roots` renders, what `weedr share issue` grants, what `weedr service
    list` reports and what `twig` links to. A name derived at render time would
    be a second answer, and a grant could name a hostname the tunnel does not
    serve.

    The table is REPLACED rather than merged, because `destinations` is keyed to
    the manifest's routes: a label the manifest dropped stops being claimed and
    stops being carried, so the record, the expose verbs and the drift item
    compute over one host set rather than an accumulating one (tickets
    293/294).

    `weedr expose set` calls this too: the act moves a route between the
    tunnel's zone and the bare name, and the name has to move in the same act
    or the grant and the tunnel disagree until the next render.
    """
    if holders is None:
        holders = publications.host_holders(_others(record.service))
    record.route_hosts = {
        label: publications.claim_host(
            label,
            track.host_prefix,
            _zone(track, destination, config.tunnel_domain, record.service),
            holders,
            record.service,
        )
        for label, destination in destinations.items()
    }


def _project_from(source: Source) -> str:
    """The project the `--from` source belongs to, never a path basename: under
    the new layout the staging directory's basename is a sha.

    **A tree names no project.** A tree the operator built — by hand or with
    the guided creator — is not a poke and belongs to no registered project,
    so the project's name is empty and the manifest's own `project:` is what
    the record carries. A tree that named a project would claim one the host
    has never registered.
    """
    if source.kind == "poke":
        return str(source.project)
    if source.kind == "tree":
        return ""
    record = registry.load(str(source.service))
    if record is None or not record.project:
        raise errors.GuardenError(
            f"--from {source.service} has no registry entry naming a project",
            errors.HOST_NOT_AS_ASSUMED,
        )
    return record.project


def _deployed_hash(record, escaped_ref: str | None) -> str:
    """What THIS ref last deployed from: the instance's own tree under its
    ref, the service's own tree otherwise.

    The registry is one file per service and an instance's `create()` saves
    the service's record, so the hash has to be read where the deploy that
    wrote it recorded it — a single top-level field was answered by whichever
    deploy ran last, service or instance, and the loser re-deployed a tree
    nothing had changed (review finding 1, spec 5.3's idempotency).
    """
    if escaped_ref:
        instance = record.instances.get(escaped_ref)
        return (instance.source_hash if instance is not None else "") or ""
    return record.source_hash or ""


def _converged(
    record,
    resolved,
    manifest: manifest_mod.Manifest,
    project: str,
    source_hash: str = "",
    hosts: dict[str, str] | None = None,
) -> bool:
    if record.project != project or record.environment != resolved.track.name:
        return False
    if source_hash and _deployed_hash(record, resolved.escaped_ref) != source_hash:
        return False
    if resolved.escaped_ref and resolved.escaped_ref not in record.instances:
        return False
    # The route host is an ALLOCATION, like a publication, and a record that
    # holds a name this manifest would no longer be allocated is not converged:
    # the slice is rendered from the record, so without this the record keeps a
    # name in no zone forever and a re-ingest answers "converged" while the
    # tunnel publishes a hostname no DNS can answer (ticket 324).
    if hosts is not None and dict(record.route_hosts) != hosts:
        return False
    declared = dict.fromkeys(manifest.state, "state")
    declared.update(dict.fromkeys(manifest.bulk, "bulk"))
    if declared != {volume.name: volume.kind for volume in record.volumes.values()}:
        return False
    return all(
        record.volumes[vol].config == paths.snapper_config(resolved.name, vol, resolved.escaped_ref)
        for vol in manifest.state
    )


def _repair(record, resolved) -> list[str]:
    """The tree of a service that is already converged, converged to the
    tree's rule (ticket 334).

    **What is repaired is the UNIT DIRECTORIES: the service's own and every
    instance's.** Those are the directories the INSTALLER made — the quadlet
    directory, the levels above it, and the drop-in directory under it — and it
    made them by `conf.write_file`'s `mkdir(parents=True)`, so they carry the
    mutator's umask and root's ownership. A host that ran an older guarden
    carries them that way, and nothing else repairs them: `_make_tree`'s walk
    owns the rest of the tree, and it runs on a create that is not converged.

    **Why not the whole tree.** The walk already owns the whole tree, and it
    reaches the unit directories too — so a repair that walked the whole tree
    would be a second statement of the tree's rule in a second place, and the
    two would drift. The repair is narrow because the INSTALLER is the only
    writer that made a directory wrong.

    **Why not the files.** A unit file's mode is the tree's `0700` like every
    other file under it (spec 2.1, ticket 320), and the one writer that makes a
    unit states it. What a converged create repairs is the thing the service
    cannot make for itself: a directory in its own home.

    **Whose mode wins: the tree's.** The tree's rule is `0700` to the service
    user (spec 2.1), and it is a rule about the ISOLATION BOUNDARY rather than
    about a convenience: `0700` on the service's tree is what stops every
    service user reading every other service's state volumes off the host
    filesystem. An operator who widened a directory under the home has widened
    the boundary, and a repair that did not put it back would leave the hole
    open — so the tree's rule wins, and the repair says what it changed so an
    operator who meant it can say so in a place guarden reads.

    The lines are NOTES and not warnings: a repair is the verb doing what it
    says, so the deploy exits `0` and the operator sees what was corrected.
    """
    owner = units.owner_of(record)
    repaired = units.repair_unit_dirs(record.service, owner, sorted(record.instances))
    return [f"repaired {path} to the service's own" for path in repaired]


def _make_tree(name: str, owner: tuple[int, int], escaped_ref: str | None = None) -> None:
    """The whole tree, `0700` to the service user, with no carve-out for the home.

    The `0700` is what the scheme rests on: without it every service user reads
    every other service's state volumes straight off the host filesystem, and the
    per-consumer credentials and the uid-matched firewall rules stop being
    controls and become decoration. A service is `0700` as a unit — home, state,
    bulk and every instance's volumes, unit files included — and **no config
    subvolume is ever created**, for any track, including a gitops-created
    production service.
    """
    tree = paths.service_tree(name)
    tree.mkdir(parents=True, exist_ok=True)
    directories = [
        paths.service_home(name),
        paths.unit_dir(name),
        tree / volumes.SUBVOLUME,
        tree / volumes.BULK,
    ]
    if escaped_ref:
        # An instance's unit directory lives under the service's home and its
        # volumes under `instances/`, a sibling of the service's own and never a
        # child of them (spec 2 and 5.2).
        #
        # **The instance's own quadlet directory is created here, and it is
        # the service's own user who owns it.** Without this the directory was
        # created by the first `units.install` — by `conf.write_file`'s
        # `path.parent.mkdir` — so it was root-owned with the mutator's umask
        # (0755, typically) inside a `0700` home, and the spec's "nothing
        # root-owned lives inside a service's home" was false for it. The
        # service could not write its own unit directory, and the mode depended
        # on who invoked the mutator.
        directories += [
            paths.instance_home(name, escaped_ref),
            paths.instance_home(name, escaped_ref) / paths.QUADLET,
            paths.instance_tree(name, escaped_ref) / volumes.SUBVOLUME,
            paths.instance_tree(name, escaped_ref) / volumes.BULK,
        ]
    for directory in directories:
        directory.mkdir(parents=True, exist_ok=True)
    for path in [tree, *sorted(tree.rglob("*"))]:
        if paths.SNAPSHOTS in path.parts:
            # snapper's subtree: the snapshots are read-only btrfs subvolumes
            # (a chown raises EROFS -- measured 2026-10-12, `weedr service
            # ingest` reconciling a service whose instance already carried a
            # snapshot: `/var/lib/.../state/data/.snapshots/1/snapshot`,
            # `OSError: [Errno 30] Read-only file system`) and their ownership
            # is snapper's, not the service user's.
            continue
        if _in_podman_store(path, paths.service_home(name)):
            # Podman's store is podman's to own. Its overlay carries the
            # image's own modes and owners, and re-moding it to 0700 under the
            # service uid left the container unable to stat its own entrypoint
            # -- the container's root is subuid-mapped, not the service uid -- so
            # `postgres:17-alpine` died with `permission denied` on
            # `/usr/local/bin/docker-entrypoint.sh` (measured 2026-10-18,
            # app-vm). See `_in_podman_store`.
            #
            # The root is the **home**, because podman resolves the store from
            # `HOME`, which every unit pins to the home (render.py). Rooted at
            # the tree instead, the guard asked for `.local/share/containers`
            # beside the home and matched nothing, so this walk went on
            # re-moding the store -- the line `tests/t380-store-walk.sh` fails
            # on without it.
            continue
        if path.is_symlink():
            # A link's target is not the tree's to own, and may not exist at
            # all: podman's image store carries links such as
            # `/usr/bin/pinentry` whose target the image does not ship, and a
            # chown follows a link by default -- so walking into one raised
            # FileNotFoundError and stopped the whole create (measured
            # 2026-10-18, `weedr service ingest postgres-staging` after the
            # first pull had populated `home/.local/share/containers`). The
            # link itself is the tree's; it is owned, and not followed.
            conf.set_owner(path, owner, follow=False)
            continue
        conf.set_owner(path, owner)
        os.chmod(path, TREE_MODE)



def _source_hash(directory: Path) -> str:
    """The content hash of everything that determines the render, for the
    convergence check.

    **The whole staged tree, because the whole staged tree is the build's
    context.** `_copy_source` copies the tree into the home and `podman build`
    reads the home, so every file in the tree is a build input and not only
    the four the renderer reads: a Containerfile that COPYs `Cargo.toml` is
    changed by an edit to `Cargo.toml`, and a hash that did not see it would
    answer "converged" and skip the rebuild — the image would go on being the
    old one while the source had moved.

    Compare **source, not output**: a Containerfile build produces an image —
    hash the source files, not the built image. A compose render produces
    quadlets — hash the compose content, not the rendered quadlets.

    `deployed_sha` (the poke commit) is not: re-ingesting the same commit
    after editing the compose file is a change the operator made and the
    convergence check must see it.

    **The hash walks the tree the way the copy walks it**, and it skips the
    same things the copy skips: the podman store (which is in the home of a
    service the tree was read from, and is podman's rather than the source's),
    the snapper subtree, and the secret database the store holds.
    """
    import hashlib

    h = hashlib.sha256()
    for path in sorted(directory.rglob("*")):
        if _excluded_from_source(path.relative_to(directory)):
            continue
        if not path.is_file():
            continue
        h.update(path.relative_to(directory).as_posix().encode())
        h.update(path.read_bytes())
    return h.hexdigest()


def _copy_source(directory: Path, name: str, owner: tuple[int, int]) -> None:
    """The repository's whole staged tree into a home.

    A repository ships either `compose.yaml` at its root or `.guarden/quadlet/`
    and exactly one of them, and this is the copy that makes
    `add --from <service>` a copy of that service's manifest and unit source
    rather than a re-derivation of them.

    **The whole tree, not four files, because the build verb reads it.** The
    home is `podman build`'s context (spec 6.6), and a `COPY` resolves
    against the context directory: a Containerfile that says
    `COPY Cargo.toml Cargo.lock ./` needs those files IN the context, and a
    context of four files cannot satisfy it — the build died with `125` and
    `"/Cargo.toml": no such file or directory` (measured, ticket 317). So the
    tree is copied whole, and the tree's own layout is unchanged.

    **What is not copied: the podman store, the podman configuration directory
    and the snapper subtree.** The store is podman's — it holds the image
    layers and the per-user secret database in cleartext, and a source read
    from another service's home (`add --from <service>`) carries that
    service's store, so copying it whole would copy another service's
    credential material into the new one. The configuration directory holds
    the RENDERED units of the service the tree was read from, which are that
    service's own and not its source's. The guard below walks the same
    `.snapshots` the service walk skips, because the home is not snapshotted
    today and a build context that carried snapper's read-only subvolume
    would be a context `podman build` cannot copy.

    **A file that is not copied is not in the context, and that is not the
    same as being excluded from it.** The exclusion in the context's own
    ignore file is a second thing and is written at BUILD time
    (`weedr._build`), because the home's store grows after this copy and a
    copy-time exclusion would be a statement about the past.
    """
    home = paths.service_home(name)
    _copy_tree(directory, home)
    for path in [home, *sorted(home.rglob("*"))]:
        if paths.SNAPSHOTS in path.parts:
            # The same snapper subtree the service walk skips: read-only, and
            # snapper's to own. The home is not snapshotted today, and the
            # guard keeps the two walks agreeing if that changes.
            continue
        if _in_podman_store(path, home):
            # The same store the service walk leaves alone, and for the same
            # reason: a re-ingest walks a home that already carries it.
            continue
        if path.is_symlink():
            # The same link the service walk will not follow. The home already
            # carries podman's image store by the time a service is re-ingested,
            # and that store holds links whose target the image does not ship
            # (`usr/bin/pinentry -> pinentry-curses` in postgres:17-alpine,
            # measured 2026-10-18): a chown follows a link by default, so
            # walking into one ended the create with FileNotFoundError. The
            # link is the tree's; its target is the image's.
            conf.set_owner(path, owner, follow=False)
            continue
        conf.set_owner(path, owner)


# The paths in a service's home that are guarden's or podman's and not the
# source's. They are the paths a tree read from a service's OWN home carries
# and a poke's staging tree does not.
#
# **The parts, and not the paths, because a path is not a sequence of parts.**
# `Path(".config/containers") in (".config", "containers", "systemd")` is
# False — a `Path` is never equal to a string — so a check written that way
# matched nothing and the exclusion was silently inert. The comparison is
# against the tuple of the path's own parts.
_PODMAN_STORE_PARTS = paths.PODMAN_STORE.parts
_PODMAN_CONFIG_PARTS = paths.QUADLET.parts[:2]


def _excluded_from_source(relative: Path) -> bool:
    """Whether a path in the source tree is the host's and not the source's.

    The podman store holds the image layers and the per-user secret database
    in cleartext, and the podman configuration directory holds the RENDERED
    units of the service the tree was read from. Neither is the source's, and
    a tree read from a service's own home carries both.
    """
    parts = relative.parts
    if paths.SNAPSHOTS in parts:
        return True
    if parts[: len(_PODMAN_STORE_PARTS)] == _PODMAN_STORE_PARTS:
        return True
    if parts[: len(_PODMAN_CONFIG_PARTS)] == _PODMAN_CONFIG_PARTS:
        return True
    return False


def _copy_tree(directory: Path, home: Path) -> None:
    """The source tree into the home, minus the subtrees that are not the
    source's.

    **A link is not dereferenced, and one is carried rather than copied.** The
    source is a tree a POKE brought in, so it is untrusted, and `copytree`
    follows links by default — which would copy a target's bytes into the
    service's home. The copy carries the link instead.

    **The podman store and the podman configuration are not copied.** The
    store is podman's own (it holds the image layers and the per-user secret
    database), and the configuration directory holds the RENDERED units of
    the service the tree was read from — neither is the source's, and a tree
    read from a service's own home carries both.

    **The `.snapshots` subtree is not copied**, for the reason the service
    walk skips it: snapper's subvolumes are read-only, and a build context
    that carried one is a context `podman build` cannot copy.
    """
    for path in sorted(directory.rglob("*")):
        relative = path.relative_to(directory)
        if _excluded_from_source(relative):
            continue
        target = home / relative
        if path.is_symlink():
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, target, follow_symlinks=False)
            continue
        if path.is_dir():
            target.mkdir(parents=True, exist_ok=True)
            continue
        if not path.is_file():
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target, follow_symlinks=False)


def write_build_exclusions(home: Path, owner: tuple[int, int]) -> None:
    """Guarden's exclusion into the context's own ignore file, for both of the
    names podman reads.

    **The exclusion is written at BUILD time and not at copy time**, because
    the home's podman store grows after the copy — the store is podman's, it
    holds the image layers, and a copy-time statement about it would be a
    statement about the past. The build is the moment the context is read.

    **The source's own patterns are kept, and guarden's come after them.**
    The source owns what the build does not see (spec 6.6), so its patterns
    are the context's own; and the LAST matching pattern wins (measured on
    podman 5.7.0: `*.txt` then `!plain.txt` re-includes the file), so guarden's
    lines last means a source-side `!` negation cannot re-include the store.

    **Both names carry BOTH halves, and that is the whole subtlety.** Podman
    reads `.containerignore` in preference to `.dockerignore` and never
    consults the second when the first is present (measured). So:

    - guarden writes **both** names, because a source that ships only
      `.containerignore` would otherwise have guarden's `.dockerignore`
      ignored entirely, and the store would go into the image;
    - and **the source's patterns go into BOTH**, because writing guarden's
      block alone into `.containerignore` would silently DROP the source's
      narrowing — the `.dockerignore` would never be read at all, and the
      source's own exclusion would stop holding. Measured: a context whose
      `.dockerignore` excluded `Cargo.toml` and whose `.containerignore` held
      only guarden's block built the image WITH `Cargo.toml` in it.

    So each name is written with the source's patterns of BOTH names first and
    guarden's block last. A source that ships one of them therefore keeps its
    narrowing under either name, and the union of the two is what the build
    sees.

    **The merge is idempotent.** A build that runs twice, or a home that was
    copied from another service's home, must not accumulate guarden's block
    twice: the marker line is where guarden's part begins, and everything from
    there on is replaced.

    **The file is written by root and made readable by the service user**,
    which is the uid the build runs as. The home is `0700` to that user, so
    the mode that matters is the file's own.
    """
    guarden_lines = [BUILD_MARKER, *BUILD_EXCLUSIONS]
    source_lines: list[str] = []
    seen: set[str] = set()
    for name in BUILD_IGNORE_NAMES:
        path = home / name
        if not path.is_file():
            continue
        try:
            body = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        for line in _source_ignore_lines(body):
            if line not in seen:
                seen.add(line)
                source_lines.append(line)
    for name in BUILD_IGNORE_NAMES:
        body = "\n".join([*source_lines, *guarden_lines]) + "\n"
        conf.write_file(home / name, body, IGNORE_MODE, owner)


def _source_ignore_lines(body: str) -> list[str]:
    """The source's own patterns, with guarden's previous block removed.

    The marker is where guarden's part begins, so a file that already carries
    one is truncated there and the source's part is kept — which is what makes
    the merge idempotent and what keeps a service that edits its own home's
    ignore file from accumulating guarden's block on every build.
    """
    lines: list[str] = []
    for line in body.splitlines():
        if line.strip() == BUILD_MARKER:
            break
        lines.append(line)
    # A trailing blank line is the source's own spacing; it is dropped so the
    # marker is the one thing between the two halves.
    while lines and not lines[-1].strip():
        lines.pop()
    return lines


def _reap_staging(parent: Path) -> None:
    """Take the staging trees whose creator run no longer answers — best effort.

    The `rmtree` this replaces deleted `render-source/<source>` whatever another
    run was doing with it — the whole of the race — and this keeps only trees
    whose named creator is gone: a run's tree is named after the pid that staged
    it, so while that pid answers, its tree is never a candidate (`kill(pid, 0)`
    answers across uids, so `EPERM` means alive too), and an entry that is not
    `<pid>-<random>` at all is a leftover of the shared layout this replaces
    (where `render-source/<source>` *was* the tree).

    **The pid check is about the creator and proves nothing about who is reading
    the tree.** The reader is not the run: `units.render_units` runs `loom` under
    `runuser`, from `tool.call`'s bare `subprocess.run` — no `start_new_session`,
    no timeout, nothing tying the child's life to the parent's — so a mutator
    SIGKILLed mid-render (the OOM killer is the realistic one; it takes the
    parent and leaves the child) leaves that `loom` orphaned and still reading a
    tree whose creator pid no longer answers, and the next run to stage from
    this source takes the tree from under it. The per-invocation tree closes the
    race ticket 301 names — one live run `rmtree`ing the tree another live run
    holds — and this is what remains after it: an unclean parent death first,
    never a concurrent run.

    The reap is deliberately one-sided when it cannot decide either way, which
    makes it best effort in both: a creator pid the kernel has handed to some
    long-lived process since keeps its dead run's tree here for good (nothing
    else bounds this directory) — the better of the two failures, because the
    other one is deleting a tree someone is reading.
    """
    for entry in list(parent.iterdir()):
        creator, sep, _rest = entry.name.partition("-")
        if sep and creator.isdigit():
            try:
                pid = int(creator)
                if pid == os.getpid():
                    continue
                os.kill(pid, 0)
                continue
            except ProcessLookupError:
                pass
            except PermissionError:
                continue
            except (OverflowError, ValueError):
                # Not a pid this machine can hold: wider than a pid_t (the
                # conversion raises before the syscall) or longer than int()
                # takes. The name promised a run and names none — take it.
                pass
            except OSError:
                # Anything else the kernel might answer, which for signal 0
                # this cannot name: keep the tree rather than guess.
                continue
        if entry.is_dir():
            shutil.rmtree(entry, ignore_errors=True)
        else:
            entry.unlink(missing_ok=True)


@contextmanager
def _render_source(directory: Path) -> Iterator[Path]:
    """The render inputs where `loom` — running as `guarden` — can read them.

    `units.install` hands its source to `loom` through `runuser -u guarden`
    (ADR-0012), and a source inside a service's own tree is `0700` to that
    service (`TREE_MODE`, spec 2.1): the renderer got `EACCES`, `Path.is_file()`
    swallowed it as "not there", and `render` answered that a manifest which is
    present "does not exist" (measured 2026-10-18, `weedr service add
    myapp-staging --from myapp-production`, whose source is production's home —
    and the same failure waits behind the home-fallback in `_manifest_directory`,
    a second `ingest` whose staging tree has already been removed).

    So a source a renderer cannot enter is staged first, exactly as a poke's
    staging tree has always been: the four inputs `_copy_source` copies,
    root-owned and `0755`, where the renderer is only a reader. Only a source
    under `services/` is staged — a staging tree, a module's shipped source and
    a template are root-owned and readable already.

    **The tree belongs to the invocation that staged it and is gone when that
    invocation ends**, because nothing that reads it needs the path to be
    stable. There is one consumer: `units.install` → `render_units` → `loom
    render <source>`, reading this tree for the length of one render, and
    nothing after it. `_source_hash` hashes the **original** directory (a poke's
    staging tree or the source's own home, by design — 00d0150), never this
    copy; `_manifest_directory` resolves a manifest from the source directory or
    the service's home, also never this copy; and no registry field, diagnostic
    or printed line names where the inputs were staged from. So two runs from
    one source have no reason to see the same path, and the way they stop
    deleting each other's tree out from under a read is to not share one:
    `render-source/<source>/<pid>-<random>`, created by `mkdtemp` (which cannot
    hand the same name to two runs) and removed in this function's `finally`,
    including when the copy it was staging failed.

    A lock keyed on the source was the other shape and is the wrong one. spec
    3.5 enumerates the lock names and their order, and `conf._rank` refuses a
    name outside that table, so it would be a spec change to the contract; it
    would serialise two independent adds behind one whole render to protect a
    tree nothing keeps; and it would still leave a killed run's tree behind,
    which is what `_reap_staging` takes over — best effort, and on the terms
    its own docstring states.
    """
    if paths.SERVICES not in directory.parents:
        yield directory
        return
    relative = directory.relative_to(paths.SERVICES)
    parent = paths.LIB / "render-source" / relative.parts[0]
    parent.mkdir(parents=True, exist_ok=True)
    os.chmod(parent, 0o755)
    _reap_staging(parent)
    stage = Path(tempfile.mkdtemp(prefix=f"{os.getpid()}-", dir=parent))
    try:
        for relative_input in (".guarden", "compose.yaml", *BUILD_INPUTS):
            source = directory / relative_input
            target = stage / relative_input
            if source.is_dir():
                # **A link is not dereferenced, and one is refused.** The source
                # is the SERVICE's own home, so the service can plant a link in
                # it — and `copytree` follows links by default, so root would
                # have copied the TARGET's bytes into a `0755` directory every
                # local uid can traverse, which is how one service's credential
                # blob reaches another. The copy carries the link instead.
                shutil.copytree(source, target, symlinks=True)
            elif source.is_file():
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, target, follow_symlinks=False)
        # The copies carry the home's modes — `0700` all the way down, because
        # `_make_tree` modes every file and not only every directory — so the
        # staged tree is re-moded as it is written: directories traversable,
        # files readable, and nothing writable by the renderer.
        for path in [stage, *sorted(stage.rglob("*"))]:
            os.chmod(path, 0o755 if path.is_dir() else 0o644)
        yield stage
    finally:
        shutil.rmtree(stage, ignore_errors=True)


def _ensure_admin_units(uid: int) -> None:
    """Reconcile the existence of podman's uid-scoped search path and create
    nothing in it: a regenerated unit must not clobber a root-owned drop-in, which is
    what that path being searched after the home's own directory buys (ADR-0003).

    **The path's own directories are created with a stated mode**, because the
    generator walks them as the service user: a directory the umask made
    `0700` would be invisible to the very uid the units are for, and a
    `0750` one would refuse the edge and every other uid the generator may
    run as. `0755` on the way down and `0644` on the file inside is what the
    probe measured (`probe-quadlet-dropins.md` rows 8 and 10).

    Nothing inside the uid's own directory is created, read or removed here:
    the admin's own `90-admin.conf` is the human's file, and the one file
    guarden writes in there is written where it is written — by the install,
    with the name it has.

    **This is the mutator's half of the admin path, and the renderer reads
    the directory too** (ADR-0024). `render._dropins` merges every `*.conf`
    in a unit's drop-in directory into the unit before generation, so an
    operator's `MemoryMax=` reaches the rendered unit. That read is the
    renderer's and not this function's: the mutator reconciles the EXISTENCE
    of the path and writes the one file it owns, and it neither copies the
    admin's file in from somewhere else nor stages a copy of it anywhere.
    The admin path is the only path to an admin's unit, and there is no
    staging copy of it.
    """
    for parent in paths.admin_parents():
        parent.mkdir(parents=True, exist_ok=True)
        os.chmod(parent, ADMIN_UNITS_MODE)
    target = paths.ADMIN_UNITS / str(uid)
    if not target.exists():
        target.mkdir(parents=True, exist_ok=True)
        os.chmod(target, ADMIN_UNITS_MODE)


def units_dir(name: str, escaped_ref: str | None = None) -> Path:
    home = paths.service_home(name)
    if escaped_ref:
        home = home / escaped_ref
    return home / paths.QUADLET


def units_of(name: str, escaped_ref: str | None = None) -> list[str]:
    directory = units_dir(name, escaped_ref)
    if not directory.is_dir():
        return []
    return sorted(path.stem for path in directory.glob("*.container"))


def refuse_legacy_volumes(name: str, escaped_ref: str | None = None) -> None:
    """Refuse a `state` volume whose data is at the root, at the START and not
    only at the ingest (ADR-0020).

    **Why the start needs it too.** The mutator refuses at ingest, so a fresh
    deployment never carries the wrong shape. But a service deployed before
    this change has a volume with its data at the root, and the operator who
    re-runs `weedr service start` on it gets the container's own answer: the
    image's chown error, in a container's log, naming nothing that can be
    acted on. The refusal here is the same one the mutator makes, and it
    names the volume, the payload directory and the work.

    **The volumes are the service's own, read from its registry.** A service
    that declares no `state` volume has nothing to refuse, and a service whose
    registry entry is gone has nothing to read and nothing to refuse.
    """
    record = registry.load(name)
    if record is None:
        return
    for vol in record.volumes.values():
        if vol.kind != "state":
            continue
        volumes.refuse_root_data(name, vol.name, escaped_ref)


def ensure_owner_line(name: str, escaped_ref: str | None = None) -> None:
    """Probe what the record does not answer yet, record it, and put guarden's
    `UserNS=` line where the generator reads it, before the units are started
    (ADR-0019).

    `weedr service start` calls this in front of `start_units`. A first start
    probes each DISTINCT image the installed units name, as the service user,
    writes the answers into the registry — `owner_uid`/`owner_gid` for a
    service whose units name one image, those plus a per-unit `owner_units` map
    when they name several — and re-renders so every unit's OWN drop-in
    carries the `UserNS=keep-id:uid=...,gid=...` of ITS OWN image before the
    container it is about to start. The line is rendered, never hand-written,
    so the refusal of a repository's own `Userns=` is untouched (spec 6.3),
    and a unit whose image cannot be read or resolved raises the probe's one
    line rather than being skipped.

    **The line is a DROP-IN, and not a line in the base unit**
    (`50-guarden-keepid.conf` in the uid-scoped search path). The base unit
    carries no `UserNS=` line at all, which is what makes the pin survive a
    regeneration of the unit and lets an admin's own `90-admin.conf` override
    it by name order alone.

    A later start finds every unit answered and does not probe again, and
    re-renders only when the drop-in guarden owns does not hold exactly the
    line the record renders for that unit — so the line is stable across
    starts, re-renders and re-ingests, an edited record is rendered through
    rather than overwritten by a second probe, a unit a re-ingest added (or an
    image that changed) is the probe's condition again, and a record with the
    probe removed is probed again.
    """
    record = registry.load(name)
    if record is None:
        raise errors.GuardenError(
            f"{name} has no registry entry, so there is nothing to start",
            errors.HOST_NOT_AS_ASSUMED,
        )
    plan = _owner_plan(name, record, escaped_ref)
    if plan:
        probed = {reference: probe_image(name, record, reference) for reference in plan}
        with conf.lock("registry"):
            current = registry.load(name)
            if current is None:
                raise errors.GuardenError(
                    f"{name} lost its registry entry while its image user was being probed",
                    errors.HOST_NOT_AS_ASSUMED,
                )
            _record_owners(current, name, escaped_ref, probed)
            registry.save(current, (0, users.group_id(GUARDEN_GROUP)))
        record = current
    unit_images = _installed_images(name, escaped_ref)
    for path in sorted(units_dir(name, escaped_ref).glob("*.container")):
        unit = unitsource.parse(path)
        # A pin and a source's own `User=` cannot both decide the container's
        # user — the line maps the probed pair onto the service identity while
        # `User=` names the uid the container runs as, and a uid that is not
        # the pair is one the pin maps nowhere — so the refusal happens here
        # as well as in the render: this is the path that answers the start,
        # and it answers with the input code rather than through the
        # renderer's exit plumbing. It is asked per unit, because
        # the line is per unit: a service whose other unit is pinned does not
        # take this unit's `User=` away.
        pinned = render.owner_line(record, unit.stem(), unit_images[unit.stem()])
        if pinned is not None:
            render.refuse_pinned_user(unit, pinned, f"{name}: the unit {path.name}")
    if not _carries_owner_line(name, escaped_ref, record):
        with _unit_source(name, record, escaped_ref) as source:
            units.install(source, name, escaped_ref)


# The spellings of one declaration: no `USER` at all, the number, and the name.
# All three say "this container runs its entrypoint as container root", so all
# three take the probe's root row and no other — a group part cannot make a
# root declaration non-root. Reading `root` through the passwd row while `0`
# took the entrypoint's handoff was two paths for one declaration, and the
# second path recorded root without ever asking the entrypoint who it hands
# off to (ADR-0019's Consequences).
ROOT_DECLARATIONS = frozenset({"", "0", "root"})


def _is_root_declaration(declared: str) -> bool:
    """Whether `Config.User` declares container root, in any of its spellings."""
    return declared.partition(":")[0] in ROOT_DECLARATIONS


def _installed_images(name: str, escaped_ref: str | None) -> dict[str, str]:
    """Every installed unit and the image it names, keyed by unit.

    The probe's question is per unit (ADR-0019): two units of one service may
    name two images, and each image's user is its own answer, so this is the
    lookup the plan and the record are both built from — not the first file the
    directory hands back. A unit that names no image is answered the reference
    its own build tags (images.reference_for), which is the fallback the
    single-image probe gave the whole directory.
    """
    found: dict[str, str] = {}
    for path in sorted(units_dir(name, escaped_ref).glob("*.container")):
        unit = unitsource.parse(path)
        declared = unit.one("Container", "Image")
        found[unit.stem()] = (
            declared.strip() if declared and declared.strip() else images.reference_for(name)
        )
    return found


def _owner_plan(name: str, record, escaped_ref: str | None) -> list[str]:
    """The images a probe still owes this record, and `[]` when it owes none.

    Not probed at all (`owner_uid is None`) is every distinct image in the
    directory; after that, only the units the record does not answer: one it
    holds no entry for, or one whose `Image=` has changed since its pair was
    read from that image.
    """
    unit_images = _installed_images(name, escaped_ref)
    if record.owner_uid is None or record.owner_gid is None:
        return sorted(set(unit_images.values())) or [images.reference_for(name)]
    return sorted(
        {image for stem, image in unit_images.items() if record.answer_for(stem, image) is None}
    )


def _record_owners(current, name: str, escaped_ref: str | None,
                   probed: dict[str, tuple[int, int]]) -> None:
    """Write the probe's answers into the record: the service-level anchor and,
    when the units name more than one image, the per-unit map the renderer
    answers each unit from (ADR-0019).

    Two shapes on purpose. A service whose units name one image keeps exactly
    the record it has always had — `owner_uid`/`owner_gid`, the drift anchor
    (ticket 277) and the field an operator edits by hand — plus `owner_image`,
    so a unit that later names another image is the probe's condition again
    rather than a unit that pair answers. Only a service whose units DISAGREE
    grows `owner_units`, and its anchor stays the first unit's pair, so the
    single-number fields never disappear and never change meaning.
    """
    unit_images = _installed_images(name, escaped_ref)
    pairs: dict[str, tuple[str, int, int]] = {}
    for stem, image in sorted(unit_images.items()):
        if image in probed:
            uid, gid = probed[image]
        else:
            held = current.answer_for(stem, image)
            if held is None:
                raise errors.GuardenError(
                    f"{name}: the registry entry holds no probed image user for the unit "
                    f"{stem} after the probe, so that unit's line has no source",
                    errors.HOST_NOT_AS_ASSUMED,
                )
            uid, gid = held
        pairs[stem] = (image, uid, gid)
    if pairs and len({image for image, _, _ in pairs.values()}) > 1:
        image, uid, gid = pairs[sorted(pairs)[0]]
        current.owner_uid, current.owner_gid = uid, gid
        current.owner_image = image
        current.owner_units = {
            stem: registry.OwnerUnit(image=owned, uid=owned_uid, gid=owned_gid)
            for stem, (owned, owned_uid, owned_gid) in sorted(pairs.items())
        }
        return
    if pairs:
        image, uid, gid = next(iter(pairs.values()))
    else:
        # No unit installed at all: the reference this service's build tags,
        # which is the answer the single-image probe gave a directory with no
        # `Image=` in it.
        image = images.reference_for(name)
        uid, gid = probed[image]
    current.owner_uid, current.owner_gid = uid, gid
    current.owner_image = image
    current.owner_units = {}


def probe_image(name: str, record, reference: str) -> tuple[int, int]:
    """The uid and gid THIS image declares, read at first start — one image at
    a time, because a service's units may name several (ADR-0019).

    `podman image inspect` gives `Config.User` — a number, a `uid:gid`, a name,
    or nothing — and every shape is resolved by ONE table (ADR-0019):

        `Config.User`     the answer
        ----------------  --------------------------------------------------
        empty             the entrypoint's handoff, else (0, 0)
        `0`, `root`       the same row: one declaration, one path
        a number          that uid; its gid from `:gid`, its passwd row, or 0
        a name            that passwd row, then `:group` or the row's own gid

    The last two rows read the image's OWN `/etc/passwd` and `/etc/group`, by
    running the image as container root: a probe that started the container as
    the declared user could not answer the one case that matters, an image
    whose declared user does not exist in it. A missing image is pulled first,
    once, because the start that asked for it needs the image either way.

    Exit `1` when the image is not on the host and cannot be pulled — the
    filesystem — and `2` when the image names a user or group it does not
    carry, or a uid or gid field of those files is not the number it has to
    be: the declaration is the input, and it is rejected where it is
    visible. Every one of these is one line naming the service (spec 1.2).
    """
    user, entrypoint, command = _image_config(name, record, reference)
    declared = user
    if _is_root_declaration(declared):
        # The stock postgres and alpine shape, and the two spellings of it: no
        # `USER` at all, `USER 0`, and `USER root` are one declaration — this
        # container runs its entrypoint as container root — so all three take
        # this row. The answer is the handoff the entrypoint names (the app
        # user a gosu or su-exec would switch to) and never a passwd row picked
        # by itself: every row of a base image is a system account, and a pin
        # on one would put init on a uid the application never asked for — on
        # an image with no `USER` line the pin IS what pid 1 runs as (measured,
        # t351: 2000 under `keep-id:uid=2000`), and on `USER root` the line
        # would map a number the entrypoint drops away from while init stays
        # root (measured, t352: pid 1 = 0 under `keep-id:uid=3000`). Either
        # way the application never asked for that account. Nothing defensible
        # falls out, and this is the record for it:
        # container root, which the default map already moves onto the service
        # identity, so no line is rendered and the service runs exactly as it
        # did before ADR-0019 (the keep-id map for uid=0 was measured to carry
        # only the pinned pair, which would stop an entrypoint that drops
        # privileges rather than fix its owner).
        handoff = _entrypoint_user(name, record, reference, [*entrypoint, *command])
        if handoff is None:
            return (0, 0)
        declared = handoff
    uid_text, separator, gid_text = declared.partition(":")
    if _is_number(uid_text):
        uid = int(uid_text)
        if separator:
            if _is_number(gid_text):
                return (uid, int(gid_text))
            # A numeric uid with a name for its group. The group database is
            # the only one this row reads: /etc/passwd is not opened for a
            # `uid:groupname` declaration, which is one `podman run` per probe
            # saved on the shape that declares its group by name.
            group = _image_file(name, record, reference, "/etc/group")
            if group is None:
                raise _cannot_run(name, record, reference, gid_text)
            found = _named(group, gid_text)
            if found is None:
                raise _no_such_group(name, reference, gid_text)
            where = f"the gid of the group {gid_text!r} in /etc/group"
            return (uid, _number(name, reference, found[2], where))
        passwd = _image_file(name, record, reference, "/etc/passwd")
        if passwd is None:
            # The read FAILED, which is not "this uid has no passwd row": the
            # row is what says whether the image carries one, and a file the
            # host could not read leaves the question unanswered (spec 1.2).
            raise _cannot_run(name, record, reference, declared)
        entry = _uid_entry(passwd, uid)
        if entry is not None:
            where = f"the gid of uid {uid} in /etc/passwd"
            return (uid, _number(name, reference, entry[3], where))
        # A number the image's passwd does not carry is what podman runs the
        # container with a gid of 0 for, and the line has to map the gid the
        # container will actually have.
        return (uid, 0)
    # A name: the image's own databases decide both numbers.
    passwd = _image_file(name, record, reference, "/etc/passwd")
    if passwd is None:
        raise _cannot_run(name, record, reference, declared)
    entry = _named(passwd, uid_text)
    if entry is None:
        raise errors.GuardenError(
            f"{name}: the image {reference} declares the user {declared!r}, which its "
            "/etc/passwd does not name",
            errors.REJECTED_INPUT,
        )
    # The row must carry the fields this branch reads: the uid at index 2 and
    # — where the declaration names no group of its own — the gid at index 3.
    # A row that stops short of the gid (`app:x:1000`) is the image's own
    # declaration, incomplete, and an incomplete declaration is refused where
    # it is visible, the same way a gid that is not a number is (spec 1.2: one
    # line, exit `2`). It used to be an `IndexError` out of the probe instead
    # (measured, t352).
    uid_where = f"the uid of the user {uid_text!r} in /etc/passwd"
    uid_text_read = _row_field(name, reference, entry, 2, "uid", "/etc/passwd", uid_text)
    if not separator:
        gid_where = f"the gid of the user {uid_text!r} in /etc/passwd"
        gid_text_read = _row_field(name, reference, entry, 3, "gid", "/etc/passwd", uid_text)
        return (_number(name, reference, uid_text_read, uid_where),
                _number(name, reference, gid_text_read, gid_where))
    uid = _number(name, reference, uid_text_read, uid_where)
    if _is_number(gid_text):
        return (uid, int(gid_text))
    group = _image_file(name, record, reference, "/etc/group")
    if group is None:
        raise _cannot_run(name, record, reference, gid_text)
    found = _named(group, gid_text)
    if found is None:
        raise _no_such_group(name, reference, gid_text)
    where = f"the gid of the group {gid_text!r} in /etc/group"
    return (uid, _number(name, reference, found[2], where))


def _row_field(name: str, reference: str, row: list[str], index: int, field: str,
               database: str, subject: str) -> str:
    """One field of a passwd or group row, or a refusal when the row does not
    carry it.

    A row is a list of fields, and the resolver reads the uid at index 2 and
    the gid at index 3 of a passwd row. A row that stops short of them —
    `app:x:1000` names a user and a uid and no gid — says nothing about the
    gid the container would run with, so it is the image's own declaration and
    it is incomplete.

    **A missing field is the same class as a field that is not a number**, and
    the refusal is the same refusal: one line naming the service, the
    database and the field, exit `2` (spec 1.2). The difference is only that
    the missing one was an `IndexError` out of the probe — a traceback where
    the spec promises one line — while the other was already refused
    (measured, t352: `app:x:1000` came back as `IndexError: list index out of
    range` from `entry[3]`).
    """
    if len(row) > index:
        return row[index]
    raise errors.GuardenError(
        f"{name}: the image {reference} carries {subject!r} in its {database} without "
        f"a {field}, and a uid or a gid is a field of that row",
        errors.REJECTED_INPUT,
    )


def _cannot_run(name: str, record, reference: str, declared: str) -> errors.GuardenError:
    """The image could not be run to resolve the name it declares: the host
    cannot execute what it is being asked about (spec 1.2, exit 1)."""
    return errors.GuardenError(
        f"{name}: the image {reference} declares {declared!r} and could not be run to "
        f"resolve it",
        errors.HOST_NOT_AS_ASSUMED,
    )


def _no_such_group(name: str, reference: str, group: str) -> errors.GuardenError:
    return errors.GuardenError(
        f"{name}: the image {reference} declares the group {group!r}, which its "
        "/etc/group does not name",
        errors.REJECTED_INPUT,
    )


def _is_number(value: str) -> bool:
    """Whether a uid or gid field is a number — THE predicate, the one every
    field the resolver reads goes through: both halves of `Config.User` and
    every uid/gid field of the image's own `/etc/passwd` and `/etc/group`.

    `isdecimal`, not `isdigit`: every decimal digit is one `int()` accepts
    (`int('٣')` is 3), while `isdigit` also counts the superscripts and
    fractions `int()` refuses — `'²'.isdigit()` is True and `int('²')`
    raises ValueError. A guard that is a strict superset of the `int()` behind
    it lets a field through the guard and kills it in the conversion, which is
    what an image-controlled field did: a passwd uid of `²` walked out of
    `weedr service start` as a traceback instead of the refusal it is
    (measured, t352).
    """
    return value.isdecimal()


def _number(name: str, reference: str, value: str, where: str) -> int:
    """One uid or gid field read out of the image's OWN passwd or group.

    Every one of them is a field of a file the image wrote, so a field that is
    not a number is the image's declaration rejected where it is visible: an
    `int()` allowed to raise instead walks out of the probe as a traceback, and
    the probe promises one line naming the service (spec 1.2). The check is
    `_is_number` and not a `try`, because the same predicate decides which
    fields the resolver treats as numbers at all — and while that predicate
    was `isdigit` the equivalence was false, `isdigit` being a superset of
    what `int()` takes (see `_is_number`).
    """
    if not _is_number(value):
        raise errors.GuardenError(
            f"{name}: the image {reference} carries {value!r} as {where}, and a uid "
            "or a gid is a number",
            errors.REJECTED_INPUT,
        )
    return int(value)


def _named(document: str, name: str) -> list[str] | None:
    """A passwd or group record by its name, or `None` when the databases do
    not carry one.

    **A row is only a row for the fields it carries.** The passwd row
    `app:x:1000` names a user and a uid and stops: the gid the container
    would run with is a field of that row which the row does not carry, and
    the caller read it out of the row unguarded — so the short row came back
    as an `IndexError` out of `weedr service start` (measured, t352), a
    traceback where spec 1.2 promises one line.

    A missing field is the same class of the image's own declaration as a
    field that is not a number, and the refusal is the same refusal
    (ADR-0019). So the reader answers with the row it found and the CALLER
    checks that the row carries the fields it is about to read, naming the
    service and the field when it does not.
    """
    for line in document.splitlines():
        fields = line.split(":")
        if len(fields) >= 3 and fields[0] == name:
            return fields
    return None


def _uid_entry(passwd: str, uid: int) -> list[str] | None:
    for line in passwd.splitlines():
        fields = line.split(":")
        if len(fields) >= 4 and fields[2] == str(uid):
            return fields
    return None


def _image_config(name: str, record, reference: str) -> tuple[str, list[str], list[str]]:
    """`Config.User`, `Config.Entrypoint` and `Config.Cmd` from the service
    user's own store, pulling once if the image is not there yet.

    The whole `inspect` document rather than a `--format` template: the three
    fields are three shapes (a string and two lists) and JSON is the one
    spelling that carries all three without the template's own escaping
    standing between the value and the reader. All three from one call because
    the empty-user case needs the other two."""
    result = _podman(name, record, "image", "inspect", reference)
    if not result.ok:
        pull = _podman(name, record, "pull", reference)
        if not pull.ok:
            raise errors.GuardenError(
                f"{name}: the image {reference} is not in {name}'s podman store and podman "
                f"pull failed: {_detail(pull)}",
                errors.HOST_NOT_AS_ASSUMED,
            )
        result = _podman(name, record, "image", "inspect", reference)
        if not result.ok:
            raise errors.GuardenError(
                f"{name}: podman could not read {reference} after pulling it: {_detail(result)}",
                errors.HOST_NOT_AS_ASSUMED,
            )
    try:
        document = json.loads(result.stdout)
    except ValueError as exc:
        raise errors.GuardenError(
            f"{name}: podman image inspect {reference} answered a document that is not JSON: "
            f"{errors.oneline(str(exc))}",
            errors.HOST_NOT_AS_ASSUMED,
        ) from None
    items = document if isinstance(document, list) else [document]
    for item in items:
        if not isinstance(item, dict):
            continue
        config = item.get("Config") or {}
        if not isinstance(config, dict):
            continue
        user = config.get("User")
        return (
            user.strip() if isinstance(user, str) else "",
            _strlist(config.get("Entrypoint")),
            _strlist(config.get("Cmd")),
        )
    raise errors.GuardenError(
        f"{name}: podman image inspect {reference} carries no Config to read a user from",
        errors.HOST_NOT_AS_ASSUMED,
    )


def _strlist(value) -> list[str]:
    if isinstance(value, list) and all(isinstance(item, str) for item in value):
        return value
    return []


# The handoff a root-then-drop entrypoint makes: `gosu postgres …` or
# `su-exec app …`, the two spellings that mean "and then run as this user".
# The token after the command is the whole answer, and it is looked up in the
# image's own passwd rather than trusted as a number.
#
# **The target may carry a group after a colon** — `postgres:postgres` is what
# `gosu` and `su-exec` both accept, and the stock postgres image spells its
# entrypoint that way. The resolver already understands the colon (the
# declaration is split on its first colon before the number and the name
# branches are taken), so the two spellings of this rule — the in-word form
# and the exec form — must accept the SAME set of targets. They used not to:
# the in-word form took the user part and went on, and the exec form's
# pattern had no colon in it at all, so `ENTRYPOINT ["su-exec",
# "postgres:postgres"]` was SKIPPED — the probe answered "no handoff",
# recorded root, rendered no line and printed nothing, and the application's
# uid landed in the subuid band (ticket 277). A silent wrong answer, where
# the rule's own table promises a refusal.
#
# One pattern, used by both, so the two spellings cannot drift apart again.
HANDOFF_TARGET = r"(?:[A-Za-z_][A-Za-z0-9_.\-]*|\d+)(?::(?:[A-Za-z_][A-Za-z0-9_.\-]*|\d+))?"
HANDOFF = re.compile(r"(?:^|[\s;|&])(?:gosu|su-exec)\s+(" + HANDOFF_TARGET + ")")

# The same command and the same user as TWO argv elements, which is how an OCI
# image spells them: `ENTRYPOINT ["su-exec", "app"]` puts them in separate
# elements, so a scan that looks for `gosu <user>` inside one word never sees
# them together — the probe answered "no handoff" without having looked and
# recorded root as an answer (t351's kidexec). The next element is taken only
# when it is the token `HANDOFF` would have captured, so a handoff command
# followed by something that is not a user (`gosu --help`, a stray `--`) is
# skipped rather than answered with a name the image's passwd will refuse.
HANDOFF_COMMANDS = frozenset({"gosu", "su-exec"})
HANDOFF_USER = re.compile(HANDOFF_TARGET)


def _entrypoint_user(name: str, record, reference: str, argv: list[str]) -> str | None:
    """The user the entrypoint hands execution to, and only that (ADR-0019).

    Asked of the words of `Entrypoint`/`Cmd` first — `sh -c 'exec gosu app …'`
    carries the name inside one element, and the exec form
    `["su-exec", "app", …]` carries it as the word after a bare handoff
    command, with or without a `user:group` spec — and then of every `.sh`
    script ANY of those words names, at whatever position it sits: the stock
    supervisor shape
    `["/sbin/tini", "--", "/docker-entrypoint.sh"]` names its script second,
    and a read gated on `argv[0].endswith(".sh")` never opened it, so the
    probe answered "no handoff" from having looked at nothing. **Only a `.sh`
    name is read**: a word naming a script that does not end in `.sh` is not
    opened, because reading every argv element as a script would refuse every
    image — the gate is the code's narrowing, and it is the narrowing this
    docstring states. A passwd row
    alone is never the answer: an entrypoint that is the application itself
    declares nothing to hand off to, and choosing a row would pin the line
    onto a uid nobody asked for. None means "no defensible user", which the
    caller records as root — a script that could not be READ raises instead,
    because that is the host failing to answer and not an answer of "nobody".
    """
    for index, word in enumerate(argv):
        if word in HANDOFF_COMMANDS:
            if index + 1 < len(argv) and HANDOFF_USER.fullmatch(argv[index + 1]):
                return argv[index + 1]
            continue
        found = HANDOFF.search(word)
        if found:
            return found.group(1)
    for word in argv:
        if not word.endswith(".sh"):
            continue
        script = _image_file(name, record, reference, word)
        if script is None:
            raise _cannot_run(name, record, reference, word)
        found = HANDOFF.search(script)
        if found:
            return found.group(1)
    return None


# The entrypoint name resolved before `cat` is handed it: PATH first, then the
# name itself. A bare entrypoint — `docker-entrypoint.sh`, the stock postgres
# and mysql shape — is a name the image carries on its PATH while its WORKDIR
# is somewhere else entirely, and `cat` alone resolves that name against the
# WORKDIR instead, so the read failed for exactly the images ADR-0019 exists
# for: the failure was read as "no handoff", and the record settled on root
# with nothing printed. The literal-name fallback is the other half of what a
# name means — `bin/entry.sh` is read against the WORKDIR, where a shell would
# read it too.
RESOLVE_THEN_CAT = """found=$(command -v "$1")
if [ -n "$found" ]; then
    target=$found
else
    target=$1
fi
cat -- "$target"
"""


def _image_file(name: str, record, reference: str, path: str) -> str | None:
    """The image's own file, read by running the image as container root —
    `--user 0` and not the declared user, for the reason probe_image gives.

    `None` is a read that FAILED and never an answer: podman could not run,
    the file is not there, the name resolves to nothing. Every caller turns it
    into `_cannot_run`'s one line (spec 1.2), because reading it as "no such
    row / no handoff" is what settled the record on root while the host had
    simply not been able to look.

    A name with no slash goes through the shell above; a path — `/etc/passwd`,
    `/etc/group`, an entrypoint the image names absolutely — goes to `cat`
    verbatim, exactly as it always did.
    """
    if "/" in path:
        result = _podman(
            name, record, "run", "--rm", "--user", "0", "--entrypoint", "cat", reference, path
        )
    else:
        result = _podman(
            name,
            record,
            "run",
            "--rm",
            "--user",
            "0",
            "--entrypoint",
            "sh",
            reference,
            "-c",
            RESOLVE_THEN_CAT,
            "sh",
            path,
        )
    if not result.ok:
        return None
    return result.stdout


def _detail(result) -> str:
    text = result.stderr.strip() or result.stdout.strip()
    return errors.oneline(text) or f"{result.argv[0]} exited {result.returncode}"


def _podman(name: str, record, *argv: str):
    """podman as the service user, from the service's own home.

    The probe runs unprivileged as the service identity; the mutator's own hand
    stays on the unit write (ADR-0001).

    **`USER` and `LOGNAME` are named for the service, and that is measured
    rather than decoration — but the reason is NOT the one this file used to
    give.** The old text said "`runuser -u` swaps the uid but keeps the
    caller's environment, and the caller is root — so podman saw `USER=root`".
    **That was REFUTED by measurement on the golden VM** (util-linux 2.41.3,
    podman 5.7.0), and the refutation is recorded in `tool.py` where the
    scrub lives:

    ```
    $ runuser -u probe-svc -- env | grep -E '^(HOME|USER|LOGNAME)='
    HOME=/var/lib/guarden/services/probe-svc/home
    LOGNAME=probe-svc
    USER=probe-svc
    ```

    **`runuser` SETS `HOME`, `USER`, `LOGNAME`, `SHELL` and `PATH` for a
    non-root target and inherits everything ELSE verbatim.** The measurement
    that produced the refuted claim was `setpriv`, which this repository's own
    `tests/t350-keepid.sh` uses and which genuinely keeps the caller's
    environment — the comment named both tools and only the second behaved
    that way.

    **The mechanism it described is still true**, and that is what the scrub is
    for: podman's keep-id mapping reads the subid files keyed by `$USER`, and
    forcing `USER=root` into podman answers `cannot find UID/GID for user
    root: no subuid ranges found for user "root" in /etc/subuid` — measured.
    With `USER` named for the service the map is complete — measured on the
    golden: init uid/gid 10001/10001 under `keep-id:uid=10001,gid=10001`,
    three-row maps. A systemd user manager sets both for the service already;
    this is the same shape for the calls this program makes itself, and
    naming them is defence in depth against a caller that reaches podman by
    another route.

    **The environment the scrub actually changes is the one `runuser` really
    does inherit**: `XDG_RUNTIME_DIR`, `XDG_DATA_HOME`, `XDG_CONFIG_HOME`,
    `XDG_CACHE_HOME`, `DBUS_SESSION_BUS_ADDRESS`, `CONTAINERS_*`, `PWD` and
    `OLDPWD`. `tool.runuser_as` is where that is decided, and this call goes
    through it — so there is one place a `runuser -u` command is built and a
    second call site cannot miss the scrub."""
    home = paths.service_home(name)
    try:
        return tool.call(tool.runuser_as(name, "podman", *argv), cwd=home)
    except errors.GuardenError as exc:
        # Every failure `tool.call` reports here is bytes it could not read —
        # an image's own file or podman's own answer, which is what this run
        # was asked about — and the probe's contract is one line NAMING THE
        # SERVICE (spec 1.2), so the name is put on before it leaves.
        raise errors.GuardenError(f"{name}: {exc.message}", exc.code) from None


def _carries_owner_line(name: str, escaped_ref: str | None, record) -> bool:
    """Whether every installed unit already holds exactly the line the record
    renders FOR THAT UNIT — or holds none at all when the record renders it
    none. Anything else is a render that has not happened yet.

    **The answer is read from the DROP-IN, and not from the base unit**
    (ADR-0019). The pin lives in
    `/etc/containers/systemd/users/<uid>/<unit>.container.d/50-guarden-keepid.conf`
    and the base unit carries no `UserNS=` line at all, so a base unit that
    holds no line is the CORRECT state and not a missing one. Reading the
    base unit would reinstall the units on every single start — churn, and a
    reinstall that would overwrite nothing but would also mean guarden and an
    admin whose `90-admin.conf` says something different fight over the file
    for ever.

    What this therefore answers is one question per unit: **does the file
    guarden owns in that unit's drop-in directory carry exactly the line the
    record renders for that unit?** A unit the record answers with no line
    must have NO drop-in of guarden's own — a stale pin left behind by a
    record that changed is as wrong as a missing one, and the mapping it
    carries would be in force.

    The admin's own `90-admin.conf` is **not read and not compared**: it is
    the human's file, guarden never writes it, and the two of them coexist
    by name order alone. A different `UserNS=` in it is the admin's decision
    and it wins — that is the model, not a drift.
    """
    files = sorted(units_dir(name, escaped_ref).glob("*.container"))
    if not files:
        return False
    unit_images = _installed_images(name, escaped_ref)
    for path in files:
        unit = unitsource.parse(path)
        want = render.owner_line(record, unit.stem(), unit_images[unit.stem()])
        found = _installed_owner_line(record, unit.stem(), escaped_ref)
        if found != want:
            return False
    return True


def _installed_owner_line(record, stem: str, escaped_ref: str | None) -> str | None:
    """The line guarden's own drop-in carries for this unit, or `None`.

    The file is named for the unit **the generator reads** — the entry stem,
    so an instance's `<unit>-<escaped-ref>` and not the `<unit>` its own
    directory holds — and its content is the one line guarden wrote. A file
    that is not there, or that carries no `UserNS=` line, is `None`; a file
    that carries one is that line.
    """
    if not record.uid:
        return None
    unit = units.entry_stem(stem, escaped_ref)
    directory = paths.admin_dropin_dir(record.uid, unit)
    dropin = directory / paths.KEEPID_DROPIN
    if not dropin.is_file():
        return None
    try:
        parsed = unitsource.parse(dropin)
    except errors.GuardenError:
        return None
    return parsed.one("Container", "UserNS")


@contextmanager
def _unit_source(name: str, record, escaped_ref: str | None = None) -> Iterator[Path]:
    """Where `units.install` gets its source for this service: the tree the units
    being re-rendered were installed from — an instance's own home first when
    this start is an instance's, then the service's home, and the module's
    shipped tree for a service a module created. The same sources the installs
    that created these units read from, looked up in the same order the
    directory they are being installed into resolves.

    A CONTEXT MANAGER, because the service's own home is not readable by the
    renderer (it is `0700` to that service) and has to be staged for it
    (ADR-0012, ticket 301): the staged tree must exist for the whole install
    and go away with it. Handing the caller the staged PATH without staging it
    would read a tree that is not there, and handing over the manager object
    instead of entering it would read a path named
    "<contextlib._GeneratorContextManager object at 0x…>" — a manifest that
    "does not exist" for a reason that has nothing to do with the manifest.
    """
    homes = [paths.service_home(name)]
    if escaped_ref:
        homes.insert(0, paths.instance_home(name, escaped_ref))
    for home in homes:
        if _manifest_in(home).is_file():
            with _render_source(home) as staged:
                yield staged
            return
    if record.installed_by:
        shipped = modules_mod.source_of(record.installed_by, name)
        if _manifest_in(shipped).is_file():
            yield shipped
            return
    raise errors.GuardenError(
        f"{name}: no manifest in {homes[-1]} and no module source, so its units cannot be "
        "re-rendered with the probed line",
        errors.HOST_NOT_AS_ASSUMED,
    )


def stop_units(name: str, escaped_ref: str | None = None) -> None:
    # `units_of` reports what the instance's own directory holds — `web` — while
    # the entry podman's generator turned into a unit is `web-<escaped-ref>`, so
    # every start and stop translates the one into the other through
    # `units.entry_stem`, the rule's one home, and nowhere else.
    for unit in units_of(name, escaped_ref):
        _unit(name, "stop", units.entry_stem(unit, escaped_ref))


def start_units(name: str, escaped_ref: str | None = None) -> None:
    """The other half of `stop_units`, and in the same user's manager.

    A fork and a rollback are stop/swap/start, so something has to start the
    units again on the way out, and a verb that started them through a different
    mechanism would be a second way to start a service. This starts what the home
    declares and says nothing about a service that declares nothing: whether an
    empty unit directory is a failure is a question for the verb that promises a
    start, and `weedr service start` is the only one.
    """
    # Reload first: a `.container` file is a DECLARATION, and the unit exists only
    # once quadlet's generator has run. The manager has not reloaded since the
    # units were installed, so `systemctl --user start` answers "Unit not found"
    # for a service that is fully declared — which is the first of the two cases
    # _unit's own docstring names and says is the host, not the program.
    tool.call(["systemctl", "--user", "--machine", f"{name}@", "daemon-reload"])
    for unit in units_of(name, escaped_ref):
        _unit(name, "start", units.entry_stem(unit, escaped_ref))


def _unit(name: str, verb: str, unit: str) -> None:
    """One unit in the service's own manager, and exit 5 means one thing per verb.

    A `.container` file in the home is a declaration, not a systemd unit: the unit
    exists once the generator has made one, and until then `systemctl ... stop
    <unit>` answers `Failed to stop <unit>: Unit <unit> not loaded.` and exits 5.
    **For a stop that is the state the verb asked for** — not running is what a
    stop is for — so 5 is not a failure, it is measured, and a fork that refused
    would refuse to clone a volume because of a unit that was never there.

    **For a start the same answer is the opposite of what was asked.** Nothing is
    running and the caller asked for something running, so exit `0` here reports
    work that did not happen, which is the one thing `0` may not mean (spec 1.2).
    The declaration is in the service's own home, so this is not a unit nobody ever
    wrote: either the manager has not reloaded since the units were installed and
    the generator has not run, or the unit is there and the manager will not load
    it. Both are the host not being in the state the request assumed, both are `1`,
    and neither is distinguished from the other by anything guarden can see — so the
    line names the unit and quotes what systemd said rather than guessing which.

    A manager that cannot be reached (exit 1 with "Transport endpoint is not
    connected") means the user's systemd manager is not running — the service was
    never started, so the units are effectively already stopped. For a stop this is
    the desired state. For a start it would be a failure, but start reloads the
    manager first, so this case does not occur there.
    """
    result = tool.call(["systemctl", "--user", "--machine", f"{name}@", verb, unit])
    if result.returncode == 0:
        return
    if result.returncode == 5 and verb == "stop":
        return
    # Manager not running: service was never started, units are effectively stopped.
    if result.returncode == 1 and verb == "stop":
        stderr = result.stderr.strip()
        if "Transport endpoint is not connected" in stderr:
            return
    detail = errors.oneline(result.stderr.strip() or result.stdout.strip())
    raise errors.GuardenError(
        f"{name}: systemctl {verb} of the unit {unit} exited {result.returncode}"
        + (f": {detail}" if detail else ""),
        errors.HOST_NOT_AS_ASSUMED,
    )


def remove(resolved, config, now: str) -> list[str]:
    """Take a service, or one instance of one, away. Returns the lines to print."""
    record = registry.load(resolved.name)
    if record is None:
        raise errors.GuardenError(
            f"{resolved.name} has no registry entry, so there is nothing to remove",
            errors.HOST_NOT_AS_ASSUMED,
        )
    if resolved.ref:
        return _remove_instance(resolved, record)
    return _remove_service(resolved, record, now)


def _gated_refusal(name: str, track_name: str) -> None:
    """A refusal no caller can switch off with an argument.

    spec 5.3: there is no flag that overrides this, because a sudoers rule
    granting the verb cannot tell that flag from any other argument. The only way
    to make it possible is for the operator to remove the root-owned marker, and
    `hose` never reads it: the refusal is enforced here, root-side.
    """
    if not paths.ALLOW_GATED_DROP.exists():
        raise errors.GuardenError(
            f"{name} is on the gated track {track_name!r}, so removing it is refused; the "
            f"only way to allow it is for the operator to remove {paths.ALLOW_GATED_DROP}",
            errors.HOST_NOT_AS_ASSUMED,
        )


def _remove_service(resolved, record, now: str) -> list[str]:
    if resolved.track.gated:
        _gated_refusal(resolved.name, resolved.track.name)
    if record.instances:
        live = ", ".join(sorted(record.instances))
        raise errors.GuardenError(
            f"{resolved.name} still has instances ({live}); remove them first, one at a "
            f"time, with `weedr service remove <name>/<ref>`",
            errors.HOST_NOT_AS_ASSUMED,
        )

    printed = [f"removed {resolved.name}"]
    stop_units(resolved.name)

    when = _stamp(now)
    for volume in record.volume_list():
        source = paths.volume(resolved.name, volume.kind, volume.name)
        if not source.exists():
            continue
        target = paths.removed(resolved.name, when, volume.name)
        target.parent.mkdir(parents=True, exist_ok=True)
        os.rename(source, target)
        printed.append(f"moved the {volume.kind} volume {volume.name} to {target}")

    users.destroy(resolved.name, record.uid)
    _drop_admin_units(record.uid, printed)
    _drop(paths.service_tree(resolved.name))
    _drop(paths.ETC_SERVICES / resolved.name)
    _drop(paths.SHARED / resolved.name)
    basicauth_mod.drop(resolved.name)
    with conf.lock("registry"):
        registry.delete(resolved.name)
    printed.append("its snapper configurations are left for `soil storage` to remove")
    return printed


def _remove_instance(resolved, record) -> list[str]:
    printed = previews.forget(resolved, record)
    with conf.lock("registry"):
        registry.save(record, (0, users.group_id(GUARDEN_GROUP)))
    return printed


def _drop(path: Path) -> None:
    if path.is_dir():
        shutil.rmtree(path)
    elif path.exists():
        path.unlink()


def _drop_admin_units(uid: int, printed: list[str]) -> None:
    """The uid's admin path, with the human's own files left in it (ADR-0019).

    **The removal takes guarden's own file and leaves the admin's.** A
    `rmtree` of `/etc/containers/systemd/users/<uid>/` would delete the
    operator's `90-admin.conf` — a file guarden never wrote, never reads and
    never promised to keep, and the one place the admin's own decision
    about a container's user lives. Deleting it would make the admin's
    override vanish the moment the service was removed and come back, and
    there is no way to tell "the admin had nothing there" from "the admin
    had something there" afterwards.

    So the directory is emptied of what guarden wrote — the
    `50-guarden-keepid.conf` files, and the drop-in directories guarden
    created for them — and **every other file in it is left exactly where
    it is**. An empty directory guarden created and an empty directory the
    admin had are the same state, so the directory itself is removed only
    when nothing of the admin's is left in it.

    The instances' directories are the same: an instance's drop-in
    directory is named for the entry stem, and it is guarden's own file in
    it, so the same rule applies to them.
    """
    root = paths.ADMIN_UNITS / str(uid)
    if not root.is_dir():
        return
    kept = 0
    for path in sorted(root.rglob("*")):
        if path.is_file() and path.name != paths.KEEPID_DROPIN:
            kept += 1
    for path in sorted(root.rglob("*")):
        if path.is_file() and path.name == paths.KEEPID_DROPIN:
            path.unlink()
    # The directories guarden created for its own file go with it; a directory
    # that still holds one of the admin's files stays. Deepest first, so an
    # inner directory is gone before the one above it is asked whether it is
    # empty.
    for path in sorted(root.rglob("*"), key=lambda item: len(item.parts), reverse=True):
        if path.is_dir() and not any(path.iterdir()):
            shutil.rmtree(path, ignore_errors=True)
    if kept == 0 and root.is_dir() and not any(root.iterdir()):
        shutil.rmtree(root, ignore_errors=True)
    if kept:
        printed.append(
            f"left the admin's own drop-ins in {root} alone ({kept} file(s))"
        )


def _stamp(now: str) -> str:
    return now.replace("-", "").replace(":", "")
