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

import os
import shutil
import tempfile
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass, field
from pathlib import Path

from guarden import (
    conf,
    edges,
    errors,
    gate,
    names,
    paths,
    previews,
    projects,
    publications,
    registry,
    tool,
    units,
    users,
    volumes,
)
from guarden import manifest as manifest_mod
from guarden import modules as modules_mod
from guarden import overrides as overrides_mod

TREE_MODE = 0o700


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

# The build context: the files `podman build` reads besides the unit source.
#
# A Containerfile is the thing `weedr service build` exists to read, and it is
# not the unit source, so a home that copies only `.guarden/` and
# `compose.yaml` has no build context at all — `podman build .` in it answers
# `125` (no such file or directory) on every run. The file's own name is the
# one podman resolves when no `-f` is given, so it is the entry in this list.
# A `.dockerignore` is listed too, because a build that copies the whole home
# needs it to leave the rootless image store and the secret database out of the
# context — those are the two things in the home that are large and not the
# build's.
BUILD_INPUTS = (Path("Containerfile"), Path(".dockerignore"))


@dataclass(frozen=True)
class Source:
    """`--from`, resolved to something guarden owns rather than to a location."""

    kind: str
    project: str | None = None
    sha: str | None = None
    service: str | None = None
    module: str | None = None

    def directory(self) -> Path:
        if self.kind == "poke":
            return paths.STAGING / str(self.project) / str(self.sha)
        if self.kind == "module":
            return modules_mod.source_of(str(self.module), str(self.service))
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


def _source_label(source: Source) -> str:
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
    """
    if source.kind != "poke":
        return registry.SOURCE_MANUAL
    return (
        registry.SOURCE_GITOPS
        if str(source.project) in projects.load()
        else registry.SOURCE_MANUAL
    )


def create(resolved: names.Resolved, source: Source, config, now: str) -> Outcome:
    directory = _manifest_directory(source, resolved.name)
    manifest = manifest_mod.read(_manifest_in(directory))
    project = manifest.project or _project_from(source)
    outcome = Outcome(resolved=resolved)

    # Before identity, before the volumes, before the home: an edge the provider
    # does not offer, and a route host another service already holds, are the two
    # things in this ordering that would otherwise leave a system user and a
    # subvolume behind on the way out.
    edges.check(resolved.name, manifest, resolved.track.name, config)
    check_hosts(resolved.name, manifest, resolved.track)

    existing = registry.load(resolved.name)
    source_hash = _source_hash(directory) if source.kind == "poke" else ""
    if existing is not None and _converged(existing, resolved, manifest, project, source_hash):
        outcome.converged = True
        outcome.uid = existing.uid
        return outcome

    fresh = bool(resolved.escaped_ref) and (
        existing is None or resolved.escaped_ref not in existing.instances
    )
    if fresh and existing is not None:
        outcome.notes += previews.admit(resolved, existing, now)
    outcome.fresh_instance = fresh

    identity = users.ensure(resolved.name, paths.service_home(resolved.name))
    outcome.uid = identity.uid
    owner = users.tree_owner(identity)
    root_owner = (0, users.group_id(GUARDEN_GROUP))

    _make_tree(resolved.name, owner, resolved.escaped_ref)
    _copy_source(directory, resolved.name, owner)

    granted = overrides_mod.seeded(resolved.track, overrides_mod.load(resolved.name))
    overrides_mod.save(resolved.name, granted, root_owner)
    outcome.warnings = users.reconcile_groups(resolved.name, granted.groups)

    record = existing or registry.Registry(
        service=resolved.name,
        workload=names.workload_of(resolved.name, resolved.track.name),
        project=project,
        environment=resolved.track.name,
        uid=identity.uid,
        created=now,
        source=_source_label(source),
    )
    record.project = project
    record.environment = resolved.track.name
    record.uid = identity.uid
    # `provides` is written by the mutator at creation from the manifest, and it
    # is the only copy a consumer can read: the provider's own tree is 0700 to
    # the provider and loom runs as guarden.
    record.provides = list(manifest.provides)
    if source_hash:
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
    _ensure_admin_units(identity.uid)

    if resolved.escaped_ref and resolved.escaped_ref not in record.instances:
        # Recorded before the volumes exist, not after: an instance that is not in
        # the registry cannot be counted against the cap, reported by `list`, or
        # have a seed written against it by the fork in spec 5.3 step 12. `seed`
        # stays empty here — no fork has taken yet — and the instance's
        # publications are allocated below, once it exists.
        previews.register(resolved, record, now)

    _allocate(resolved, record, manifest, config, source)

    # spec 5.3 step 9: on an ungated track every `@sensitive` key nothing has been
    # planted for gets a value minted once, so a poke is never blocked on a human.
    # A gated track gets none — there a missing key is a gate failure, and
    # generating one would hide exactly what the gate is for.
    if not resolved.track.gated:
        gate.mint_generated(record, gate.schema_for(resolved.name), now)

    retention = volumes.retention_from(resolved.track, granted)
    for vol in manifest.state:
        volumes.create_state(resolved.name, vol, retention, owner, resolved.escaped_ref)
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
        with _render_source(directory) as staged:
            outcome.notes += units.install(staged, resolved.name)
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
    that is not a template name at all (anything with a `/`, a leading `.` or
    an upper-case letter in it) is §1.2's row "a name that breaks a rule", and
    it is `2` whatever the host holds — the same answer the same-shaped
    `add --from /tmp` gives (pinned by t250). An answer that names nothing where
    the installed set offered a choice is input too, so it is `2` as well.

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
        # No answer with nothing to answer *from* is the host's emptiness;
        # no answer with a set on the prompt is an input that named nothing.
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
    # directory, **as the service user and `0640`** — the way `units.install`
    # lands every rendered unit. The template is root-owned and installed, and a
    # copy that kept its `root:root 0644` was a file inside a `0700` home that
    # the service could neither read, chown nor remove — including from the
    # service's own podman generator, which is the process that has to read it
    # (AGENTS.md: nothing root-owned inside a service's home). This copy is what
    # `weedr service start` finds.
    quadlet_dir = units_dir(resolved.name, resolved.escaped_ref)
    quadlet_dir.mkdir(parents=True, exist_ok=True)
    for path in sorted(template_dir.rglob("*")):
        if path.is_file():
            target = quadlet_dir / path.relative_to(template_dir)
            conf.write_file(target, path.read_text(encoding="utf-8"), units.UNIT_MODE, owner)

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


def _allocate(resolved, record, manifest, config, source: Source) -> None:
    """Publications and route hosts, from the ranges the host declares.

    spec 7.4 and 4. One publication per container that gets one, allocated
    from `ingress.publication_range` and refused rather than shared, and one
    full host name per route label with the track's own prefix in front of it.
    An instance's publications are its own, so two previews of one service are
    both routable at once.
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
    holders = publications.host_holders(records)
    for route in manifest.routes:
        record.route_hosts[route.host] = publications.claim_host(
            route.host, resolved.track.host_prefix, holders, record.service
        )
        # Record the destination for this route (edge or tunnel)
        granted = overrides_mod.load(resolved.name) if resolved.name else None
        tunnel_labels = set(granted.expose_tunnel) if granted else set()
        track_expose = resolved.track.expose
        record.route_destinations[route.host] = (
            "tunnel" if route.host in tunnel_labels else track_expose
        )

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


