"""`loom`'s render: a manifest, a registry and the host's own files become bytes,
or nothing at all.

**Pure, and the purity is why this is one function.** The same manifest, the same
registry, the same overrides and the same configuration produce the same bytes,
every run: no timestamp, no set iteration, no ordering that depends on what the
filesystem happened to hand back first. The plan is built entirely in memory and
is written only once every check has passed, so a refused render leaves nothing
behind — which is what makes "it refuses to render what it cannot resolve" mean
something rather than mean "it wrote half of it".

**The renderer owns every field the design has an opinion about** (spec 4, 6.3),
and the order is the argument: the opinionated pass runs *after* the source is
read and *before* anything is emitted, so a converter that passes a field through
and a repository that writes one by hand are treated identically. The owned fields
are the refusal list, the whole `PublishPort` set, `Network=pasta:`, `AddHost=`,
the credential requests, the `.volume` units and the start-order edges. What is
left — image, command, entrypoint, environment, user, working directory, labels —
belongs to the repository, and podlet owns the translation of those.

The plan has three directories rather than one flat pile, and each names who
installs it:

    <out>/units/     the quadlet files the mutator copies into the service's home
    <out>/system/    root-owned files, spec 6.10's `<name>.target`
    <out>/shared/    the slices `roots` and `twig` read (spec 2)

`--out` is the render directory the mutator copies from and removes (spec 2), and
`loom` writes nothing outside it: the converter's scratch space is a temporary
directory that is gone before this returns.
"""

from __future__ import annotations

import os
import shutil
from dataclasses import dataclass, field
from pathlib import Path

from guarden import (
    compose,
    conf,
    edgeconf,
    edges,
    errors,
    names,
    paths,
    registry,
    secretschema,
    unitsource,
)
from guarden import config as config_mod
from guarden import manifest as manifest_mod
from guarden import modules as modules_mod
from guarden import overrides as overrides_mod
from guarden import publications as publications_mod
from guarden.compose import Mount
from guarden.config import Config, Track
from guarden.overrides import Overrides
from guarden.registry import Registry
from guarden.unitsource import Unit

QUADLET_DIR = Path(".guarden") / "quadlet"
ENV_FILE = "guarden.env"
ORDER_DROPIN = "10-guarden-order.conf"
ORDER_TARGET = "guarden-order.target"
DROPDIN_SECTION = "Service"

# The fields guarden owns, removed from whatever the unit source said before
# anything is emitted. The same set for a translated Compose file and a
# hand-written quadlet file, because a converter that passed one through must
# not be a boundary and a hand-written one is a repository asking out loud.
OWNED_KEYS = (
    "AddHost",
    "PodmanArgs",
    "PublishPort",
    "Network",
    "Secret",
    "Volume",
    "EnvironmentFile",
    "LoadCredentialEncrypted",
    "Device",
    "AddDevice",
    "HostUsers",
    "Rootfs",
)

# The refusal list (spec 6.3) in the vocabulary a hand-written quadlet file is
# written in. A Compose file's spelling of the same requests is refused in
# `compose.refuse`, before the converter ever sees it.
REFUSED_DIRECTIVES = (
    "PodmanArgs",
    "BindPaths",
    "BindReadOnlyPaths",
    "Mounts",
    "Device",
    "AddDevice",
    "HostUsers",
    "Rootfs",
    "Userns",
    "NoNewPrivileges",
    "Privileged",
)

LOOPBACK = "127.0.0.1"
ALLOWED_ROOT = "/etc/guarden"
SUBSTITUTION = "${domain}"
BACKEND = "pasta"
ABSENT = Path("/nonexistent/guarden/nothing")

# The order the renderer's own keys are written in, after the repository's. Fixed
# so a regenerated unit is byte-identical when nothing changed.
GUARDEN_OWNED_ORDER = (
    "ContainerName",
    "Network",
    "AddHost",
    "EnvironmentFile",
    "Volume",
    "PublishPort",
    "Secret",
)


@dataclass
class Context:
    """Everything a `render` reads from the host.

    `check` has none of it, and that is the whole difference between the two
    verbs: whether an edge's provider exists, and what publication it was
    allocated, are answers from the host that a manifest alone cannot give.
    """

    service: str
    instance: str | None
    record: Registry
    config: Config
    granted: Overrides
    track: Track

    def publications(self) -> dict[str, int]:
        """This unit directory's publications: an instance's own, or the
        service's. Allocated per instance so two previews of one service can both
        be routed at once (spec 7.4)."""
        if self.instance:
            instance = self.record.instances.get(self.instance)
            if instance is not None and instance.publication:
                return dict(instance.publication)
        return dict(self.record.publication)

    def unit_dir(self) -> Path:
        home = paths.service_home(self.service)
        if self.instance:
            home = paths.instance_home(self.service, self.instance)
        return home / paths.QUADLET

    def volume_path(self, kind: str, volume: str) -> Path:
        return paths.volume(self.service, kind, volume, self.instance)

    def volume_name(self, volume: str) -> str:
        return f"{self.service}-{volume}.volume"


@dataclass
class Source:
    """The unit source, resolved: the container set, and what each one declares."""

    kind: str
    origin: Path
    units: dict[str, Unit]
    mounts: dict[str, list[Mount]]
    warnings: list[str] = field(default_factory=list)

    def containers(self) -> list[str]:
        return sorted(self.units)


