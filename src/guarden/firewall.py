"""`/etc/guarden/firewall/50-services.conf` and `services/<name>.conf`: the
mutator's half, and its only writer.

`50-services.conf` carries the nat rules that forward a granted public port
onto a service's loopback publication, the `guarden-in` INPUT accepts, the
root and resolver accepts in `guarden-svc`, one `jump guarden-svc-<name>;`
per registered service, granted rules, and the default deny.

Each `services/<name>.conf` carries that service's own per-(publication, uid)
accept rules in its dedicated `guarden-svc-<name>` chain.
"""

from __future__ import annotations

import difflib
import sys
from dataclasses import dataclass, field
from pathlib import Path

from guarden import (
    conf,
    edges,
    errors,
    hosttool,
    paths,
    publications,
    registry,
    rules,
    tool,
    users,
)
from guarden import config as config_mod
from guarden import manifest as manifest_mod
from guarden import modules as modules_mod
from guarden import overrides as overrides_mod
from guarden.hosttool import warn

SERVICES_CONF = paths.FIREWALL / "50-services.conf"
SERVICES_DIR = paths.FIREWALL_SERVICES
SERVICES_MODE = 0o640
SERVICE_MODE = 0o640
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
    path = paths.manifest_in_home(record.service, record.app)
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


def service_uids() -> set[int]:
    """Every deployed service's uid, from the registry and nowhere else."""
    uids: set[int] = set()
    for name in registry.names():
        record = registry.load(name)
        if record is not None and record.uid:
            uids.add(record.uid)
    return uids


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


def route_publications(record, destination: str | None = None) -> set[str]:
    """The publication names this service's own manifest gives a route.

    Read from the manifest in the service's home, which is `0700` to the
    service: the firewall has to converge whether or not anybody has rendered
    the units, and a rendered file is not the input it is derived from.

    With `destination`, only the routes whose **recorded** destination is that
    one (ticket 293): the edge is granted what it serves, a `tunnel` route is
    dialled by cloudflared and a `loopback` route is served by nobody outside
    the box. A host the record says nothing about is an edge route — the same
    pre-293 reading `tunnel_publications` gives it.
    """
    path = paths.manifest_in_home(record.service, record.app)
    if not path.is_file():
        return set()
    try:
        manifest = manifest_mod.read(path)
    except errors.GuardenError:
        return set()
    routes = manifest.routes
    if destination is not None:
        routes = [
            route
            for route in routes
            if record.route_destinations.get(route.host, "edge") == destination
        ]
    return {route.container for route in routes}


def tunnel_uids() -> set[int]:
    """Every service the tunnel module ships, by uid.

    Read the same way `edge_uids` reads the edge, and for the same reason: what
    the tunnel is is what the configuration says, not a name in this program.
    An empty set is a host with no tunnel and not an error.
    """
    try:
        host = config_mod.load()
    except errors.GuardenError:
        return set()
    found: set[int] = set()
    for module in host.modules:
        try:
            shipped = modules_mod.read(module)
        except errors.GuardenError:
            continue
        for entry in shipped.services:
            if entry.ingress:
                continue
            record = registry.load(entry.name)
            if record is not None:
                found.add(record.uid)
    return found


def tunnel_publications(record) -> set[str]:
    """The publication names of this service's routes the tunnel carries.

    A route's destination is a track's `expose` and a service's root-owned
    `[expose] tunnel`, and the mutator recorded it per route host, so the answer
    is the registry's rather than a second reading of the track here. A route the
    registry says nothing about is an edge route: it was ingested before the
    field existed, and the edge's own accept already covers it.

    **The answer is the SERVICE's container names, and an instance's publication
    carries the same names.** An instance renders the same manifest, so the
    container behind a route is the same name in both — and the accept set below
    is keyed by that name, so one answer serves both publications. What
    distinguishes them is the port, and the port is the instance's own.
    """
    path = paths.manifest_in_home(record.service, record.app)
    if not path.is_file():
        return set()
    try:
        manifest = manifest_mod.read(path)
    except errors.GuardenError:
        return set()
    return {
        route.container
        for route in manifest.routes
        if record.route_destinations.get(route.host) == "tunnel"
    }


