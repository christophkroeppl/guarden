"""`compose.yaml`: the repository's declaration, and the converter that reads it.

**Two halves, and the split is the whole point of this module.**

The *declaration* is the repository's, so the refusal list (spec 6.3) is checked
on it in the vocabulary it was written in: a Compose file that asks for
`cap_add:` is a repository asking for a capability, and the answer is exit `2`
naming the key. The same key in a hand-written quadlet file has no spelling of
its own — it would arrive as a `PodmanArgs=` line, which is refused for the same
reason and named for what it is.

The *translation* is podlet's, and it is **untrusted input rather than a finished
unit** (spec 4). `loom` drives the pinned release, unprivileged, and then
overwrites or removes every field the design has an opinion about. The
`network_mode:` key is the one the spec says is replaced rather than refused —
"`network_mode: host` that survived rendering would give a repository the host's
whole network namespace" — so it is replaced with the `[network]` table's backend
and reported as a `warning:`. Replacing it is as safe as refusing it, and
refusing it would make a repository that asks for the host's network fail rather
than render without it.
"""

from __future__ import annotations

import os
import re
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from guarden import errors, paths

COMPOSE_REL = Path("compose.yaml")

# The pinned artefact's own name, resolved the way `soil packages` installs it.
#
# **Not a bare `podlet` from PATH.** Two reasons, and the second is the one that
# matters: the fetch is pinned and digest-verified, and a lookup that consulted
# PATH would run *any* executable called `podlet` a unprivileged repository could
# put on the renderer's PATH, which is exactly the "unverified third-party binary"
# the pin exists to prevent. `soil packages` installs it at
# `/usr/lib/guarden/bin/podlet`; this is that path, under `GUARDEN_PREFIX`.
PODLET = paths.BIN / "podlet"

# The record `soil packages` reads the release, the artefact and its SHA256 out of,
# plus the row for this host's architecture. Named here rather than typed into the
# diagnostic, so a message and the file agree.
PODLET_RECORD = paths.ETC_GUARDEN / "podlet.release"

# The pinned release's translation entry point, verbatim: the subcommand is
# `compose`, and the output directory is the **global** `--file` option, which
# has to precede the subcommand. `podlet quadlet --outdir <dir> <file>` was the
# shape the retired fake modelled and the shape no podlet release has ever had —
# every release answers `error: unrecognized subcommand 'quadlet'` — so a fill
# alone would not have made this work.
PODLET_ARGV = ("--file", "{outdir}", "compose")

# podlet renders its diagnostics through `color_eyre`, so its cause chain arrives
# with SGR escapes on it. Stripping them is what makes `_detail` able to collapse
# the chain into the one line spec 1.2 asks for.
ANSI = re.compile(r"\x1b\[[0-9;]*m")

# The refusal list (spec 6.3), in the vocabulary a Compose file is written in. The
# value is the predicate, because `privileged: false` and `pid: something-else`
# are not the thing being refused.
REFUSED_COMPOSE_KEYS: dict[str, str] = {
    "cap_add": "any value",
    "cap_drop": "any value",
    "devices": "any value",
    "userns_mode": "any value",
    "privileged": "true",
    "pid": "host",
    "podman_args": "any value",
}

# Host memory knobs, refused in the Compose vocabulary for the reason the same
# thing is refused in the manifest's: a zram device or a swappiness value is
# host configuration, it is in the root-owned `/etc/guarden/guarden.toml`, and
# `sysctls:` here would be a repository stating a value the host owns. Refused
# by name rather than left to the closed key set's "unknown key", because a
# developer who reaches for this wants to be told who owns it.
REFUSED_COMPOSE_HOST: dict[str, str] = {
    "zram": "a zram device is host configuration, in the root-owned "
            "/etc/guarden/guarden.toml, and it is the operator's",
    "swap": "a swap device is host configuration, and it is the operator's",
    "sysctls": "vm.swappiness and the rest of the host's kernel knobs are converged by "
               "`soil sysctl` from the root-owned guarden.toml",
}


@dataclass(frozen=True)
class Mount:
    """One `volumes:` entry, resolved as far as the renderer needs it."""

    kind: str  # "volume" (a named volume) or "bind" (a host path)
    source: str
    target: str
    mode: str = ""

    @property
    def is_path(self) -> bool:
        return self.kind == "bind"


@dataclass
class Translation:
    """What the converter produced: a container and the unit's text.

    The text is read **inside** the converter's scratch directory rather than a
    path to it, because the directory is a temporary one and a path into it is
    gone before the caller could open it.
    """

    container: str
    text: str


