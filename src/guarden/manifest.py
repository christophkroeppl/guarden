"""The project manifest: `.guarden/service.yml`, read with `safe_load` and nothing else.

A repository is YAML because a developer editing their own infrastructure is
better served by the format they know and by one that allows comments in the
obvious place (spec 3). `safe_load` only, always: this is a document a stranger
wrote, and a loader that can construct an object is a loader that runs code.

**Every block has a closed key set, and an unknown key is refused by name**
(spec 4). The rule is stated twice in the spec because the first version covered
only the top level, so a typo in a nested key was silently dropped and a
manifest asking for `authentification: true` got a route with no auth on it and
no diagnostic saying so. A silent drop is the failure this parser exists to make
impossible, so the top-level check is here even for the keys this ticket does not
consume.

What this ticket consumes is `project`, `units`, `state`, `bulk` and `provides`:
the volumes are what the mutator creates and what the registry records, and the
project is one of two registry fields that may differ. The deep shape of
`needs:`, `ports:`, `routes:` and `widgets:` belongs to the tickets that consume
them — the renderer, the edge and the dashboard — and is not validated here
rather than half-validated twice.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from guarden import errors, names

MANIFEST_REL = Path(".guarden") / "service.yml"

TOP_LEVEL_KEYS = {
    "project",
    "units",
    "state",
    "bulk",
    "needs",
    "provides",
    "ports",
    "routes",
    "widgets",
    "schema",
}

# Each block's own key set, closed. spec 4 is emphatic that the rule covers the
# keys *inside* a known one as well, and says why: a typo in a nested key was
# silently dropped, and a manifest asking for `authentification: true` got a route
# with no auth on it and no diagnostic saying so. Only the key sets are checked
# here — whether a container exists, whether a port is in range and whether a
# host is a label are the checks of the tickets that consume those blocks.
BLOCK_KEYS = {
    "needs": {"service", "as", "port", "auth"},
    "ports": {"container", "port"},
    "routes": {"container", "port", "host", "auth"},
    "widgets": {"container", "file"},
}

# spec 4: an `environment` key is refused specifically, with a message saying who
# decides it. It is a key a developer would reach for, and the answer is never
# in the repository.
REFUSED_KEYS = {
    "environment": "the host decides the environment; it is recorded in /etc/guarden/guarden.toml"
}

VOLUME_RE = re.compile(r"^[a-z0-9][a-z0-9._-]*$")
PROVIDES_KINDS = ("db", "secret")


@dataclass
class Manifest:
    source: Path
    project: str | None
    units: str | None
    state: list[str] = field(default_factory=list)
    bulk: list[str] = field(default_factory=list)
    provides: list[str] = field(default_factory=list)

    def volume_kind(self, name: str) -> str:
        return "state" if name in self.state else "bulk"


def _yaml():
    """`pyyaml`, imported here and not at module scope.

    `--help` has to answer on a host where a runtime dependency is not installed
    yet, and a program that cannot print its own usage because a library is
    missing is a bad thing to hand someone over ssh. The import failure is
    therefore a diagnostic naming the distribution's package, which is what
    `soil packages` installs.
    """
    try:
        import yaml
    except ImportError:
        raise errors.GuardenError(
            "python3-yaml is not importable; it is the distribution's package, "
            "installed by `soil packages`",
            errors.HOST_NOT_AS_ASSUMED,
        ) from None
    return yaml


def read(path: Path) -> Manifest:
    """Read one manifest. A repository that ships a broken one is rejected input."""
    yaml = _yaml()
    try:
        text = path.read_text()
    except FileNotFoundError:
        raise errors.GuardenError(f"the manifest {path} does not exist") from None
    except OSError as exc:
        raise errors.GuardenError(f"the manifest {path} could not be read: {exc.strerror}") from exc

    try:
        document = yaml.safe_load(text)
    except yaml.YAMLError as exc:
        raise errors.GuardenError(f"the manifest {path} is not valid YAML: {exc}") from exc

    if document is None:
        document = {}
    if not isinstance(document, dict):
        raise errors.GuardenError(f"the manifest {path} is not a mapping")

    for key in document:
        if key in REFUSED_KEYS:
            raise errors.GuardenError(f"the manifest {path} has a {key!r} key: {REFUSED_KEYS[key]}")
    unknown = sorted(set(document) - TOP_LEVEL_KEYS)
    if unknown:
        raise errors.GuardenError(
            f"the manifest {path} has an unknown key {unknown[0]!r}; "
            f"the keys are: {', '.join(sorted(TOP_LEVEL_KEYS))}"
        )
    _check_blocks(document, path)

    state = _volumes(document.get("state", []), "state", path)
    bulk = _volumes(document.get("bulk", []), "bulk", path)
    both = sorted(set(state) & set(bulk))
    if both:
        raise errors.GuardenError(
            f"the manifest {path} lists {both[0]!r} as both a state and a bulk volume"
        )

    return Manifest(
        source=path,
        project=_project(document.get("project"), path),
        units=_units(document.get("units"), path),
        state=state,
        bulk=bulk,
        provides=_provides(document.get("provides", []), path),
    )


def _check_blocks(document: dict, path: Path) -> None:
    """The closed key set of each list-of-entries block, refused by name."""
    for block, allowed in BLOCK_KEYS.items():
        entries = document.get(block)
        if entries is None:
            continue
        if not isinstance(entries, list):
            raise errors.GuardenError(f"the manifest {path}: {block} is not a list")
        for entry in entries:
            if not isinstance(entry, dict):
                raise errors.GuardenError(
                    f"the manifest {path}: a {block} entry is not a mapping; a bare "
                    f"string is not a valid entry"
                )
            extra = sorted(set(entry) - allowed)
            if extra:
                raise errors.GuardenError(
                    f"the manifest {path}: a {block} entry has an unknown key "
                    f"{extra[0]!r}; the keys are: {', '.join(sorted(allowed))}"
                )


def _volumes(value: Any, key: str, path: Path) -> list[str]:
    if not isinstance(value, list):
        raise errors.GuardenError(f"the manifest {path}: {key} is not a list")
    out = []
    for item in value:
        if not isinstance(item, str) or not VOLUME_RE.match(item):
            raise errors.GuardenError(
                f"the manifest {path}: {key} entry {item!r} must be a name matching "
                f"{VOLUME_RE.pattern}"
            )
        out.append(item)
    return out


def _provides(value: Any, path: Path) -> list[str]:
    if not isinstance(value, list):
        raise errors.GuardenError(f"the manifest {path}: provides is not a list")
    out = []
    for item in value:
        if not isinstance(item, str):
            raise errors.GuardenError(
                f"the manifest {path}: a provides entry is a single string naming a kind, "
                f"and {item!r} is not a string"
            )
        if item not in PROVIDES_KINDS:
            raise errors.GuardenError(
                f"the manifest {path}: provides names the kind {item!r}, and the kinds are "
                f"{', '.join(PROVIDES_KINDS)}"
            )
        out.append(item)
    return out


def _project(value: Any, path: Path) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or not names.NAME_RE.match(value):
        raise errors.GuardenError(
            f"the manifest {path}: project {value!r} must match {names.NAME_RE.pattern}"
        )
    return value


def _units(value: Any, path: Path) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or not value.strip():
        raise errors.GuardenError(f"the manifest {path}: units is not a path")
    return value