@dataclass
class Plan:
    """The whole render, in memory: relative path -> text, plus the warnings."""

    files: dict[str, str] = field(default_factory=dict)
    warnings: list[str] = field(default_factory=list)

    def add(self, path: str, text: str) -> None:
        self.files[path] = text

    def sorted_paths(self) -> list[str]:
        return sorted(self.files)


# --- templates ---------------------------------------------------------------


def template_dir() -> Path:
    """Where the templates are, and why the checkout comes before the install.

    A checkout is where the template being edited and the render being tested are
    the same file, and the installed copy under `/usr/lib/guarden/templates` is
    the fallback for a host that runs from there. A changed template changes the
    next render, which is the property a test can only check if the two are the
    same file.
    """
    override = os.environ.get("GUARDEN_TEMPLATES")
    if override:
        return Path(override)
    beside = Path(__file__).parent / "templates"
    return beside if beside.is_dir() else paths.TEMPLATES


def render_template(name: str, **fields) -> str:
    """Units are rendered from `templates/` with jinja2 and not from heredocs
    (spec 6.3). `--help` has to answer on a host where a runtime dependency is
    not installed yet, so the import is here rather than at module scope."""
    try:
        import jinja2
    except ImportError:
        raise errors.GuardenError(
            "python3-jinja2 is not importable; it is the distribution's package, "
            "installed by `soil packages`",
            errors.HOST_NOT_AS_ASSUMED,
        ) from None
    directory = template_dir()
    if not directory.is_dir():
        raise errors.GuardenError(
            f"the template directory {directory} does not exist; units are rendered from "
            f"templates/ and not from strings built in the program",
            errors.HOST_NOT_AS_ASSUMED,
        )
    environment = jinja2.Environment(
        loader=jinja2.FileSystemLoader(str(directory)),
        undefined=jinja2.StrictUndefined,
        keep_trailing_newline=True,
        trim_blocks=True,
        lstrip_blocks=True,
        autoescape=False,
    )
    try:
        template = environment.get_template(name)
    except jinja2.TemplateNotFound:
        raise errors.GuardenError(
            f"the template {name} is missing from {directory}", errors.HOST_NOT_AS_ASSUMED
        ) from None
    return template.render(**fields)


# --- the unit source ---------------------------------------------------------


def resolve_unit_source(directory: Path, document: manifest_mod.Manifest) -> Source:
    """`compose.yaml` at the root or `.guarden/quadlet/`, exactly one.

    Both present is ambiguous and neither is incomplete, and both are refused
    naming both accepted locations rather than picking one: a renderer that
    quietly preferred one would make the repository's real behaviour depend on
    which file happened to exist.
    """
    compose_file = directory / compose.COMPOSE_REL
    quadlet_dir = directory / QUADLET_DIR
    has_compose = compose_file.is_file()
    has_quadlet = quadlet_dir.is_dir()

    if has_compose and has_quadlet:
        raise errors.GuardenError(
            f"the unit source is ambiguous: both {compose_file} and {quadlet_dir} are present, "
            f"and a project ships exactly one of them"
        )
    if not has_compose and not has_quadlet:
        raise errors.GuardenError(
            f"the unit source is missing: this project ships neither {compose_file} nor "
            f"{quadlet_dir}"
        )
    _check_declared(document, compose.COMPOSE_REL if has_compose else QUADLET_DIR)
    if has_compose:
        return _compose_source(compose_file)
    return _quadlet_source(quadlet_dir)


def _check_declared(document: manifest_mod.Manifest, present: Path) -> None:
    """`units:` names which of the two accepted locations this project ships.

    It is checked rather than believed, because a manifest that says one thing
    and a repository that ships another is a case where the developer is looking
    at a file guarden is not going to read.
    """
    declared = document.units
    if declared is None:
        return
    if Path(declared) not in (compose.COMPOSE_REL, QUADLET_DIR):
        raise errors.GuardenError(
            f"the manifest {document.source} names units: {declared!r}, and the accepted "
            f"locations are {compose.COMPOSE_REL} and {QUADLET_DIR}"
        )
    if Path(declared) != present:
        raise errors.GuardenError(
            f"the manifest {document.source} names units: {declared}, and the unit source this "
            f"project ships is {present}"
        )


def _compose_source(path: Path) -> Source:
    document = compose.document(path)
    declared = compose.services(document, path)
    warnings: list[str] = []
    mounts: dict[str, list[Mount]] = {}
    for container, body in sorted(declared.items()):
        compose.refuse(body, container, path)
        wanted = body.get("network_mode")
        if wanted is not None:
            warnings.append(
                f"the unit source {path} asks for network_mode: {wanted} on the service "
                f"{container!r}, and it is replaced rather than passed through: a guarden unit "
                f"always carries the host's own [network] backend, because a surviving "
                f"network_mode: host would give a repository the host's network namespace"
            )
        mounts[container] = compose.mounts(body, container, path)

    units: dict[str, Unit] = {}
    for translation in compose.convert(path):
        if translation.container in units:
            raise errors.GuardenError(
                f"podlet produced two units for the service {translation.container!r} when it "
                f"translated {path}"
            )
        units[translation.container] = unitsource.loads(
            translation.text, path / f"{translation.container}.container"
        )
    for container in declared:
        if container not in units:
            raise errors.GuardenError(
                f"podlet translated {path} without producing a unit for the service "
                f"{container!r}, and the render would have no container to give it to",
                errors.HOST_NOT_AS_ASSUMED,
            )
    for container in units:
        units[container].path = path / f"{container}.container"
    return Source(kind="compose", origin=path, units=units, mounts=mounts, warnings=warnings)