def yaml_module():
    try:
        import yaml
    except ImportError:  # pragma: no cover - the same diagnostic as the manifest's
        raise errors.GuardenError(
            "python3-yaml is not importable; it is the distribution's package, "
            "installed by `soil packages`",
            errors.HOST_NOT_AS_ASSUMED,
        ) from None
    return yaml


def document(path: Path) -> dict[str, Any]:
    """`safe_load` only. A repository is a stranger's document (spec 4)."""
    yaml = yaml_module()
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        raise errors.GuardenError(f"the unit source {path} does not exist") from None
    except (OSError, UnicodeDecodeError) as exc:
        raise errors.GuardenError(
            f"the unit source {path} could not be read: {getattr(exc, 'strerror', exc)}"
        ) from exc
    try:
        loaded = yaml.safe_load(text)
    except yaml.YAMLError as exc:
        raise errors.GuardenError(
            f"the unit source {path} is not valid YAML: {errors.oneline(str(exc))}"
        ) from exc
    if loaded is None:
        loaded = {}
    if not isinstance(loaded, dict):
        raise errors.GuardenError(f"the unit source {path} is not a mapping")
    return loaded


def services(doc: dict[str, Any], path: Path) -> dict[str, dict]:
    """The `services:` table, which is the container set (spec 6.3)."""
    table = doc.get("services")
    if table is None:
        raise errors.GuardenError(f"the unit source {path} has no `services:` mapping")
    if not isinstance(table, dict) or not table:
        raise errors.GuardenError(f"the unit source {path}: `services:` is empty or not a mapping")
    out: dict[str, dict] = {}
    for name, body in table.items():
        if not isinstance(name, str) or not name.strip():
            raise errors.GuardenError(f"the unit source {path}: a service name is empty")
        if body is None:
            body = {}
        if not isinstance(body, dict):
            raise errors.GuardenError(
                f"the unit source {path}: the service {name!r} is not a mapping"
            )
        out[name] = body
    return out


def refuse(body: dict[str, Any], container: str, path: Path) -> None:
    """The refusal list, checked on the repository's own declaration.

    One diagnostic, one line, naming the container and the key: the two facts
    somebody needs to fix it, and nothing else.
    """
    for key, wanted in REFUSED_COMPOSE_KEYS.items():
        if key not in body:
            continue
        value = body[key]
        if key == "privileged" and value is not True:
            continue
        if key == "pid" and str(value) != "host":
            continue
        raise errors.GuardenError(
            f"the unit source {path}: the service {container!r} asks for {key}: "
            f"{_shown(value)}, and a guarden service does not get {key} ({wanted}); "
            f"the isolation boundary is the service's own uid and the 0700 on its tree"
        )
    for key, why in REFUSED_COMPOSE_HOST.items():
        if key in body:
            raise errors.GuardenError(
                f"the unit source {path}: the service {container!r} asks for {key}: "
                f"{_shown(body[key])}, and {why}"
            )
    _refuse_templated_ports(body, container, path)


def _refuse_templated_ports(body: dict[str, Any], container: str, path: Path) -> None:
    """A `ports:` entry carrying a `$`, in either interpolation form, refused
    before the converter sees it.

    The converter parses the host-IP field before any substitution, so
    `127.0.0.1:${PORT:-19069}:8069` dies in *its* parser with "invalid IP address
    syntax" — a message about an IP address that is written correctly — and the
    reader is sent to the wrong line. The bare form is the same rule and was not
    covered: `127.0.0.1:$PORT:8069` reached the converter and died in it with
    "error parsing `$PORT` as an integer: invalid digit found in string"
    (measured, t431). So the rule is one line and holds for the whole dollar: a
    port entry carries no `$`, neither `${NAME}` nor `$NAME` nor the `$$` escape
    that becomes a literal one, because every one of them lands in a field that
    has to be a number. Guarden answers instead, naming the construct, and it
    does so before the converter runs: a guarden host allocates the loopback
    publication itself from the manifest's ingress, so a repository's published
    port is not the thing that decides where a service is reached.
    """
    entries = body.get("ports") or []
    if not isinstance(entries, list):
        raise errors.GuardenError(
            f"the unit source {path}: the service {container!r} has a `ports:` that is not a list"
        )
    for entry in entries:
        if isinstance(entry, dict):
            shown = ", ".join(f"{key}={value}" for key, value in entry.items())
        else:
            shown = str(entry)
        if "$" in shown:
            # The message names every form and the whole entry, because the
            # test above IS the whole entry — all keys of a long-syntax dict —
            # and the rule refuses the `$$` escape too: a repository that
            # wrote `$$` was told about two forms it did not use, and one
            # that templated `published:` was told about the host-IP (review
            # finding 5).
            raise errors.GuardenError(
                f"the unit source {path}: the service {container!r} has a ports entry "
                f"{shown!r} carrying a $: no field of a ports entry may be templated — "
                f"not ${{NAME}}, not $NAME, and not the $$ escape that becomes a "
                f"literal one — because guarden allocates the loopback publication "
                f"from the manifest's ingress"
            )


