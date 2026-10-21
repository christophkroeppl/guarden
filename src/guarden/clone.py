"""The snapshot-clone chain: a tmp container, a dump, a scrub and a load.

ticket 327, ADR-0025. **The operation an operator performs when a production
database is cloned onto a staging one**, which guarden had no verb for and which
the operator performed by hand in twelve steps
(phase-a-snapshot-clone-testrun.md, §9).

**The chain crosses services, and that is what shapes this module.** The snapshot
belongs to the production service; the throwaway container runs in the production
service's own podman store; the dump is written into the TARGET service's bulk
volume; the scrub rule is the TARGET's own manifest; and the load happens in the
TARGET. No single one of the four steps acts on "a service", which is why the
verbs are a group and not four more on `weedr service`.

**The throwaway container is NOT a service.** It has no unit, no publication, no
registry entry and no track, because guarden has exactly one class of DEPLOYED
thing and a container a verb starts for the length of a dump is not deployed. It
lives in the source service's own podman store and runs as the source service's
user, so the data it serves is data that service owns. `weedr clone remove` is
the verb that ends it, and it refuses a subvolume this verb did not make.

**The engine is a constant and it is named here.** `postgres` is the only engine
these verbs speak, in the same shape as `edges.ENGINE`. A service that does not
provide the `db` kind is refused, because a dump of something that is not a
database is not a dump.

**The dump is a PLAIN SQL dump, and it is plain on purpose.** The scrub is a
filter over a dump's text, and a custom-format dump is a binary archive no filter
can read. The trade is the operator's own: the Phase A testrun took both and the
transform only ever worked on the plain one.

**The file handoff streams the bytes, and the reason is measured.** `podman cp`
cannot write into `/var/lib/guarden` — the operator's own run answered
`chmod /: operation not permitted` (phase-a-snapshot-clone-testrun.md, §3) — and
the file is written by root into a bulk volume that is `0700` to the service
user. So `pg_dump` writes to stdout and `psql` reads stdin; the container's own
file system is never the handoff, and the tar stream the operator used by hand
is not in the product.
"""

from __future__ import annotations

import os
import re
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path

from guarden import (
    conf,
    errors,
    names,
    paths,
    registry,
    tool,
    volumes,
)
from guarden import (
    config as config_mod,
)
from guarden import manifest as manifest_mod
from guarden import snapshotid as ids

# The engine, in one place (ADR-0025). `edges.ENGINE` is the other user of the
# same name, and the two are the same engine: the edge creates a role and a
# database in it, and this chain dumps and restores through it.
ENGINE = "postgres"

# The superuser `pg_dump`, `pg_isready` and `psql` run as inside the container.
# The image's own superuser, which is what the edge's DDL uses (`edges.PSQL_USER`).
PSQL_USER = "postgres"

# The kind a service must provide to be dumped, transformed or loaded.
DB_KIND = "db"

# A container name podman accepts, and nothing that could be a path.
CONTAINER_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,62}$")

# How long a started container is given to accept connections. The image
# recovers WAL after a snapshot, and the operator's own run measured 14s.
READY_ATTEMPTS = 120
READY_INTERVAL = 1.0

# The `COPY` block's own shape in a plain SQL dump: every table's rows sit
# between `COPY <table> (<columns>) FROM stdin;` and a lone `\.`, one row a line,
# tab-separated.
COPY_HEADER = "COPY "
COPY_FOOTER = "\\."


@dataclass(frozen=True)
class Service:
    """The service a verb acts on, resolved against the host's tracks."""

    name: str
    record: registry.Registry
    document: manifest_mod.Manifest
    owner: tuple[int, int]

    @property
    def bulk(self) -> list[registry.Volume]:
        return [volume for volume in self.record.volume_list() if volume.kind == paths.BULK]

    @property
    def state(self) -> list[registry.Volume]:
        return [volume for volume in self.record.volume_list() if volume.kind == paths.STATE]


def _owner(record: registry.Registry) -> tuple[int, int]:
    """The service's own uid and gid, out of the machine's passwd database.

    The same question `lineage._owner` asks, and the same answer: a clone is
    owned by the service that holds the data, because the data IS that
    service's.
    """
    from guarden import users

    entry = users.passwd_entries().get(record.service)
    if entry is None:
        raise errors.GuardenError(
            f"{record.service} has no passwd entry, so its volumes have nobody to own them",
            errors.HOST_NOT_AS_ASSUMED,
        )
    return entry


