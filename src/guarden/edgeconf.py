"""Traefik's static configuration, as the shipped unit source states it.

Traefik-specific, and shared: `roots` renders the file provider against the
entrypoint names found here, and `weedr module add` refuses a module whose
shipped source puts a redirect and TLS on one entrypoint before it installs
anything. Two readers of one file rather than two parsers.

The arguments are the ones a quadlet unit carries in `Exec=`. Reading them is
reading guarden's own shipped file, not a converter over repository input: the
module directory is root-owned and the renderer, not the mutator, is what ever
runs podlet.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path

from guarden import conf, errors, names, paths, registry, unitsource, users

ARGUMENT = re.compile(r"^--entrypoints\.(?P<name>[A-Za-z0-9_-]+)\.(?P<rest>.+)$")

# Traefik v3.2 spells this flag `--entrypoints`, all lowercase: `traefik --help`
# carries 41 of them and no `--entryPoints`. A capital P is not a flag traefik
# recognises, and an unrecognised flag is not a declaration -- it is ignored. That
# is how the gate module's nine PascalCase flags went unread: every entrypoint
# still parsed from guarden's own (wrong) spelling, every port still bound on
# traefik's defaults, and every suite that checked a bound port passed.
MISSPELLED = re.compile(r"^--entryPoints\.")
ADDRESS = re.compile(r"^:(?P<port>\d+)$")

# `/etc/guarden/edge/auth-provider`: the one file connecting the auth module to
# `roots`. The middleware is defined in a file of its own rather than inside
# every rendered route file, because a route with no `auth:` must render byte for
# byte what it rendered before — a definition in the template would be in all of
# them, and the file provider merges the directory so one definition serves all.
MARKER_NAME = "auth-provider"
MARKER = paths.ETC_GUARDEN / "edge" / MARKER_NAME
MARKER_MODE = 0o640
MIDDLEWARE = "guarden-forward-auth"


@dataclass
class Entrypoint:
    name: str
    port: int = 0
    tls: bool = False
    redirect: bool = False
    http3: bool = False
    api: bool = False
    certificates: list[str] = field(default_factory=list)


def _arguments(unit: unitsource.Unit) -> list[str]:
    out: list[str] = []
    for value in unit.get("Container", "Exec"):
        out.extend(str(value).split())
    return out


def entrypoints(unit: unitsource.Unit, where: str) -> dict[str, Entrypoint]:
    """The entrypoints one unit declares, keyed by name, in first-seen order."""
    found: dict[str, Entrypoint] = {}
    for argument in _arguments(unit):
        match = ARGUMENT.match(argument)
        if match is None:
            if MISSPELLED.match(argument):
                raise errors.GuardenError(
                    f"{where}: {argument.split('=')[0]} is spelled with a capital P, and traefik "
                    f"does not recognise it -- `traefik --help` lists `--entrypoints`, lowercase. "
                    f"An ignored flag is not a declaration: traefik would run on its default "
                    f"entrypoints and this file would claim the ones it asked for."
                )
            continue
        name = match["name"]
        rest = match["rest"]
        entry = found.get(name)
        if entry is None:
            entry = found[name] = Entrypoint(name=name)
        key = rest.partition("=")[0]
        if key == "http.tls":
            entry.tls = True
        elif key == "http.redirections.entrypoint.to":
            entry.redirect = True
        elif key == "http3":
            entry.http3 = True
        elif key in (
            "http.api",
            "http.api.dashboard",
            "http.api.insecure",
        ):
            # **Compared on the key, not the whole argument.** `_arguments`
            # yields `--entrypoints.api.http.api=true` whole, so testing
            # `rest` for equality never matched a flag that carries a value and
            # the API entrypoint parsed with `api=False`. `http.api` is the flag
            # that *enables* the API; dashboard and insecure only configure it
            # once enabled.
            entry.api = True
    for argument, value in _address_pairs(unit):
        match = ARGUMENT.match(argument)
        if match is None or match["rest"] != "address":
            continue
        address = ADDRESS.match(value)
        if address is None:
            raise errors.GuardenError(
                f"{where}: --entrypoints.{match['name']}.address={value!r}, and a traefik "
                f"entrypoint address is `:<port>` inside a container"
            )
        found[match["name"]].port = int(address["port"])
    check(found, where)
    return found


def api_port(found: dict[str, Entrypoint], where: str) -> int | None:
    """The port the edge serves its API on, from its own shipped source.

    A module declares `api = true` and the source says where; spec 3.6's key set
    has no port in it and the module must not grow one, so the entrypoint that
    carries `--entrypoints.<name>.http.api` is the answer.
    """
    serving = [entry for entry in found.values() if entry.api]
    if len(serving) > 1:
        raise errors.GuardenError(
            f"{where} enables the traefik API on {len(serving)} entrypoints"
            f" ({', '.join(entry.name for entry in serving)}), and the API is published on one "
            f"loopback port: a second would be a second port nothing accepts on"
        )
    if not serving:
        return None
    if not serving[0].port:
        raise errors.GuardenError(
            f"{where}: the entrypoint {serving[0].name!r} serves the traefik API and binds no "
            f"port, so its publication would forward to nothing"
        )
    return serving[0].port


def _address_pairs(unit: unitsource.Unit) -> list[tuple[str, str]]:
    out: list[tuple[str, str]] = []
    for argument in _arguments(unit):
        name, separator, value = argument.partition("=")
        if separator:
            out.append((name, value))
    return out


def check(found: dict[str, Entrypoint], where: str) -> None:
    """One entrypoint, one job.

    An entrypoint that both redirects to HTTPS and terminates TLS answers a
    request it can never finish: the redirect is served in the clear to a
    client that dialled TLS. Traefik would start it, so the refusal is ours.
    """
    if not found:
        raise errors.GuardenError(
            f"{where} declares no traefik entrypoint, and the edge is a service whose whole "
            f"purpose is the ports it answers on"
        )
    for entry in found.values():
        if entry.redirect and (entry.tls or entry.certificates):
            raise errors.GuardenError(
                f"{where}: the entrypoint {entry.name!r} both redirects to HTTPS and terminates "
                f"TLS, and one entrypoint does one job: a redirect is answered in the clear to "
                f"a client that dialled TLS"
            )


def of_source(directory: Path, where: str) -> dict[str, Entrypoint]:
    """Every entrypoint a shipped unit source declares, across its units."""
    out: dict[str, Entrypoint] = {}
    for path in sorted(directory.rglob("*.container")):
        for name, entry in entrypoints(unitsource.parse(path), f"{path}").items():
            existing = out.get(name)
            if existing is None:
                out[name] = entry
                continue
            if existing.port != entry.port:
                raise errors.GuardenError(
                    f"{where}: the entrypoint {name!r} is port {existing.port} in one unit and "
                    f"{entry.port} in another, and a forwarded port has to land on one of them"
                )
    return out


def routing_entrypoints(found: dict[str, Entrypoint]) -> list[str]:
    """The entrypoints a route may be attached to: the ones that serve.

    The redirect entrypoint serves nothing — every request to it becomes a
    redirect — and the API entrypoint is a control surface rather than a way in,
    so a router attached to either would answer something other than the
    container, which is what a route on the wrong entrypoint is.
    """
    return [
        entry.name
        for entry in found.values()
        if not entry.redirect and not entry.api and entry.port
    ]


def write_marker(service: str) -> None:
    """Write `/etc/guarden/edge/auth-provider`, `0640 root:guarden`.

    Written once, by `weedr module add auth`, and by nothing else: not by a
    service, not by a manifest, not by a poke and not by a later sync. The
    renderer reads it and never creates it, so a marker that is missing is a
    host that has no auth provider rather than a file it is about to get.
    """
    conf.write_file(MARKER, f"{service}\n", MARKER_MODE, (0, users.group_id("guarden")))


def read_marker() -> str | None:
    """The service name the marker names, or `None` when there is no marker.

    Absent is not an error here: the module not being installed is the warning
    path, and a caller that wants the refusal asks `provider`.
    """
    try:
        text = MARKER.read_text(encoding="utf-8")
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise errors.GuardenError(
            f"{MARKER} could not be read: {exc.strerror}", errors.HOST_NOT_AS_ASSUMED
        ) from exc
    return text.strip()


def provider(config) -> str:
    """The auth service named by the marker, validated, or exit `1`.

    **Fail-closed and before any configuration is written.** The name must be a
    well-formed service name, must resolve to a service that exists, and that
    service must be in a track with `gated = true`. A caller that gets a name
    back can render a rule aimed at it; a caller that gets an exception writes
    nothing at all, so the routes that were working keep working.

    A marker naming nothing is exit `1` and not exit `2`: the marker is a
    root-owned file on the host, so it is the host and not an input a caller
    supplied.
    """
    name = read_marker()
    if name is None:
        raise errors.GuardenError(
            f"{MARKER} does not exist, and it names the service `auth: true` routes are "
            f"aimed at; `weedr module add auth` writes it",
            errors.HOST_NOT_AS_ASSUMED,
        )
    if not names.NAME_RE.match(name):
        raise errors.GuardenError(
            f"{MARKER} names {name!r}, which is not a service name; it holds one service "
            f"name and nothing else",
            errors.HOST_NOT_AS_ASSUMED,
        )
    record = registry.load(name)
    if record is None:
        raise errors.GuardenError(
            f"{MARKER} names the service {name!r}, and no service by that name exists on "
            f"this host; `weedr service list` reports the services that do",
            errors.HOST_NOT_AS_ASSUMED,
        )
    track = config.track(record.environment)
    if track is None:
        raise errors.GuardenError(
            f"{MARKER} names the service {name!r}, whose environment {record.environment!r} "
            f"names no track in {paths.GUARDEN_TOML}; the tracks are: "
            f"{names.known_tracks(list(config.tracks)) or 'none'}",
            errors.HOST_NOT_AS_ASSUMED,
        )
    if not track.gated:
        raise errors.GuardenError(
            f"{MARKER} names the service {name!r}, which is in the track {track.name!r} and "
            f"that track is not gated; an auth provider behind the same gate as the things it "
            f"protects is no gate at all",
            errors.HOST_NOT_AS_ASSUMED,
        )
    return name


def marker_is_current(service: str) -> bool:
    """Whether the marker already names `service`, so the write can be skipped.

    Idempotence in the mutator rather than in the filesystem: `weedr module add`
    is run twice on a host that converged, and a rewrite of an identical file
    would change its mtime for no reason.
    """
    return read_marker() == service