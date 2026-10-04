"""`/etc/guarden/firewall/30-services.conf`: the mutator's half, and its only writer.

Two things live in this file and they are both spec 7.6/7.5: the nat rules that
forward a granted public port onto a service's loopback publication, and the
whole uid-matched `filter OUTPUT` set — every accept, then one drop.
"""

from __future__ import annotations

import difflib
import sys
from dataclasses import dataclass

from guarden import conf, errors, hosttool, paths, publications, registry, tool, users
from guarden import config as config_mod
from guarden import manifest as manifest_mod
from guarden import modules as modules_mod
from guarden import overrides as overrides_mod

SERVICES_CONF = paths.FIREWALL / "30-services.conf"
SERVICES_MODE = 0o644
UNIT = "guarden-firewall.service"
UNIT_PATH = ("etc", "systemd", "system", UNIT)
INPUT_CHAIN = "guarden-in"
OUTPUT_CHAIN = "guarden-svc"
LOOPBACK = "127.0.0.1"
LOOPBACK_NETWORK = "127.0.0.0/8"
PROTOCOLS = ("tcp", "udp")
MIN_PORT = 1
MAX_PORT = 65535
REFUSED_PREFIXES = ("private:", "public:")


@dataclass(frozen=True)
class Grant:
    service: str
    port: int
    protocol: str
    publication: int

    @property
    def selector(self) -> str:
        return f"{self.port}/{self.protocol}"


def owner() -> tuple[int, int]:
    return (0, users.group_id("guarden"))


def config():
    return config_mod.load()


def parse_selector(value: str) -> tuple[int, str]:
    if value.startswith(REFUSED_PREFIXES):
        raise errors.GuardenError(
            f"{value!r} names a private or public grant, and there is no such distinction: a "
            f"grant is a translation from a public port to the service's loopback "
            f"publication, and no service ever binds a non-loopback address",
            errors.REJECTED_INPUT,
        )
    number, separator, protocol = value.partition("/")
    if not separator:
        raise errors.GuardenError(
            f"{value!r} is a bare port. The argument is PORT/PROTO, as in 8080/tcp: the "
            f"protocol belongs to the rule, and a grant never means both at once",
            errors.REJECTED_INPUT,
        )
    if not number.isdigit() or not MIN_PORT <= int(number) <= MAX_PORT:
        raise errors.GuardenError(
            f"{number!r} is not a port number between {MIN_PORT} and {MAX_PORT}",
            errors.REJECTED_INPUT,
        )
    if protocol not in PROTOCOLS:
        raise errors.GuardenError(
            f"{protocol!r} is not a protocol; a grant names tcp or udp", errors.REJECTED_INPUT
        )
    return int(number), protocol


def requested_container(record, number: int) -> str:
    path = paths.manifest_in_home(record.service)
    if not path.is_file():
        raise errors.GuardenError(
            f"{record.service} has no manifest in its home at {path}, so the container behind "
            f"a requested port cannot be resolved",
            errors.HOST_NOT_AS_ASSUMED,
        )
    for entry in manifest_mod.read(path).ports:
        if entry.port == number:
            return entry.container
    raise errors.GuardenError(
        f"{record.service} requests port {number}, and its manifest holds no ports: entry with "
        f"that number, so there is no container for the grant to translate onto",
        errors.HOST_NOT_AS_ASSUMED,
    )


def resolve(record, number: int, protocol: str) -> Grant:
    container = requested_container(record, number)
    publication = record.publication.get(container)
    if publication is None:
        raise errors.GuardenError(
            f"{record.service} names the container {container!r} in ports: and its registry "
            f"entry allocates no publication for it, so there is nothing to translate the "
            f"public port onto",
            errors.HOST_NOT_AS_ASSUMED,
        )
    return Grant(record.service, number, protocol, publication)


def holder(number: int, protocol: str, excluding: str) -> str | None:
    for name in registry.names():
        if name == excluding:
            continue
        if f"{number}/{protocol}" in overrides_mod.load(name).open:
            return name
    return None


def collect() -> list[Grant]:
    found: list[Grant] = []
    for name in registry.names():
        record = registry.load(name)
        if record is None:
            continue
        for entry in overrides_mod.load(name).open:
            number, _, protocol = entry.partition("/")
            found.append(resolve(record, int(number), protocol or "tcp"))
    return sorted(found, key=lambda grant: (grant.port, grant.protocol, grant.service))


def admin_uid(config) -> int:
    """`host.admin_user`'s uid: the one uid the edge's API answers to.

    The API is a control surface rather than ingress (spec 7.5), so its
    accept set is this uid alone and it is never forwarded.
    """
    if not config.admin_user:
        raise errors.GuardenError(
            f"{config.path}: [host] admin_user is empty, and the edge's API accept set names "
            f"one uid; `soil install --apply` records the invoking user there",
            errors.HOST_NOT_AS_ASSUMED,
        )
    accounts = users.passwd_entries()
    if config.admin_user not in accounts:
        raise errors.GuardenError(
            f"there is no {config.admin_user!r} account on this host, and it is the uid the "
            f"edge's API accept set names",
            errors.HOST_NOT_AS_ASSUMED,
        )
    return accounts[config.admin_user][0]


