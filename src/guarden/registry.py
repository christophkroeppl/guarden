"""`/var/lib/guarden/registry/<name>.toml`: the record of a service's identity.

The registry is a **projection** (spec 3.4): anything derivable from the
manifest and the host is recomputed, and only what cannot be is stored — the
uid, the deployed sha, the allocated publications, the snapshot numbers and the
seeds. It is the single record of a service's identity, its edges, its
publications, its lineage and its ports, and it is `0640 root:guarden` because it
describes the whole topology: a service that can read it can read the map of the
box.

Written only by the mutator, and only through the spec 3.5 protocol. Read with
no lock, because a writer renames and a reader therefore sees the old file or
the new one and never a partial one.

A configuration's *name* is opaque and nothing parses it (spec 8.1): workload
and volume names may both contain `-`, so `<service>-<volume>` cannot be
decomposed. The service's `environment` is a field here precisely so that
anything needing the track reads it from this file rather than guessing from the
name.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from guarden import conf, errors, paths

REGISTRY_MODE = 0o640
SOURCE_MANUAL = "manual"
SOURCE_GITOPS = "gitops"


@dataclass
class Volume:
    name: str
    kind: str
    config: str | None = None
    snapshots: int | None = None

    def to_document(self) -> dict[str, Any]:
        document: dict[str, Any] = {}
        if self.config is not None:
            document["config"] = self.config
        if self.snapshots is not None:
            document["snapshots"] = self.snapshots
        return document

    @classmethod
    def from_document(cls, kind: str, name: str, document: dict) -> Volume:
        return cls(
            name=name,
            kind=kind,
            config=document.get("config"),
            snapshots=document.get("snapshots"),
        )


@dataclass
class Seed:
    """The snapshot a service was forked from, per its own state volume.

    spec 3.4's example writes `seed = { data = 38 }`, and the value here is a
    table rather than a number because **the snapshot belongs to the source**:
    a preview is protected because something was forked from the production
    snapshot it came from, and a number with no service beside it names nothing
    that can be marked. §8.5 requires the reconciler to mark "every snapshot
    named as a `seed` by any service's registry", and a bare number cannot be
    named by anything.
    """

    service: str
    volume: str
    number: int

    def to_document(self) -> dict[str, Any]:
        return {"service": self.service, "volume": self.volume, "number": int(self.number)}

    @classmethod
    def from_document(cls, document: Any) -> Seed:
        """Three fields or a refusal, because a seed missing two of them is not one.

        The registry is guarden's own file and this is the only place a value in
        it can be checked against what it has to be, so a hand edit that dropped
        `service` is caught here rather than becoming a mark on `:@41` — a
        snapshot id with an empty service in it, which is not a snapshot anything
        holds.
        """
        if not isinstance(document, dict):
            raise errors.GuardenError(
                "a seed names the snapshot it was forked from, and a bare number names "
                "nothing that can be marked; it is a table of service, volume and number",
                errors.HOST_NOT_AS_ASSUMED,
            )
        missing = [
            key for key in ("service", "volume", "number") if not document.get(key)
        ]
        if missing:
            raise errors.GuardenError(
                f"a seed is missing {', '.join(missing)}; a seed names the snapshot it was "
                f"forked from, and a seed with no service and volume beside it names "
                f"nothing that can be marked",
                errors.HOST_NOT_AS_ASSUMED,
            )
        return cls(
            service=str(document["service"]),
            volume=str(document["volume"]),
            number=int(document["number"]),
        )


def _seeds(document: Any) -> dict[str, Seed]:
    return {
        name: Seed.from_document(entry)
        for name, entry in (document or {}).items()
    }


@dataclass
class Instance:
    ref: str
    escaped_ref: str
    created: str
    publication: dict[str, int] = field(default_factory=dict)
    seed: dict[str, Seed] = field(default_factory=dict)

    def to_document(self) -> dict[str, Any]:
        # `ref` is stored alongside the escaped key, because the escaping is
        # deliberately many-to-one: `feature/x` and `feature-x` both become
        # `feature\x2dx` so that they cannot collide, which is exactly why the raw
        # ref cannot be recovered from the key. spec 3.4's example does not list
        # this key, and an operator shown `feature\x2dx` where they typed
        # `feature-login` would be reading a storage detail as a name.
        document: dict[str, Any] = {"ref": self.ref, "created": self.created}
        if self.publication:
            document["publication"] = dict(self.publication)
        if self.seed:
            document["seed"] = {name: seed.to_document() for name, seed in self.seed.items()}
        return document

    @classmethod
    def from_document(cls, escaped_ref: str, document: dict) -> Instance:
        return cls(
            ref=document.get("ref", escaped_ref),
            escaped_ref=escaped_ref,
            created=document.get("created", ""),
            publication=dict(document.get("publication", {})),
            seed=_seeds(document.get("seed")),
        )


@dataclass
class RuleEntry:
    """One requested `firewall:` rule: the name a grant names, the chain, the text.

    The name is a request's stable identity and the text is its content, because
    deduplication is by content and the count of grants is by name (spec 7.7).
    A grant is `overrides.toml`'s answer and never enters here as text: this is
    what the manifest asked for, in manifest order, and it installs nothing.
    """

    name: str
    chain: str
    rule: str

    def to_document(self) -> dict[str, str]:
        return {"name": self.name, "chain": self.chain, "rule": self.rule}

    @classmethod
    def from_document(cls, document: Any) -> RuleEntry:
        """Three fields or a refusal, for the reason `Seed.from_document` gives.

        A request missing its `rule` is not a request, and a grant naming it
        would resolve to nothing to install.
        """
        if not isinstance(document, dict):
            raise errors.GuardenError(
                "a requested firewall rule names the rule it wants installed, and a bare "
                "value names no rule; it is a table of name, chain and rule",
                errors.HOST_NOT_AS_ASSUMED,
            )
        missing = [key for key in ("name", "chain", "rule") if not document.get(key)]
        if missing:
            raise errors.GuardenError(
                f"a requested firewall rule is missing {', '.join(missing)}; a request names "
                f"what it wants installed, and one with no rule behind it is nothing to grant",
                errors.HOST_NOT_AS_ASSUMED,
            )
        return cls(
            name=str(document["name"]),
            chain=str(document["chain"]),
            rule=str(document["rule"]),
        )


def _rule_entries(value: Any) -> list[RuleEntry]:
    return [RuleEntry.from_document(entry) for entry in (value or [])]


@dataclass
class OwnerUnit:
    """One unit's own probe answer, for a service whose units name more than one
    image (ADR-0019): the image the pair was read from, and the pair.

    The image is in the record because the pair is only true of the image it
    was read from — a unit whose `Image=` changes is the probe's condition
    again, and a record that could not say which image answered which unit
    could only answer every unit with ONE image's user, which is the failure
    this field exists to prevent.
    """

    image: str
    uid: int
    gid: int

    def to_document(self) -> dict[str, Any]:
        return {"image": self.image, "uid": self.uid, "gid": self.gid}

    @classmethod
    def from_document(cls, entry: Any) -> OwnerUnit:
        """Three fields or a refusal, for the reason `RuleEntry.from_document`
        gives: an entry that does not name an image and two numbers is not an
        answer, and rendering it would pin a unit nobody probed."""
        if not isinstance(entry, dict):
            raise errors.GuardenError(
                "a per-unit image owner is a table of image, uid and gid, and this "
                "one is not",
                errors.HOST_NOT_AS_ASSUMED,
            )
        try:
            return cls(image=str(entry["image"]), uid=int(entry["uid"]), gid=int(entry["gid"]))
        except (KeyError, TypeError, ValueError):
            raise errors.GuardenError(
                "a per-unit image owner is a table of image, uid and gid, and this "
                "one does not carry all three",
                errors.HOST_NOT_AS_ASSUMED,
            ) from None


@dataclass
class Registry:
    service: str
    workload: str
    project: str
    environment: str
    uid: int
    created: str
    # The uid and gid guarden probed out of the service's image at its first
    # start, and the only source the renderer's `UserNS=keep-id:uid=...,gid=...`
    # line is written from (ADR-0019). `None` is "not probed yet", which is the
    # probe's own condition; `0` is the image declaring no user at all, whose
    # container root the default map already moves onto the service identity.
    owner_uid: int | None = None
    owner_gid: int | None = None
    # The image those two were read from. The pair is only true of that image,
    # so a unit naming another one is the probe's condition again rather than a
    # unit this pair answers (ADR-0019).
    owner_image: str | None = None
    # Per-unit answers, written only when the service's units name MORE THAN
    # ONE image: `owner_uid`/`owner_gid` stay the single-image record they have
    # always been — the drift anchor and the field an operator edits by hand —
    # and this map is what the renderer answers each unit from when the units
    # disagree about their user. An empty map writes no table at all, so a
    # single-image document gains only `owner_image` and never a table.
    owner_units: dict[str, OwnerUnit] = field(default_factory=dict)
    source: str = SOURCE_MANUAL
    installed_by: str | None = None
    deployed_sha: str | None = None
    source_hash: str | None = None
    publication: dict[str, int] = field(default_factory=dict)
    edges: dict[str, dict] = field(default_factory=dict)
    provides: list[str] = field(default_factory=list)
    route_hosts: dict[str, str] = field(default_factory=dict)
    route_destinations: dict[str, str] = field(default_factory=dict)
    ports_requested: list[int] = field(default_factory=list)
    ports_granted: list[int] = field(default_factory=list)
    firewall_requested: list[RuleEntry] = field(default_factory=list)
    # Never read when rendering: `overrides.toml` is the authority (spec 7.7).
    firewall_granted: list[str] = field(default_factory=list)
    volumes: dict[str, Volume] = field(default_factory=dict)
    # A slot service's own seed, per state volume. An instance's is inside its
    # own `[instances."<escaped-ref>"]` table, because an instance's volumes are
    # the instance's and a seed recorded against the service would be ambiguous
    # between two previews of the same workload.
    seed: dict[str, Seed] = field(default_factory=dict)
    instances: dict[str, Instance] = field(default_factory=dict)
    # `gate` is `None` when the gate has never been evaluated, and that is **not**
    # the same as `state = "ready"` (spec 3.4): the registry omits the table
    # entirely rather than writing a verdict nobody took.
    gate: dict[str, Any] | None = None
    generated: dict[str, str] = field(default_factory=dict)
    immutable: dict[str, str] = field(default_factory=dict)

    def volume_list(self) -> list[Volume]:
        """`state` before `bulk`, then by name: a fixed order, so a regenerated
        registry and a rendered list agree byte for byte."""
        return sorted(self.volumes.values(), key=lambda v: (v.kind != "state", v.name))

    def to_document(self) -> dict[str, Any]:
        document: dict[str, Any] = {
            "service": self.service,
            "workload": self.workload,
            "project": self.project,
            "environment": self.environment,
            "uid": self.uid,
            "created": self.created,
            "source": self.source,
        }
        if self.installed_by:
            document["installed_by"] = self.installed_by
        if self.deployed_sha:
            document["deployed_sha"] = self.deployed_sha
        if self.source_hash:
            document["source_hash"] = self.source_hash
        if self.owner_uid is not None:
            document["owner_uid"] = self.owner_uid
        if self.owner_gid is not None:
            document["owner_gid"] = self.owner_gid
        if self.owner_image:
            document["owner_image"] = self.owner_image
        if self.owner_units:
            document["owner_units"] = {
                name: unit.to_document() for name, unit in sorted(self.owner_units.items())
            }
        if self.publication:
            document["publication"] = dict(self.publication)
        if self.edges:
            document["edges"] = {name: dict(edge) for name, edge in self.edges.items()}
        if self.provides:
            document["provides"] = {"kinds": list(self.provides)}
        if self.route_hosts:
            document["route_hosts"] = dict(self.route_hosts)
        if self.route_destinations:
            document["route_destinations"] = dict(self.route_destinations)
        if self.ports_requested or self.ports_granted:
            document["ports"] = {
                "requested": list(self.ports_requested),
                "granted": list(self.ports_granted),
            }
        if self.firewall_requested or self.firewall_granted:
            firewall: dict[str, Any] = {
                "requested": [entry.to_document() for entry in self.firewall_requested]
            }
            if self.firewall_granted:
                firewall["granted"] = list(self.firewall_granted)
            document["firewall"] = firewall
        state = {v.name: v for v in self.volumes.values() if v.kind == "state"}
        bulk = {v.name: v for v in self.volumes.values() if v.kind == "bulk"}
        if state:
            document["state"] = {name: v.to_document() for name, v in sorted(state.items())}
        if bulk:
            document["bulk"] = {name: v.to_document() for name, v in sorted(bulk.items())}
        if self.seed:
            document["seed"] = {
                name: seed.to_document() for name, seed in sorted(self.seed.items())
            }
        if self.instances:
            document["instances"] = {
                key: instance.to_document() for key, instance in sorted(self.instances.items())
            }
        if self.gate is not None:
            document["gate"] = dict(self.gate)
        if self.generated:
            document["generated"] = dict(self.generated)
        if self.immutable:
            document["immutable"] = dict(self.immutable)
        return document

    @classmethod
    def from_document(cls, document: dict) -> Registry:
        volumes: dict[str, Volume] = {}
        for kind in ("state", "bulk"):
            for name, entry in (document.get(kind) or {}).items():
                volumes[name] = Volume.from_document(kind, name, entry or {})
        instances = {
            key: Instance.from_document(key, entry or {})
            for key, entry in (document.get("instances") or {}).items()
        }
        ports = document.get("ports") or {}
        firewall = document.get("firewall") or {}
        provides = (document.get("provides") or {}).get("kinds") or []
        return cls(
            service=document["service"],
            workload=document.get("workload", ""),
            project=document.get("project", ""),
            environment=document.get("environment", ""),
            uid=document.get("uid", 0),
            created=document.get("created", ""),
            source=document.get("source", SOURCE_MANUAL),
            installed_by=document.get("installed_by"),
            deployed_sha=document.get("deployed_sha"),
            source_hash=document.get("source_hash"),
            owner_uid=_owner_id(document, "owner_uid"),
            owner_gid=_owner_id(document, "owner_gid"),
            owner_image=document.get("owner_image"),
            owner_units={
                name: OwnerUnit.from_document(entry)
                for name, entry in (document.get("owner_units") or {}).items()
            },
            publication=dict(document.get("publication") or {}),
            edges={name: dict(edge or {}) for name, edge in (document.get("edges") or {}).items()},
            provides=list(provides),
            route_hosts=dict(document.get("route_hosts") or {}),
            route_destinations=dict(document.get("route_destinations") or {}),
            ports_requested=list(ports.get("requested") or []),
            ports_granted=list(ports.get("granted") or []),
            firewall_requested=_rule_entries(firewall.get("requested")),
            firewall_granted=[str(name) for name in (firewall.get("granted") or [])],
            volumes=volumes,
            seed=_seeds(document.get("seed")),
            instances=instances,
            gate=document.get("gate"),
            generated=dict(document.get("generated") or {}),
            immutable=dict(document.get("immutable") or {}),
        )


def _owner_id(document: dict, key: str) -> int | None:
    """One of the probe's two numbers as the document spells it: converted,
    or refused.

    `owner_uid` is the field an operator edits BY HAND, so a quoted value
    reaches this reader as a string — and unconverted it walked into the
    renderer's `uid and uid > 0` and out of `weedr service start` as a
    TypeError (measured, t350), a traceback instead of the one line spec 1.2
    promises. Converting is what `OwnerUnit.from_document` already does for
    the per-unit table; a value that is not a number at all is refused the
    same way it refuses one, naming the service and the field: host state
    that does not hold what guarden wrote (spec 1.2, exit 1).
    """
    value = document.get(key)
    if value is None:
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        raise errors.GuardenError(
            f"{document.get('service', 'the service')}: the registry entry carries "
            f"{value!r} as {key}, and a uid or gid the probe recorded is a number",
            errors.HOST_NOT_AS_ASSUMED,
        ) from None


def path_for(service: str) -> Path:
    return paths.registry(service)


def load(service: str) -> Registry | None:
    """A service's record, or `None` when it has none. Absent is not an error."""
    document = conf.read_toml(path_for(service))
    if not document:
        return None
    try:
        return Registry.from_document(document)
    except KeyError as exc:
        raise errors.GuardenError(
            f"{path_for(service)} has no {exc.args[0]!r}", errors.HOST_NOT_AS_ASSUMED
        ) from exc