def resolve(name_argument: str, tracks) -> Service:
    """The service a verb acts on, and everything the verb needs to know about it.

    **A service that provides no `db` kind is refused here, once, for every
    verb.** The dump, the scrub and the load all speak to a database, and a
    service that holds none is not one they can act on.
    """
    resolved = names.resolve(name_argument, list(tracks), allow_default=False)
    record = registry.load(resolved.name)
    if record is None:
        raise errors.GuardenError(
            f"{resolved.name} has no registry entry, so there is nothing to do",
            errors.HOST_NOT_AS_ASSUMED,
        )
    document = manifest_mod.read(paths.manifest_in_home(resolved.name))
    if DB_KIND not in record.provides and DB_KIND not in document.provides:
        raise errors.GuardenError(
            f"{resolved.name} provides no {DB_KIND!r} kind, so it holds no database these "
            f"verbs can speak to; a service that offers a database says `provides: [{DB_KIND}]` "
            f"in its manifest",
            errors.HOST_NOT_AS_ASSUMED,
        )
    return Service(
        name=resolved.name,
        record=record,
        document=document,
        owner=_owner(record),
    )


def _checked_name(value: str, what: str) -> str:
    """A container name, and a refusal for anything that could name a path."""
    if not CONTAINER_NAME.match(value or ""):
        raise errors.GuardenError(
            f"{what} {value!r} is not a container name: it must start with a letter or a "
            f"digit and hold only letters, digits, '_', '.' and '-', up to 63 characters",
            errors.REJECTED_INPUT,
        )
    return value


def _inside(root: Path, value: str, what: str) -> Path:
    """A path inside a volume, and a refusal for anything that leaves it.

    **The bulk volume is the operator's landing area and not a path they name.**
    `--out` and `--from` are relative names inside it, so a value that is
    absolute or carries `..` is refused rather than resolved: a root verb whose
    destination is repository input must not be able to write anywhere else.
    """
    if not value:
        raise errors.GuardenError(f"{what} is empty, and it names a file", errors.REJECTED_INPUT)
    candidate = Path(value)
    if candidate.is_absolute() or ".." in candidate.parts:
        raise errors.GuardenError(
            f"{what} {value!r} is not a name inside the service's bulk volume; it is a "
            f"relative path below the volume and it may not be absolute or carry '..'",
            errors.REJECTED_INPUT,
        )
    return root.joinpath(*candidate.parts)


def _volume_path(service: Service, volume: registry.Volume) -> Path:
    return paths.volume(service.name, volume.kind, volume.name)


def _volume_named(service: Service, name: str, kind: str) -> registry.Volume:
    for volume in service.record.volume_list():
        if volume.name == name and volume.kind == kind:
            return volume
    raise errors.GuardenError(
        f"{service.name} declares no {kind} volume named {name!r}, so there is no such volume "
        f"to act on; `weedr service list` names the volumes this service holds",
        errors.HOST_NOT_AS_ASSUMED,
    )


def _bulk_volume(service: Service) -> registry.Volume:
    """The service's bulk volume, and a refusal when it declares none.

    **A dump has to land somewhere that is not snapshotted.** A `state:` volume
    would put the dump into the snapshot history, and a bulk volume is exactly
    the concept for it: a landing area, not a store.
    """
    bulk = service.bulk
    if not bulk:
        raise errors.GuardenError(
            f"{service.name} declares no bulk volume, so there is nowhere for a dump to land: "
            f"a dump is a landing area and not a store, and a `state:` volume is snapshotted. "
            f"Declare a `bulk:` volume and mount that name in the unit source",
            errors.HOST_NOT_AS_ASSUMED,
        )
    return bulk[0]


def _unit_files(service: Service) -> list[Path]:
    from guarden import service as service_mod

    directory = service_mod.units_dir(service.name)
    return sorted(directory.glob("*.container")) if directory.is_dir() else []


def _unit_volume_sources(service: Service, unit: Path) -> list[tuple[str, str]]:
    """The (declared volume, mount point) pairs one container unit mounts.

    **The installed unit does not carry the volume's NAME.** The renderer
    rewrites `Volume=<name>:<path>` into `Volume=<mounted path>:<path>`
    (`render._volume_lines`), and the mounted path for a `state` volume is its
    payload rather than the subvolume root (ADR-0020), so the name a manifest
    declared appears only in the source. Both spellings are resolved here,
    against the service's own registry and through the one derivation the
    renderer also uses, because the question the verbs ask is "which container
    mounts the volume my snapshot came from" and the answer must survive the
    render.
    """
    from guarden import unitsource

    declared = {volume.name: volume for volume in service.record.volume_list()}
    parsed = unitsource.parse(unit)
    out: list[tuple[str, str]] = []
    for value in parsed.get("Container", "Volume"):
        parts = value.split(":")
        if len(parts) < 2 or not parts[0]:
            continue
        source = parts[0]
        for name, volume in declared.items():
            mounted = paths.mount_source(service.name, volume.kind, name)
            if source == name or Path(source) == mounted:
                out.append((name, parts[1]))
    return out


def _unit_volumes(service: Service, unit: Path) -> list[str]:
    return [name for name, _ in _unit_volume_sources(service, unit)]