def edge_uids() -> set[int]:
    """Every service an enabled module declares ingress for, by uid.

    Read from `[modules] enabled` and the module files, so what is "the edge"
    is what the configuration says rather than a name written in this program.
    """
    try:
        host = config_mod.load()
    except errors.GuardenError:
        return set()
    found: set[int] = set()
    for module in host.modules:
        try:
            entry = modules_mod.read(module).edge()
        except errors.GuardenError:
            continue
        record = registry.load(entry.name) if entry is not None else None
        if record is not None:
            found.add(record.uid)
    return found


def route_publications(record) -> set[str]:
    """The publication names this service's own manifest gives a route.

    Read from the manifest in the service's home, which is `0700` to the
    service: the firewall has to converge whether or not anybody has rendered
    the units, and a rendered file is not the input it is derived from.
    """
    path = paths.manifest_in_home(record.service)
    if not path.is_file():
        return set()
    try:
        manifest = manifest_mod.read(path)
    except errors.GuardenError:
        return set()
    return {route.container for route in manifest.routes}


def accept_lines(config) -> list[str]:
    """One line per `(publication, allowed uid)`, services in name order.

    A publication's accept set is: the service itself, the uid of every consumer
    that declared an edge to it **on that publication**, the edge's uid for every
    route publication, and `host.admin_user` alone on the API. The API replaces
    the whole set, because it is a control surface and the edge's own uid is not
    an answer to "who may see it".

    **A consumer's uid is granted per publication, not per provider.** An edge
    names a port, and a provider may hold several publications; granting the
    consumer on all of them would hand it the ports it never asked for. The
    number comes from the consumer's own registry edge — the same number
    `render.edge_publications` writes into `<AS>_PORT` — so the rule and the
    variable can never be built from two different answers.
    """
    edge = edge_uids()
    everything = [record for record in (registry.load(n) for n in registry.names())
                  if record is not None]
    routed = {record.service: route_publications(record) for record in everything}
    consumers = consumer_uids(everything)
    admin: int | None = None

    lines: list[str] = []
    for record in everything:
        allowed: dict[int, set[str]] = {}
        claimants = consumers.get(record.service, {})
        for name, port in sorted(record.publication.items()):
            if name == publications.API:
                if admin is None:
                    admin = admin_uid(config)
                uids = {admin}
            else:
                uids = {record.uid} | claimants.get(port, set())
                if record.uid in edge or name in routed.get(record.service, set()):
                    uids |= edge
            for uid in sorted(uids):
                allowed.setdefault(port, set()).add(uid)
        for port in sorted(allowed):
            for match in sorted(allowed[port]):
                lines.append(
                    f"    mod owner uid-owner {match} daddr {LOOPBACK} "
                    f"proto tcp dport {port} jump ACCEPT;"
                )
    return lines


def consumer_uids(everything) -> dict[str, dict[int, set[int]]]:
    """Service -> publication -> the uids of the consumers that dial that
    publication. Read from the consumers' own registries, never from a
    provider's manifest: the mutator allocated those numbers when it installed
    the edges and this is where they were recorded.

    `min` is the reader's convention for an edge that carries more than one
    publication, so the accept set and `<AS>_PORT` name the same port.
    """
    found: dict[str, dict[int, set[int]]] = {}
    for record in everything:
        for provider, entry in sorted(record.edges.items()):
            numbers = [n for n in (entry.get("publications") or []) if isinstance(n, int)]
            if not numbers:
                continue
            found.setdefault(provider, {}).setdefault(min(numbers), set()).add(record.uid)
    return found


