"""`weedr port`: the grant a manifest asks for and an admin decides (spec 6.2)."""

from __future__ import annotations

import json
import sys

from guarden import conf, errors, firewall, names, registry
from guarden import overrides as overrides_mod


def _record(service: str):
    names.validate(service)
    record = registry.load(service)
    if record is None:
        raise errors.GuardenError(
            f"{service} has no registry entry, so it has asked for no port to grant",
            errors.HOST_NOT_AS_ASSUMED,
        )
    return record


def _requested(record, number: int) -> None:
    if number in record.ports_requested:
        return
    raise errors.GuardenError(
        f"{record.service} requests no port {number}, and a port no manifest requested may not "
        f"be granted at all: a grant is a translation to a publication, a publication is "
        f"allocated per container, and a request naming only a public port names no container, "
        f"so the grant had no destination. The manifest needs "
        f"`ports: [ {{ container: <container>, port: {number} }} ]` and a deploy before this",
        errors.REJECTED_INPUT,
    )


def open_port(service: str, argument: str) -> int:
    number, protocol = firewall.parse_selector(argument)
    record = _record(service)
    _requested(record, number)
    grant = firewall.resolve(record, number, protocol)
    entry = grant.selector

    with conf.lock("overrides"):
        held = firewall.holder(number, protocol, excluding=service)
        if held is not None:
            raise errors.GuardenError(
                f"port {number}/{protocol} is already granted to {held}, and a public port goes "
                f"to one service at a time; `weedr port close {held} {number}/{protocol}` first",
                errors.HOST_NOT_AS_ASSUMED,
            )
        granted = overrides_mod.load(service)
        already = entry in granted.open
        if not already:
            granted.open = sorted([*granted.open, entry])
            overrides_mod.save(service, granted, firewall.owner())

    firewall.print_diff(firewall.install(firewall.config()))
    if already:
        sys.stdout.write(f"{service} {entry} is already granted\n")
        return 0
    sys.stdout.write(f"granted {service} {entry} to 127.0.0.1:{grant.publication}\n")
    return 0


def close_port(service: str, argument: str) -> int:
    number, protocol = firewall.parse_selector(argument)
    _record(service)
    entry = f"{number}/{protocol}"

    with conf.lock("overrides"):
        granted = overrides_mod.load(service)
        held = entry in granted.open
        if held:
            granted.open = [item for item in granted.open if item != entry]
            overrides_mod.save(service, granted, firewall.owner())

    firewall.print_diff(firewall.install(firewall.config()))
    if not held:
        sys.stdout.write(f"{service} {entry} was not granted\n")
        return 0
    sys.stdout.write(f"closed {service} {entry}\n")
    return 0


def list_ports(as_json: bool) -> int:
    services = firewall.listing()
    if as_json:
        sys.stdout.write(json.dumps({"services": services}, separators=(",", ":")) + "\n")
        return 0
    sys.stdout.write(firewall.as_text(services))
    return 0