def _unit_mount_point(service: Service, unit: Path, volume: str) -> str:
    """The path inside the container that this volume is mounted at."""
    for name, target in _unit_volume_sources(service, unit):
        if name == volume:
            return target
    raise errors.GuardenError(
        f"the unit {unit} mounts no volume named {volume!r}, so there is no data directory "
        f"to clone the snapshot into",
        errors.HOST_NOT_AS_ASSUMED,
    )


def _unit_container_name(unit: Path) -> str:
    """The name podman knows the unit's container by.

    The renderer writes `ContainerName=<service>-<container>` into every unit, so
    this is the name every other verb in guarden uses to reach it
    (`edges.provision` asks for `<provider>-<container>` too).
    """
    from guarden import unitsource

    parsed = unitsource.parse(unit)
    named = parsed.one("Container", "ContainerName")
    if named and named.strip():
        return named.strip()
    return unit.stem


def _unit_mounting(service: Service, volume: str, what: str) -> Path:
    """The one container unit of the service that mounts this volume."""
    units = [unit for unit in _unit_files(service) if volume in _unit_volumes(service, unit)]
    if not units:
        raise errors.GuardenError(
            f"{service.name} declares no unit that mounts the volume {volume!r}, so there is "
            f"no container {what}",
            errors.HOST_NOT_AS_ASSUMED,
        )
    if len(units) > 1:
        listed = ", ".join(unit.name for unit in units)
        raise errors.GuardenError(
            f"{service.name} has more than one unit mounting the volume {volume!r} ({listed}), "
            f"so which container {what} is not a question this verb can answer",
            errors.HOST_NOT_AS_ASSUMED,
        )
    return units[0]


def _database_unit(service: Service, what: str) -> Path:
    """The service's own database container: the one that mounts a state volume.

    **A state volume is where a database's data is**, because a `db` provider
    that declared a bulk volume and no state volume would lose the database on
    every recreate. A service whose state volumes are mounted by more than one
    container is refused rather than guessed at; `--from` names the container
    for a dump, and a load has no such flag because there is one database to
    load into or there is not.
    """
    state_names = {volume.name for volume in service.state}
    units = [
        unit for unit in _unit_files(service) if set(_unit_volumes(service, unit)) & state_names
    ]
    if not units:
        units = _unit_files(service)
    if not units:
        raise errors.GuardenError(
            f"{service.name} declares no unit, so it has no container {what}",
            errors.HOST_NOT_AS_ASSUMED,
        )
    if len(units) > 1:
        listed = ", ".join(unit.name for unit in units)
        raise errors.GuardenError(
            f"{service.name} has more than one unit ({listed}), so which container {what} is "
            f"not a question this verb can answer; a `db` provider has one database container",
            errors.HOST_NOT_AS_ASSUMED,
        )
    return units[0]


def _snapshots_of(config: str) -> list[dict] | None:
    from guarden import snapper

    return snapper.entries_of(config)


# --------------------------------------------------------------------------
# weedr clone snapshot
# --------------------------------------------------------------------------


def snapshot(snapshot_id: ids.SnapshotId, as_name: str, tracks) -> list[str]:
    """A throwaway container, cut from a snapshot, running against the clone.

    **The clone is a copy-on-write subvolume, so the source snapshot is never
    written to and the clone costs nothing until the container writes.** The
    read-only flag is cleared because a snapshot is read-only and the postgres
    entrypoint chowns its data directory on start; a read-only clone would
    refuse. The clone gets **no `.snapshots` subvolume**: nothing has a snapper
    configuration on it, so there is nothing to snapshot, and making one would
    reintroduce ticket 325's chown-into-a-read-only-subtree on a container that
    has no snapshots to protect.

    **The container runs the source service's own image**, read out of the
    source's own installed unit, so the tmp container is the same postgres the
    source runs and the operator has no second image to name.
    """
    container = _checked_name(as_name, "--as")
    source = resolve(snapshot_id.service, tracks)
    volume = _volume_named(source, snapshot_id.volume, paths.STATE)
    config = volume.config or paths.snapper_config(snapshot_id.service, snapshot_id.volume)
    entries = _snapshots_of(config)
    if entries is None:
        raise errors.GuardenError(
            f"the configuration {config} could not be read, so whether {snapshot_id} exists is "
            f"unknown; `weedr service list` names the services this host holds",
            errors.HOST_NOT_AS_ASSUMED,
        )
    if not any(entry.get("number") == snapshot_id.number for entry in entries):
        raise errors.GuardenError(
            f"there is no snapshot {snapshot_id} in the configuration {config}; "
            f"`stakes list` names the snapshots this host holds",
            errors.HOST_NOT_AS_ASSUMED,
        )

    unit = _unit_mounting(source, snapshot_id.volume, "to clone the snapshot into")
    image = _image_of(unit)
    mount = _unit_mount_point(source, unit, snapshot_id.volume)
    target = _clone_path(source, container)
    _clone(paths.snapshot(snapshot_id.service, snapshot_id.volume, snapshot_id.number), target,
           source.owner)
    data = paths.payload_at(target, volume.kind)
    try:
        _run_container(source, container, image, mount, unit, data)
    except BaseException:
        _remove_clone(target)
        raise
    return [
        f"cloned {snapshot_id} into {target}",
        f"started the container {container} in {source.name}'s own store, serving {mount}",
        f"dump it with `weedr clone dump <target> --db <database> --out <file> "
        f"--from {source.name}:{container}`",
        f"remove it with `weedr clone remove {source.name} --as {container}`",
    ]