def check_siblings(declared: dict[str, dict], path: Path) -> None:
    """A sibling container named as a host, refused with `needs:` (spec 7.3).

    **Decision, ticket 285: intra-compose connectivity is out of scope by
    design, and this is the refusal that makes it visible.** The whole of name
    resolution the renderer writes is `AddHost=<service>:<ingress.alias>` for a
    declared edge — a *service* name, with no suffix and no alias — and there is
    no name map to put a container in (spec 7.3). Two containers of one Compose
    file are siblings rather than provider and consumer, so a value naming one as
    a host renders units in which the name resolves to nothing: the file
    converts, the units render, and nothing says so until something dials.

    **A rendered entry would not connect either.** From inside a container the
    alias is the host's loopback, where each container answers on its
    *publication* — an allocation from `ingress.publication_range` — and never on
    the container port the value dials (spec 7.4), so `http://api:3000` would
    reach a port nothing binds. Making that work needs a port-translating name
    map, which is the mechanism this design does not have.

    The answer is the vocabulary the manifest already carries: the target becomes
    a service of its own and `needs:` names it. Refused here, on the repository's
    own declaration and in the vocabulary it was written in, before the converter
    runs — one line naming the container, the sibling, where the value was
    written and the value.
    """
    for container in sorted(declared):
        values = _host_values(declared[container])
        for sibling in sorted(declared):
            if sibling == container:
                continue
            for where, text, bare in values:
                if _dials(text, sibling, bare):
                    raise errors.GuardenError(
                        f"the unit source {path}: the service {container!r} names its "
                        f"sibling container {sibling!r} as a host in {where} "
                        f"({text!r}), and a name inside one unit source resolves to "
                        f"nothing: the renderer writes AddHost= only for a declared "
                        f"edge and it carries a service name (spec 7.3), so split "
                        f"{sibling!r} into a service of its own and name it under "
                        f"`needs:` in the manifest, or give this value an address "
                        f"that exists"
                    )


def _host_values(body: dict[str, Any]) -> list[tuple[str, str, bool]]:
    """Every value in which this service could name a host, as
    `(where, text, bare)`.

    `where` is what the diagnostic names — the key the value was written under —
    and `bare` is whether a text that *is* a sibling's name, with no port and no
    scheme, counts as a reference. It does for an environment value
    (`BITCOIN_HOST=bitcoind` is the shape a stack writes) and for an
    `extra_hosts` name, which is a hosts-file name by construction. It does not
    for a command argument, where an argument equal to a sibling's name
    (`command: [ "node", "worker.js" ]`) is this container's own program rather
    than something to dial.
    """
    out: list[tuple[str, str, bool]] = []
    environment = body.get("environment")
    if isinstance(environment, dict):
        for key, value in environment.items():
            out.append((f"environment {key}", _text_of(value), True))
    elif isinstance(environment, list):
        for entry in environment:
            if not isinstance(entry, str):
                continue
            key, separator, value = entry.partition("=")
            if separator:
                out.append((f"environment {key}", value, True))
    for key in ("command", "entrypoint"):
        for item in _arguments(body.get(key)):
            out.append((key, item, False))
    healthcheck = body.get("healthcheck")
    if isinstance(healthcheck, dict):
        for item in _arguments(healthcheck.get("test")):
            out.append(("healthcheck", item, False))
    extra = body.get("extra_hosts")
    if isinstance(extra, dict):
        for name in extra:
            out.append(("extra_hosts", _text_of(name), True))
    elif isinstance(extra, list):
        for entry in extra:
            out.append(("extra_hosts", _text_of(entry), True))
    return out


def _arguments(value: Any) -> list[str]:
    if isinstance(value, str):
        return [value]
    if isinstance(value, list):
        return [_text_of(item) for item in value]
    return []


