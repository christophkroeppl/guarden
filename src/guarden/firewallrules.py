"""`weedr firewall`: the grant a manifest asks for and an admin decides (spec 7.7).

Same shape as `weedr port` and for the same reason: repository input naming
something the host owns. `open` and `close` are root and on no sudoers rule, so
nothing that answers a push can reach them; `list` reads the registries and the
overrides, both `root:guarden`, so it needs no privilege a `guarden` program
lacks and is the one that is.
"""

from __future__ import annotations

import json
import re
import sys

from guarden import conf, errors, firewall, names, registry, tool
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

def show(service: str) -> int:
    names.validate(service)
    record = registry.load(service)
    if record is None:
        raise errors.GuardenError(
            f"{service} has no registry entry, so there is nothing to show",
        )
    config = firewall.config()
    accept_map = firewall._service_accept_map(config)

    sys.stdout.write(f"service: {service} (uid {record.uid})\n\n")

    sys.stdout.write("dial-set (what this service may reach):\n")
    for owner_svc in sorted(accept_map):
        for port in sorted(accept_map[owner_svc]):
            for uid, reason in sorted(accept_map[owner_svc][port].items()):
                if uid == record.uid:
                    sys.stdout.write(
                        f"  127.0.0.1:{port}  ({owner_svc})  {reason}\n"
                    )
    sys.stdout.write("  127.0.0.53:53  (resolver)  resolver\n")

    sys.stdout.write("\ndoor-set (who may dial this service's publications):\n")
    for port in sorted(accept_map.get(service, {})):
        for uid, reason in sorted(accept_map[service][port].items()):
            sys.stdout.write(f"  {port}: uid {uid}  {reason}\n")
    return 0


def check() -> int:
    port_owner = {}
    for name in registry.names():
        record = registry.load(name)
        if record is None:
            continue
        for port in record.publication.values():
            port_owner[port] = record.uid
        for instance in record.instances.values():
            for port in instance.publication.values():
                port_owner[port] = record.uid

    try:
        result = tool.call(["ss", "-tlnpe"])
    except errors.GuardenError:
        result = None
    found = False
    if result is not None and result.ok:
        for line in (result.stdout or "").splitlines():
            fields = line.split()
            if len(fields) < 4:
                continue
            local = fields[3]
            if not local.startswith("127.0.0.1:"):
                continue
            try:
                port = int(local.rsplit(":", 1)[1])
            except ValueError:
                continue
            if port not in port_owner:
                continue
            uid_match = re.search(r"uid:(\d+)", line)
            uid = int(uid_match.group(1)) if uid_match else None
            if uid is None:
                pid_match = re.search(r"pid=(\d+)", line)
                if pid_match:
                    try:
                        with open(f"/proc/{pid_match.group(1)}/status") as handle:
                            for row in handle:
                                if row.startswith("Uid:"):
                                    uid = int(row.split()[1])
                                    break
                    except OSError:
                        uid = None
            if uid is None:
                continue
            owner = port_owner[port]
            if uid != owner:
                sys.stdout.write(
                    f"squatted publication: 127.0.0.1:{port} listener uid {uid} "
                    f"!= owner {owner}\n"
                )
                found = True
    if not found:
        sys.stdout.write("no squatted publications\n")
    return 0