def remove(service_argument: str, as_name: str, tracks) -> list[str]:
    """The container and the clone, and nothing else.

    **The clone is removed only when it is the one this verb made.** A subvolume
    under `clones/` is guarden's own by construction, and anything else is data:
    `weedr service purge` is the verb that destroys data.
    """
    container = _checked_name(as_name, "--as")
    source = resolve(service_argument, tracks)
    target = _clone_path(source, container)
    if not _is_subvolume(target):
        raise errors.GuardenError(
            f"there is no clone named {target}, so there is nothing to remove; `weedr clone "
            f"snapshot` makes one",
            errors.HOST_NOT_AS_ASSUMED,
        )
    _remove_container(source, container)
    _remove_clone(target)
    return [f"removed the container {container}", f"removed the clone {target}"]


def _clone_path(source: Service, as_name: str) -> Path:
    """Where the clone lives: the source service's own tree, beside the volumes.

    **It is under `clones/` and not under `state/`**, because `state/` holds
    nothing but snapshotted subvolumes and a clone has no snapper configuration —
    the split exists precisely so an unsnapshotted tree is never inside a
    snapshotted one. It is inside the service's `0700` tree because the clone
    holds that service's data.
    """
    return paths.service_tree(source.name) / paths.CLONES / as_name


def _is_subvolume(path: Path) -> bool:
    result = tool.call(["btrfs", "subvolume", "show", str(path)])
    return result.ok


def _clone(source: Path, target: Path, owner: tuple[int, int]) -> None:
    """The copy-on-write clone, the read-only flag cleared, the owner set."""
    if target.exists():
        raise errors.GuardenError(
            f"{target} is already there, so it is not a clone this verb would have made; "
            f"remove it with `weedr clone remove` or choose another name",
            errors.HOST_NOT_AS_ASSUMED,
        )
    if not source.exists():
        raise errors.GuardenError(
            f"the snapshot subvolume {source} is not there, so there is nothing to clone",
            errors.HOST_NOT_AS_ASSUMED,
        )
    parent = target.parent
    parent.mkdir(parents=True, exist_ok=True)
    volumes.own(parent, owner)
    result = tool.call(["btrfs", "subvolume", "snapshot", str(source), str(target)])
    if not result.ok:
        detail = result.stderr.strip() or result.stdout.strip()
        raise errors.GuardenError(
            f"the snapshot {source} could not be cloned: {detail}", errors.HOST_NOT_AS_ASSUMED
        )
    tool.run(["btrfs", "property", "set", str(target), "ro", "false"])
    volumes.own(target, owner)


def _remove_clone(target: Path) -> None:
    """The clone's own subvolume, deleted.

    **A btrfs subvolume is deleted, not removed.** `shutil.rmtree` on one leaves
    the subvolume itself behind and the filesystem's accounting of it wrong, so
    the delete is btrfs's own ioctl.
    """
    if not target.exists():
        return
    result = tool.call(["btrfs", "subvolume", "delete", str(target)])
    if not result.ok:
        detail = result.stderr.strip() or result.stdout.strip()
        raise errors.GuardenError(
            f"the clone {target} could not be deleted: {detail}", errors.HOST_NOT_AS_ASSUMED
        )


def _image_of(unit: Path) -> str:
    from guarden import unitsource

    parsed = unitsource.parse(unit)
    image = parsed.one("Container", "Image")
    if not image or not image.strip():
        raise errors.GuardenError(
            f"the unit {unit} names no image, so there is no container to run against the clone",
            errors.HOST_NOT_AS_ASSUMED,
        )
    return image.strip()


def _environment(unit: Path) -> list[str]:
    """The source unit's own `Environment=` assignments, carried over.

    **They are the image's conventions**, `PGDATA` in particular: it is a
    subdirectory of the mount (tickets 273 and 277), and without it the postgres
    entrypoint treats the mount root as the data directory. A `Secret=` line is
    not carried: a snapshot already holds an initialised cluster, so the
    entrypoint skips initialisation and never asks for the superuser password.
    """
    from guarden import unitsource

    parsed = unitsource.parse(unit)
    out: list[str] = []
    for line in parsed.get("Container", "Environment"):
        for assignment in line.split():
            if "=" in assignment and not assignment.startswith("HOME="):
                out.extend(["--env", assignment])
    return out