def _quadlet_source(directory: Path) -> Source:
    files = sorted(directory.glob("*.container"))
    if not files:
        raise errors.GuardenError(f"the unit source {directory} has no .container unit in it")
    units: dict[str, Unit] = {}
    for path in files:
        unit = unitsource.parse(path)
        units[unit.stem()] = unit
    mounts = {name: _mounts_of_unit(unit) for name, unit in units.items()}
    return Source(kind="quadlet", origin=directory, units=units, mounts=mounts)


def _mounts_of_unit(unit: Unit) -> list[Mount]:
    out: list[Mount] = []
    for value in unit.get("Container", "Volume"):
        out.append(_quadlet_mount(value, unit))
    return out


def _quadlet_mount(value: str, unit: Unit) -> Mount:
    parts = value.split(":")
    if len(parts) == 1:
        raise errors.GuardenError(
            f"the unit source {unit.path}: Volume={value!r} has no source, so it names no "
            f"volume and no host path"
        )
    source, target = parts[0], parts[1]
    mode = parts[2] if len(parts) > 2 else ""
    if source.endswith(".volume"):
        source = source[: -len(".volume")]
    if source.startswith(("./", "../", "~")):
        raise errors.GuardenError(
            f"the unit source {unit.path}: Volume={value!r} names the relative host path "
            f"{source!r}, and a relative path resolves against whatever directory podman is "
            f"started in; use a declared volume, an absolute path under the service's own "
            f"volumes, or one the admin allowed in [mounts] allow"
        )
    kind = "bind" if source.startswith("/") else "volume"
    return Mount(kind=kind, source=source, target=target, mode=mode)


# --- the checks that need no host --------------------------------------------


def refuse_directives(source: Source) -> None:
    """The refusal list, on a hand-written unit, named as it was written.

    These are guardrails against accidents and not a boundary against a hostile
    repository: the repository's code runs as the service user, which can write
    files in its own home. What actually holds is the per-service uid and the
    `0700` on its tree (ADR-0003).

    **A translated Compose file is not refused here.** Its refusals are on the
    repository's own declaration, in the vocabulary it was written in
    (`compose.refuse`), because `network_mode: host` is *replaced* rather than
    refused — the spec says so, and replacing it is as safe as refusing it. What
    a converter emits for the fields guarden owns is removed by the opinionated
    pass either way, so a converter that passed a capability through gets it
    removed rather than installed.
    """
    if source.kind != "quadlet":
        return
    for container in source.containers():
        unit = source.units[container]
        for key in REFUSED_DIRECTIVES:
            for value in unit.get("Container", key):
                raise errors.GuardenError(
                    f"the unit source {unit.path}: the container {container!r} sets "
                    f"{key}={value!r}, and a guarden service does not get it"
                )
        for value in unit.get("Container", "Network"):
            if not value.startswith(BACKEND):
                raise errors.GuardenError(
                    f"the unit source {unit.path}: the container {container!r} asks for "
                    f"Network={value!r}, and the only backend the renderer writes is "
                    f"{BACKEND}, from the [network] table in {paths.GUARDEN_TOML}"
                )


def check_containers(document: manifest_mod.Manifest, source: Source) -> None:
    """`routes:`, `ports:` and `widgets:` name a container the unit source
    defines. Both sides are input, so this is exit `2` naming the manifest and the
    key (spec 1.2)."""
    defined = source.containers()
    for block, entries in (
        ("routes", [(route.container, "routes") for route in document.routes]),
        ("ports", [(entry.container, "ports") for entry in document.ports]),
        ("widgets", [(widget.container, "widgets") for widget in document.widgets]),
    ):
        for container, _ in entries:
            if container not in source.units:
                raise errors.GuardenError(
                    f"the manifest {document.source}: the {block} entry names the container "
                    f"{container!r}, and the unit source {source.origin} defines "
                    f"{', '.join(defined)}"
                )


def check_volumes(document: manifest_mod.Manifest, source: Source) -> list[Mount]:
    """The mounts, the declared volumes, and the two ways they can disagree.

    **A mounted named volume in neither `state:` nor `bulk:` is refused, naming
    the volume.** It would land in the service's rootless image store, where
    nothing snapshots it, nothing lists it, and removing the service discards it.
    The manifest is not allowed to make that mistake, and it is the single most
    expensive one available.

    The other direction is refused too: a volume the manifest declares and the
    unit source does not mount is a declaration that does nothing, and a subvolume
    nobody mounts is not what the manifest said.
    """
    declared = dict(document.volumes())
    for container in source.containers():
        for mount in source.mounts.get(container, []):
            if mount.is_path or mount.source in declared:
                continue
            raise errors.GuardenError(
                f"the unit source {source.origin}: the container {container!r} mounts the named "
                f"volume {mount.source!r}, which the manifest {document.source} declares in "
                f"neither `state:` nor `bulk:`; an undeclared volume lands in the service's "
                f"image store, where nothing snapshots it, nothing lists it, and removing the "
                f"service discards it"
            )
    mounted = {
        mount.source
        for container in source.containers()
        for mount in source.mounts.get(container, [])
        if not mount.is_path
    }
    for name in sorted(set(declared) - mounted):
        raise errors.GuardenError(
            f"the manifest {document.source} declares the volume {name!r}, and the unit source "
            f"{source.origin} does not mount it"
        )
    return [mount for container in source.containers() for mount in source.mounts[container]]