def save(registry: Registry, owner: tuple[int, int]) -> None:
    conf.write_toml(path_for(registry.service), registry.to_document(), REGISTRY_MODE, owner)


def delete(service: str) -> bool:
    target = path_for(service)
    if not target.exists():
        return False
    target.unlink()
    return True


def names() -> list[str]:
    """Every service with a record, in name order."""
    if not paths.REGISTRY.is_dir():
        return []
    return sorted(path.stem for path in paths.REGISTRY.glob("*.toml"))


def remove_report() -> list[tuple[str, str, str]]:
    """What `weedr service list` says about the removed directory: one
    `(service, when, volume)` per moved volume, in a stable order.

    A removed service has no registry entry — `remove` reverses all of it — so
    there is no `services` object to hang this on, and the human report is where
    it belongs. The JSON field set in spec 1.2 covers `weedr service list --json`
    only, and it is `services`.
    """
    if not paths.REMOVED.is_dir():
        return []
    out: list[tuple[str, str, str]] = []
    for service_dir in sorted(paths.REMOVED.iterdir()):
        if not service_dir.is_dir():
            continue
        for when_dir in sorted(service_dir.iterdir()):
            if not when_dir.is_dir():
                continue
            for volume_dir in sorted(when_dir.iterdir()):
                out.append((service_dir.name, when_dir.name, volume_dir.name))
    return out
