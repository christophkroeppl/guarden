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

**A fourth directory, `admin/`, holds the one file the mutator writes in
podman's uid-scoped search path** (ADR-0019): the keep-id pin's
`50-guarden-keepid.conf`. It is not in the service's home — nothing
root-owned lives there — and the mutator installs it into
`/etc/containers/systemd/users/<uid>/<unit>.container.d/`, where the
generator reads it and where the admin's own `90-admin.conf` sits beside it.

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
    edgeresolve,
    edges,
    errors,
    exposure,
    images,
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
    # ADR-0019: the keep-id pin lives in a drop-in of its own, and the base
    # unit carries no `UserNS=` line at all. A source's own line is refused
    # by name (`REFUSED_DIRECTIVES` and the spelling check beside it), and
    # the admin's drop-in is never merged into the base either — so the only
    # way a `UserNS=` reaches a unit is the file guarden writes.
    "UserNS",
)

# The refusal list (spec 6.3) in the vocabulary a hand-written quadlet file is
# written in. A Compose file's spelling of the same requests is refused in
# `compose.refuse`, before the converter ever sees it.
#
# `Sysctl=` is here for the same reason as `zram:` is refused in the Compose
# vocabulary and `zram:` in the manifest: `vm.swappiness` and its neighbours are
# the host's kernel knobs and `soil sysctl` converges them from the root-owned
# guarden.toml, so a `Sysctl=` line is a repository stating a value the host
# owns. It is the one way a unit source names a host knob at all, which is
# exactly why it needs refusing by name rather than an "unknown key".
REFUSED_DIRECTIVES = (
    "PodmanArgs",
    "BindPaths",
    "BindReadOnlyPaths",
    "Mount",
    "Device",
    "AddDevice",
    "HostUsers",
    "Rootfs",
    "Userns",
    "NoNewPrivileges",
    "Privileged",
    "Sysctl",
)

LOOPBACK = "127.0.0.1"
ALLOWED_ROOT = "/etc/guarden"
SUBSTITUTION = "${domain}"
BACKEND = "pasta"
ABSENT = Path("/nonexistent/guarden/nothing")

# The order the renderer's own keys are written in, after the repository's. Fixed
# so a regenerated unit is byte-identical when nothing changed.
#
# **`UserNS` is not in this list, and its absence is the model** (ADR-0019):
# the keep-id pin lives in a drop-in of guarden's own —
# `/etc/containers/systemd/users/<uid>/<unit>.container.d/50-guarden-keepid.conf`
# — and the base unit carries no `UserNS=` line at all. The pin therefore
# survives a regeneration of the unit, an admin's own `90-admin.conf` in the
# same directory overrides it by name order alone, and no render can carry
# the line twice.
GUARDEN_OWNED_ORDER = (
    "ContainerName",
    "Network",
    "AddHost",
    "EnvironmentFile",
    "Volume",
    "Mount",
    "PublishPort",
    "Secret",
)


def owner_line(record: Registry, unit: str, image: str) -> str | None:
    """The `UserNS=` value the renderer writes for THIS unit, and `None` when it
    writes none — the one spelling of the line, answered per unit (ADR-0019).

    `image` is the reference THIS unit names, and it is part of the answer:
    the pair is only true of the image it was read from, so a unit naming
    another one is the probe's condition again and renders no line rather than
    another image's pin — the failure the per-unit map exists to prevent, and
    the same question `_owner_plan` asks before the start path probes. The
    start path reads this to decide whether the installed units already hold
    what the record renders for each of them, so the check and the render
    cannot drift apart; what is left once the record answers is `owner_uid`:
    `None` is "not probed yet" and renders nothing (nothing has been
    measured), and `0` is an image that declares no user, whose container root
    the default map already moves onto the service identity — the line would
    name a mapping already in effect and move the rest of the map to get
    there.
    """
    pair = record.answer_for(unit, image)
    if pair is None:
        return None
    uid, gid = pair
    if uid and uid > 0 and gid is not None:
        return f"keep-id:uid={uid},gid={gid}"
    return None


def _unit_image(source: Source, container: str, context: Context) -> str:
    """The reference this unit names, resolved the way the probe resolves it:
    the declared `Image=`, or the reference this service's build tags when the
    unit declares none.

    The same two spellings `_installed_images` answers with, because the
    record's `owner_image` holds one of them and comparing a unit against any
    third spelling would read "not this image" for a unit the record does
    answer.
    """
    declared = source.units[container].one("Container", "Image")
    if declared and declared.strip():
        return declared.strip()
    return images.reference_for(context.service)