def check_hosts(name: str, manifest: manifest_mod.Manifest, track) -> None:
    """Every route host this manifest would claim, checked before identity.

    Same reason `edges.check` runs where it does: a claim refused after the user
    and the tree exist leaves a system account and a home behind on the way out,
    and the diagnostic the caller gets is the same either way.
    """
    holders = publications.host_holders(_others(name))
    for route in manifest.routes:
        publications.claim_host(route.host, track.host_prefix, holders, name)


def _project_from(source: Source) -> str:
    """The project the `--from` source belongs to, never a path basename: under the
    new layout the staging directory's basename is a sha."""
    if source.kind == "poke":
        return str(source.project)
    record = registry.load(str(source.service))
    if record is None or not record.project:
        raise errors.GuardenError(
            f"--from {source.service} has no registry entry naming a project",
            errors.HOST_NOT_AS_ASSUMED,
        )
    return record.project


def _converged(
    record,
    resolved,
    manifest: manifest_mod.Manifest,
    project: str,
    source_hash: str = "",
) -> bool:
    if record.project != project or record.environment != resolved.track.name:
        return False
    if source_hash and record.source_hash != source_hash:
        return False
    if resolved.escaped_ref and resolved.escaped_ref not in record.instances:
        return False
    declared = dict.fromkeys(manifest.state, "state")
    declared.update(dict.fromkeys(manifest.bulk, "bulk"))
    if declared != {volume.name: volume.kind for volume in record.volumes.values()}:
        return False
    return all(
        record.volumes[vol].config == paths.snapper_config(resolved.name, vol, resolved.escaped_ref)
        for vol in manifest.state
    )


