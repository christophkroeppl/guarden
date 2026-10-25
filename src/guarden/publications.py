"""Publication and route-host allocation, from the ranges the host declares.

spec 7.2 and 7.4: one loopback namespace, one publication per container, and
the allocation persisted in the registry so it is stable across regenerations
and unique per service and per instance. The range is
`ingress.publication_range` and nothing here chooses a number of its own.

A host is allocated the same way (spec 4): `<track host_prefix><label>`, plus
the zone the route is published in when it is a tunnel route, and the second
claimant is refused with the holder named.
"""

from __future__ import annotations

from guarden import errors

API = "api"


def held(records) -> set[int]:
    used: set[int] = set()
    for record in records:
        used.update(record.publication.values())
        for instance in record.instances.values():
            used.update(instance.publication.values())
    return used


def allocate(wanted, current: dict[str, int], used: set[int], span, what: str) -> dict[str, int]:
    """One publication per name in `wanted`, none of them held by anybody else.

    `current` is what this service already holds and a name keeps its number
    while that number is still free: the allocation is persisted, so a second
    render must not move a port a rendered firewall rule already names. Names
    are taken in sorted order so the same input allocates the same numbers on
    every run.
    """
    first, last = span
    if not 1 <= first <= last <= 65535:
        raise errors.GuardenError(
            f"ingress.publication_range is {first}-{last}, and a publication is a TCP/UDP number",
            errors.HOST_NOT_AS_ASSUMED,
        )
    taken = set(used)
    out: dict[str, int] = {}
    for name in sorted(set(wanted)):
        existing = current.get(name)
        if isinstance(existing, int) and existing not in taken:
            out[name] = existing
            taken.add(existing)
            continue
        free = [port for port in range(first, last + 1) if port not in taken]
        if not free:
            raise errors.GuardenError(
                f"{what}: ingress.publication_range {first}-{last} has no free publication "
                f"left for {name!r}",
                errors.HOST_NOT_AS_ASSUMED,
            )
        out[name] = free[0]
        taken.add(free[0])
    return out


def claim_host(label: str, prefix: str, zone: str, holders: dict[str, str], service: str) -> str:
    """`<host_prefix><label><zone>`, refused when another service already holds it.

    `holders` maps a full host name to the service that claimed it and is read
    from every registry, so the refusal names the holder rather than a number.

    `zone` is the suffix the route's destination publishes it in — `""` for a
    route the edge or nothing carries, `.` and the tunnel's zone when it is a
    tunnel route (`service._zone` is the one place that decides, and it is the
    one place because a name is only ever right if the record and the tunnel
    agree about it).
    """
    full = f"{prefix}{label}{zone}"
    holder = holders.get(full)
    if holder is not None and holder != service:
        raise errors.GuardenError(
            f"{service} claims the route host {full!r}, and {holder} already holds it; a "
            f"route host is allocated and the allocator refuses the second claimant",
            errors.HOST_NOT_AS_ASSUMED,
        )
    return full


def host_holders(records) -> dict[str, str]:
    out: dict[str, str] = {}
    for record in records:
        for full in record.route_hosts.values():
            out[full] = record.service
    return out