def refuse_pinned_user(unit: Unit, pinned: str, origin: str) -> None:
    """A source's own `User=` refused while a keep-id pin is in force
    (ADR-0019).

    The line maps exactly ONE uid — the probed pair — onto the service
    identity, and `User=` decides the uid the container actually runs as: any
    other uid runs where the line maps nothing, so its writes land in the
    service's subuid band (ticket 277), with nothing about the run saying the
    line named a uid the container never ran as. That is the whole rationale,
    and it does not rest on who pid 1 is, which is measured two ways and
    differs by spelling: an image that names a `USER` runs it (t352 asserts
    `USER root` under a pin has pid 1 = 0) and an image with no `USER` line
    runs the pinned pair (t351 asserts 2000). What never differs is where
    each uid LANDS, and two owners of one container's user is one too many —
    the repository is not one of them. Refused only when a pin is being
    rendered: with no pin,
    `User=` is the repository's own field and passes through as it always has,
    which is what keeps this off every deployment that has no non-root image
    user to map. Called from the render and from the start path, so the
    sentence the diagnostic speaks is one sentence.
    """
    value = unit.one("Container", "User")
    if value:
        raise errors.GuardenError(
            f"{origin} sets User={value!r}, and a service whose image user is pinned by "
            f"guarden's {pinned} line does not get a User= of its own",
            errors.REJECTED_INPUT,
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

    def provider(self, logical: str) -> str:
        """The concrete service `logical` names on this host and track.

        The renderer's half of the one consult point: the mutator resolved the
        same name when it wrote the edge's registry key, so `edge_publications`
        below looks the key up by the answer this returns. Reading the override
        file here is what makes a pin effective on the very next render, which
        is the property the file exists for — a pin an operator has to re-ingest
        to apply is not a pin.
        """
        return edgeresolve.resolve(self.config, self.track.name, logical)

    def instance_ref(self) -> str:
        """This render's instance, as the ref the operator typed.

        `--instance` carries the **escaped** key (spec 5.2: a verb takes the ref
        raw and the escaping is internal), and the slice's `ref` is what
        `roots.render_tunnel` escapes again on the way into cloudflared's
        `ingress.path` — the escaped key here would be escaped twice and match
        no request.
        """
        if not self.instance:
            return ""
        instance = self.record.instances.get(self.instance)
        return instance.ref if instance is not None else ""

    def unit_dir(self) -> Path:
        home = paths.service_home(self.service)
        if self.instance:
            home = paths.instance_home(self.service, self.instance)
        return home / paths.QUADLET

    def volume_path(self, kind: str, volume: str) -> Path:
        return paths.volume(self.service, kind, volume, self.instance)

    def volume_root(self) -> Path:
        """The tree `volume_root()` paths live under, for this unit.

        An instance's own tree when there is one, else the service's: an instance's
        tree is a SIBLING of the service's volumes rather than a child, so the
        service tree alone would not cover a preview.
        """
        return paths.volume_root(self.service, self.instance)


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

    # Checked once the whole container set is known and before the converter is
    # driven: a sibling name is a fact about two services in this file, and the
    # refusal belongs on the repository's own declaration (spec 7.3, ticket 285).
    compose.check_siblings(declared, path)

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
    # Checked once the whole set is known and before anything is written: spec
    # 7.3 states the refusal for a unit source and names no vocabulary, so a
    # hand-written unit reaches the check a Compose file reaches (ticket 299 —
    # it was wired into `_compose_source` only, and a `.guarden/quadlet/` source
    # rendered names that resolve to nothing).
    compose.check_siblings(
        {name: _unit_body(unit) for name, unit in units.items()}, directory
    )
    return Source(kind="quadlet", origin=directory, units=units, mounts=mounts)


def _unit_body(unit: Unit, domain: str = "") -> dict:
    """The unit's host-naming values in the vocabulary `check_siblings` reads.

    The refusal is one rule and must have one reader: spec 7.3 names the
    container, the sibling, the key and the value for "a unit source", and the
    keys a hand-written unit writes those facts in are `Environment=`, `Exec=`,
    `HealthCmd=` and `AddHost=` where a Compose file writes `environment`,
    `command`, `healthcheck` and `extra_hosts`. The values are mapped here
    rather than the check growing a second reader that could disagree with the
    first about what counts as dialling a host.

    `domain` is the render's own `${domain}` substitution (spec 4), and the
    values are substituted here before they are mapped: a value is not final
    until the marker is replaced, and the rule has to read what the unit will
    carry — `Environment=APP_HOST=${domain}` beside a `domain.container`
    renders `APP_HOST=<domain>`, the same dead dial as the literal form.
    `_quadlet_source` maps with the default (no domain) because the literal
    forms are refused there, before the host is asked anything; `build` passes
    the domain once the host has answered.
    """
    environment: dict[str, str] = {}
    for line in unit.get("Container", "Environment"):
        # systemd splits a value on whitespace, so one line carries several
        # assignments, and a quoted stretch is ONE string holding whatever it
        # holds: `Environment="A=1 B=2"` is the single variable `A` with the
        # value `1 B=2`, and `B` does not exist (systemd.syntax). Splitting on
        # whitespace and unquoting each token is what read the quoted form as
        # two assignments and refused files on dials systemd would never make.
        for assignment in _assignments(_substitute(line, domain)):
            key, separator, value = assignment.partition("=")
            if separator:
                environment[key] = value
    body: dict = {"environment": environment}
    command = unit.one("Container", "Exec")
    if command is not None:
        body["command"] = _substitute(command, domain)
    health = unit.one("Container", "HealthCmd")
    if health is not None:
        body["healthcheck"] = {"test": _substitute(health, domain)}
    hosts = [_substitute(host, domain) for host in unit.get("Container", "AddHost")]
    if hosts:
        body["extra_hosts"] = hosts
    return body


def _assignments(line: str) -> list[str]:
    """One `Environment=` value as systemd reads it: whitespace separates the
    assignments and a double-quoted stretch is ONE of them, quotes dropped
    because the check reads the values the container will see.

    Only double quotes group, because that is all systemd.syntax gives one —
    an apostrophe is a character like any other, which is why `shlex` is not
    the reader here (it would refuse `Environment=WHO=alice's` outright).
    """
    out: list[str] = []
    token = ""
    quoted = False
    for char in line:
        if char == '"':
            quoted = not quoted
            continue
        if char.isspace() and not quoted:
            if token:
                out.append(token)
                token = ""
            continue
        token += char
    if token:
        out.append(token)
    return out


def _mounts_of_unit(unit: Unit) -> list[Mount]:
    out: list[Mount] = []
    for key in ("Volume", "Mount"):
        for value in unit.get("Container", key):
            out.append(_quadlet_mount(value, unit))
    return out


def _quadlet_mount(value: str, unit: Unit) -> Mount:
    if "=" in value and ":" not in value:
        return _quadlet_long_mount(value, unit)
    parts = value.split(":")
    if len(parts) == 1:
        raise errors.GuardenError(
            f"the unit source {unit.path}: a mount of {value!r} has no source, so it names "
            f"no volume and no host path"
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


def _quadlet_long_mount(value: str, unit: Unit) -> Mount:
    """`Mount=type=bind,source=<path>,destination=<path>[,opt...]`.

    Quadlet's long form, and the only one that can express a bind with mount
    options. The keys are read rather than the string being split on `:`, because
    there are no colons in it and a source path is the `source=` value verbatim.
    """
    fields: dict[str, str] = {}
    for part in value.split(","):
        key, _, item = part.partition("=")
        fields[key.strip().lower()] = item.strip()
    source = fields.get("source", "")
    if not source:
        raise errors.GuardenError(
            f"the unit source {unit.path}: Mount={value!r} has no source=, so it names no "
            f"volume and no host path"
        )
    if source.endswith(".volume") or source.endswith(".image") or source.endswith(".network"):
        raise errors.GuardenError(
            f"the unit source {unit.path}: Mount={value!r} names {source!r}, and quadlet "
            f"resolves that suffix to a podman object rather than a host path; a guarden "
            f"volume is a btrfs subvolume and is mounted by its own path"
        )
    if source.startswith(("./", "../", "~")):
        raise errors.GuardenError(
            f"the unit source {unit.path}: Mount={value!r} names the relative host path "
            f"{source!r}, and a relative path resolves against whatever directory podman is "
            f"started in; use a declared volume, an absolute path under the service's own "
            f"volumes, or one the admin allowed in [mounts] allow"
        )
    kind = "bind" if source.startswith("/") else "volume"
    mode = fields.get("options", "")
    return Mount(kind=kind, source=source, target=fields.get("destination", ""), mode=mode)


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
        # `REFUSED_DIRECTIVES` stays the list it is, and `UserNS` is checked
        # beside it because that is quadlet's own spelling of the directive
        # (podman-systemd.unit(5)) — a source writing it would otherwise pass
        # the refusal and reach the generated unit, where the invariant is
        # that only guarden's renderer emits a line at all (ADR-0019).
        for key in (*REFUSED_DIRECTIVES, "UserNS"):
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


def check_exec(unit: unitsource.Unit, origin: str) -> None:
    """Refuse a `.container` that sets `Exec=` more than once.

    **Quadlet keeps only the last `Exec=` line.** The accumulating form has never
    been implemented upstream — podman#24901 is an open feature request for it —
    so several lines collapse to one in silence: the container starts on fewer
    arguments than the source asked for and looks misconfigured.

    **One line carrying a space-separated list is the supported form, and this
    does not refuse it.** The generator splits an unquoted value on whitespace and
    the process receives one argv token per argument; measured by running the
    generator by hand on both shapes. An earlier version of this check refused that
    shape too, from a reading of `\\x20` that mistook systemd's *quoting* marker for
    an inability to split, and it would have refused every working unit here.

    What the emitter must not do is quote the value: `format_line` emits `Exec=`
    unquoted for this reason, because a quoted list arrives as ONE token that the
    process discards whole.
    """
    values = unit.get("Container", "Exec")
    if len(values) > 1:
        raise errors.GuardenError(
            f"{origin} sets `Exec=` {len(values)} times, and quadlet keeps only the "
            f"last one (podman#24901): the container would run on fewer arguments "
            f"than this file asks for, without a word. Put the arguments on one "
            f"line, space-separated."
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
        roots = [ALLOWED_ROOT, *allowed]
        if context is not None:
            roots.append(str(context.volume_root()))
        if any(_under(mount.source, root) for root in roots if root):
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
        concrete = context.provider(edge.service)
        if concrete == context.service:
            raise errors.GuardenError(
                f"the manifest {document.source} needs {edge.service!r}, which is the service "
                f"that declared it: a self-edge has no consumer and is nearly always a "
                f"copy-paste"
            )
        provider = registry.load(concrete)
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
                f"{concrete} offers {', '.join(provider.provides) or 'nothing'}: the "
                f"consumer wants the kind {edge.prefix!r} and the provider does not list it",
                errors.HOST_NOT_AS_ASSUMED,
            )


def edge_publications(
    document: manifest_mod.Manifest, context: Context
) -> list[tuple[str, str, int]]:
    """`<AS>_PORT` for every edge, from the consumer's own registry.

    A publication is an allocation, so it is in the registry and not in either
    manifest: the consumer's tree is the only one `loom` can read, and the
    mutator records the edge's publications when it installs the edge. An edge
    with no allocated publication is exit `1` — the host has not been asked yet —
    rather than a loopback port the renderer invented.

    Each row is `(logical, concrete, port)`: the logical name the manifest wrote,
    the concrete provider name the host resolved it to, and the publication. The
    caller uses the concrete name for `AddHost=` and the environment file's
    `_HOST`, and the logical name to match the row back to its `needs:` entry.

    **The lookup falls back to the old two-part key.** A registry written by an
    earlier guarden carries only `provider:port`, and the three-part key
    `provider:port:as` was introduced to disambiguate two edges on one provider
    and port. The old key is still read so that an upgrade does not break existing
    edges — the `as:` prefix is unique per manifest, so the three-part key
    cannot collide with the old one.

    **And a pin written after the install does not orphan the allocation.** The
    record's key names the provider **the mutator resolved when it wrote it**
    (`edges.install` keys it by `resolve_name`), while this lookup resolves
    again — so `[edge_overrides]` moving the resolution leaves the only
    allocation the box has under the old name, and reading only today's key
    would answer "never installed" for an edge that was. `_recorded` reads the
    resolved keys first and then any entry carrying this edge's `port` and
    `as`, which is this `needs:` entry's record under whatever provider name it
    was written and nothing else's. What it never does is invent a port: a
    record with no allocation is still exit `1`.
    """
    out: list[tuple[str, str, int]] = []
    for edge in document.needs:
        concrete = context.provider(edge.service)
        stored = _recorded(context.record, concrete, edge)
        numbers = [
            value for value in (stored.get("publications") or [])
            if isinstance(value, int) and not isinstance(value, bool)
        ]
        if not numbers:
            raise errors.GuardenError(
                f"{context.service} needs {edge.service!r} on port {edge.port} and its "
                f"registry entry names no allocated publication for that edge; the mutator "
                f"allocates one when it installs the edge, and the renderer does not guess "
                f"a loopback port",
                errors.HOST_NOT_AS_ASSUMED,
            )
        out.append((edge.service, concrete, min(numbers)))
    return out


def _recorded(record, concrete: str, edge) -> dict:
    """The registry entry the mutator wrote for this `needs:` entry.

    The resolved name's own keys come first — the three-part key, then the old
    two-part one — so a record written under today's resolution is what answers,
    and only an edge whose resolution has moved since the install falls through
    to the entries keyed by another provider name.
    """
    keys = [
        edges.edge_key(concrete, edge.port, edge.prefix),
        edges.edge_key(concrete, edge.port, ""),
    ]
    keys += [
        key
        for key in sorted(record.edges)
        if key not in keys and _is_this_edge(record.edges.get(key), edge)
    ]
    for key in keys:
        stored = record.edges.get(key) or {}
        if stored.get("publications"):
            return stored
    return record.edges.get(keys[0]) or {}


def _is_this_edge(stored, edge) -> bool:
    """Whether a registry entry is this `needs:` entry under some provider name.

    `as:` is unique per manifest and the port is the one the entry declares, so
    the pair names one `needs:` entry and no other.
    """
    return (
        isinstance(stored, dict)
        and stored.get("port") == edge.port
        and stored.get("as") == edge.prefix
    )


def check_ingress(document: manifest_mod.Manifest, context: Context) -> str:
    """The alias, and only where it is needed.

    `AddHost=<name>:<alias>` is the whole of the name resolution there is, so a
    service that needs a name and an empty `ingress.alias` would render host
    entries that resolve to nothing. Empty is what the key is until `soil
    install` derives it from the pinned `-g`, so this is exit `1` — the host is
    not in the state the render assumed. A service that needs no name is not
    refused for a missing alias.
    """
    if not document.needs and not routed_names(context.service):
        return context.config.alias
    if not context.config.alias:
        raise errors.GuardenError(
            f"{context.config.path}: ingress.alias is empty and {context.service} renders host "
            f"entries, so every rendered AddHost= would resolve to nothing; `soil install` "
            f"derives the alias from the pinned -g and writes it there (ADR-0018)",
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


def check_publish_ports(unit: unitsource.Unit) -> None:
    """Refuse a `PublishPort` list that names one host port twice.

    A publication names a **host-side** socket. `pasta` has one listener per
    protocol, `--tcp-ports` and `--udp-ports`, so the same host port on both
    protocols is a **valid** request -- verified, with the edge's own list of four
    publishes including `443` and `443/udp` on one host port, which starts and
    serves. What pasta cannot do is bind the *same* host port twice *on one
    protocol*, and that is what this refuses.

    **Measured, after I got it wrong.** I first believed a host port could not be
    published for both protocols, from `Listen failed for HOST TCP port
    127.0.0.1/20002: Address already in use`. That error was from a *reproduction*
    in which the second publish had lost its `/udp` suffix, not from guarden's
    output. Keying this on (host, protocol) rather than on host alone is the whole
    difference between refusing a working configuration and catching a real one.
    """
    seen: dict[str, str] = {}
    for line in unit.get("Container", "PublishPort"):
        parts = line.split(":")
        if len(parts) < 3:
            continue
        host = ":".join(parts[:2])
        protocol = "udp" if parts[-1].endswith("/udp") else "tcp"
        previous = seen.get(f"{host}/{protocol}")
        if previous is not None:
            raise errors.GuardenError(
                f"{host} is published twice over {protocol} ({previous} and "
                f"{line}), and pasta binds one listener per protocol per port: "
                f"the container would not start. Publishing one host port on both "
                f"tcp and udp is fine; publishing it twice on one protocol is not.",
                errors.REJECTED_INPUT,
            )
        seen[f"{host}/{protocol}"] = line


def build(
    directory: Path, document: manifest_mod.Manifest, source: Source, context: Context | None
) -> Plan:
    """The whole render, in memory."""
    plan = Plan(warnings=list(source.warnings))
    refuse_directives(source)
    check_containers(document, source)
    for container, unit in source.units.items():
        check_exec(unit, f"{source.origin}: {container}")
    mounts = check_volumes(document, source)
    check_mount_paths(mounts, source, context)

    edge_ports: list[tuple[str, str, int]] = []
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
    if context is not None:
        # The same rule, once more, on the values the render will actually
        # write: `${domain}` is still literal when `_quadlet_source` and
        # `_compose_source` refuse the literal forms, so
        # `Environment=APP_HOST=${domain}` beside a `domain.container` rendered
        # APP_HOST=<domain> — the same dead dial — and was refused by nothing
        # (review finding 4). `check` reads no host (loom, spec 6.3) and cannot
        # know the domain; `render` can, and refuses. One reader of the rule —
        # `compose.check_siblings` — on the same vocabulary, once more.
        compose.check_siblings(
            {name: _unit_body(unit, domain) for name, unit in source.units.items()},
            source.origin,
        )

    for container in source.containers():
        owner = _owner_of(context, source, container)
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
                owner=owner,
            ),
        )
        plan.add(
            f"units/{container}.container.d/{ORDER_DROPIN}",
            render_template("quadlet-order-dropin.j2", service=context.service if context else ""),
        )
        if owner is not None:
            plan.add(
                f"admin/{container}.container.d/{paths.KEEPID_DROPIN}",
                render_template(
                    "quadlet-keepid-dropin.j2",
                    service=context.service if context else "",
                    owner=owner,
                ),
            )

    if edge_ports:
        plan.add(f"units/{ENV_FILE}", _environment_file(document, edge_ports))
    plan.add(f"system/{ORDER_TARGET}", _order_target(document, context))
    plan.add("shared/routes.toml", _routes(document, context, ports))
    plan.add("shared/schema.toml", _schema_slice(schema, context))
    plan.add("shared/widgets.toml", _widget_slice(document, source, context))
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

    **Guarden's own file is NOT merged, and the base unit carries no
    `UserNS=` line** (ADR-0019). Merging it would put the pin into the base
    unit, and the base unit would then carry the line twice over — once from
    the admin merge and once from the drop-in the generator reads — which is
    the two-writers-one-key shape the whole drop-in model exists to avoid.
    The pin's own file is written by the mutator, into the same directory, and
    read by the generator; the renderer's business with it ends here, where it
    is named and skipped.

    The skip is by NAME and not by content: the file is identified by the name
    the mutator writes it under, so a hand-written drop-in that happens to
    carry a `UserNS=` line is refused by the base unit's own filter instead
    (the `UserNS` entry in `OWNED_KEYS`).
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
            if path.name == paths.KEEPID_DROPIN:
                continue
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
    DNAT onto one of these, written by the mutator into `50-services.conf` — so
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


def _owner_of(context: Context | None, source: Source, container: str) -> str | None:
    """The keep-id line THIS unit's own image answers, or `None` (ADR-0019).

    One reader for the answer, because the base unit's refusal and the
    drop-in's content are the same question: the pair the registry holds for
    this unit and for the image this unit names. The base unit carries no
    line (the pin is a drop-in of its own), but the refusal of a source's own
    `User=` still stands — a `User=` that is not the pinned pair runs where
    the line maps nothing — so the answer is asked here, once, and the
    refusal rides on it.

    `None` is the whole of the other cases: no record to answer from, a
    record that answers another image, and a pair probed to `0` (an image
    that declares no user, whose container root the default map already
    moves onto the service identity). No line in any of them.
    """
    if context is None:
        return None
    owner = owner_line(context.record, container, _unit_image(source, container, context))
    if owner is None:
        return None
    refuse_pinned_user(
        source.units[container],
        owner,
        f"the unit source {source.origin}: the container {container!r}",
    )
    return owner


def _container_unit(
    document: manifest_mod.Manifest,
    source: Source,
    container: str,
    context: Context | None,
    merged: Unit | None,
    ports: dict[str, tuple[int, int]],
    edge_ports: list[tuple[str, str, int]],
    routed: list[str],
    schema: secretschema.Schema,
    domain: str,
    owner: str | None = None,
) -> str:
    """One container unit: the source's own fields, then every field guarden owns.

    The order inside `[Container]` is the source's order, then guarden's own keys
    in a fixed order, so a regenerated unit differs from the last one only where
    something actually changed.

    **The unit carries no `UserNS=` line** (ADR-0019): the keep-id pin is a
    drop-in of guarden's own in the admin path, and `owner` — the answer for
    this unit — is written there instead. A unit that carried the line as
    well would have two writers for one key.
    """
    unit = merged if merged is not None else _merged(source.units[container])
    service = context.service if context else ""
    for key in OWNED_KEYS:
        unit.drop("Container", key)

    unit_keys = _lines(unit, "Unit", domain, drop=("Description",))
    description = source.units[container].one("Unit", "Description")
    unit_keys.insert(0, f"Description={description or f'{service} {container}'.strip()}")
    # The unit runs in the service's OWN home. Without this podman inherits root's
    # as its working directory and refuses to start with "cannot chdir to /root:
    # Permission denied", exit 125 — a unit that is installed correctly and cannot
    # run. HOME goes with it for the same reason: podman resolves its rootless
    # storage from it.
    unit_keys.insert(0, f"WorkingDirectory={paths.service_home(service)}")
    unit_keys.insert(1, f"Environment=HOME={paths.service_home(service)}")

    # The repository's own fields first, in the order the source wrote them, and
    # then the fields guarden owns in a fixed order — so a regenerated unit
    # differs from the last one only where something actually changed.
    container_keys = _lines(unit, "Container", domain)

    if not unit.one("Container", "ContainerName"):
        unit.put("Container", "ContainerName", [f"{service}-{container}".lstrip("-")])
    if context is not None and context.instance:
        # One instance, one container name: the computed
        # `<service>-<container>` (and a repository-declared ContainerName
        # alike) is the same for every instance of the service, so the second
        # `podman run` is refused with the name already in use — two previews
        # of one service could never run at once (spec 5.2). The suffix is the
        # instance's registry key in hex: podman's container-name grammar takes
        # `[A-Za-z0-9][A-Za-z0-9_.-]*` only, where systemd's `\xNN` key carries
        # a backslash podman refuses and no dashed encoding is unambiguous at
        # the component boundary, while hex of the key is injective and always
        # valid (spec 5.2).
        named = unit.one("Container", "ContainerName")
        unit.put(
            "Container",
            "ContainerName",
            [f"{named}-{context.instance.encode().hex()}"],
        )
    if context is not None:
        unit.put("Container", "Network", [context.config.network])
        # Every name this unit may have to resolve: the providers it declared an
        # edge to, and — for the edge itself — every routed service, because a
        # route target is `<service>:<publication>` and the edge has no other
        # way to turn that name into an address.
        hosts = [concrete for _, concrete, _ in sorted(edge_ports)]
        hosts.extend(name for name in routed if name not in hosts)
        if hosts:
            unit.put(
                "Container",
                "AddHost",
                [f"{name}:{context.config.alias}" for name in hosts],
            )
        if edge_ports:
            # **The value is escaped, and the path on disk is not.** Quadlet
            # reads `EnvironmentFile=` by C-unescaping its value, and the
            # instance's directory is named by the escaped ref — `feature/x` is
            # `feature\x2fx` — so an unescaped value names a path that does not
            # exist and podman refuses the container with
            # `parsing file "...": no such file or directory` (ticket 315).
            # `unitsource.escape_path` is the rule, and its docstring carries
            # the measurement: the value has to survive quadlet's unescape
            # AND systemd's, so it carries a doubled backslash and the
            # directory on disk keeps its one.
            unit.put(
                "Container",
                "EnvironmentFile",
                [unitsource.escape_path(str(context.unit_dir() / ENV_FILE))],
            )
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
    check_publish_ports(unit)
    requests = _secret_requests(document, schema)
    if requests:
        unit.put("Container", "Secret", requests)
    # ADR-0019: the keep-id line is NOT written here. The pin is a drop-in of
    # guarden's own in the admin path (`50-guarden-keepid.conf`), written from
    # the registry's probed owner and from nothing a repository can reach; the
    # base unit carries no `UserNS=` line at all, so a regeneration of the
    # unit cannot disturb the pin and an admin's own `90-admin.conf` can
    # override it. `owner` was asked once, in `_owner_of`, and it is the
    # drop-in's content there.
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
    """A declared volume becomes the subvolume's own path; an admin-allowed host
    path is passed through as it was written.

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
            # `Volume=<subvolume>:<target>` — a bind mount of the path the mutator
            # made. Create-before-install already orders it: the subvolume exists
            # before the unit is installed, so no `.volume` unit is needed and the
            # dependency edge it would have provided is already held.
            if context is not None:
                path = context.volume_path(declared[mount.source], mount.source)
            else:
                path = ABSENT / declared[mount.source] / mount.source
            out.append(f"{path}:{mount.target}{mode}")
    return out


def _secret_requests(
    document: manifest_mod.Manifest, schema: secretschema.Schema
) -> list[str]:
    """A credential *request* and never a value (spec 6.3).

    `Secret=<KEY>,type=mount` in `[Container]` and nothing else: podman resolves
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
        f"{edges.credential_key(edge.auth, edge)},type={secretschema.TYPE_MOUNT}"
        for edge in document.needs
        if edge.auth in (edges.AUTH_DATABASE, edges.AUTH_SECRET)
    )
    ordered: list[str] = []
    for line in out:
        if line not in ordered:
            ordered.append(line)
    return ordered