def _service_accept_map(
    config,
) -> dict[str, dict[int, dict[int, str]]]:
    """One accept per (service, publication, uid), grouped by service and port,
    with a human-readable reason for each uid's presence.

    Returns ``{service: {port: {uid: reason}}}``.  The reason is one of
    ``own``, ``admin``, ``consumer:<name>``, ``edge:<name>`` or
    ``tunnel:<name>``.
    """
    edge = edge_uids()
    tunnel = tunnel_uids()
    everything = [
        record for record in (registry.load(n) for n in registry.names())
        if record is not None
    ]
    # Ticket 293: only the routes recorded `edge` — only what the edge
    # actually serves — take an edge accept on their publication.
    routed = {
        record.service: route_publications(record, "edge") for record in everything
    }
    tunnelled = {record.service: tunnel_publications(record) for record in everything}
    consumers = consumer_uids(everything)
    admin: int | None = None

    # uid -> service name, used to build human-readable reason strings.
    uid_to_name: dict[int, str] = {}
    for record in everything:
        if record.uid:
            uid_to_name[record.uid] = record.service

    result: dict[str, dict[int, dict[int, str]]] = {}
    for record in everything:
        allowed: dict[int, dict[int, str]] = {}
        claimants = consumers.get(record.service, {})
        edge_names = routed.get(record.service, set())
        tunnel_names = tunnelled.get(record.service, set())

        def _add(port: int, uid: int, reason: str, allowed=allowed) -> None:
            allowed.setdefault(port, {})[uid] = reason

        for name, port in sorted(record.publication.items()):
            if name == publications.API:
                if admin is None:
                    admin = admin_uid(config)
                _add(port, admin, "admin")
            else:
                _add(port, record.uid, "own")
                for c_uid in sorted(claimants.get(port, set())):
                    c_name = uid_to_name.get(c_uid, str(c_uid))
                    _add(port, c_uid, f"consumer:{c_name}")
                if record.uid in edge or name in edge_names:
                    for e_uid in sorted(edge):
                        e_name = uid_to_name.get(e_uid, str(e_uid))
                        _add(port, e_uid, f"edge:{e_name}")
                if name in tunnel_names:
                    for t_uid in sorted(tunnel):
                        t_name = uid_to_name.get(t_uid, str(t_uid))
                        _add(port, t_uid, f"tunnel:{t_name}")
        for instance in record.instances.values():
            for name, port in sorted(instance.publication.items()):
                if name == publications.API:
                    # An instance never holds the API: the API belongs to the
                    # edge's own service, and the edge is not a preview.
                    continue
                _add(port, record.uid, "own")
                if record.uid in edge or name in edge_names:
                    for e_uid in sorted(edge):
                        e_name = uid_to_name.get(e_uid, str(e_uid))
                        _add(port, e_uid, f"edge:{e_name}")
                if name in tunnel_names:
                    for t_uid in sorted(tunnel):
                        t_name = uid_to_name.get(t_uid, str(t_uid))
                        _add(port, t_uid, f"tunnel:{t_name}")
        result[record.service] = allowed
    return result


def _accept_lines_from_map(
    accept_map: dict[str, dict[int, dict[int, str]]],
) -> list[str]:
    """Re-create the flat accept lines from the structured map.

    Used only to keep the main ``50-services.conf`` free of per-(publication,
    uid) accepts after the refactor; the per-service files render through
    :func:`_service_file_lines` instead.
    """
    return []


def service_chain_name(name: str) -> str:
    """The per-service chain name used in ferm and iptables."""
    return f"{OUTPUT_CHAIN}-{name}"


def _service_file_lines(
    service: str,
    port_accepts: dict[int, dict[int, str]],
) -> list[str]:
    """The ferm lines for one service's dedicated chain."""
    lines = ["table filter", f"chain {service_chain_name(service)} {{"]
    for port in sorted(port_accepts):
        for uid in sorted(port_accepts[port]):
            reason = port_accepts[port][uid]
            comment = f"  # {reason}" if reason else ""
            lines.append(
                f"    mod owner uid-owner {uid} daddr {LOOPBACK} "
                f"proto tcp dport {port} jump ACCEPT;{comment}"
            )
    lines.append("}")
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
            name = edges.provider_of(provider)
            found.setdefault(name, {}).setdefault(min(numbers), set()).add(record.uid)
    return found


