"""`weedr service list`: the status command, human and `--json`.

spec 6.2 and spec 1.2's field set. The field set is **closed**: an unknown field
is never emitted and never read, and adding one to a program is a change to that
table and not a compatible addition. So every one of the fourteen fields is
present on every service object, and a field with nothing to say is `null` or an
empty collection rather than absent — with the one distinction the spec insists
on, that `gate: null` is **not** the same as `gate.state = "ready"`, because one
is a verdict nobody took.

Two host invariants are reported here and corrected by nobody: IPv6 being
re-enabled, and `net.ipv4.ip_unprivileged_port_start` not being `1024`. Both put
the box outside the design. `soil sysctl` converges the second — raising the
threshold is a tightening and is exactly what guarden should do — and this verb
only says so, because the operator who changed it is the one who can put it back.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field

from guarden import edges, paths, registry, snapper
from guarden import overrides as overrides_mod

IPV6 = "net/ipv6/conf/all/disable_ipv6"
IP_UNPRIVILEGED_PORT_START = "net/ipv4/ip_unprivileged_port_start"
PORT_THRESHOLD = "1024"


@dataclass
class Listing:
    services: list[dict]
    warnings: list[str]
    removed: list[tuple[str, str, str]]
    # The values guarden minted rather than a human planted. Spec 1.2's field set
    # is closed and has no room for them, and adding one would be a change to that
    # table; `weedr secret list --json` carries the same fact per key in its
    # `source`, so the human report is where `list` mentions it.
    generated: dict[str, dict[str, str]] = field(default_factory=dict)


def host_invariants() -> list[str]:
    """The two things that put the box outside this design, reported and not fixed."""
    warnings: list[str] = []
    ipv6 = _read_sysctl(IPV6)
    if ipv6 is None:
        warnings.append(f"warning: could not read {paths.sysctl(IPV6)}, so IPv6 is unchecked")
    elif ipv6 != "1":
        warnings.append("warning: IPv6 has been re-enabled; every rule guarden renders is IPv4")
    threshold = _read_sysctl(IP_UNPRIVILEGED_PORT_START)
    if threshold is None:
        warnings.append(
            f"warning: could not read {paths.sysctl(IP_UNPRIVILEGED_PORT_START)}, "
            f"so the privileged port threshold is unchecked"
        )
    elif threshold != PORT_THRESHOLD:
        warnings.append(
            f"warning: net.ipv4.ip_unprivileged_port_start is {threshold}, not "
            f"{PORT_THRESHOLD}, so an unprivileged process may bind a privileged port"
        )
    return warnings


def _read_sysctl(name: str) -> str | None:
    try:
        return paths.sysctl(name).read_text().strip()
    except OSError:
        return None


def build() -> Listing:
    """One object per service, plus the host's own warnings and the removed
    directory's contents.

    The removed directory is in the human report and **not** in the JSON: spec 1.2
    makes `weedr service list --json` exactly `services`, and a removed service has
    no registry entry for an object to hang on, because `remove` reverses all of
    it. Adding a `removed` key to that object would be a change to a closed field
    set, and the ticket's "reports anything sitting in the removed directory" is
    satisfied where the field set does not bind.
    """
    invariants = host_invariants()
    services = []
    generated: dict[str, dict[str, str]] = {}
    for name in registry.names():
        record = registry.load(name)
        if record is not None:
            services.append(_service_object(record, invariants))
            generated[record.service] = dict(sorted(record.generated.items()))
    return Listing(
        services=services,
        warnings=invariants,
        removed=registry.remove_report(),
        generated=generated,
    )


def _service_object(record, invariants: list[str]) -> dict:
    granted = overrides_mod.load(record.service)
    granted_numbers = granted.granted_numbers()
    pending = [port for port in record.ports_requested if port not in granted_numbers]
    warnings = [*invariants]
    for group in granted.groups:
        warnings.append(f"warning: supplementary group {group!r} is not on the host")
    return {
        "name": record.service,
        "workload": record.workload,
        "project": record.project,
        "environment": record.environment,
        "uid": record.uid,
        "source": record.source,
        "deployed_sha": record.deployed_sha,
        "publication": {
            "containers": [
                {"container": container, "port": port}
                for container, port in sorted(record.publication.items())
                if container != "api"
            ],
            "api": record.publication.get("api"),
        },
        "edges": [
            {
                "service": edges.provider_of(provider),
                "port": edge.get("port"),
                "as": edge.get("as"),
                "auth": edge.get("auth"),
                "publications": edge.get("publications", []),
            }
            for provider, edge in sorted(record.edges.items())
        ],
        "ports": {
            "requested": list(record.ports_requested),
            "granted": granted_numbers,
            "pending": pending,
        },
        "route_hosts": dict(record.route_hosts),
        "volumes": [_volume_object(record, volume) for volume in record.volume_list()],
        "instances": [
            {
                "ref": instance.ref,
                "created": instance.created,
                "seed": {name: seed.to_document() for name, seed in instance.seed.items()},
                "volumes": [
                    _volume_object(record, volume, escaped)
                    for volume in record.volume_list()
                ],
            }
            for escaped, instance in sorted(record.instances.items())
        ],
        "gate": dict(record.gate) if record.gate is not None else None,
        "warnings": warnings,
    }


def _volume_object(record, volume, escaped_ref: str | None = None) -> dict:
    moved = _removed_path(record.service, volume.name)
    config_name = volume.config
    if config_name is None and escaped_ref:
        config_name = paths.snapper_config(record.service, volume.name, escaped_ref)
    counts = snapper.read(config_name) if config_name else None
    return {
        "name": volume.name,
        "kind": volume.kind,
        "config": config_name,
        "snapshots": counts.to_json() if counts is not None else None,
        "removed": str(moved) if moved else None,
    }


def _removed_path(service: str, vol: str):
    """Where a volume of this service now lives, if it has been moved aside.

    Read out of the removed directory rather than remembered anywhere, so the
    answer survives a restore and a `list` on a half-removed service is an answer
    rather than a guess.
    """
    if not paths.REMOVED.is_dir():
        return None
    for service_dir in sorted(paths.REMOVED.iterdir()):
        if service_dir.name != service or not service_dir.is_dir():
            continue
        for when_dir in sorted(service_dir.iterdir()):
            candidate = when_dir / vol
            if candidate.is_dir():
                return candidate
    return None


def as_json(listing: Listing) -> str:
    """One JSON object on one line and nothing else, so a caller may parse it
    without stripping prose. The object is `services` and nothing else."""
    return json.dumps({"services": listing.services}, separators=(",", ":"))


def as_text(listing: Listing) -> str:
    lines: list[str] = []
    if not listing.services:
        lines.append("no services")
    for entry in listing.services:
        lines.append(_service_text(entry, listing.generated.get(entry["name"], {})))
    if listing.removed:
        lines.append("removed:")
        for service, when, vol in listing.removed:
            lines.append(f"  {service} {when} {vol}")
    for warning in listing.warnings:
        lines.append(warning)
    return "\n".join(lines) + "\n"


def _service_text(entry: dict, generated: dict[str, str]) -> str:
    lines = [
        f"{entry['name']}  workload {entry['workload']}  project {entry['project']}  "
        f"track {entry['environment']}  uid {entry['uid']}  source {entry['source']}"
    ]
    publications = ", ".join(
        f"{pair['container']}={pair['port']}" for pair in entry["publication"]["containers"]
    )
    if entry["publication"]["api"]:
        publications += f", api={entry['publication']['api']}"
    lines.append(f"  publications   {publications or 'none'}")
    ports = entry["ports"]
    granted = ports["granted"] or "none"
    pending = ports["pending"] or "none"
    lines.append(f"  ports          granted {granted}  pending {pending}")
    for volume in entry["volumes"]:
        config = volume["config"] or "no snapper configuration"
        line = f"  volume         {volume['kind']} {volume['name']}  {config}"
        if volume["snapshots"] is not None:
            counts = volume["snapshots"]
            line += (
                f"  {counts['total']} snapshots, {counts['marked']} marked,"
                f" oldest {counts['oldest'] or '-'}, newest {counts['newest'] or '-'}"
            )
            limits = counts["limits"]
            if limits:
                line += f"  NUMBER_LIMIT {limits.get('NUMBER_LIMIT', '-')}"
                line += f", NUMBER_LIMIT_IMPORTANT {limits.get('NUMBER_LIMIT_IMPORTANT', '-')}"
        if volume["removed"]:
            line += f"  moved to {volume['removed']}"
        lines.append(line)
    if entry["instances"]:
        for instance in entry["instances"]:
            lines.append(f"  instance       {instance['ref']}  seed {instance['seed'] or 'none'}")
    for key, when in sorted(generated.items()):
        lines.append(f"  generated      {key}  minted {when}")
    if entry["gate"] is None:
        lines.append("  gate           not evaluated")
    else:
        reason = entry["gate"].get("reason")
        lines.append(
            f"  gate           {entry['gate'].get('state')}" + (f"  {reason}" if reason else "")
        )
    for warning in entry["warnings"]:
        lines.append(f"  {warning}")
    return "\n".join(lines)