def _run_container(
    source: Service, container: str, image: str, mount: str, unit: Path, data: Path
) -> None:
    """The throwaway container, running against the clone.

    **It is a `podman run` and not a unit.** A unit would make it a service —
    with a publication, a target and a lifecycle guarden would then have to own.
    It publishes no port: a publication is guarden's own allocation and is
    recorded in the service's registry, and this container has no registry entry.
    The operator reaches it with `podman exec`, which is how the operator's own
    run reached it.

    **The clone's DATA is mounted, not the clone's own root.** A `state`
    volume's data lives one level down inside its subvolume (ADR-0020), and the
    clone of one volume root carries that same layout, so `data` is the payload
    the renderer would have written for the volume. Mounting the root instead
    would put the image's data path one level off — a postgres that initialises
    an empty cluster beside the data it was cloned from — and would hand the
    entrypoint's recursive chown snapper's root-owned `.snapshots` subtree.

    **It is mounted at the path the source's own unit mounts the volume at**,
    because the image's conventions are written for that path. A clone mounted
    somewhere else would not be a postgres the image recognises.

    **The container carries the source unit's `UserNS=keep-id` pin, and without
    it the clone does not start.** The source runs its image's own user (999 in
    the postgres image) mapped onto the service's uid, so the volume's files are
    the service's on the host and 999's inside the container. A `podman run`
    with the default map would instead make container root the service's uid and
    container 999 an unmapped subuid, and the 0700 clone would be a directory the
    image's own user cannot enter: the entrypoint's `mkdir -p "$PGDATA"` answers
    `Permission denied` on the parent and the container dies before postgres
    starts (measured on the golden VM). `render.owner_line` is the one spelling
    of the pin, so the throwaway container is mapped exactly as the source is.
    """
    argv = [
        *tool.runuser_as(source.name, "podman", "run", "--detach"),
        "--name",
        container,
        "--network",
        _network(),
        "--volume",
        f"{data}:{mount}:rw",
    ]
    pin = _userns(source, unit, image)
    if pin is not None:
        argv.extend(["--userns", pin])
    argv.extend(_environment(unit))
    argv.append(image)
    result = tool.call(argv, cwd="/tmp")
    if not result.ok:
        detail = errors.oneline(result.stderr.strip() or result.stdout.strip())
        raise errors.GuardenError(
            f"the container {container} did not start" + (f": {detail}" if detail else ""),
            errors.HOST_NOT_AS_ASSUMED,
        )
    _wait_for_engine(source.name, container)


def _userns(source: Service, unit: Path, image: str) -> str | None:
    """The `UserNS=` value the source unit's own drop-in carries, or `None`.

    **The same function the renderer writes the source's pin with**, so the
    throwaway container cannot be mapped differently from the container whose
    data it serves. `None` is an unprobed image or one that declares no user, and
    both mean the default map is the right one.
    """
    from guarden import render

    return render.owner_line(source.record, unit.stem, image)


def _network() -> str:
    """The host's own network backend, so the clone reaches the host the same
    way the source's container does. It is the host's `[network]` table, which
    is where the option set is pinned (spec 3.1), and not the source's unit.
    """
    return config_mod.load().network


def _wait_for_engine(account: str, container: str) -> None:
    """Block until the container accepts connections, and name the timeout.

    **A dump run the instant `podman run` returns meets a database that is still
    recovering WAL**, and the operator's own run measured 14 seconds before it
    accepted a connection. A verb that said "started" and left the caller to
    guess would make the next step of the chain a retry loop in a shell script.

    **A container that has already exited is not waited on for the full two
    minutes**, and its own words are in the diagnostic. `podman logs` reads
    nothing under the journald log driver, which is what a machine with a
    user manager uses, so the read is the journal filtered by the service uid —
    that is where the entrypoint's refusal is, and a timeout that named only the
    clock cost a diagnosis round (measured on the golden VM).
    """
    for _ in range(READY_ATTEMPTS):
        ready = tool.call(
            tool.runuser_as(account, "podman", "exec", container, "pg_isready", "-U", PSQL_USER),
            cwd="/tmp",
        )
        if ready.ok:
            return
        state = tool.call(
            tool.runuser_as(account, "podman", "inspect", container, "--format",
                            "{{.State.Status}} {{.State.ExitCode}}"),
            cwd="/tmp",
        )
        if state.ok and state.stdout.split()[:1] == ["exited"]:
            break
        time.sleep(READY_INTERVAL)
    raise errors.GuardenError(
        f"the container {container} did not start serving {ENGINE}: "
        f"{_diagnosis(account, container)}",
        errors.HOST_NOT_AS_ASSUMED,
    )