def check_mount_paths(mounts: list[Mount], source: Source, context: Context | None) -> None:
    """A host-path bind outside the service's own volumes, `/etc/guarden` and the
    admin's `[mounts] allow` is refused, naming the path (spec 6.3).

    A repository cannot widen its own mounts: `overrides.toml` is root-owned and
    outside the service's tree, and an entry in `[mounts] allow` is a grant in the
    same sense a port is (ADR-0006).
    """
    allowed = context.granted.mounts if context else []
    where = paths.overrides(context.service) if context else "the root-owned overrides.toml"
    for mount in mounts:
        if not mount.is_path:
            continue
        if _under(mount.source, ALLOWED_ROOT) or any(_under(mount.source, e) for e in allowed):
            continue
        raise errors.GuardenError(
            f"the unit source {source.origin}: a container mounts the host path "
            f"{mount.source!r}, which is not the service's own volume, is not {ALLOWED_ROOT}, "
            f"and is not in [mounts] allow in {where}"
        )


def _under(path: str, root: str) -> bool:
    if not root:
        return False
    return path == root or path.startswith(root.rstrip("/") + "/")


# --- the checks that need the host -------------------------------------------


def check_edges(document: manifest_mod.Manifest, context: Context) -> None:
    """`needs:` against the **registry**, and `provides:` kind to kind.

    The provider's `provides:` is read from its registry rather than from its
    manifest, because the provider's tree is `0700` to the provider and `loom`
    runs as `guarden`: the registry is the only copy of it a consumer can read.
    That is also why there is one exit code for a disagreement rather than two —
    a provider with no registry entry and a provider whose kinds do not include
    the consumer's `as:` are both answers that came from the host, and both are
    exit `1` naming both services and both kinds.
    """
    for edge in document.needs:
        if edge.service == context.service:
            raise errors.GuardenError(
                f"the manifest {document.source} needs {edge.service!r}, which is the service "
                f"that declared it: a self-edge has no consumer and is nearly always a "
                f"copy-paste"
            )
        provider = registry.load(edge.service)
        if provider is None:
            raise errors.GuardenError(
                f"{context.service} needs {edge.service!r} as {edge.prefix!r}, and there is "
                f"no registry entry for it; a service that does not exist yet is created by a "
                f"later deploy, and one that never is names a service this host has never "
                f"heard of",
                errors.HOST_NOT_AS_ASSUMED,
            )
        if edge.prefix not in provider.provides:
            raise errors.GuardenError(
                f"{context.service} needs {edge.service!r} as {edge.prefix!r}, and "
                f"{edge.service} offers {', '.join(provider.provides) or 'nothing'}: the "
                f"consumer wants the kind {edge.prefix!r} and the provider does not list it",
                errors.HOST_NOT_AS_ASSUMED,
            )


def edge_publications(document: manifest_mod.Manifest, context: Context) -> list[tuple[str, int]]:
    """`<AS>_PORT` for every edge, from the consumer's own registry.

    A publication is an allocation, so it is in the registry and not in either
    manifest: the consumer's tree is the only one `loom` can read, and the
    mutator records the edge's publications when it installs the edge. An edge
    with no allocated publication is exit `1` — the host has not been asked yet —
    rather than a loopback port the renderer invented.
    """
    out: list[tuple[str, int]] = []
    for edge in document.needs:
        stored = (context.record.edges.get(edge.service) or {}).get("publications") or []
        numbers = [
            value for value in stored if isinstance(value, int) and not isinstance(value, bool)
        ]
        if not numbers:
            raise errors.GuardenError(
                f"{context.service} needs {edge.service!r} and its registry entry names no "
                f"allocated publication for the edge; the mutator allocates one when it "
                f"installs the edge, and the renderer does not guess a loopback port",
                errors.HOST_NOT_AS_ASSUMED,
            )
        out.append((edge.service, min(numbers)))
    return out


def check_ingress(document: manifest_mod.Manifest, context: Context) -> str:
    """The alias, and only where it is needed.

    `AddHost=<name>:<alias>` is the whole of the name resolution there is, so a
    service that needs a name and an empty `ingress.alias` would render host
    entries that resolve to nothing. Empty is what the key is until `soil
    install` measures it, so this is exit `1` — the host is not in the state the
    render assumed. A service that needs no name is not refused for a missing
    alias.
    """
    if not document.needs and not routed_names(context.service):
        return context.config.alias
    if not context.config.alias:
        raise errors.GuardenError(
            f"{context.config.path}: ingress.alias is empty and {context.service} renders host "
            f"entries, so every rendered AddHost= would resolve to nothing; `soil install` "
            f"measures the alias and writes it there",
            errors.HOST_NOT_AS_ASSUMED,
        )
    return context.config.alias