def render(config, grants: list[Grant]) -> str:
    # A forwarded port is a PREROUTING DNAT and nothing else. There is no POSTROUTING
    # masquerade here and there must never be one: after the translation the destination
    # is local, so the packet goes to INPUT and never reaches POSTROUTING, and a rule
    # matching `-d 127.0.0.1 --dport <pub>` matches no packet in either direction.
    interface = config.interface or hosttool.default_route_device()
    lines = [
        "# Written by weedr, and by nothing else. soil firewall owns",
        "# 10-framework.conf and 20-ingress-nat.conf; the three files are disjoint",
        "# and each has exactly one writer.",
        "#",
        "# A granted port is a PREROUTING DNAT onto the service's own loopback",
        "# publication. No POSTROUTING masquerade is written here: the destination",
        "# is local after the translation, so the packet is delivered to INPUT and",
        "# never reaches POSTROUTING, and conntrack rewrites the reply's source to",
        "# the public address the client dialled.",
        "",
    ]
    if grants:
        lines += ["table nat", "chain PREROUTING {"]
        for grant in grants:
            lines.append(
                f"    if {interface} proto {grant.protocol} dport {grant.port} "
                f"DNAT to 127.0.0.1:{grant.publication};"
            )
        lines.append("}")
    lines += [
        "",
        "table filter",
        f"chain {INPUT_CHAIN} {{",
        "",
        "# 10-framework.conf jumps to this chain from INPUT above its own drop, so",
        "# these accepts are reachable. INPUT takes a forwarded port plainly: the",
        "# packet has no socket there, so an owner match would be unreliable, and",
        "# the uid restriction belongs in OUTPUT.",
    ]
    for grant in grants:
        lines.append(
            f"    proto {grant.protocol} dport {grant.port} jump ACCEPT;"
        )
    lines += [
        "}",
    ]
    lines += [
        "",
        "# The uid-matched OUTPUT set, and the order is the whole of it: every",
        "# accept above the drop, and the drop carries no -m owner. A default deny",
        "# that names the uids it applies to leaves every uid outside that set with",
        "# the box's own default policy, which is how guarden itself, an operator's",
        "# shell and sshd all reach every publication.",
        "#",
        "# Every destination is 127.0.0.1 and never ingress.alias: pasta maps a",
        "# container's gateway onto the host's loopback in userspace, before the",
        "# kernel's packet path, so a rule naming the alias matches nothing.",
        "",
        "chain OUTPUT {",
        f"    jump {OUTPUT_CHAIN};",
        "}",
        "",
        f"chain {OUTPUT_CHAIN} {{",
        *accept_lines(config),
        f"    daddr {LOOPBACK_NETWORK} jump DROP;",
        "}",
    ]
    return "\n".join(lines) + "\n"


def installed() -> str:
    if not SERVICES_CONF.is_file():
        return ""
    try:
        return SERVICES_CONF.read_text(encoding="utf-8")
    except OSError as exc:
        raise errors.GuardenError(
            f"{SERVICES_CONF} could not be read: {exc.strerror}", errors.HOST_NOT_AS_ASSUMED
        ) from exc


def load_set() -> None:
    """Put the rendered set in force, or say that it is not in force yet."""
    if not paths.PREFIX.joinpath(*UNIT_PATH).is_file():
        sys.stderr.write(
            errors.warn(
                f"{SERVICES_CONF} is written and is what guarden intends, but {UNIT} is not "
                f"installed on this host, so nothing has loaded it into the running ruleset"
            )
        )
        return
    result = tool.call(["systemctl", "reload-or-restart", UNIT])
    if result.ok:
        return
    detail = errors.oneline(result.stderr.strip() or result.stdout.strip())
    raise errors.GuardenError(
        f"{SERVICES_CONF} is written but {UNIT} did not load it: {detail or result.returncode}. "
        f"`soil firewall --apply` installs the unit",
        errors.HOST_NOT_AS_ASSUMED,
    )


def install(config) -> str:
    with conf.lock("firewall"):
        body = render(config, collect())
        before = installed()
        diff = "".join(
            difflib.unified_diff(
                before.splitlines(keepends=True),
                body.splitlines(keepends=True),
                fromfile=f"{SERVICES_CONF} (installed)",
                tofile=f"{SERVICES_CONF} (rendered)",
            )
        )
        if body != before:
            conf.write_file(SERVICES_CONF, body, SERVICES_MODE)
            load_set()
    return diff


def print_diff(diff: str) -> None:
    if diff:
        sys.stdout.write(diff if diff.endswith("\n") else diff + "\n")


def listing() -> list[dict]:
    out: list[dict] = []
    for name in registry.names():
        record = registry.load(name)
        if record is None:
            continue
        granted = overrides_mod.load(name).granted_numbers()
        requested = list(record.ports_requested)
        out.append(
            {
                "name": name,
                "requested": requested,
                "granted": granted,
                "pending": [port for port in requested if port not in granted],
            }
        )
    return out


def as_text(services: list[dict]) -> str:
    width = max((len(entry["name"]) for entry in services), default=0)
    lines = [f"{'SERVICE'.ljust(width)}  {'REQUESTED':<20}  {'GRANTED':<20}  PENDING"]
    for entry in services:
        lines.append(
            f"{entry['name'].ljust(width)}  {_ports(entry['requested']):<20}  "
            f"{_ports(entry['granted']):<20}  {_ports(entry['pending'])}"
        )
        api = _api_publication(entry["name"])
        if api:
            # On its own line because it is not a grant and never will be: a
            # control surface on loopback, reachable by `host.admin_user` and by
            # nobody else, and never forwarded from outside.
            lines.append(
                f"{''.ljust(width)}  api {api} on loopback, host.admin_user only, "
                f"never forwarded"
            )
    return "\n".join(lines) + "\n"


def _api_publication(service: str) -> int | None:
    record = registry.load(service)
    if record is None:
        return None
    return record.publication.get("api")


def _ports(numbers: list[int]) -> str:
    return ", ".join(str(number) for number in numbers) or "none"