def render(config, grants: list[Grant]) -> tuple[str, dict[str, str]]:
    """Render the firewall configuration.

    Returns ``(main_body, service_bodies)`` where ``main_body`` is the content
    of ``50-services.conf`` and ``service_bodies`` maps each registered service
    name to the content of its ``services/<name>.conf`` file.
    """
    interface = config.interface or hosttool.default_route_device()
    lines = [
        "# Written by weedr, and by nothing else. soil firewall owns",
        "# 10-framework.conf and 20-ingress-nat.conf; those three files are disjoint",
        "# and each has exactly one writer. The directory holds two more —",
        "# 00-ssh.conf, seed-once, and 30-admin.conf, admin-edited — neither of",
        "# which weedr writes (8c78126).",
        "#",
        "# A granted port is a PREROUTING DNAT onto the service's own loopback",
        "# publication. No POSTROUTING masquerade is written here: the destination",
        "# is local after the translation, so the packet is delivered to INPUT and",
        "# never reaches POSTROUTING, and conntrack rewrites the reply's source to",
        "# the public address the client dialled.",
        "",
        "table nat",
        "chain PREROUTING {",
    ]
    for grant in grants:
        lines.append(
            f"    if {interface} proto {grant.protocol} dport {grant.port} "
            f"DNAT to 127.0.0.1:{grant.publication};"
        )
    lines += [
        "}",
        "",
        "table filter",
        f"chain {INPUT_CHAIN} {{",
        "",
        "# 10-framework.conf jumps to this chain from INPUT above its own drop, so",
        "# these accepts are reachable. INPUT takes a forwarded port plainly: the",
        "# packet has no socket there, so an owner match would be unreliable, and",
        "# the uid restriction belongs in OUTPUT.",
        "#",
        "# **The port here is the PUBLICATION, not the public port.** PREROUTING",
        "# DNAT rewrites the destination port as well as the address, so a packet",
        "# that dialled the public port arrives at INPUT carrying the publication's",
        "# number. An accept on the public port matches no packet in either",
        "# direction and the grant delivers nothing from off the box.",
    ]
    # Deduplicated by `(protocol, publication)`: the render is a set, so two public
    # ports forwarded onto one container are one accept at INPUT, not two.
    for protocol, publication in sorted({(g.protocol, g.publication) for g in grants}):
        lines.append(f"    proto {protocol} dport {publication} jump ACCEPT;")
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
        # Bind policing (gap G3): a socket bound to one of this host's
        # publication ports must be owned by that publication's service uid.
        # A hostile service that squats on another service's publication
        # answers from that port with its own uid; its reply carries the
        # publication as its source port and is dropped here, before the
        # ESTABLISHED accept can let it through, and the attempt is logged.
        # The owner match is negated, so a socket owned by the
        # publication's own uid is untouched and legitimate binds keep
        # working.
        *bind_policing_lines(),
        # The reply half of a connection that was just permitted. A reply's
        # destination is an ephemeral port on loopback, so it lands inside the
        # deny's `127.0.0.0/8` range and is dropped without this: the request
        # passes, the SYN-ACK does not, and the client sees a timeout rather
        # than an answer. INPUT has carried this rule since the first commit.
        #
        # It widens nothing. ESTABLISHED is conntrack's word for "this packet
        # belongs to a connection that already exists", so the rule cannot
        # open a path — it can only let the far side of one answer.
        "    mod conntrack ctstate (ESTABLISHED RELATED) jump ACCEPT;",
        f"    mod owner uid-owner 0 daddr {LOOPBACK} proto tcp jump ACCEPT;",
        # The stub resolver, with the per-publication accepts and above the granted
        # rules — guarden's own accepts first, then what an admin granted, then the
        # single default deny last. `service_uids()` is the registry's uids and
        # nothing else: `users.passwd_entries()` would sweep in `guarden`, `hose`,
        # `operator` and every package's system user, and a rule meant for a service
        # would become a host-wide one. Root is not one of them: it is added inside
        # `rules.resolver_lines`, beside the service uids and not as one of them
        # (ADR-0023), so the resolver's uid set is the service uids and root.
        *rules.resolver_lines(service_uids()),
        # Per-service jumps: every registered service gets its own chain in
        # services/<name>.conf, and this chain jumps to it.  An accept then
        # cannot land below the deny — that stops being a line-ordering
        # convention in one renderer and becomes a property of the chain graph.
        *(
            f"    jump {service_chain_name(name)};"
            for name in sorted(registry.names())
            if registry.load(name) is not None
        ),
        # A granted rule renders ABOVE the deny and never after it: position is
        # guarden's, and a grant that landed below a default deny would be
        # unreachable while still appearing in the file.
        *granted_rule_lines(),
        f"    daddr {LOOPBACK_NETWORK} jump DROP;",
        "}",
    ]
    main_body = "\n".join(lines) + "\n"

    accept_map = _service_accept_map(config)
    service_bodies: dict[str, str] = {}
    for name in sorted(accept_map):
        service_lines = _service_file_lines(name, accept_map[name])
        service_bodies[name] = "\n".join(service_lines) + "\n"

    return main_body, service_bodies