def _environment_file(
    document: manifest_mod.Manifest, edge_ports: list[tuple[str, str, int]]
) -> str:
    """`<AS>_HOST` and `<AS>_PORT` for every edge, or `<AS>_<DB>_HOST`,
    `<AS>_<DB>_PORT` and `<AS>_<DB>_USER` for each database of a
    multi-database edge.

    The host is the concrete provider service name the host resolved the
    logical name to, with no suffix and no alias, and there is no name map
    and no `/etc/hosts` (spec 7.3).

    For a multi-database edge the consumer also needs:
    - `<AS>_<DB>_USER`: the role name, `{concrete_provider}-{db_name}`
    - `<AS>_PASSWORD`: the edge's password, available as a Secret
    """
    rows = []
    for edge in document.needs:
        for logical, concrete, publication in edge_ports:
            if logical != edge.service:
                continue
            if edge.databases:
                for db_name in edge.databases:
                    user = f"{concrete}-{db_name}"
                    name = f"{edge.variable}_{db_name.upper()}"
                    rows.append((name, concrete, publication, user))
            else:
                rows.append((edge.variable, concrete, publication, None))
    return render_template("guarden.env.j2", rows=rows)


def _order_target(document: manifest_mod.Manifest, context: Context | None) -> str:
    """`<name>.target`: the real edges, in the *system* manager (spec 6.10).

    A unit in one service's user manager cannot require a unit in another's — two
    different dependency graphs — so the edges live here and the mutator installs
    the file. The edges are `Wants=`, not `Requires=`: a provider that is down
    does not stop its consumers, the consumer's first dial fails and it retries.
    """
    providers: list[str] = []
    if context is not None:
        for edge in document.needs:
            concrete = context.provider(edge.service)
            if concrete not in providers:
                providers.append(concrete)
    return render_template(
        "guarden-order.target.j2",
        service=context.service if context else "",
        providers=sorted(providers),
    )


