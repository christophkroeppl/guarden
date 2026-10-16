"""`/etc/guarden/guarden.toml`: the host's own configuration, and the track table.

**The environment set is this table, not a code enum** (spec 3.1). Adding
`preprod` is appending a block, and nothing in guarden branches on a track's
name — which is why a track carries a `fork_from` field rather than guarden
recognising the words `production`, `staging` and `preview`.

Two exit codes, and the split is the point:

- A file that will not parse, or a key whose type is wrong, is **exit `1`**. It is
  the host, not a rejected input: spec 1.2's `2` row is about a manifest and a
  unit source, and this is a file on the filesystem.
- A well-formed file that breaks a rule this document states is **exit `2`**
  naming the track: `cap` on a `kind = "slot"` track or missing from a
  `kind = "instance"` one, and a `fork_from` that names no track or its own.

`[zram]` is the one optional table. It is absent on every host that has not been
asked for a compressed swap device, and its absence is the default rather than a
default value: `zram.knob` returns nothing for it and `soil install` builds no
items, so nothing about zram exists on a host that never asked. Its rules live
in `guarden/zram.py` rather than here, because they are the kernel's and the
generator's and not this table's — an algorithm guarden does not offer, a level
outside zstd's own range, and a percentage over 100.

Nothing here writes the file. `weedr module add` appends to `[modules] enabled`
and `soil install` writes the alias derived from the pinned `[network]
pasta_options`; a read is a read, and it takes no lock (spec 3.5).
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from guarden import conf, durations, errors, paths, zram

SLOT = "slot"
INSTANCE = "instance"
KINDS = (SLOT, INSTANCE)

TOP_LEVEL_KEYS = {
    "host",
    "ingress",
    "network",
    "build",
    "modules",
    "zram",
    "environments",
    "share",
    "firewall",
    "providers",
}
TRACK_KEYS = {
    "name",
    "host_prefix",
    "gated",
    "weight",
    "free_limit",
    "keep_last",
    "kind",
    "fork_from",
    "cap",
    "expose",
}
TRACK_DEFAULTS = {
    "host_prefix": "",
    "gated": False,
    "weight": 100,
    "free_limit": 0.10,
    "keep_last": 0,
    "kind": SLOT,
    "fork_from": "",
    "cap": None,
    "expose": "edge",
}
NETWORK_KEYS = {"backend", "pasta_options"}

# `[share]` is the root-owned table the issuance family reads and no repository
# can write. `max` is the longest a grant may last and the one value an operator
# decides; `account` and `app` name the vendor side the reconciler projects onto,
# and `token_name`/`scopes` are the audit trail for the API token — the token's
# *value* is never in this file, only the name of the file it is read from and the
# scopes it needs, so an operator can see what a leaked one would reach.
SHARE_KEYS = {"max", "account", "app", "token_name", "scopes"}
SHARE_DEFAULTS = {
    "max": "168h",
    "account": "",
    "app": "",
    "token_name": "share",
    "scopes": ["Access: Apps and Policies Write"],
}

# `[firewall]` is the root-owned table for admin firewall configuration.
# `admin_dropin` controls whether the 30-admin.conf drop-in file is installed.
# When enabled (default), the file is managed by soil and may be edited by an admin.
FIREWALL_KEYS = {"admin_dropin"}
FIREWALL_DEFAULTS = {
    "admin_dropin": True,
}


# spec 3.1: pasta is the only backend v1 supports, and slirp4netns is refused
# rather than degraded to. A rootless container on slirp4netns has a gateway that
# reaches nothing on the host (ticket 15, item A), so "degrading" to it would
# leave a box where no container can reach any other.
BACKEND = "pasta"

# spec 3.1 and ticket 15 item E: an option that removes the host mapping is exit
# `2` naming the key. `--map-gw` is pasta's own default and is what makes the
# host reachable at all, which is why the whole option set is written into
# guarden.toml and refused here rather than left to `containers.conf`.
REFUSED_PASTA_OPTIONS = ("--no-map-gw",)
REFUSED_PASTA_PAIRS = (("--map-host-loopback", "none"),)

# The pinned addressing (spec 3.1): the complete option set every configuration
# carries and every render writes as `Network=pasta:`. `-a` is the container's
# address, `-n` its width and `-g` the gateway pasta maps onto the host's
# loopback, so `soil install` derives `ingress.alias` from `-g`: the alias is a
# function of this table rather than something measured.
PASTA_OPTIONS = ("--map-gw", "--ipv4-only", "-a", "10.0.2.100", "-n", "24", "-g", "10.0.2.2")

# Every accepted set must carry these, because a set without them is not the
# pinned addressing: podman appends its default `--no-map-gw` when the literal
# `--map-gw` token is absent, and an option of the second row with no value
# after it pins nothing at all.
REQUIRED_PASTA_FLAGS = ("--map-gw", "--ipv4-only")
REQUIRED_PASTA_VALUES = ("-a", "-n", "-g")


@dataclass(frozen=True)
class Track:
    """One `[[environments]]` row."""

    name: str
    host_prefix: str
    gated: bool
    weight: int
    free_limit: float
    keep_last: int
    kind: str
    fork_from: str
    cap: int | None
    expose: str


@dataclass(frozen=True)
class Share:
    """The `[share]` table: the bound on a grant, and the vendor side it reaches."""

    max_seconds: int
    account: str
    app: str
    token_name: str
    scopes: tuple[str, ...]


@dataclass(frozen=True)
class Firewall:
    """The `[firewall]` table: admin firewall configuration."""

    admin_dropin: bool


@dataclass(frozen=True)
class Config:
    path: str
    domain: str
    interface: str
    admin_user: str
    alias: str
    tunnel_domain: str
    publication_range: tuple[int, int]
    modules: tuple[str, ...]
    lanes: int
    tracks: tuple[Track, ...]
    share: Share
    firewall: Firewall
    backend: str = BACKEND
    pasta_options: tuple[str, ...] = PASTA_OPTIONS
    zram: zram.Zram | None = None
    providers: dict[str, dict[str, str]] = field(default_factory=dict)

    def track(self, name: str) -> Track | None:
        return next((track for track in self.tracks if track.name == name), None)

    def resolve_provider(self, track: str, logical: str) -> str:
        return (self.providers or {}).get(track, {}).get(logical, logical)

    @property
    def network(self) -> str:
        """The `Network=` value every generated unit carries, verbatim and in
        order: `pasta:` followed by the option set, from this table and nowhere
        else (spec 3.1). The options are joined with commas — podman cuts the
        value at the first colon and splits the remainder on commas — so a colon
        between two options arrives as one mangled option and podman appends its
        default `--no-map-gw`, and the host mapping is off."""
        return f"{self.backend}:" + ",".join(self.pasta_options)


def _type_error(where: str, key: str, want: str) -> errors.GuardenError:
    return errors.GuardenError(f"{where}: {key} is not {want}", errors.HOST_NOT_AS_ASSUMED)


def _str(table: dict, key: str, where: str) -> str:
    value = table.get(key, "")
    if not isinstance(value, str):
        raise _type_error(where, key, "a string")
    return value


def _bool(table: dict, key: str, where: str) -> bool:
    value = table.get(key, False)
    if not isinstance(value, bool):
        raise _type_error(where, key, "a boolean")
    return value


def int_value(table: dict, key: str, where: str) -> int:
    value = table.get(key, 0)
    if isinstance(value, bool) or not isinstance(value, int):
        raise _type_error(where, key, "an integer")
    return value


def float_value(table: dict, key: str, where: str) -> float:
    """A number, as TOML's types mean one: `0.10`, never `"0.10"`.

    TOML's types are distinct — a float and a string are different values — and
    its standard defines no conversion between them. Rust's serde, the
    reference behaviour for typed configuration, refuses a string where a
    number is required; so does this, with the table and key named and the
    host's own file treated like the input it is (spec 1.2). Coercing would
    resurrect the class this repository has already paid for: two readers that
    disagree about which spellings are numbers produce a value that is
    sometimes `0.2` and sometimes `"0.20"`, which `snapper set-config` — a
    string comparison — reports as drift on a volume the check had just
    written itself (measured 2026-10-12).

    Public because there are two readers of the same row: this module's track
    reader and `hostprep._retention_for`'s converge, and one house rule means
    they cannot drift apart. `int_value` is its sibling for integer keys.
    """
    value = table.get(key, TRACK_DEFAULTS["free_limit"])
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise _type_error(where, key, "a number")
    return float(value)


def _cap(table: dict, where: str) -> int | None:
    value = table.get("cap")
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, int):
        raise _type_error(where, "cap", "an integer")
    return value


def load(path: Any = None) -> Config:
    """Read the file. Never write it."""
    where_file = paths.GUARDEN_TOML if path is None else path
    document = conf.read_toml(where_file)

    unknown = sorted(set(document) - TOP_LEVEL_KEYS)
    if unknown:
        raise errors.GuardenError(
            f"{where_file}: unknown key {unknown[0]!r}", errors.HOST_NOT_AS_ASSUMED
        )

    host = document.get("host", {})
    ingress = document.get("ingress", {})
    network = document.get("network", {})
    build = document.get("build", {})
    modules = document.get("modules", {})
    share = document.get("share", {})
    firewall = document.get("firewall", {})
    for table, name, keys in (
        (host, "host", {"domain", "interface", "admin_user"}),
        (ingress, "ingress", {"alias", "tunnel_domain", "publication_range", "forwarded"}),
        (network, "network", NETWORK_KEYS),
        (share, "share", SHARE_KEYS),
        (firewall, "firewall", FIREWALL_KEYS),
        (build, "build", {"lanes"}),
        (modules, "modules", {"enabled"}),
    ):
        extra = sorted(set(table) - keys)
        if extra:
            raise errors.GuardenError(
                f"{where_file}: [{name}] has an unknown key {extra[0]!r}",
                errors.HOST_NOT_AS_ASSUMED,
            )

    span = ingress.get("publication_range", [20000, 32767])
    if (
        not isinstance(span, list)
        or len(span) != 2
        or not all(isinstance(port, int) and not isinstance(port, bool) for port in span)
    ):
        raise _type_error(str(where_file), "ingress.publication_range", "a pair of integers")

    enabled = modules.get("enabled", [])
    if not isinstance(enabled, list) or not all(isinstance(name, str) for name in enabled):
        raise _type_error(str(where_file), "modules.enabled", "a list of strings")

    tracks = _tracks(document.get("environments", []), where_file)
    return Config(
        path=str(where_file),
        providers=_providers(document.get("providers", {}), where_file),
        domain=_str(host, "domain", f"{where_file} [host]"),
        interface=_str(host, "interface", f"{where_file} [host]"),
        admin_user=_str(host, "admin_user", f"{where_file} [host]"),
        alias=_str(ingress, "alias", f"{where_file} [ingress]"),
        tunnel_domain=_str(ingress, "tunnel_domain", f"{where_file} [ingress]"),
        publication_range=(span[0], span[1]),
        modules=tuple(enabled),
        lanes=int_value(build, "lanes", f"{where_file} [build]"),
        tracks=tuple(tracks),
        share=_share(share, where_file),
        firewall=_firewall(firewall, where_file),
        backend=_backend(network, where_file),
        pasta_options=_pasta_options(network, where_file),
        zram=zram.knob(document, str(where_file)),
    )


def _share(table: dict, where_file: Any) -> Share:
    """`[share] max`, and the vendor side it names.

    `max` is a duration in guarden's own syntax and is the one value an operator
    decides: a `--until` above it is refused. It is converted to seconds **here**
    and stored that way, because a duration is what a person types and a number
    is what a comparison uses, and the two must not be re-derived at each call
    site. A value that is not a duration is exit `2`: it is a line a person wrote
    in a root-owned file, and the grammar is the rule the table states.
    """
    where = f"{where_file} [share]"
    raw = table.get("max", SHARE_DEFAULTS["max"])
    if not isinstance(raw, str):
        raise _type_error(str(where_file), "share.max", "a duration")
    maximum = durations.parse(raw, f"{where} max")
    token_name = table.get("token_name", SHARE_DEFAULTS["token_name"])
    if not isinstance(token_name, str):
        raise _type_error(str(where_file), "share.token_name", "a string")
    scopes = table.get("scopes", SHARE_DEFAULTS["scopes"])
    if not isinstance(scopes, list) or not all(isinstance(item, str) for item in scopes):
        raise _type_error(str(where_file), "share.scopes", "a list of strings")
    return Share(
        max_seconds=maximum,
        account=_str(table, "account", where),
        app=_str(table, "app", where),
        token_name=token_name,
        scopes=tuple(scopes),
    )


def _firewall(table: dict, where_file: Any) -> Firewall:
    """`[firewall] admin_dropin`, controls the admin drop-in file."""
    value = table.get("admin_dropin", FIREWALL_DEFAULTS["admin_dropin"])
    if not isinstance(value, bool):
        raise _type_error(str(where_file), "firewall.admin_dropin", "a boolean")
    return Firewall(admin_dropin=value)


def _backend(table: dict, where_file: Any) -> str:
    """`[network] backend`, refused rather than degraded to (spec 3.1).

    A well-formed file that breaks a rule this table states is exit `2` naming
    the key, which is the same rule the track table follows; a file that will not
    parse is the host and is exit `1` (see the module note).
    """
    value = table.get("backend", BACKEND)
    if not isinstance(value, str):
        raise _type_error(str(where_file), "network.backend", "a string")
    if value != BACKEND:
        raise errors.GuardenError(
            f"{where_file}: [network] backend is {value!r}, and the only backend v1 supports "
            f"is {BACKEND!r}; the other is refused rather than degraded to, because a container "
            f"that cannot reach the host is not a degraded guarden"
        )
    return value


def _pasta_options(table: dict, where_file: Any) -> tuple[str, ...]:
    """The complete set of pasta options, refused if one removes the host
    mapping and refused unless it carries the pinned addressing (spec 3.1,
    ticket 15 item E).

    Both spellings of a valued option are refused, because both are how a list
    gets written: `--map-host-loopback none` as two entries and
    `--map-host-loopback=none` as one. A refusal that only understood one of them
    would be a refusal that turns on punctuation.

    The list the refusal tests is the comma-split one, because that is the list
    podman runs: it cuts the value at the first colon and then on commas, so an
    entry packed behind a comma has to be tested piecewise — a `--no-map-gw`
    after one would otherwise evade this refusal while podman still honoured it.
    The positive requirement reads the same list, for the same reason: it is the
    one podman runs, so it is the one that has to carry the pinned shape.

    **A set that only avoids the refusals is not enough.** The literal
    `--map-gw` token has to be there — podman appends its default `--no-map-gw`
    when it is absent, so `[ "--ipv4-only" ]` silently loses the host mapping —
    and `-a`, `-n` and `-g` have to be followed by their values, because a flag
    with nothing after it pins no addressing and derives no alias.
    """
    value = table.get("pasta_options", list(PASTA_OPTIONS))
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise _type_error(str(where_file), "network.pasta_options", "a list of strings")
    options = [piece for item in value for piece in item.split(",")]
    for index, option in enumerate(options):
        if option in REFUSED_PASTA_OPTIONS:
            raise _refused_pasta(where_file, option)
        for flag, setting in REFUSED_PASTA_PAIRS:
            if option == f"{flag}={setting}":
                raise _refused_pasta(where_file, option)
            if option == flag and index + 1 < len(options) and options[index + 1] == setting:
                raise _refused_pasta(where_file, f"{flag} {setting}")
    for flag in REQUIRED_PASTA_FLAGS:
        if flag not in options:
            raise _unpinned_pasta(where_file, f"{flag!r}")
    for flag in REQUIRED_PASTA_VALUES:
        if not any(
            option == flag and index + 1 < len(options) and options[index + 1]
            for index, option in enumerate(options)
        ):
            raise _unpinned_pasta(where_file, f"{flag!r} with its value")
    return tuple(value)


def _refused_pasta(where_file: Any, option: str) -> errors.GuardenError:
    return errors.GuardenError(
        f"{where_file}: [network] pasta_options has {option!r}, which removes the mapping "
        f"that makes the host reachable from a container; a container with no route to the "
        f"host is not a degraded guarden, it is a box where nothing can reach anything"
    )


def _unpinned_pasta(where_file: Any, piece: str) -> errors.GuardenError:
    return errors.GuardenError(
        f"{where_file}: [network] pasta_options does not carry {piece}, and a set that is "
        f"not the pinned addressing is refused rather than repaired: podman appends its "
        f"default --no-map-gw when the literal --map-gw token is absent, and `soil install` "
        f"derives ingress.alias from -g"
    )


def _providers(table: Any, where_file: Any) -> dict[str, dict[str, str]]:
    if not isinstance(table, dict):
        raise _type_error(str(where_file), "providers", "a table")
    out: dict[str, dict[str, str]] = {}
    for track, mapping in table.items():
        if not isinstance(mapping, dict):
            raise _type_error(str(where_file), f"providers.{track}", "a table")
        resolved: dict[str, str] = {}
        for logical, concrete in mapping.items():
            if not isinstance(concrete, str) or not concrete:
                raise _type_error(
                    str(where_file), f"providers.{track}.{logical}", "a service name"
                )
            resolved[logical] = concrete
        out[track] = resolved
    return out


def _tracks(rows: Any, where_file: Any) -> list[Track]:
    if not isinstance(rows, list):
        raise _type_error(str(where_file), "environments", "a list of [[environments]] tables")

    tracks: list[Track] = []
    for row in rows:
        if not isinstance(row, dict):
            raise _type_error(str(where_file), "environments", "a list of tables")
        extra = sorted(set(row) - TRACK_KEYS)
        if extra:
            raise errors.GuardenError(
                f"{where_file}: a track has an unknown key {extra[0]!r}",
                errors.HOST_NOT_AS_ASSUMED,
            )
        name = _str(row, "name", f"{where_file} a track")
        if not name:
            raise errors.GuardenError(
                f"{where_file}: a track has an empty name", errors.HOST_NOT_AS_ASSUMED
            )
        where = f"{where_file} track {name!r}"
        kind = _str(row, "kind", where)
        if kind not in KINDS:
            raise errors.GuardenError(f"{where}: kind is {kind!r}; it is 'slot' or 'instance'")
        tracks.append(
            Track(
                name=name,
                host_prefix=_str(row, "host_prefix", where),
                gated=_bool(row, "gated", where),
                weight=int_value(row, "weight", where),
                free_limit=float_value(row, "free_limit", where),
                keep_last=int_value(row, "keep_last", where),
                kind=kind,
                fork_from=_str(row, "fork_from", where),
                cap=_cap(row, where),
                expose=_str(row, "expose", where) or TRACK_DEFAULTS["expose"],
            )
        )

    by_name = {track.name: track for track in tracks}
    for track in tracks:
        where = f"track {track.name!r}"
        if track.kind == INSTANCE and track.cap is None:
            raise errors.GuardenError(f'{where}: kind = "instance" must carry a cap')
        if track.kind == SLOT and track.cap is not None:
            raise errors.GuardenError(f'{where}: kind = "slot" must not carry a cap')
        if track.fork_from == track.name:
            raise errors.GuardenError(f"{where}: fork_from names its own track")
        if track.fork_from and track.fork_from not in by_name:
            raise errors.GuardenError(
                f"{where}: fork_from {track.fork_from!r} names no track in the table"
            )
        if track.expose not in ("edge", "tunnel"):
            raise errors.GuardenError(
                f"{where}: expose is {track.expose!r}; it must be 'edge' or 'tunnel'"
            )
    return tracks