def _diagnosis(account: str, container: str) -> str:
    """What the container is doing, and the last thing it said."""
    state = tool.call(
        tool.runuser_as(account, "podman", "inspect", container, "--format",
                        "{{.State.Status}} (exit {{.State.ExitCode}})"),
        cwd="/tmp",
    )
    said = state.stdout.strip() if state.ok else ""
    from guarden import users

    entry = users.passwd_entries().get(account)
    if entry is None:
        return said or "the container said nothing"
    journal = tool.call(
        ["journalctl", "--no-pager", "-n", "200", "--since", "-10 min", f"_UID={entry[0]}"]
    )
    lines = [line for line in journal.stdout.splitlines() if container in line]
    if not lines:
        return said or "the container said nothing, and the journal holds no line for it"
    tail = errors.oneline(" | ".join(line.split(": ", 1)[-1] for line in lines[-3:]))
    return f"{said}; {tail}" if said else tail


def _remove_container(source: Service, container: str) -> None:
    """The throwaway container, stopped and removed. Stopped first: a running
    container holds the clone open and its removal would fail.
    """
    for verb in ("stop", "rm"):
        tool.call(tool.runuser_as(source.name, "podman", verb, container), cwd="/tmp")


# --------------------------------------------------------------------------
# weedr clone dump
# --------------------------------------------------------------------------


def dump(
    service: Service, database: str, out: str, source: tuple[str, str] | None, tracks
) -> list[str]:
    """A plain SQL dump, out of a running container, into the service's bulk volume.

    **The dump goes into the service's own bulk volume**, which is the concept
    the operator named ("staging pg (bulk volume)"): a bulk volume is never
    snapshotted, so a dump in it enters no snapshot and no fork.

    **The container is named with its service when it is not the target's own**,
    because the container runs in the SOURCE service's podman store and the dump
    lands in the TARGET's bulk volume. A `podman exec` as the target's user
    cannot reach a container the source's user owns, so
    `--from <source-service>:<container>` carries both halves of the name and the
    verb refuses to guess which store a bare container name lives in.
    """
    volume = _bulk_volume(service)
    if source is None:
        holder = service
        container = _unit_container_name(_database_unit(service, "to dump from"))
    else:
        holder = _other_service(source[0], service, tracks)
        container = _checked_name(source[1], "--from container")
    path = _inside(_volume_path(service, volume), out, "--out")
    _pg_dump(holder, container, database, path, service.owner)
    return [
        f"dumped the database {database} of {container} to {path}",
        f"{path.stat().st_size} bytes",
    ]


def _other_service(name_argument: str, target: Service, tracks) -> Service:
    """The service a named container belongs to, resolved and cross-checked.

    **A dump whose source and target are one service is not a clone**, and a
    verb that performed one would be doing the operator's own `pg_dump | psql` in
    a much less reviewable way.
    """
    resolved = names.resolve(name_argument, list(tracks), allow_default=False)
    if resolved.name == target.name:
        raise errors.GuardenError(
            f"the source {name_argument} and the target {target.name} are the same service, so "
            f"there is nothing to clone: a clone's source is a production snapshot and its "
            f"target is the staging service the snapshot is copied onto",
            errors.HOST_NOT_AS_ASSUMED,
        )
    return resolve(name_argument, tracks)


def _pg_dump(
    source: Service, container: str, database: str, target: Path, owner: tuple[int, int]
) -> None:
    """The dump, made by the container's own `pg_dump` and written to the target.

    **The bytes go from the container's stdout to the file, with the spec 3.5
    protocol** — a temporary file in the same directory, an fsync, a rename. The
    write is root's, the file is chowned to the service that will read it, and
    nothing is buffered in this process: a dump is production data and it is
    megabytes.
    """
    argv = tool.runuser_as(
        source.name,
        "podman",
        "exec",
        container,
        "pg_dump",
        "-U",
        PSQL_USER,
        "-d",
        database,
        "--format=plain",
        "--no-owner",
        "--no-privileges",
    )
    target.parent.mkdir(parents=True, exist_ok=True)
    temp = _temp_for(target)
    handle = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(handle, "wb") as stream:
            producer = subprocess.Popen(
                argv, stdout=stream, stderr=subprocess.PIPE, cwd="/tmp"
            )
            _, err = producer.communicate()
            stream.flush()
            os.fsync(stream.fileno())
    except BaseException:
        temp.unlink(missing_ok=True)
        raise
    if producer.returncode != 0:
        detail = errors.oneline(err.decode(errors="replace").strip())
        temp.unlink(missing_ok=True)
        raise errors.GuardenError(
            f"{ENGINE} could not dump the database {database} of {container}"
            + (f": {detail}" if detail else ""),
            errors.HOST_NOT_AS_ASSUMED,
        )
    conf.set_owner(temp, owner)
    os.chmod(temp, 0o600)
    os.replace(temp, target)