def is_edge(service: str) -> bool:
    """Whether an enabled module installed this service as the edge."""
    for name in config_mod.load().modules:
        try:
            entry = modules_mod.read(name).edge()
        except errors.GuardenError:
            continue
        if entry is not None and entry.name == service:
            return True
    return False


def routed_names(service: str) -> list[str]:
    """Every service this render's consumer may have to name: the routed ones.

    The edge resolves the service name of every route it proxies, so those names
    go into the **edge's** own units as `AddHost=` entries pointing at the alias.
    Without them the edge cannot resolve its own configuration, which is a 502
    on every route and the first thing to check when one appears.
    """
    if service is None or not is_edge(service):
        return []
    out = []
    for name in registry.names():
        record = registry.load(name)
        if record is not None and record.route_hosts and record.service != service:
            out.append(record.service)
    return sorted(out)


def ingress_ports(service: str) -> list[str]:
    """Every loopback `PublishPort` the edge's declared ingress binds on.

    `127.0.0.1:<publication>:<container port>` per declared ingress entry, and
    the renderer owns the whole set like every other port: the module's file is
    guarden's own and the allocation is the registry's, and nothing else may
    write a `PublishPort` line. `/udp` rides on the line because a forwarded udp
    port is a different protocol from the same number over tcp.

    The API publication rides here too, on the entrypoint the edge's own source
    serves it from: it is a control surface rather than ingress, so it is never
    forwarded, but a publication nothing binds is a port the firewall admits and
    nothing answers.
    """
    record = registry.load(service) if service else None
    if record is None or not is_edge(service):
        return []
    out: list[str] = []
    for module in config_mod.load().modules:
        try:
            entry = modules_mod.read(module).edge()
        except errors.GuardenError:
            continue
        if entry is None or entry.name != service:
            continue
        for endpoint, port, protocol in modules_mod.read(module).ingress_for(service):
            publication = record.publication.get(endpoint)
            if publication is None:
                continue
            suffix = "/udp" if protocol == "udp" else ""
            out.append(f"{LOOPBACK}:{publication}:{port}{suffix}")
        if entry.api:
            publication = record.publication.get(publications_mod.API)
            port = edgeconf.api_port(
                edgeconf.of_source(modules_mod.source_of(module, entry.name), entry.name),
                entry.name,
            )
            if publication is not None and port:
                out.append(f"{LOOPBACK}:{publication}:{port}")
    return out


# --- the render --------------------------------------------------------------


def build(
    directory: Path, document: manifest_mod.Manifest, source: Source, context: Context | None
) -> Plan:
    """The whole render, in memory."""
    plan = Plan(warnings=list(source.warnings))
    refuse_directives(source)
    check_containers(document, source)
    mounts = check_volumes(document, source)
    check_mount_paths(mounts, source, context)

    edge_ports: list[tuple[str, int]] = []
    routed: list[str] = []
    if context is not None:
        check_edges(document, context)
        check_ingress(document, context)
        edge_ports = edge_publications(document, context)
        routed = routed_names(context.service)

    schema = secretschema.read(directory / document.schema if document.schema else ABSENT)
    plan.warnings.extend(_image_warnings(source, context))
    dropins = _dropins(context, source)
    ports = _publications(document, context)
    domain = context.config.domain if context else ""

    for container in source.containers():
        plan.add(
            f"units/{container}.container",
            _container_unit(
                document=document,
                source=source,
                container=container,
                context=context,
                merged=dropins.get(container),
                ports=ports,
                edge_ports=edge_ports,
                routed=routed,
                schema=schema,
                domain=domain,
            ),
        )
        plan.add(
            f"units/{container}.container.d/{ORDER_DROPIN}",
            render_template("quadlet-order-dropin.j2", service=context.service if context else ""),
        )

    if edge_ports:
        plan.add(f"units/{ENV_FILE}", _environment_file(document, edge_ports))
    for name, kind in document.volumes():
        plan.add(f"units/{name}.volume", _volume_unit(name, kind, context))
    plan.add(f"system/{ORDER_TARGET}", _order_target(document, context))
    plan.add("shared/routes.toml", _routes(document, context, ports))
    plan.add("shared/schema.toml", _schema_slice(schema, context))
    for widget in document.widgets:
        plan.add(f"shared/widgets/{Path(widget.file).name}", _widget_file(directory, widget.file))
    return plan


def _dropins(context: Context | None, source: Source) -> dict[str, Unit]:
    """The admin's drop-in, merged into the source before generation (spec 6.3).

    `/etc/containers/systemd/users/<uid>/<unit>.container.d/` is the injection
    point, and it is searched *after* the home's own directory precisely so that a
    regenerated unit does not clobber it — which is only true if the renderer
    reads it and puts it back. A drop-in's `[Service]` keys land in the generated
    scope, because quadlet's own `[Container]` table has only `Memory=` and the
    systemd keys are the only way to express a soft and a hard limit together.
    """
    out: dict[str, Unit] = {}
    if context is None or not context.record.uid:
        return out
    for container in source.containers():
        directory = paths.ADMIN_UNITS / str(context.record.uid) / f"{container}.container.d"
        if not directory.is_dir():
            continue
        merged = _merged(source.units[container])
        for path in sorted(directory.glob("*.conf")):
            dropin = unitsource.parse(path)
            for section in dropin.order:
                for key, values in dropin.sections[section].items():
                    merged.put(section, key, values)
        out[container] = merged
    return out


