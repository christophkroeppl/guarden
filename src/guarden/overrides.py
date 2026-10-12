"""`/etc/guarden/services/<name>/overrides.toml`: the admin's grant surface, and
the whole of it (spec 3.3).

Five tables and nothing else. `[ports] open` is a public port the admin granted;
`[retention] keep_last` and `[retention] free_limit` override the track's
defaults; `[groups] add` gives the service user supplementary groups, which is
how a hardware-transcoding service reaches `/dev/dri` without the renderer
knowing anything about video; and `[mounts] allow` is the only way a host path
outside the service's own volumes and `/etc/guarden` becomes bind-mountable.
`[expose] tunnel` names route LABELS published through the tunnel INSTEAD of
the edge. There is deliberately no `[expose] edge` because "not through the
tunnel" is what the track's `expose` already says.

**Nothing else is overridable.** Routes, edges, state volumes, the unit source
and the credential schema are the repository's, and this file does not touch
them — so a key here that is not one of the eight is refused by name rather than
ignored, because a silently ignored grant is a grant an operator believes is in
effect.

`keep_last` is the ladder's **daily bucket maximum** and nothing else (spec 8.1):
it is not a mark count, and it does not move `NUMBER_LIMIT_IMPORTANT`. The other
buckets live beside it so an operator who wants a track to keep nothing can say
so, because `keep_last = 0` only turns the daily bucket off.

Seeded from the track on creation and never rewritten by anything but an admin's
own verb.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from typing import Any

from guarden import conf, errors, paths

OVERRIDES_MODE = 0o640

KEYS = {"ports", "retention", "groups", "mounts", "firewall", "expose"}
PORT_KEYS = {"open"}
RETENTION_KEYS = {"keep_last", "free_limit", "weekly", "monthly", "quarterly"}
GROUP_KEYS = {"add"}
MOUNT_KEYS = {"allow"}
FIREWALL_KEYS = {"allow"}
EXPOSE_KEYS = {"tunnel"}

WEEKLY = 4
MONTHLY = 6
QUARTERLY = 2


@dataclass
class Overrides:
    open: list[str] = field(default_factory=list)
    keep_last: int | None = None
    free_limit: float | None = None
    weekly: int | None = None
    monthly: int | None = None
    quarterly: int | None = None
    groups: list[str] = field(default_factory=list)
    mounts: list[str] = field(default_factory=list)
    firewall: list[str] = field(default_factory=list)
    expose_tunnel: list[str] = field(default_factory=list)

    def to_document(self) -> dict[str, Any]:
        document: dict[str, Any] = {}
        if self.open:
            document["ports"] = {"open": list(self.open)}
        retention: dict[str, Any] = {}
        if self.keep_last is not None:
            retention["keep_last"] = self.keep_last
        if self.free_limit is not None:
            retention["free_limit"] = self.free_limit
        if self.weekly is not None:
            retention["weekly"] = self.weekly
        if self.monthly is not None:
            retention["monthly"] = self.monthly
        if self.quarterly is not None:
            retention["quarterly"] = self.quarterly
        if retention:
            document["retention"] = retention
        if self.groups:
            document["groups"] = {"add": list(self.groups)}
        if self.mounts:
            document["mounts"] = {"allow": list(self.mounts)}
        if self.firewall:
            document["firewall"] = {"allow": list(self.firewall)}
        if self.expose_tunnel:
            document["expose"] = {"tunnel": list(self.expose_tunnel)}
        return document

    def keep_last_or(self, track_default: int) -> int:
        return track_default if self.keep_last is None else self.keep_last

    def free_limit_or(self, track_default: float) -> float:
        return track_default if self.free_limit is None else self.free_limit

    def granted_numbers(self) -> list[int]:
        """The public ports granted, as numbers.

        The stored form is a `PORT/PROTO` string, which is what spec 3.3 shows and
        what the protocol belongs to; the registry's `requested`/`granted` are
        bare numbers (spec 6.2), so the grant resolves against one shape and this
        is where the string becomes a number.
        """
        return [_port_number(grant) for grant in self.open]


def _port_number(grant: str) -> int:
    return int(grant.split("/", 1)[0])


def _string_list(table: dict, key: str, allowed: set[str], where: str) -> list[str]:
    value = table.get(key, [])
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise errors.GuardenError(
            f"{where}: {key} is not a list of strings", errors.HOST_NOT_AS_ASSUMED
        )
    return list(value)


def _int(table: dict, key: str, where: str) -> int | None:
    if key not in table:
        return None
    value = table[key]
    if isinstance(value, bool) or not isinstance(value, int):
        raise errors.GuardenError(f"{where}: {key} is not an integer", errors.HOST_NOT_AS_ASSUMED)
    return value


def _float(table: dict, key: str, where: str) -> float | None:
    if key not in table:
        return None
    value = table[key]
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise errors.GuardenError(f"{where}: {key} is not a number", errors.HOST_NOT_AS_ASSUMED)
    return float(value)


def load(service: str) -> Overrides:
    """An absent file is an empty grant surface: nothing has been granted yet."""
    where = paths.overrides(service)
    document = conf.read_toml(where)
    for key in sorted(set(document) - KEYS):
        raise errors.GuardenError(f"{where}: unknown key {key!r}", errors.HOST_NOT_AS_ASSUMED)

    ports = document.get("ports", {})
    if not isinstance(ports, dict):
        raise errors.GuardenError(f"{where}: [ports] is not a table", errors.HOST_NOT_AS_ASSUMED)
    extra = sorted(set(ports) - PORT_KEYS)
    if extra:
        raise errors.GuardenError(
            f"{where}: [ports] has an unknown key {extra[0]!r}", errors.HOST_NOT_AS_ASSUMED
        )

    retention = document.get("retention", {})
    if not isinstance(retention, dict):
        raise errors.GuardenError(
            f"{where}: [retention] is not a table", errors.HOST_NOT_AS_ASSUMED
        )
    extra = sorted(set(retention) - RETENTION_KEYS)
    if extra:
        raise errors.GuardenError(
            f"{where}: [retention] has an unknown key {extra[0]!r}", errors.HOST_NOT_AS_ASSUMED
        )

    for table, allowed in (
        ("groups", GROUP_KEYS),
        ("mounts", MOUNT_KEYS),
        ("firewall", FIREWALL_KEYS),
        ("expose", EXPOSE_KEYS),
    ):
        section = document.get(table, {})
        if not isinstance(section, dict):
            raise errors.GuardenError(
                f"{where}: [{table}] is not a table", errors.HOST_NOT_AS_ASSUMED
            )
        extra = sorted(set(section) - allowed)
        if extra:
            raise errors.GuardenError(
                f"{where}: [{table}] has an unknown key {extra[0]!r}", errors.HOST_NOT_AS_ASSUMED
            )

    return Overrides(
        open=_string_list(ports, "open", PORT_KEYS, f"{where} [ports]"),
        keep_last=_int(retention, "keep_last", f"{where} [retention]"),
        free_limit=_float(retention, "free_limit", f"{where} [retention]"),
        weekly=_int(retention, "weekly", f"{where} [retention]"),
        monthly=_int(retention, "monthly", f"{where} [retention]"),
        quarterly=_int(retention, "quarterly", f"{where} [retention]"),
        groups=_string_list(document.get("groups", {}), "add", GROUP_KEYS, f"{where} [groups]"),
        mounts=_string_list(document.get("mounts", {}), "allow", MOUNT_KEYS, f"{where} [mounts]"),
        firewall=_string_list(
            document.get("firewall", {}), "allow", FIREWALL_KEYS, f"{where} [firewall]"
        ),
        expose_tunnel=_string_list(
            document.get("expose", {}), "tunnel", EXPOSE_KEYS, f"{where} [expose]"
        ),
    )


def seeded(track, overrides: Overrides | None = None) -> Overrides:
    """A new service's overrides: the track's retention defaults, and nothing else.

    The track's `free_limit` and `keep_last` are written rather than left to be
    defaulted at read time, so `weedr service list` reports a value an operator
    can find and change in the one file that is the admin's to change.
    """
    if overrides is None:
        return Overrides(
            keep_last=track.keep_last,
            free_limit=track.free_limit,
            weekly=WEEKLY,
            monthly=MONTHLY,
            quarterly=QUARTERLY,
        )
    if overrides.keep_last is None:
        overrides.keep_last = track.keep_last
    if overrides.free_limit is None:
        overrides.free_limit = track.free_limit
    if overrides.weekly is None:
        overrides.weekly = WEEKLY
    if overrides.monthly is None:
        overrides.monthly = MONTHLY
    if overrides.quarterly is None:
        overrides.quarterly = QUARTERLY
    return overrides


def save(service: str, overrides: Overrides, owner: tuple[int, int]) -> None:
    conf.write_toml(paths.overrides(service), overrides.to_document(), OVERRIDES_MODE, owner)
    # The service's configuration directory is created by the write protocol's
    # umask-dependent mkdir; it is stated here because a service whose unit
    # bind-mounts a source under `/etc/guarden` resolves the path as its own
    # user, and under an 027 umask the directory would be one that user cannot
    # traverse (spec 2.1's row: `0755`, a listing of names and no secrets).
    try:
        os.chmod(paths.overrides(service).parent, 0o755)
    except OSError:
        pass