def _make_tree(name: str, owner: tuple[int, int], escaped_ref: str | None = None) -> None:
    """The whole tree, `0700` to the service user, with no carve-out for the home.

    The `0700` is what the scheme rests on: without it every service user reads
    every other service's state volumes straight off the host filesystem, and the
    per-consumer credentials and the uid-matched firewall rules stop being
    controls and become decoration. A service is `0700` as a unit — home, state,
    bulk and every instance's volumes — and **no config subvolume is ever
    created**, for any track, including a gitops-created production service.
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
        directories += [
            paths.instance_home(name, escaped_ref),
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

    `_copy_source` copies exactly these things out of a staging tree:
    `.guarden/`, `compose.yaml`, and the build context (`Containerfile` and
    `.dockerignore`). Those are the only inputs the renderer and the build
    verb read, so a hash over them is the exact predicate for "would the
    rendered units be the same as last time". Compare **source, not output**:
    a Containerfile build produces an image — hash the Containerfile content,
    not the built image. A compose render produces quadlets — hash the compose
    content, not the rendered quadlets.

    `deployed_sha` (the poke commit) is not: re-ingesting the same commit
    after editing the compose file is a change the operator made and the
    convergence check must see it.
    """
    import hashlib

    h = hashlib.sha256()
    # Every file _copy_source copies — the full set of render inputs.
    for rel in [".guarden", "compose.yaml", *BUILD_INPUTS]:
        path = directory / rel
        if path.is_dir():
            for f in sorted(path.rglob("*")):
                if f.is_file() and paths.SNAPSHOTS not in f.parts:
                    h.update(f.relative_to(directory).as_posix().encode())
                    h.update(f.read_bytes())
        elif path.is_file():
            # `rel` is a name and not only a string: the build inputs are
            # `Path`s, and a Containerfile that is present would have reached
            # here as one and ended the create with an AttributeError rather
            # than a hash (measured: t250, after the Containerfile was seeded).
            h.update(str(rel).encode())
            h.update(path.read_bytes())
    return h.hexdigest()


def _copy_source(directory: Path, name: str, owner: tuple[int, int]) -> None:
    """The repository's `.guarden/`, compose file and build context into a home.

    A repository ships either `compose.yaml` at its root or `.guarden/quadlet/`
    and exactly one of them, and this is the copy that makes
    `add --from <service>` a copy of that service's manifest and unit source
    rather than a re-derivation of them.

    **The whole tree, not the two files, because the build verb reads it.** A
    home that holds only `.guarden/` and `compose.yaml` is a home with no
    Containerfile, and `weedr service build` runs `podman build` with that home
    as its context — so a service whose unit source declares a build would fail
    with `125` (no such file or directory) on every run. The Containerfile is a
    build input and it lives beside the unit source, so the context is copied
    with them; the tree's own layout is unchanged, and the renderer still reads
    exactly what it read before.

    **What is not copied: the snapper subtree and anything root-owned.** The
    guard below walks the same `.snapshots` the service walk skips, because the
    home is not snapshotted today and a build context that carried snapper's
    read-only subvolume would be a context `podman build` cannot copy.
    """
    home = paths.service_home(name)
    if (directory / ".guarden").is_dir():
        shutil.copytree(directory / ".guarden", home / ".guarden", dirs_exist_ok=True)
    for relative in ("compose.yaml", *BUILD_INPUTS):
        source = directory / relative
        target = home / relative
        if source.is_dir():
            shutil.copytree(source, target, dirs_exist_ok=True)
        elif source.is_file():
            shutil.copy2(source, target)
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


def _reap_staging(parent: Path) -> None:
    """Take the staging trees no run is holding any more.

    The `rmtree` this replaces deleted `render-source/<source>` whatever another
    run was doing with it — the whole of the race — and this keeps only the half
    of that behaviour nothing can be reading. A run's tree is named after the
    pid that staged it, so a tree whose creator no longer answers is a run that
    was killed before its own `finally` could clean up after it, and an entry
    that is not `<pid>-<random>` at all is not a run's tree but a leftover of
    the shared layout this replaces (where `render-source/<source>` *was* the
    tree). A live run answers for its pid, so a concurrent run's tree is never a
    candidate: `kill(pid, 0)` answers across uids, so `EPERM` means alive too.
    """
    for entry in list(parent.iterdir()):
        creator, sep, _rest = entry.name.partition("-")
        if sep and creator.isdigit():
            if int(creator) == os.getpid():
                continue
            try:
                os.kill(int(creator), 0)
                continue
            except ProcessLookupError:
                pass
            except PermissionError:
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
    which is what `_reap_staging` answers for.
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
                shutil.copytree(source, target)
            elif source.is_file():
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, target)
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
    """Reconcile the existence of podman's uid-scoped search path and nothing
    inside it: a regenerated unit must not clobber a root-owned drop-in, which is
    what that path being searched after the home's own directory buys (ADR-0003)."""
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


def stop_units(name: str, escaped_ref: str | None = None) -> None:
    for unit in units_of(name, escaped_ref):
        _unit(name, "stop", unit)


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
        _unit(name, "start", unit)


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
    _drop(paths.ADMIN_UNITS / str(record.uid))
    _drop(paths.service_tree(resolved.name))
    _drop(paths.ETC_SERVICES / resolved.name)
    _drop(paths.SHARED / resolved.name)
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


def _stamp(now: str) -> str:
    return now.replace("-", "").replace(":", "")