def _merged(unit: Unit) -> Unit:
    merged = Unit(path=unit.path)
    for section in unit.order:
        for key, values in unit.sections[section].items():
            merged.put(section, key, values)
    return merged


def _publications(
    document: manifest_mod.Manifest, context: Context | None
) -> dict[str, tuple[int, int]]:
    """The rendered publication set: container -> (publication, container port).

    **The renderer owns the published-port set completely.** Every `PublishPort`
    in the unit source was removed before this ran, and the whole set comes from
    the allocations and the grants: a `ports:` entry in a Compose file would
    otherwise become a `PublishPort=` line verbatim, and the grant ceiling would
    be advisory (ADR-0006).

    Every one is a **loopback** publication, written `PublishPort=<address>:<pub>:<port>`.
    A granted public port never appears here at all — it becomes a `PREROUTING`
    DNAT onto one of these, written by the mutator into `30-services.conf` — so
    nothing in a rendered unit binds a non-loopback address (spec 7.5).
    """
    wanted: dict[str, int] = {}
    for route in document.routes:
        wanted.setdefault(route.container, route.port)
    for entry in document.ports:
        wanted.setdefault(entry.container, entry.port)
    out: dict[str, tuple[int, int]] = {}
    if context is None:
        return out
    allocated = context.publications()
    for container, port in sorted(wanted.items()):
        publication = allocated.get(container)
        if publication is None:
            raise errors.GuardenError(
                f"{context.service} names the container {container!r} in its routes or its "
                f"ports, and its registry entry allocates no publication for it; a grant is a "
                f"translation to a publication, so there is nothing to translate to",
                errors.HOST_NOT_AS_ASSUMED,
            )
        out[container] = (publication, port)
    return out


def _container_unit(
    document: manifest_mod.Manifest,
    source: Source,
    container: str,
    context: Context | None,
    merged: Unit | None,
    ports: dict[str, tuple[int, int]],
    edge_ports: list[tuple[str, int]],
    routed: list[str],
    schema: secretschema.Schema,
    domain: str,
) -> str:
    """One container unit: the source's own fields, then every field guarden owns.

    The order inside `[Container]` is the source's order, then guarden's own keys
    in a fixed order, so a regenerated unit differs from the last one only where
    something actually changed.
    """
    unit = merged if merged is not None else _merged(source.units[container])
    service = context.service if context else ""
    for key in OWNED_KEYS:
        unit.drop("Container", key)

    unit_keys = _lines(unit, "Unit", domain, drop=("Description",))
    description = source.units[container].one("Unit", "Description")
    unit_keys.insert(0, f"Description={description or f'{service} {container}'.strip()}")

    # The repository's own fields first, in the order the source wrote them, and
    # then the fields guarden owns in a fixed order — so a regenerated unit
    # differs from the last one only where something actually changed.
    container_keys = _lines(unit, "Container", domain)

    if not unit.one("Container", "ContainerName"):
        unit.put("Container", "ContainerName", [f"{service}-{container}".lstrip("-")])
    if context is not None:
        unit.put("Container", "Network", [context.config.network])
        # Every name this unit may have to resolve: the providers it declared an
        # edge to, and — for the edge itself — every routed service, because a
        # route target is `<service>:<publication>` and the edge has no other
        # way to turn that name into an address.
        hosts = [provider for provider, _ in sorted(edge_ports)]
        hosts.extend(name for name in routed if name not in hosts)
        if hosts:
            unit.put(
                "Container",
                "AddHost",
                [f"{name}:{context.config.alias}" for name in hosts],
            )
        if edge_ports:
            unit.put("Container", "EnvironmentFile", [str(context.unit_dir() / ENV_FILE)])
    volume_keys = _volume_lines(document, source, container, context)
    if volume_keys:
        unit.put("Container", "Volume", volume_keys)
    if container in ports:
        publication, port = ports[container]
        unit.put("Container", "PublishPort", [f"{LOOPBACK}:{publication}:{port}"])
    ingress = ingress_ports(service) if service else []
    if ingress:
        published = list(unit.get("Container", "PublishPort"))
        for line in ingress:
            if line not in published:
                published.append(line)
        unit.put("Container", "PublishPort", published)
    requests = _secret_requests(document, schema)
    if requests:
        unit.put("Container", "Secret", requests)
    container_keys.extend(_lines(unit, "Container", domain, only=GUARDEN_OWNED_ORDER))

    return render_template(
        "quadlet-container.j2",
        service=service,
        container=container,
        origin=str(source.origin),
        unit_keys=unit_keys,
        container_keys=container_keys,
        service_keys=_service_keys(context, unit),
    )


def _lines(unit: Unit, section: str, domain: str, drop: tuple[str, ...] = (),
           only: tuple[str, ...] = ()) -> list[str]:
    out: list[str] = []
    for key, value in unit.lines(section):
        if drop and key in drop:
            continue
        if only and key not in only:
            continue
        out.append(unitsource.format_line(key, _substitute(value, domain), unit.path))
    return out


