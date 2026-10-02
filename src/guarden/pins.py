"""The pin store: one file per pinned snapshot, and the projection beside it.

spec 6.8, 8.5 and ADR-0007. Two things live here and they are kept apart:

- **A pin file**, `/var/lib/guarden/stakes/<service>:<volume>@<number>`, owned by
  `stakes` and written by it. One file per snapshot, created and removed by
  name, never aggregated — which is why it takes no lock and needs none: there is
  no read-modify-write to lose, and a program that maintained a shared index
  would be a program whose index could disagree with the files it indexes.
- **The seeds**, derived from the service registries. Nothing maintains them: a
  service records the snapshot it was forked from and that is the whole of it.
  A pin is a *priority with a budget*, so the projection is a recomputation and
  not an append, and a process that died midway leaves nothing to reconcile.

A pin protects nothing by itself. What protects a snapshot is the mark
`snapper modify` writes, and `weedr pin sync` — a separate root action, because
`stakes` runs as `guarden` and writing snapper's metadata is not something an
unprivileged program can do — recomputes those marks from both sources.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path

from guarden import errors, paths, registry
from guarden import snapshotid as ids

PIN_MODE = 0o660

# The `guarden=` provenance key a pin file carries. A seed names the service that
# forked from it, because a service's registry is where that fact lives; a pin
# file is the operator's own statement, so it names itself and does not pretend a
# service asked for it.
PIN_AUTHOR = "pin"


@dataclass(frozen=True)
class Want:
    """One snapshot that must carry the mark, and the configuration it lives in.

    The configuration comes from the service and volume **separately**, never
    from parsing either the id or a configuration name: a configuration's name
    is opaque and nothing parses it (spec 8.1), and the derivation runs the other
    way — a service name and a volume name, both known — which is
    `paths.snapper_config` and is the same call the mutator made when it created
    the configuration.
    """

    config: str
    number: int
    author: str
    snapshot: ids.SnapshotId


@dataclass
class Pin:
    """What `stakes` reports: a snapshot something wants, and why."""

    snapshot: ids.SnapshotId
    note: str = ""
    seeds: list[str] = field(default_factory=list)
    has_file: bool = False

    def to_json(self) -> dict:
        # spec 1.2's field set, closed: `id`, `service`, `volume`, `number`,
        # `note` and `marked`, and nothing else. `marked` is a statement about
        # what `weedr pin sync` will write, not about the filesystem, because a
        # pin is a priority with a budget and not a promise.
        return {
            "id": str(self.snapshot),
            "service": self.snapshot.service,
            "volume": self.snapshot.volume,
            "number": self.snapshot.number,
            "note": self.note,
            "marked": True,
        }


def path_for(snapshot: ids.SnapshotId) -> Path:
    return paths.STAKES / str(snapshot)


def write(snapshot: ids.SnapshotId, note: str = "") -> bool:
    """Create the file. Idempotent: the same pin twice is one file, not two."""
    target = path_for(snapshot)
    existed = target.exists()
    paths.STAKES.mkdir(parents=True, exist_ok=True)
    handle = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, PIN_MODE)
    with os.fdopen(handle, "w") as stream:
        stream.write(note)
    os.chmod(target, PIN_MODE)
    return not existed


def remove(snapshot: ids.SnapshotId) -> bool:
    target = path_for(snapshot)
    if not target.exists():
        return False
    target.unlink()
    return True


def note_of(snapshot: ids.SnapshotId) -> str | None:
    """The note on a pin file, or `None` when there is no file at all.

    `None` and `""` are different answers: an absent file is a snapshot nothing
    wants, and a file with no note is a pin whose operator gave no reason.
    """
    target = path_for(snapshot)
    if not target.exists():
        return None
    return target.read_text(encoding="utf-8").strip()


def stored() -> tuple[dict[ids.SnapshotId, str], list[str]]:
    """Every pin file, and the names in the directory that are not ids.

    A name that will not parse is reported rather than skipped in silence: a pin
    file nothing can act on is a file an operator reads at three in the morning
    believing it protects something.
    """
    pins: dict[ids.SnapshotId, str] = {}
    stray: list[str] = []
    if not paths.STAKES.is_dir():
        return pins, stray
    for entry in sorted(paths.STAKES.iterdir()):
        if not entry.is_file():
            continue
        try:
            snapshot = ids.parse(entry.name, "pin file")
        except errors.GuardenError:
            stray.append(entry.name)
            continue
        pins[snapshot] = entry.read_text(encoding="utf-8").strip()
    return pins, stray


def seeds() -> dict[ids.SnapshotId, list[str]]:
    """Every snapshot a registry names as a seed, and the services naming it.

    The snapshot is the **source's**, because the source's is what has to
    survive: a preview is protected because something was forked from the
    production snapshot it came from, and evicting that preview must not release
    a snapshot another preview is still forked from.
    """
    wanted: dict[ids.SnapshotId, list[str]] = {}
    for service in registry.names():
        record = registry.load(service)
        if record is None:
            continue
        for seed in _seeds_of(record.seed):
            _want(wanted, record, seed)
        for _, instance in sorted(record.instances.items()):
            for seed in _seeds_of(instance.seed):
                _want(wanted, record, seed)
    return wanted


def _seeds_of(table: dict) -> list[registry.Seed]:
    return [seed for _, seed in sorted(table.items()) if seed is not None]


def _want(into: dict[ids.SnapshotId, list[str]], record, seed) -> None:
    snapshot = ids.SnapshotId(
        service=seed.service, volume=seed.volume, number=int(seed.number)
    )
    referring = into.setdefault(snapshot, [])
    if record.service not in referring:
        referring.append(record.service)


def collect() -> list[Pin]:
    """The union of what was pinned by hand and what a registry forks from.

    The union rather than the pin files alone, because `stakes list` is the
    command that answers "which snapshots are protected, and by whom" — and a
    snapshot a preview was forked from is protected whatever anybody pinned.
    """
    files, _ = stored()
    wanted = seeds()
    return [
        Pin(
            snapshot=snapshot,
            note=files.get(snapshot, ""),
            seeds=sorted(wanted.get(snapshot, [])),
            has_file=snapshot in files,
        )
        for snapshot in sorted(set(files) | set(wanted), key=str)
    ]


def configurations() -> list[str]:
    """Every configuration a registry knows, which is every configuration guarden made.

    The removal pass needs the configurations a pin **no longer** names, so the
    set cannot be built from the wants: a released pin's snapshot is marked and
    nothing wants it, and only a configuration that is read anyway can have that
    mark cleared. A snapshot list per configuration, one read each.
    """
    found: set[str] = set()
    for service in registry.names():
        record = registry.load(service)
        if record is None:
            continue
        for volume in record.volume_list():
            if volume.kind != paths.STATE:
                continue
            found.add(
                volume.config
                or paths.snapper_config(record.service, volume.name)
            )
        for escaped in record.instances:
            for volume in record.volume_list():
                if volume.kind == paths.STATE:
                    found.add(
                        paths.snapper_config(record.service, volume.name, escaped)
                    )
    return sorted(found)


def wants() -> list[Want]:
    """What `weedr pin sync` will mark, deduplicated and in a stable order.

    A pin file names a service's state volume and nothing else. A seed names the
    source it was forked from, and §8.3 refuses an **instance** source for a
    state volume — an instance's volumes are not the service's — so a seed's
    configuration is always the slot form and never carries an escaped ref.
    """
    files, _ = stored()
    wanted = seeds()
    out: list[Want] = []
    seen: set[tuple[str, int, str]] = set()
    for snapshot in sorted(set(files) | set(wanted), key=str):
        config = paths.snapper_config(snapshot.service, snapshot.volume)
        for author in sorted(wanted.get(snapshot, [])) or [PIN_AUTHOR]:
            key = (config, snapshot.number, author)
            if key in seen:
                continue
            seen.add(key)
            out.append(
                Want(config=config, number=snapshot.number, author=author, snapshot=snapshot)
            )
    return out
