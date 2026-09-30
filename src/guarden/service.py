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

from guarden import conf, errors, names, paths, registry, tool, users, volumes
from guarden import manifest as manifest_mod
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

    def directory(self) -> Path:
        if self.kind == "poke":
            return paths.STAGING / str(self.project) / str(self.sha)
        return paths.service_home(str(self.service))


@dataclass
class Outcome:
    resolved: names.Resolved
    converged: bool = False
    uid: int = 0
    warnings: list[str] = field(default_factory=list)


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

    existing = registry.load(resolved.name)
    if existing is not None and _converged(existing, resolved, manifest, project):
        outcome.converged = True
        outcome.uid = existing.uid
        return outcome

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
    _ensure_admin_units(identity.uid)

    if resolved.escaped_ref and resolved.escaped_ref not in record.instances:
        # The instance is recorded at creation, because an instance that is not in
        # the registry cannot be counted against the cap or reported by `list`,
        # and a second ingest of the same ref has to be able to tell that from a
        # ref that has not been created yet. `seed` and `publication` stay empty:
        # no fork has taken place, and the publication allocator is a later ticket.
        record.instances[resolved.escaped_ref] = registry.Instance(
            ref=str(resolved.ref), escaped_ref=resolved.escaped_ref, created=now
        )

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

    with conf.lock("registry"):
        registry.save(record, root_owner)
    return outcome


def _record(record, vol: str, kind: str, config_name: str | None) -> None:
    record.volumes[vol] = registry.Volume(name=vol, kind=kind, config=config_name)


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


def units_of(name: str, escaped_ref: str | None = None) -> list[str]:
    home = paths.service_home(name)
    if escaped_ref:
        home = home / escaped_ref
    directory = home / paths.QUADLET
    if not directory.is_dir():
        return []
    return sorted(path.stem for path in directory.glob("*.container"))


def stop_units(name: str, escaped_ref: str | None = None) -> None:
    for unit in units_of(name, escaped_ref):
        tool.run(["systemctl", "--user", "--machine", f"{name}@", "stop", unit])


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

    users.destroy(resolved.name)
    _drop(paths.ADMIN_UNITS / str(record.uid))
    _drop(paths.service_tree(resolved.name))
    _drop(paths.ETC_SERVICES / resolved.name)
    _drop(paths.SHARED / resolved.name)
    with conf.lock("registry"):
        registry.delete(resolved.name)
    printed.append("its snapper configurations are left for `soil storage` to remove")
    return printed


def _remove_instance(resolved, record) -> list[str]:
    if resolved.track.kind != "instance":
        raise errors.GuardenError(
            f"{resolved.name} is on track {resolved.track.name!r}, which is kind "
            f'"{resolved.track.kind}", so it has no instances'
        )
    escaped = str(resolved.escaped_ref)
    instance = record.instances.get(escaped)
    if instance is None:
        raise errors.GuardenError(
            f"{resolved.name} has no instance {resolved.ref!r}", errors.HOST_NOT_AS_ASSUMED
        )

    printed = [f"removed the instance {resolved.ref} of {resolved.name}"]
    stop_units(resolved.name, escaped)
    _drop(paths.instance_tree(resolved.name, escaped))
    _drop(paths.instance_home(resolved.name, escaped))
    del record.instances[escaped]
    with conf.lock("registry"):
        registry.save(record, (0, users.group_id(GUARDEN_GROUP)))

    released = ", ".join(f"{key}={port}" for key, port in sorted(instance.publication.items()))
    printed.append(f"released the instance's publications ({released or 'none'})")
    seeds = ", ".join(f"{vol}@{number}" for vol, number in sorted(instance.seed.items()))
    printed.append(f"released the seed ({seeds or 'none'})")
    return printed


def _drop(path: Path) -> None:
    if path.is_dir():
        shutil.rmtree(path)
    elif path.exists():
        path.unlink()


def _stamp(now: str) -> str:
    return now.replace("-", "").replace(":", "")