def _substitute(value: str, domain: str) -> str:
    """`${domain}` is the only substitution, from `host.domain` (spec 4).

    No host environment variable and no service name: a rendered unit that
    depended on either would depend on when it was rendered, and the render is
    byte-identical or it is wrong.
    """
    if not domain:
        return value.replace(SUBSTITUTION, "")
    return value.replace(SUBSTITUTION, domain)


def _service_keys(context: Context | None, unit: Unit) -> list[str]:
    """`CPUWeight=` and `IOWeight=` from the track's `weight`, then the `[Service]`
    keys the unit source and the admin's drop-in wrote between them.

    The weight comes from the root-owned environment table and never from a
    manifest (spec 10), and the manifest key for one is refused by name. A
    drop-in's `CPUWeight` does not override the track's: the track is what the
    box orders services by, and a per-service drop-in is a cap rather than a
    priority.
    """
    out: list[str] = []
    if context is not None:
        out.append(f"CPUWeight={context.track.weight}")
        out.append(f"IOWeight={context.track.weight}")
    for key, value in unit.lines(DROPDIN_SECTION):
        if key in ("CPUWeight", "IOWeight") and context is not None:
            continue
        out.append(unitsource.format_line(key, value, unit.path))
    return out


def _volume_lines(
    document: manifest_mod.Manifest, source: Source, container: str, context: Context | None
) -> list[str]:
    """A named volume becomes the service's own `.volume` unit; a host path the
    admin allowed is passed through as it was written.

    The values carry no `Volume=` prefix: the key is the key, and a value that
    repeated it would render a line no parser could read.
    """
    declared = dict(document.volumes())
    out: list[str] = []
    for mount in source.mounts.get(container, []):
        mode = f":{mount.mode}" if mount.mode else ""
        if mount.is_path:
            out.append(f"{mount.source}:{mount.target}{mode}")
        elif mount.source in declared:
            name = context.volume_name(mount.source) if context else f"{mount.source}.volume"
            out.append(f"{name}:{mount.target}{mode}")
    return out


def _secret_requests(
    document: manifest_mod.Manifest, schema: secretschema.Schema
) -> list[str]:
    """A credential *request* and never a value (spec 6.3).

    `Secret=<KEY>,type=file` in `[Container]` and nothing else: podman resolves
    `<KEY>` from that service's own secret store and presents it at
    `/run/secrets/<KEY>`. A key whose application needs a variable gets
    `type=env`, which is what the schema's `@type env` means. An edge adds its
    own key under the `as` prefix — `<AS>_PASSWORD` for `auth: database`,
    `<AS>_SECRET` for `auth: secret` — so the credential the mutator planted is
    a credential the unit actually asks for.

    **There is no `LoadCredentialEncrypted=`**, and a test asserts the absence.
    These units run in the *service user's* user manager, which cannot read the
    `0600 root` system host key and has no business holding it. The credential
    materialiser decrypts once, root-side, which is why that unit exists; by the
    time the renderer runs the value is already a podman secret and the renderer
    only names it. A renderer that emitted the directive would produce a unit
    systemd cannot start, and the error would name quadlet rather than the cause.
    """
    out: list[str] = [f"{key.name},type={key.injection}" for key in schema.requests()]
    out.extend(
        f"{edges.credential_key(edge.auth, edge)},type=file"
        for edge in document.needs
        if edge.auth in (edges.AUTH_DATABASE, edges.AUTH_SECRET)
    )
    ordered: list[str] = []
    for line in out:
        if line not in ordered:
            ordered.append(line)
    return ordered


def _volume_unit(name: str, kind: str, context: Context | None) -> str:
    """A `.volume` unit for every declared volume, `state` and `bulk` alike,
    because a container must be able to mount either (spec 6.3).

    A `state` volume is bound to `/var/lib/guarden/services/<name>/state/<vol>`
    and a `bulk` one to the `bulk/` sibling, which is where the mutator created
    the subvolume. The path is derived; a manifest never writes one.
    """
    return render_template(
        "quadlet-volume.j2",
        service=context.service if context else "",
        volume=name,
        kind=kind,
        source=str(context.volume_path(kind, name) if context else ABSENT / kind / name),
        volume_name=context.volume_name(name) if context else f"{name}.volume",
    )


def _environment_file(document: manifest_mod.Manifest, edge_ports: list[tuple[str, int]]) -> str:
    """`<AS>_HOST` and `<AS>_PORT` for every edge. The host is the provider's own
    service name, with no suffix and no alias, and there is no name map and no
    `/etc/hosts` (spec 7.3)."""
    rows = [
        (edge.variable, edge.service, publication)
        for edge in document.needs
        for provider, publication in edge_ports
        if provider == edge.service
    ]
    return render_template("guarden.env.j2", rows=rows)


def _order_target(document: manifest_mod.Manifest, context: Context | None) -> str:
    """`<name>.target`: the real edges, in the *system* manager (spec 6.10).

    A unit in one service's user manager cannot require a unit in another's — two
    different dependency graphs — so the edges live here and the mutator installs
    the file. The edges are `Wants=`, not `Requires=`: a provider that is down
    does not stop its consumers, the consumer's first dial fails and it retries.
    """
    return render_template(
        "guarden-order.target.j2",
        service=context.service if context else "",
        providers=sorted(edge.service for edge in document.needs),
    )


