"""A service's lifecycle: create it, and take it away again.

A service's tree comes from exactly one of two places, and **never from a path an
argument names** (spec 5.3). `ingest` takes `poke <project>@<sha>` and the
system resolves that pair to `/var/lib/guarden/staging/<project>/<sha>` itself;
`add` takes a service name and copies that service's own manifest and unit
source out of its home. There is no `--from <path>`, because a path is the one
argument in this interface that can mean something other than what it says.

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
ADMIN_UNITS_MODE = 0o755
GUARDEN_GROUP = "guarden"


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


def parse_from(values: list[str]) -> Source:
    """`--from` has exactly two accepted forms, and the error names both."""
    if len(values) == 1:
        return Source(kind="service", service=names.validate(values[0], "--from service"))
    if len(values) == 2 and values[0] == "poke":
        project, at, sha = values[1].partition("@")
        if not project or not at or not sha or "/" in sha or ".." in sha:
            raise errors.GuardenError(
                f"--from poke takes <project>@<sha>, and {values[1]!r} is not that"
            )
        return Source(kind="poke", project=project, sha=sha)
    raise errors.GuardenError(
        "--from takes either <service> or `poke <project>@<sha>`, and "
        + (" ".join(repr(value) for value in values) or "nothing")
        + " is neither"
    )


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


def create(resolved: names.Resolved, source: Source, config, now: str) -> Outcome:
    directory = _manifest_directory(source, resolved.name)
    manifest = manifest_mod.read(_manifest_in(directory))
    project = manifest.project or _project_from(source)
    outcome = Outcome(resolved=resolved)

    # Before identity, before the volumes, before the home: an edge the provider
    # does not offer, and a route host another service already holds, are the two
    # things in this ordering that would otherwise leave a system user and a
    # subvolume behind on the way out.
    edges.check(resolved.name, manifest)
    check_hosts(resolved.name, manifest, resolved.track)

    existing = registry.load(resolved.name)
    if existing is not None and _converged(existing, resolved, manifest, project):
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
        source=registry.SOURCE_GITOPS if source.kind == "poke" else registry.SOURCE_MANUAL,
    )
    record.project = project
    record.environment = resolved.track.name
    record.uid = identity.uid
    # `provides` is written by the mutator at creation from the manifest, and it
    # is the only copy a consumer can read: the provider's own tree is 0700 to
    # the provider and loom runs as guarden.
    record.provides = list(manifest.provides)
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
        _record(
            record,
            vol,
            "state",
            volumes.create_state(resolved.name, vol, retention, owner, resolved.escaped_ref),
        )
    for vol in manifest.bulk:
        volumes.create_bulk(resolved.name, vol, owner, resolved.escaped_ref)
        _record(record, vol, "bulk", None)

    # spec 5.3 step 10, after step 9: a `@sensitive` key nothing has planted for is
    # minted first, so an edge adopting `DB_PASSWORD` reuses that value rather than
    # minting a second one over it. On a gated track step 9 mints nothing and the
    # edge's own value is what exists.
    outcome.warnings += edges.install(record, manifest)

    with conf.lock("registry"):
        registry.save(record, root_owner)

    # spec 5.3 step 11: the service's own units are installed, so a deploy has
    # something to start. Without this a service existed, was listed and held its
    # volumes, and `weedr service start` refused it with "has no unit to start".
    # **After** the registry is saved: `units.install` reads the record for the
    # uid it installs under, and rendering before the entry exists answered "there
    # is no registry entry for <service>".
    if source.kind != "module":
        outcome.notes += units.install(directory, resolved.name)
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


def _converged(record, resolved, manifest: manifest_mod.Manifest, project: str) -> bool:
    if record.project != project or record.environment != resolved.track.name:
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
        conf.set_owner(path, owner)
        os.chmod(path, TREE_MODE)


def _copy_source(directory: Path, name: str, owner: tuple[int, int]) -> None:
    """The repository's `.guarden/` and compose file into the service's home.

    A repository ships either `compose.yaml` at its root or `.guarden/quadlet/`
    and exactly one of them, and this is the copy that makes
    `add --from <service>` a copy of that service's manifest and unit source
    rather than a re-derivation of them.
    """
    home = paths.service_home(name)
    if (directory / ".guarden").is_dir():
        shutil.copytree(directory / ".guarden", home / ".guarden", dirs_exist_ok=True)
    if (directory / "compose.yaml").is_file():
        shutil.copy2(directory / "compose.yaml", home / "compose.yaml")
    for path in [home, *sorted(home.rglob("*"))]:
        conf.set_owner(path, owner)


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

    Any other non-zero exit is a failure for the same reason: a manager that cannot
    be reached answers `Transport endpoint is not connected`, and pretending the
    units were stopped would be a lie about the state a fork requires.
    """
    result = tool.call(["systemctl", "--user", "--machine", f"{name}@", verb, unit])
    if result.returncode == 0:
        return
    if result.returncode == 5 and verb == "stop":
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