def _temp_for(target: Path) -> Path:
    return target.parent / f".{target.name}.{os.getpid()}.tmp"


# --------------------------------------------------------------------------
# weedr clone transform
# --------------------------------------------------------------------------


def transform(service: Service, source_name: str, out: str) -> list[str]:
    """The scrub: the manifest's rule applied to a dump, and a report of what it
    removed.

    **The rule is the service's own manifest**, because the rule is the
    operator's policy and the manifest is where a project declares what it is
    (ADR-0025). A service whose manifest carries no `scrub:` block is refused:
    there is nothing to do, and a verb that silently did nothing would report a
    transform it never performed.

    **The transform is a filter over the dump's TEXT, and it is not a query
    language.** A rule that could express arbitrary SQL would be an arbitrary
    database write dressed as a policy, and the review a manifest block is for —
    a diff in a pull request — is worthless against arbitrary SQL.
    """
    rule = service.document.scrub
    if rule.empty():
        raise errors.GuardenError(
            f"{service.name} declares no `scrub:` rule, so there is nothing to remove; the rule "
            f"is the operator's policy and it lives in the service's own manifest, beside the "
            f"deployment it governs",
            errors.REJECTED_INPUT,
        )
    volume = _bulk_volume(service)
    root = _volume_path(service, volume)
    source = _inside(root, source_name, "--from")
    target = _inside(root, out, "--out")
    if not source.is_file():
        raise errors.GuardenError(
            f"there is no dump named {source}; `weedr clone dump` writes one",
            errors.HOST_NOT_AS_ASSUMED,
        )
    if source == target:
        raise errors.GuardenError(
            f"--from and --out both name {source}, and the transform writes a new dump rather "
            f"than rewriting the one it reads",
            errors.REJECTED_INPUT,
        )
    removed = _apply(rule, source, target, service.owner)
    if not removed:
        raise errors.GuardenError(
            f"the scrub rule of {service.name} removed nothing from {source}: the rule names "
            f"tables and columns the dump does not carry, so nothing was transformed and no "
            f"file was written",
            errors.HOST_NOT_AS_ASSUMED,
        )
    lines = [f"transformed {source} into {target}"]
    for entry in removed:
        lines.append(f"removed {entry}")
    lines.append(f"removed {len(removed)} row(s)")
    return lines


def _apply(
    rule: manifest_mod.Scrub, source: Path, target: Path, owner: tuple[int, int]
) -> list[str]:
    """The rule, applied as the dump is streamed, and the rows it removed.

    **The filter works on COPY blocks, because that is where a plain dump keeps
    its rows.** A row-level rule is a filter over the lines of a block, and a
    table-level rule empties the block.

    **The block's HEADER is kept when the table is emptied.** A dump that dropped
    the `COPY` header as well would restore a table that does not exist, and the
    operator's rule was "delete the email settings" — not "delete the table the
    settings live in". The header stays, the rows go, and the restored database
    holds the table with no rows in it.
    """
    temp = _temp_for(target)
    removed: list[str] = []
    try:
        with source.open("r", encoding="utf-8", errors="replace") as reader, temp.open(
            "w", encoding="utf-8"
        ) as writer:
            inside = False
            table = ""
            columns: list[str] = []
            for line in reader:
                if not inside:
                    header = _copy_header(line)
                    if header is None:
                        writer.write(line)
                        continue
                    table, columns = header
                    inside = True
                    writer.write(line)
                    continue
                if line.rstrip("\n") == COPY_FOOTER:
                    inside = False
                    writer.write(line)
                    continue
                entry = _matching_row(rule, table, columns, line.rstrip("\n"))
                if entry is None:
                    writer.write(line)
                else:
                    removed.append(entry)
            writer.flush()
            os.fsync(writer.fileno())
    except BaseException:
        temp.unlink(missing_ok=True)
        raise
    if not removed:
        temp.unlink(missing_ok=True)
        return []
    conf.set_owner(temp, owner)
    os.chmod(temp, 0o600)
    os.replace(temp, target)
    return removed


def _copy_header(line: str) -> tuple[str, list[str]] | None:
    """The table and the columns of a COPY block, or `None` for any other line."""
    if not line.startswith(COPY_HEADER):
        return None
    rest = line[len(COPY_HEADER):]
    open_paren = rest.find("(")
    if open_paren < 0:
        return None
    table = rest[:open_paren].strip()
    close = rest.rfind(")")
    if close < open_paren:
        return None
    columns = [column.strip() for column in rest[open_paren + 1:close].split(",")]
    return table, columns


def _bare_table(table: str) -> str:
    """The table's own name without the schema, because a rule names one and not
    the other and pg_dump always writes the qualified form.
    """
    return table.rsplit(".", 1)[-1]