def _text_of(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    return str(value)


def _dials(text: str, name: str, bare: bool) -> bool:
    """Whether `text` asks for `name` as a host.

    Three shapes and no substring search, because a check that fires on its own
    shadow refuses a file that never named anything: `<name>:<port>` anywhere a
    name may stand (the boundary excludes a longer name — `my-api:8080`,
    `notapi:8080`, `api.example.com:443` are other hosts), `<scheme>://<name>`
    up to the next delimiter of a hostname, and, where `bare` says so, the whole
    value being the name.
    """
    escaped = re.escape(name)
    if re.search(rf"(?<![\w.-]){escaped}:\d+", text):
        return True
    if re.search(rf"//{escaped}(?=[:/?#\s\"']|$)", text):
        return True
    return bare and text.strip() == name


def mounts(body: dict[str, Any], container: str, path: Path) -> list[Mount]:
    """`volumes:` entries, in either spelling.

    An entry with no source is refused rather than treated as anonymous: an
    anonymous volume lands in the service's rootless image store, where nothing
    snapshots it, nothing lists it, and removing the service discards it.
    """
    entries = body.get("volumes") or []
    if not isinstance(entries, list):
        raise errors.GuardenError(
            f"the unit source {path}: the service {container!r} has a `volumes:` that is "
            f"not a list"
        )
    out: list[Mount] = []
    for entry in entries:
        if isinstance(entry, str):
            out.append(_short_mount(entry, container, path))
        elif isinstance(entry, dict):
            out.append(_long_mount(entry, container, path))
        else:
            raise errors.GuardenError(
                f"the unit source {path}: the service {container!r} has a `volumes:` entry "
                f"that is neither a string nor a mapping: {entry!r}"
            )
    return out


def _short_mount(entry: str, container: str, path: Path) -> Mount:
    parts = entry.split(":")
    if len(parts) == 1:
        raise errors.GuardenError(
            f"the unit source {path}: the service {container!r} mounts {entry!r} with no "
            f"source, which is an anonymous volume in the service's image store; declare it "
            f"under `state:` or `bulk:` and name it"
        )
    if len(parts) == 2:
        source, target, mode = parts[0], parts[1], ""
    else:
        source, target, mode = parts[0], parts[1], parts[2]
    if not source or not target:
        raise errors.GuardenError(
            f"the unit source {path}: the service {container!r} mounts {entry!r}, which has "
            f"an empty source or an empty target"
        )
    return _mount(source, target, mode, container, path)


def _long_mount(entry: dict, container: str, path: Path) -> Mount:
    unknown = sorted(set(entry) - {"type", "source", "target", "read_only", "bind", "volume"})
    if unknown:
        raise errors.GuardenError(
            f"the unit source {path}: the service {container!r} has a `volumes:` entry with "
            f"an unknown key {unknown[0]!r}"
        )
    target = entry.get("target")
    if not isinstance(target, str) or not target:
        raise errors.GuardenError(
            f"the unit source {path}: the service {container!r} has a `volumes:` entry with "
            f"no target"
        )
    kind = entry.get("type") or ("bind" if "source" in entry else "volume")
    if kind == "tmpfs":
        raise errors.GuardenError(
            f"the unit source {path}: the service {container!r} mounts a tmpfs at {target}; "
            f"a volume is declared in the manifest or it is not a volume"
        )
    if kind not in ("bind", "volume"):
        raise errors.GuardenError(
            f"the unit source {path}: the service {container!r} mounts {target} with "
            f"type: {kind!r}, which is neither 'bind' nor 'volume'"
        )
    source = entry.get("source") or entry.get("volume")
    if not isinstance(source, str) or not source:
        raise errors.GuardenError(
            f"the unit source {path}: the service {container!r} mounts {target} with no "
            f"source, which is an anonymous volume in the service's image store; declare it "
            f"under `state:` or `bulk:` and name it"
        )
    mode = "ro" if entry.get("read_only") else ""
    return _mount(source, target, mode, container, path)


def _mount(source: str, target: str, mode: str, container: str, path: Path) -> Mount:
    # A relative source is a host path too, and a worse one: it is resolved
    # against whatever directory podman is started in, which is not something a
    # manifest gets to choose.
    kind = "bind" if source.startswith(("/", "./", "../", "~")) else "volume"
    if kind == "bind" and not source.startswith("/"):
        raise errors.GuardenError(
            f"the unit source {path}: the service {container!r} mounts {source!r} at "
            f"{target}, and a relative host path is not bindable by a guarden service; "
            f"use a named volume, an absolute path under the service's own volumes, or one "
            f"the admin allowed in [mounts] allow"
        )
    return Mount(kind=kind, source=source, target=target, mode=mode)


def _shown(value: Any) -> str:
    if isinstance(value, (list, tuple)):
        return ", ".join(str(item) for item in value)
    return str(value)


def convert(path: Path) -> list[Translation]:
    """Drive the pinned `podlet` and read back what it wrote.

    **The converter's output is untrusted input.** It is returned as a list of
    files rather than as finished units precisely so that every field the design
    has an opinion about is still to be overwritten by the caller.

    The call is `podlet --file <dir> compose <file>`, the pinned release's
    translation entry point, and it runs as the unprivileged renderer, which is
    what ADR-0012 is about: who runs the converter, not whether the renderer
    writes the unit itself. A temporary directory is the converter's scratch
    space and is removed as soon as the files are read; nothing rendered is left
    outside `--out`.

    **A host with no converter says so in one line.** The pin ships filled in, so
    this is the state of a host that has not run `soil packages --apply` yet rather
    than a state no host could leave — and it is a fact about the host rather than
    about the repository's document, so exit `1`: not a traceback and not a `2` that
    would read as "your manifest is wrong" (spec 1.2). The message names the
    artefact, the path, and the phase that installs it, because those are the three
    facts somebody needs and none of them is a stack frame.
    """
    if not _converter_installed():
        raise errors.GuardenError(
            f"the pinned podlet is not installed at {PODLET}, so {path} cannot be "
            f"translated; it is fetched, digest-verified and unpacked by "
            f"`soil packages --apply` from the release, url and SHA256 in {PODLET_RECORD}",
            errors.HOST_NOT_AS_ASSUMED,
        )
    with tempfile.TemporaryDirectory(prefix="loom-podlet.") as scratch:
        argv = [str(PODLET)]
        for token in PODLET_ARGV:
            argv.append(scratch if token == "{outdir}" else token)
        argv.append(str(path))
        try:
            result = subprocess.run(  # noqa: S603 - an argv, never a shell
                argv,
                capture_output=True,
                text=True,
                check=False,
            )
        except OSError as failure:
            # Executable bit set and still not runnable: a truncated fetch, an
            # archive installed as though it were a binary, a wrong
            # architecture. `OSError` from exec is the same class of fact as a
            # missing file — this host does not have a working pinned converter —
            # and it belongs in the same one-line diagnostic rather than in a
            # traceback, which is what a truncated `curl` leaves behind.
            raise errors.GuardenError(
                f"the pinned podlet at {PODLET} could not be run: "
                f"{getattr(failure, 'strerror', failure)}; it is not an executable "
                f"program, so `soil packages --apply` did not install the pinned "
                f"release ({PODLET_RECORD} is what it installs from)",
                errors.HOST_NOT_AS_ASSUMED,
            ) from None
        if result.returncode != 0:
            detail = _detail(result.stderr or result.stdout)
            raise errors.GuardenError(
                f"podlet exited {result.returncode} translating {path}"
                + (f": {detail}" if detail else ""),
                errors.HOST_NOT_AS_ASSUMED,
            )
        produced = sorted(Path(scratch).glob("*.container"))
        translations = [
            Translation(container=unit.stem, text=unit.read_text(encoding="utf-8"))
            for unit in produced
        ]
    if not translations:
        raise errors.GuardenError(
            f"podlet produced no container unit from {path}",
            errors.HOST_NOT_AS_ASSUMED,
        )
    return translations


def _converter_installed() -> bool:
    """Whether the pinned artefact is where `soil packages` put it.

    Existence and the executable bit, and deliberately not the digest: re-verifying
    the pin on every render would make the renderer depend on `curl`'s network
    path and on root reading a root-owned record it is not going to re-fetch. The
    digest is the installer's claim and `soil packages --check` is the verb that
    asks about it.
    """
    return PODLET.is_file() and os.access(PODLET, os.X_OK)


def _detail(text: str) -> str:
    """One diagnostic line out of podlet's.

    podlet is a `color_eyre` program: it prints a numbered cause chain with ANSI
    colour, a source location and a suggestion, which is four lines and a control
    character or two. A guarden diagnostic is one line prefixed `error:` and names
    the thing it is about, so the chain is collapsed and the escapes dropped —
    the causes are all in there and the reader wanted the first one.
    """
    stripped = ANSI.sub("", text)
    lines = [line.strip() for line in stripped.splitlines() if line.strip()]
    causes = [line for line in lines if not line.startswith(("Location:", "Backtrace"))]
    return errors.oneline(" ".join(causes))