def _routes(
    document: manifest_mod.Manifest, context: Context | None, ports: dict[str, tuple[int, int]]
) -> str:
    """The route slice `roots` reads. The target is `<name>:<publication>` — the
    service's own name, with no suffix and no alias — and the full host is the
    one the mutator allocated from the manifest's label and the track's prefix."""
    rows = [
        {
            "container": route.container,
            "port": route.port,
            "publication": ports.get(route.container, (0, route.port))[0],
            "host": (context.record.route_hosts.get(route.host) if context else "") or route.host,
            "label": route.host,
            "auth": route.auth,
            "target": f"{context.service}:{ports[route.container][0]}" if context and
            route.container in ports else "",
        }
        for route in document.routes
    ]
    return render_template(
        "shared-routes.toml.j2",
        service=context.service if context else "",
        project=context.record.project if context else "",
        track=context.track.name if context else "",
        rows=rows,
    )


def _schema_slice(schema: secretschema.Schema, context: Context | None) -> str:
    """The shape of the credentials and never a value: names, whether each is
    required, whether it is sensitive, and how the container is given it."""
    return render_template(
        "shared-schema.toml.j2",
        service=context.service if context else "",
        rows=[
            {
                "name": key.name,
                "required": key.required,
                "sensitive": key.sensitive,
                "injection": key.injection,
                "example": key.example or "",
            }
            for key in schema.requests()
        ],
    )


def _widget_file(directory: Path, relative: str) -> str:
    """Widget files are copied through **unparsed** (spec 6.5): dashboard UI
    configuration, and a renderer that parsed it would be a second thing to keep
    in step with the dashboard."""
    path = directory / relative
    try:
        return path.read_text(encoding="utf-8")
    except FileNotFoundError:
        raise errors.GuardenError(
            f"the manifest declares the widget file {relative}, and it does not exist"
        ) from None


def _image_warnings(source: Source, context: Context | None) -> list[str]:
    """An untagged or `latest` image is a `warning:` naming the service and the
    container, and it does not stop the render: a moving tag is a thing an
    operator decides about, and a render that stopped would take a service down
    over a tag."""
    service = context.service if context else "this service"
    out: list[str] = []
    for container in source.containers():
        image = source.units[container].one("Container", "Image")
        if not image:
            out.append(
                f"{service}: the unit source {source.origin} gives the container {container!r} "
                f"no Image=, and a unit with no image is not one podman can start"
            )
            continue
        reference = image.split()[-1]
        if "@" in reference:
            continue
        _, separator, tag = reference.rpartition(":")
        if not separator or "/" in tag:
            out.append(
                f"{service}: the container {container!r} uses the image {reference}, which "
                f"carries no tag, so two pulls can be two different images"
            )
        elif tag == "latest":
            out.append(
                f"{service}: the container {container!r} uses the image {reference}, which is "
                f"a moving tag rather than a version"
            )
    return out


# --- the verbs' bodies -------------------------------------------------------


def load_manifest(directory: Path) -> manifest_mod.Manifest:
    path = directory / manifest_mod.MANIFEST_REL
    if not path.is_file():
        raise errors.GuardenError(
            f"the manifest {path} does not exist; a project's manifest is "
            f"{manifest_mod.MANIFEST_REL} at its root"
        )
    return manifest_mod.read(path)


def resolve_context(service: str, instance: str | None) -> Context:
    """The host's half of a `render`: the registry, the configuration, the
    overrides and the track. A file that will not parse is the host, so it is
    exit `1` (spec 1.2)."""
    names.validate(service)
    record = registry.load(service)
    if record is None:
        raise errors.GuardenError(
            f"there is no registry entry for {service}, so there is nothing to render its "
            f"units for; a service is created before it is rendered",
            errors.HOST_NOT_AS_ASSUMED,
        )
    config = config_mod.load()
    track = config.track(record.environment)
    if track is None:
        raise errors.GuardenError(
            f"{record.environment!r} is the environment of {service} and it names no track in "
            f"{config.path}; the environment set is that file's [[environments]] table",
            errors.HOST_NOT_AS_ASSUMED,
        )
    if instance and instance not in record.instances:
        raise errors.GuardenError(
            f"{service} has no instance {instance!r}", errors.HOST_NOT_AS_ASSUMED
        )
    return Context(
        service=service,
        instance=instance,
        record=record,
        config=config,
        granted=overrides_mod.load(service),
        track=track,
    )


def write(plan: Plan, out: Path) -> None:
    """Write the plan, once, having emptied `--out` first.

    Nothing outside `out` is touched: the render directory is the only thing the
    renderer writes, and the mutator copies out of it and removes it (spec 2).
    """
    if len(out.parts) < 3:
        raise errors.GuardenError(
            f"--out is {out}, which is not a directory a render may be written into"
        )
    if out.exists():
        for child in sorted(out.iterdir()):
            if child.is_dir() and not child.is_symlink():
                shutil.rmtree(child)
            else:
                child.unlink()
    for relative in plan.sorted_paths():
        conf.write_file(out / relative, plan.files[relative], 0o644)