def bind_policing_lines() -> list[str]:
    """Ferm lines that police binds on this host's publication ports (gap G3).

    A socket answering on a publication port must be owned by that
    publication's service uid.  A squatter's reply carries the publication
    as its source port and a uid that is not the owner's, so it is logged
    and dropped here.  Rules are emitted once per publication port.
    """
    out: list[str] = []
    seen: set[int] = set()
    for name in sorted(registry.names()):
        record = registry.load(name)
        if record is None:
            continue
        ports: set[int] = set(record.publication.values())
        for instance in record.instances.values():
            ports.update(instance.publication.values())
        for port in sorted(ports):
            if port in seen:
                continue
            seen.add(port)
            uid = record.uid
            out.append(
                f"    mod owner ! uid-owner {uid} proto tcp sport {port} "
                f"daddr {LOOPBACK_NETWORK} LOG log-prefix \"guarden-squat: \" "
                f"log-level warning;"
            )
            out.append(
                f"    mod owner ! uid-owner {uid} proto tcp sport {port} "
                f"daddr {LOOPBACK_NETWORK} DROP;"
            )
    return out

def granted_rule_lines() -> list[str]:
    """One ferm line per GRANTED requested rule, deduplicated by content.

    Ungranted requests render nothing: a request installs no rule, and a rule
    nobody granted is the one thing this design refuses to do on a repository's
    word alone.
    """
    out: list[str] = []
    for rule in granted_rules():
        granted_by = ", ".join(f"{s} {n}" for s, n in sorted(rule.granted_names))
        out.append(f"# {rule.rule} — granted by {granted_by}")
        out.append(f"    {rules.parse(rule.rule, 'a granted rule').ferm_line()}")
    return out


def installed() -> str:
    """Read all root-owned .conf files in the firewall directory, in lexical order.

    Only root-owned files are loaded; non-root files are skipped with a warning.
    """
    firewall_dir = paths.FIREWALL
    if not firewall_dir.is_dir():
        return ""
    out = []
    for conf_file in sorted(firewall_dir.glob("*.conf")):
        try:
            stat = conf_file.stat()
            if stat.st_uid != 0:
                warn(f"skipping non-root-owned firewall file: {conf_file.name} (uid={stat.st_uid})")
                continue
            out.append(conf_file.read_text(encoding="utf-8"))
        except OSError as exc:
            raise errors.GuardenError(
                f"{conf_file} could not be read: {exc.strerror}", errors.HOST_NOT_AS_ASSUMED
            ) from exc
    return "\n".join(out)


def _read_file(path: Path) -> str:
    """Read a single config file, returning empty string if absent."""
    if not path.is_file():
        return ""
    return path.read_text(encoding="utf-8")


def unit_installed() -> bool:
    """Whether this host has guarden's firewall to load a render into.

    `load_set` reads this, and so does the mutator before it renders on a
    service's behalf: `soil firewall --apply` is what installs the unit, and a
    host that has never run it has no `50-services.conf` loaded — so its loopback
    deny is not in force and no service uid is missing from a ruleset. Once the
    unit is there, every render has to carry every uid in the registry (spec 7.6)
    and a creation has to reach it (ticket 296).
    """
    return paths.PREFIX.joinpath(*UNIT_PATH).is_file()


def load_set() -> None:
    """Put the rendered set in force, or say that it is not in force yet."""
    if not unit_installed():
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
        main_body, service_bodies = render(config, collect())

        # Ensure the services directory exists.
        SERVICES_DIR.mkdir(parents=True, exist_ok=True)

        # Remove service files for services that no longer exist in the registry.
        current_services = set(registry.names())
        for path in SERVICES_DIR.glob("*.conf"):
            if path.stem not in current_services:
                path.unlink()

        # Write the main file if it changed.
        before_main = _read_file(SERVICES_CONF)
        main_changed = main_body != before_main
        if main_changed:
            conf.write_file(SERVICES_CONF, main_body, SERVICES_MODE, owner=owner())

        # Write each per-service file if it changed.
        service_changed = False
        for name, body in service_bodies.items():
            path = SERVICES_DIR / f"{name}.conf"
            before = _read_file(path)
            if body != before:
                conf.write_file(path, body, SERVICE_MODE, owner=owner())
                service_changed = True

        if main_changed or service_changed:
            load_set()

        # Return a unified diff for the main file only; per-service files are
        # written without a separate diff to keep the report readable.
        diff = "".join(
            difflib.unified_diff(
                before_main.splitlines(keepends=True),
                main_body.splitlines(keepends=True),
                fromfile=f"{SERVICES_CONF} (installed)",
                tofile=f"{SERVICES_CONF} (rendered)",
            )
        )
    return diff