def _matching_row(rule: manifest_mod.Scrub, table: str, columns: list[str], row: str) -> str | None:
    """The row's own description when it goes, and `None` when it stays.

    **A row is split on the tab a plain dump separates its columns with**, and
    the column the rule names is looked up BY NAME — so a rule that names a
    column does not depend on the column's position.
    """
    bare = _bare_table(table)
    for entry in rule.tables:
        if entry.name == bare:
            return f"every row of the table {table}"
    values = row.split("\t")
    for entry in rule.keys:
        if entry.table != bare or entry.column not in columns:
            continue
        value = values[columns.index(entry.column)]
        if entry.prefix is not None and value.startswith(entry.prefix):
            return f"{entry.column}={value} from the table {table}"
        if entry.equals is not None and value == entry.equals:
            return f"{entry.column}={value} from the table {table}"
    return None


# --------------------------------------------------------------------------
# weedr clone load
# --------------------------------------------------------------------------


def load(service: Service, database: str, source: str) -> list[str]:
    """A dump, loaded into the service's own database.

    **The dump is read from the service's bulk volume** — the landing area the
    dump was written to — **and restored through `psql -f -`**, because a plain
    dump is a SQL script and `psql` is what runs one.

    **The database must already exist.** The role and the database are guarden's
    own — `edges.provision` creates them and converges the password — and a load
    that created the role would be doing the edge's job in a place where the edge
    is not, and the role's password would then be the dump's password rather than
    the edge's minted one (ADR-0025).
    """
    volume = _bulk_volume(service)
    path = _inside(_volume_path(service, volume), source, "--from")
    if not path.is_file():
        raise errors.GuardenError(
            f"there is no dump named {path}; `weedr clone dump` writes one",
            errors.HOST_NOT_AS_ASSUMED,
        )
    container = _unit_container_name(_database_unit(service, "to load into"))
    _require_database(service, container, database)
    _restore(service, container, database, path)
    return [f"loaded {path} into the database {database} of {service.name}"]


def _require_database(service: Service, container: str, database: str) -> None:
    """A refusal when the target database does not exist.

    The check is `psql`'s own answer from the engine. The name is quoted into
    the query with its single quotes doubled, rather than passed as a psql
    variable: **psql does not interpolate variables in a `-c` argument**
    (measured on the golden VM — it answered `syntax error at or near ":"`), so a
    variable here would be a query that never substituted and a check that could
    not answer.
    """
    literal = database.replace("'", "''")
    argv = tool.runuser_as(
        service.name,
        "podman",
        "exec",
        container,
        "psql",
        "-U",
        PSQL_USER,
        "-d",
        "postgres",
        "-tAc",
        f"SELECT 1 FROM pg_database WHERE datname = '{literal}'",
    )
    result = tool.call(argv, cwd="/tmp")
    if not result.ok:
        detail = errors.oneline((result.stderr or result.stdout).strip())
        raise errors.GuardenError(
            f"{ENGINE} could not be asked whether {database!r} exists in {service.name}"
            + (f": {detail}" if detail else ""),
            errors.HOST_NOT_AS_ASSUMED,
        )
    if result.stdout.strip() != "1":
        raise errors.GuardenError(
            f"the database {database!r} does not exist in {service.name}, and this verb restores "
            f"into a database rather than creating one: the database and its role are the edge's "
            f"to create, and `weedr service start` provisions the consumer that dials this "
            f"provider",
            errors.HOST_NOT_AS_ASSUMED,
        )


def _restore(service: Service, container: str, database: str, path: Path) -> None:
    """The restore, through `psql` reading the dump on stdin.

    **`ON_ERROR_STOP=0`**, because a plain dump carries statements a restored
    database may legitimately refuse — a `CREATE TABLE` for a table that is
    already there — and a restore that aborted on the first of them would restore
    nothing. The exit code is psql's own, so a connection or authentication
    failure is still a failure.
    """
    argv = tool.runuser_as(
        service.name,
        "podman",
        "exec",
        "-i",
        container,
        "psql",
        "-U",
        PSQL_USER,
        "-d",
        database,
        "-q",
        "-v",
        "ON_ERROR_STOP=0",
        "-f",
        "-",
    )
    with path.open("rb") as handle:
        producer = subprocess.Popen(
            argv, stdin=handle, stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd="/tmp"
        )
        out, err = producer.communicate()
    if producer.returncode != 0:
        detail = errors.oneline(
            err.decode(errors="replace").strip() or out.decode(errors="replace").strip()
        )
        raise errors.GuardenError(
            f"{ENGINE} refused the dump into the database {database} of {service.name}"
            + (f": {detail}" if detail else ""),
            errors.HOST_NOT_AS_ASSUMED,
        )



