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