def print_diff(diff: str) -> None:
    if diff:
        sys.stdout.write(diff if diff.endswith("\n") else diff + "\n")


def _distinct(numbers: list[int]) -> list[int]:
    """`granted` is a set of port numbers: tcp and udp on one number are two grants
    and one port, and reporting it twice would name a port granted once."""
    return list(dict.fromkeys(numbers))


def listing() -> list[dict]:
    out: list[dict] = []
    for name in registry.names():
        record = registry.load(name)
        if record is None:
            continue
        granted = _distinct(overrides_mod.load(name).granted_numbers())
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


@dataclass
class GrantedRule:
    """One requested rule, keyed by its text, with everyone behind it.

    **`holders` is who asked and `granted_names` is who was granted.** Conflating
    them made `weedr firewall list` — the command for "which service opened this"
    — list no service at all for every pending rule, because a request has no
    grant yet and the listing was built from grants alone.
    """

    chain: str
    rule: str
    holders: list[tuple[str, str]] = field(default_factory=list)
    granted_names: list[tuple[str, str]] = field(default_factory=list)

    @property
    def key(self) -> tuple[str, str]:
        return (self.chain, self.rule)

    @property
    def granted(self) -> bool:
        return bool(self.granted_names)

    def object(self) -> dict:
        return {
            "rule": self.rule,
            "chain": self.chain,
            "file": str(SERVICES_CONF),
            "granted": self.granted,
            "requested_by": [
                {"service": service, "name": name}
                for service, name in sorted(self.holders)
            ],
        }


def collect_rules() -> list[GrantedRule]:
    """Every requested rule on the box, keyed by its text, with every asker.

    `overrides.toml` is the authority; the registry's granted mirror is not
    consulted, so an admin's file and the rendered ruleset cannot disagree.
    """
    found: dict[tuple[str, str], GrantedRule] = {}
    for service in registry.names():
        record = registry.load(service)
        if record is None:
            continue
        allowed = overrides_mod.load(service).firewall
        for entry in record.firewall_requested:
            rule = found.setdefault(
                (entry.chain, entry.rule), GrantedRule(entry.chain, entry.rule)
            )
            if (service, entry.name) not in rule.holders:
                rule.holders.append((service, entry.name))
                if entry.name in allowed:
                    rule.granted_names.append((service, entry.name))
    return [found[key] for key in sorted(found)]


def granted_rules() -> list[GrantedRule]:
    return [rule for rule in collect_rules() if rule.granted]


def rules_listing() -> list[dict]:
    return [rule.object() for rule in collect_rules()]


def rules_as_text(entries: list[dict]) -> str:
    """One line per rule text after deduplication, with every service behind it.

    A rule asked for by two services appears once with both names, because two
    lines for one rule would report the ruleset as being larger than it is.
    """
    if not entries:
        return "no service asks for a firewall rule\n"
    width = max(len(entry["rule"]) for entry in entries)
    chain = max(len(entry["chain"]) for entry in entries)
    lines = [f"{'RULE'.ljust(width)}  {'CHAIN'.ljust(chain)}  {'STATE':<9}  SERVICES"]
    for entry in entries:
        services = ", ".join(
            f"{ask['service']} {ask['name']}" for ask in entry["requested_by"]
        )
        state = "installed" if entry["granted"] else "pending"
        lines.append(
            f"{entry['rule'].ljust(width)}  {entry['chain'].ljust(chain)}  "
            f"{state:<9}  {services}"
        )
    return "\n".join(lines) + "\n"


def requested_rule(record, name: str):
    """The requested rule called `name`, or exit 2 naming what was asked for.

    A grant with no request behind it is an admin typing a rule into a file that
    no manifest will ever fill in, so the answer is a rejected input and it names
    the entries that do exist — otherwise the operator is left guessing which
    spelling was meant.
    """
    for entry in record.firewall_requested:
        if entry.name == name:
            return entry
    asked = ", ".join(sorted({e.name for e in record.firewall_requested})) or "none"
    raise errors.GuardenError(
        f"{record.service!r} asked for no firewall rule named {name!r}; the rules its "
        f"manifest's `firewall:` block names are: {asked}",
        errors.REJECTED_INPUT,
    )

