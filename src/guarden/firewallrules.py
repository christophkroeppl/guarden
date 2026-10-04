"""`weedr firewall`: the grant a manifest asks for and an admin decides (spec 7.7).

Same shape as `weedr port` and for the same reason: repository input naming
something the host owns. `open` and `close` are root and on no sudoers rule, so
nothing that answers a push can reach them; `list` reads the registries and the
overrides, both `root:guarden`, so it needs no privilege a `guarden` program
lacks and is the one that is.
"""

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
            f"{service} has no registry entry, so it has asked for no firewall rule to grant",
            errors.HOST_NOT_AS_ASSUMED,
        )
    return record


def open_rule(service: str, name: str) -> int:
    record = _record(service)
    names.validate(name, "firewall rule name")
    entry = firewall.requested_rule(record, name)

    with conf.lock("overrides"):
        granted = overrides_mod.load(service)
        already = name in granted.firewall
        if not already:
            granted.firewall = sorted([*granted.firewall, name])
            overrides_mod.save(service, granted, firewall.owner())
            with conf.lock("registry"):
                held = registry.load(service)
                if held is not None:
                    held.firewall_granted = sorted({*held.firewall_granted, name})
                    registry.save(held, firewall.owner())

    firewall.print_diff(firewall.install(firewall.config()))
    if already:
        sys.stdout.write(f"{service} {name} is already granted\n")
        return 0
    sys.stdout.write(f"granted {service} {name}: {entry.rule}\n")
    return 0


def close_rule(service: str, name: str) -> int:
    _record(service)
    names.validate(name, "firewall rule name")

    with conf.lock("overrides"):
        granted = overrides_mod.load(service)
        held = name in granted.firewall
        if held:
            granted.firewall = [item for item in granted.firewall if item != name]
            overrides_mod.save(service, granted, firewall.owner())
            with conf.lock("registry"):
                record = registry.load(service)
                if record is not None:
                    record.firewall_granted = [
                        item for item in record.firewall_granted if item != name
                    ]
                    registry.save(record, firewall.owner())

    firewall.print_diff(firewall.install(firewall.config()))
    if not held:
        sys.stdout.write(f"{service} {name} was not granted\n")
        return 0
    sys.stdout.write(f"closed {service} {name}\n")
    return 0


def list_rules(as_json: bool) -> int:
    entries = firewall.rules_listing()
    if as_json:
        sys.stdout.write(json.dumps({"rules": entries}, separators=(",", ":")) + "\n")
        return 0
    sys.stdout.write(firewall.rules_as_text(entries))
    return 0