def _routes(
    document: manifest_mod.Manifest, context: Context | None, ports: dict[str, tuple[int, int]]
) -> str:
    """The route slice `roots` reads. The target is `<name>:<publication>` — the
    service's own name, with no suffix and no alias — and the full host is the
    one the mutator allocated from the manifest's label and the track's prefix."""
    # Ticket 293: the slice carries what the **mutator recorded**, and only a
    # host the registry has never seen falls back to the resolver (ticket 294's
    # one function, which the mutator, this slice and the firewall all ask).
    # Rendering the default live would make it a per-render vote: installing
    # the cloudflared module would re-posture every running service on the next
    # render, which is the surprise ticket 293's grandfathering forbids. The
    # first answer stands until `weedr expose set` gives another, and
    # `soil firewall --check` reports a default that moved underneath a record.
    hosts = [route.host for route in document.routes]
    recorded = context.record.route_destinations if context else {}
    # The context-less path is `loom check`, which writes nothing; its fallback
    # is still the fail-closed one, because `edge` is the answer nothing may
    # default to (tickets 293/294).
    fallback = (
        exposure.resolve(context.record, context.track, context.config.modules)
        if context else exposure.LOOPBACK
    )
    dests = {host: recorded.get(host, fallback) for host in hosts}

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
            "destination": dests.get(route.host, exposure.EDGE),
            "ref": context.instance_ref() if context else "",
        }
        for route in document.routes
    ]
    return render_template(
        "shared-routes.toml.j2",
        service=context.service if context else "",
        project=context.record.project if context else "",
        track=context.track.name if context else "",
        # Ticket 292: the basic-auth policy the mutator recorded at creation
        # (registry `basicauth`), carried to `roots` in the slice so the
        # renderer — never the renderer re-reading a manifest — is what places
        # the middleware. Absent/false is a grandfathered service, and it
        # renders byte for byte what it rendered before.
        basicauth=bool(context.record.basicauth) if context else False,
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


def _widget_slice(
    document: manifest_mod.Manifest, source: Source, context: Context | None
) -> str:
    """The widget slice `twig` reads: which card is which container, and the
    container set the unit source defined.

    The files themselves are copied beside it unparsed; this is the only part
    `loom` generates, and it is generated because `twig` runs as `guarden` and
    cannot read the unit source to check an entry against.
    """
    seen: dict[str, str] = {}
    rows = []
    for widget in document.widgets:
        first = seen.get(widget.container)
        if first is not None:
            raise errors.GuardenError(
                f"the manifest {document.source}: the container {widget.container!r} has a "
                f"widget in {first!r} and another in {widget.file!r}, and one card is one "
                f"container"
            )
        seen[widget.container] = widget.file
        rows.append({"container": widget.container, "file": Path(widget.file).name})
    return render_template(
        "shared-widgets.toml.j2",
        service=context.service if context else "",
        containers=source.containers(),
        rows=rows,
    )


def _widget_file(directory: Path, relative: str) -> str:
    """Widget files are copied through **unparsed** (spec 6.5): dashboard UI
    configuration, and a renderer that parsed it would be a second thing to keep
    in step with the dashboard.

    **The read is contained, and the containment is asserted here rather than
    assumed.** `Path(directory) / relative` escapes the tree two ways — an
    absolute right operand discards the left one (`Path("/a") / "/etc/x"` is
    `/etc/x`), and a `..` component climbs out — and the file is read as the
    `guarden` account, which is in the `guarden` group and can read the host's
    configuration. So the resolved path is checked against the tree BEFORE the
    read.

    The manifest check (`manifest._check_widget_file`) refuses the same two
    shapes at parse time, and this is the belt: the renderer is the thing that
    opens the file, so the renderer is the thing that checks where the file is.
    A manifest that reaches the renderer by another road is still contained.
    """
    path = directory / relative
    try:
        resolved = path.resolve()
    except OSError as exc:  # pragma: no cover - a resolve that cannot answer
        raise errors.GuardenError(
            f"the manifest declares the widget file {relative}, and its path "
            f"could not be read: {exc}"
        ) from exc
    root = directory.resolve()
    if resolved != root and root not in resolved.parents:
        raise errors.GuardenError(
            f"the manifest declares the widget file {relative}, which is outside "
            f"the tree it belongs to"
        )
    try:
        return path.read_text(encoding="utf-8")
    except FileNotFoundError:
        raise errors.GuardenError(
            f"the manifest declares the widget file {relative}, and it does not exist"
        ) from None
    except PermissionError:
        # One line, not a traceback (spec 1.2): the file is inside the tree and
        # the `guarden` account cannot read it, and the answer names the file.
        raise errors.GuardenError(
            f"the manifest declares the widget file {relative}, and it cannot be read"
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
    # **`accept()` and not `read()`, because this is where the render is asked
    # whether a tree is renderable** — and the `db`-provider rule is about the
    # DECLARATION rather than about the document (spec 4). `accept()` applies
    # the rule for the trees that are declarations; for the staged copy of an
    # installed service's home — the same document under another name, staged
    # because the renderer cannot enter a `0700` home (ADR-0012) — the rule
    # does not fire, and the re-render of an installed service keeps working.
    return manifest_mod.accept(path)


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
        conf.write_file(out / relative, plan.files[relative], 0o640)
