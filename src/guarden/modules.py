"""`/usr/lib/guarden/modules/<name>/module.toml`: the module registry.

spec 3.6 and ADR-0008. There is no registry file: the directory is the
registry, and `weedr module list` reads that directory plus `[modules]
enabled` in `guarden.toml` and nothing else.

A module declares the services it installs, the shared programs it switches on,
the ingress it declares for forwarding, whether the service has an API, and the
modules it requires. It declares no path, no mode and no grant, and it
contributes no code.

`ingress` entries are `<entrypoint>:<port>/<proto>`. The name is an entrypoint
of the shipped unit source, the number is the port that entrypoint listens on
and the public port the kernel forwards to it, and the protocol is the one the
nat rule carries: `443/udp` is a different protocol and a different rule.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any

from guarden import conf, edgeconf, errors, names, paths

TOP_LEVEL_KEYS = {"name", "requires", "services", "switches"}
SERVICE_KEYS = {"service", "ingress", "api"}
SWITCH_KEYS = {"program"}
PROGRAMS = ("soil", "weedr", "loom", "roots", "twig", "furrow", "hose", "stakes")

PORT_MIN = 1
PORT_MAX = 65535
PROTOCOLS = ("tcp", "udp")


@dataclass(frozen=True)
class Service:
    name: str
    ingress: tuple[str, ...]
    api: bool


@dataclass(frozen=True)
class Module:
    name: str
    directory: Path
    requires: tuple[str, ...]
    services: tuple[Service, ...]
    switches: tuple[str, ...]

    def service(self, name: str) -> Service | None:
        return next((entry for entry in self.services if entry.name == name), None)

    def forwards(self) -> list[tuple[str, str, int, str]]:
        """One `(service, entrypoint, port, protocol)` per declared ingress.

        The order is the declaration's, and every reader sorts or counts on it,
        so a module's ingress list is the order its rules are written in.
        """
        out: list[tuple[str, str, int, str]] = []
        for entry in self.services:
            for value in entry.ingress:
                endpoint, _, number = value.partition(":")
                port, _, protocol = number.partition("/")
                out.append((entry.name, endpoint.strip(), int(port), protocol))
        return out

    def ingress_for(self, service: str) -> list[tuple[str, int, str]]:
        return [
            (endpoint, port, protocol)
            for name, endpoint, port, protocol in self.forwards()
            if name == service
        ]

    def edge(self) -> Service | None:
        """The service this module declares ingress for, if it declares any."""
        return next((entry for entry in self.services if entry.ingress), None)


def directory(name: str) -> Path:
    return paths.MODULES / name


def manifest_path(name: str) -> Path:
    return directory(name) / "module.toml"


def available() -> list[str]:
    """Every module the installation ships, in name order."""
    if not paths.MODULES.is_dir():
        return []
    return sorted(
        path.name for path in paths.MODULES.iterdir() if (path / "module.toml").is_file()
    )


def source_of(module: str, service: str) -> Path:
    """The shipped manifest and unit source for one of a module's services.

    Derived from the module and the service name, never declared: spec 5.3's
    rule is that no caller may name a location, and a root-owned program
    reading a root-owned path it shipped is not a caller naming one.
    """
    return directory(module) / service


def enabled(config) -> tuple[str, ...]:
    return tuple(config.modules)


def _type_error(where: Any, key: str, want: str) -> errors.GuardenError:
    return errors.GuardenError(f"{where}: {key} is not {want}", errors.HOST_NOT_AS_ASSUMED)


def _str(table: dict, key: str, where: Any, default: str = "") -> str:
    value = table.get(key, default)
    if not isinstance(value, str):
        raise _type_error(where, key, "a string")
    return value


def _bool(table: dict, key: str, where: Any) -> bool:
    value = table.get(key, False)
    if not isinstance(value, bool):
        raise _type_error(where, key, "a boolean")
    return value


def _string_list(table: dict, key: str, where: Any) -> list[str]:
    value = table.get(key, [])
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise _type_error(where, key, "a list of strings")
    return list(value)


def _closed(table: dict, allowed: set[str], where: Any) -> None:
    extra = sorted(set(table) - allowed)
    if extra:
        raise errors.GuardenError(
            f"{where}: unknown key {extra[0]!r}", errors.HOST_NOT_AS_ASSUMED
        )


def read(name: str) -> Module:
    """One module, from its own file. A name that ships nothing is exit `2`.

    The name is the caller's input and the directory is guarden's own
    installation, so a name naming no shipped module is a rejected input rather
    than a host that is out of state.
    """
    names.validate(name, "module name")
    where = manifest_path(name)
    if not where.is_file():
        raise errors.GuardenError(
            f"there is no module {name!r}: {where} does not exist, and the modules this "
            f"installation ships are: {', '.join(available()) or 'none'}"
        )
    document = conf.read_toml(where)
    _closed(document, TOP_LEVEL_KEYS, where)
    declared = _str(document, "name", where)
    if declared != name:
        raise errors.GuardenError(
            f"{where} declares name = {declared!r} and lives in the {name!r} directory; a "
            f"module's name is the directory it ships as"
        )
    services: list[Service] = []
    rows = document.get("services", [])
    if not isinstance(rows, list):
        raise _type_error(where, "services", "a list of [[services]] tables")
    for row in rows:
        if not isinstance(row, dict):
            raise _type_error(where, "services", "a list of [[services]] tables")
        _closed(row, SERVICE_KEYS, f"{where} a service")
        service = _str(row, "service", f"{where} a service")
        if not service:
            raise errors.GuardenError(f"{where}: a [[services]] entry names no service")
        names.validate(service, "module service name")
        services.append(
            Service(
                name=service,
                ingress=tuple(_ingress(row, service, where)),
                api=_bool(row, "api", f"{where} the service {service}"),
            )
        )
    seen = [entry.name for entry in services]
    if len(set(seen)) != len(seen):
        raise errors.GuardenError(
            f"{where}: the service {sorted({n for n in seen if seen.count(n) > 1})[0]!r} is "
            f"declared twice; a module installs a service once"
        )
    programs = _switches(document, where)
    return Module(
        name=name,
        directory=directory(name),
        requires=tuple(dict.fromkeys(_string_list(document, "requires", where))),
        services=tuple(services),
        switches=programs,
    )


def _switches(document: dict, where: Any) -> tuple[str, ...]:
    switches = document.get("switches", [])
    if not isinstance(switches, list):
        raise _type_error(where, "switches", "a list of [[switches]] tables")
    programs: list[str] = []
    for row in switches:
        if not isinstance(row, dict):
            raise _type_error(where, "switches", "a list of [[switches]] tables")
        _closed(row, SWITCH_KEYS, f"{where} a switch")
        program = _str(row, "program", f"{where} a switch")
        if program not in PROGRAMS:
            raise errors.GuardenError(
                f"{where}: [[switches]] names the program {program!r}, and the programs are "
                f"{', '.join(PROGRAMS)}"
            )
        programs.append(program)
    return tuple(dict.fromkeys(programs))


def _ingress(row: dict, service: str, where: Any) -> list[str]:
    """`<entrypoint>:<port>/<proto>` per forwarded port, every part checked."""
    out: list[str] = []
    for value in _string_list(row, "ingress", f"{where} the service {service}"):
        endpoint, separator, number = value.partition(":")
        endpoint = endpoint.strip()
        port, slash, protocol = number.partition("/")
        if not separator or not endpoint or not slash:
            raise errors.GuardenError(
                f"{where}: the ingress entry {value!r} of {service} is not "
                f"`<entrypoint>:<port>/<proto>`; the entrypoint is one the shipped unit source "
                f"defines, the port is the one it listens on, and the protocol is the one the "
                f"nat rule carries"
            )
        try:
            number_value = int(port)
        except ValueError:
            number_value = 0
        if not PORT_MIN <= number_value <= PORT_MAX:
            raise errors.GuardenError(
                f"{where}: the ingress entry {value!r} of {service} carries port {port!r}, and "
                f"a port is {PORT_MIN}-{PORT_MAX}"
            )
        if protocol not in PROTOCOLS:
            raise errors.GuardenError(
                f"{where}: the ingress entry {value!r} of {service} carries the protocol "
                f"{protocol!r}, and the protocols are {', '.join(PROTOCOLS)}"
            )
        out.append(f"{endpoint}:{port}/{protocol}")
    if len(set(out)) != len(out):
        raise errors.GuardenError(
            f"{where}: the service {service} declares the same ingress entry twice"
        )
    return out


def check_entrypoints(module: Module, service: str, found: dict[str, edgeconf.Entrypoint]) -> None:
    """Every ingress `service` declares is an entrypoint its own source has.

    A publication forwards to a loopback port a container is already listening
    on, so a module that named an entrypoint its own source does not have — or
    gave a port the entrypoint does not bind — forwards to nothing. Both are
    exit `2`, because the module's own files are input. `api = true` with no
    entrypoint serving the API is the same claim and is refused the same way.
    """
    for declared, endpoint, port, protocol in module.forwards():
        if declared != service:
            continue
        entry = found.get(endpoint)
        if entry is None:
            raise errors.GuardenError(
                f"the module {module.name!r} declares the ingress entrypoint {endpoint!r} for "
                f"{service}, and its shipped unit source declares "
                f"{', '.join(found) or 'no entrypoint'}"
            )
        if entry.port != port:
            raise errors.GuardenError(
                f"the module {module.name!r} forwards {port}/{protocol} to the entrypoint "
                f"{endpoint!r}, and that entrypoint binds :{entry.port}"
            )
    declared = module.service(service)
    if declared is not None and declared.api and edgeconf.api_port(found, service) is None:
        raise errors.GuardenError(
            f"the module {module.name!r} declares api = true for {service} and its shipped unit "
            f"source enables the traefik API on no entrypoint, so the publication it allocates "
            f"would be accepted by the firewall and answered by nothing"
        )


def listing(config) -> dict[str, list[str]]:
    """`weedr module list`: the directory plus `[modules] enabled`, nothing else."""
    shipped = available()
    return {
        "enabled": [name for name in config.modules],
        "available": shipped,
    }


AUTH_MODULE = "authelia"


def auth_provider(module: Module) -> str | None:
    """The service a `auth: true` route is put behind, from this module's services.

    It is the module's own service and never a name in its file: a module
    declares services, and the marker names one of them, so the marker is
    derived rather than another value a module could state.
    """
    if module.name != AUTH_MODULE or not module.services:
        return None
    return module.services[0].name


def write_auth_provider(module: Module) -> str | None:
    """Write the marker, once, and only for the authelia module.

    Called from `weedr module add` and from nothing else — not from a service
    install, not from a render, not from a sync. A module that is not `authelia`
    returns without touching the file, so adding `traefik` cannot overwrite it and
    a re-add of a module that has not changed rewrites nothing.
    """
    service = auth_provider(module)
    if service is None or edgeconf.marker_is_current(service):
        return None
    edgeconf.write_marker(service)
    return service
