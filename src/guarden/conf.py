"""Guarden's own state files: read TOML, write it with the spec 3.5 protocol.

Two formats, one audience each (spec 3): YAML for anything a human writes inside
a repository, TOML for anything guarden owns. Nothing on the host's critical
path depends on a parser, so the read side is the standard library's `tomllib`
and the write side is the small emitter below rather than a dependency.

The write protocol is not optional and has no exceptions: take `flock`, write a
temporary file **in the same directory** as the target, `fsync`, `rename` over
it, release. A reader takes no lock, because a reader that renamed never
existed sees the old file or the new one and never a partial one.

The lock order is part of the contract (spec 3.5), and it is enforced here
rather than documented and hoped for: taking a lock that sorts before one
already held is the deadlock, and an `AssertionError` naming both is a far
cheaper report than two hung mutators.
"""

from __future__ import annotations

import fcntl
import json
import os
import re
import tomllib
from collections.abc import Iterator, Mapping, Sequence
from contextlib import contextmanager
from pathlib import Path
from typing import Any

from guarden import errors, paths

# modules > projects > overrides > registry > preview-cap > queue > firewall > deploy-*
LOCK_ORDER = (
    "modules",
    "projects",
    "overrides",
    "registry",
    "preview-cap",
    "queue",
    "firewall",
    "snapshots",
)

# deploy-<service> and deploy-<service>-<escaped-ref> compose with nothing above
# them, so they sort after every named lock and never with each other.
_DEPLOY = 99

_held: list[tuple[str, int]] = []


def _rank(name: str) -> int:
    if name in LOCK_ORDER:
        return LOCK_ORDER.index(name)
    if name.startswith("deploy-"):
        return _DEPLOY
    raise KeyError(f"unknown lock name: {name}")


@contextmanager
def lock(*names: str) -> Iterator[None]:
    """Take the named locks, left to right, and check the order as they are taken.

    Never two at once unless they are adjacent in the order and taken left to
    right, which is what this does: each is taken and released inside the
    others only in that one legal case, and `lock()` with a single name — which
    is every call site — is an ordinary single lock.
    """
    ranks = [_rank(name) for name in names]
    if ranks != sorted(ranks):
        raise AssertionError(f"locks taken out of order: {list(names)}")
    if _held and ranks and _held[-1][1] > ranks[0]:
        raise AssertionError(f"lock {names[0]!r} taken while {sorted(_held)[-1][0]!r} is held")
    paths.LOCKS.mkdir(parents=True, exist_ok=True)
    for name in names:
        _held.append((name, _rank(name)))
    handles = []
    try:
        for name in names:
            handle = open(paths.lock_path(name), "a")  # noqa: SIM115 - closed below
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
            handles.append(handle)
        yield
    finally:
        for handle in handles:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
            handle.close()
        for _ in names:
            _held.pop()


def read_toml(path: Path) -> dict[str, Any]:
    """Read a file guarden owns. A file that will not parse is the host, so `1`."""
    try:
        with open(path, "rb") as handle:
            return tomllib.load(handle)
    except FileNotFoundError:
        return {}
    except tomllib.TOMLDecodeError as exc:
        # `TOMLDecodeError` has carried only `args` since 3.11, and has no `.msg`
        # or `.lineno` attribute on any version. Reading them raised AttributeError
        # from inside the handler, so a malformed root file escaped as a traceback
        # instead of the one diagnostic the contract promises. Take the message
        # from str(), which formats the position itself.
        raise errors.GuardenError(
            f"{path} is not valid TOML: {exc}", errors.HOST_NOT_AS_ASSUMED
        ) from exc
    except OSError as exc:
        raise errors.GuardenError(
            f"{path} could not be read: {exc.strerror}", errors.HOST_NOT_AS_ASSUMED
        ) from exc


def set_owner(path, owner: tuple[int, int]) -> None:
    """Give a file to the user and group that own it.

    Skipped when the process is not root. chown to another user is exactly the
    privilege the mutator has on a real host and exactly what an unprivileged
    fast harness does not, so the harness proves the **mode** and the golden VM
    proves the **owner**. Skipping it only when the euid is not 0 means a root
    run cannot quietly lose a `chown` that should have worked.
    """
    if os.geteuid() != 0:
        return
    os.chown(path, owner[0], owner[1])


def write_file(path: Path, text: str, mode: int, owner: tuple[int, int] | None = None) -> None:
    """Write `path` with the spec 3.5 protocol: temp in the same directory, fsync, rename."""
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.parent / f".{path.name}.{os.getpid()}.tmp"
    handle = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    try:
        with os.fdopen(handle, "w") as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
    except BaseException:
        os.unlink(temp)
        raise
    if owner is not None:
        set_owner(temp, owner)
    os.chmod(temp, mode)
    os.replace(temp, path)
    directory = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def write_toml(path: Path, document: Mapping[str, Any], mode: int = 0o640, owner=None) -> None:
    write_file(path, toml_dumps(document), mode, owner)


_BARE_KEY = re.compile(r"[A-Za-z0-9_-]+")


def toml_key(name: str) -> str:
    """A TOML key, quoted when it is not a bare key. A service's instance key is
    `feature\\x2dx`, so quoting here is the difference between a key and a syntax error."""
    if _BARE_KEY.fullmatch(name):
        return name
    return toml_string(name)


def toml_string(value: str) -> str:
    """A TOML basic string. JSON's escapes are a subset of TOML's, and writing them
    rather than escaping by hand is the difference between correct and nearly correct."""
    return json.dumps(value, ensure_ascii=False)


def toml_value(value: Any) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, str):
        return toml_string(value)
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        return repr(value)
    if isinstance(value, Mapping):
        inner = ", ".join(f"{toml_key(k)} = {toml_value(v)}" for k, v in value.items())
        return "{ " + inner + " }" if inner else "{}"
    if isinstance(value, Sequence):
        return "[" + ", ".join(toml_value(item) for item in value) + "]"
    raise TypeError(f"no TOML representation for {type(value).__name__}")


def toml_dumps(document: Mapping[str, Any]) -> str:
    lines: list[str] = []
    _emit_table(document, [], lines)
    return "".join(f"{line}\n" for line in lines)


def _is_table(value: Any) -> bool:
    return isinstance(value, Mapping)


def _emit_table(table: Mapping[str, Any], prefix: list[str], lines: list[str]) -> None:
    # Every scalar of a table comes before its sub-tables: TOML reads a bare key
    # as belonging to the header it is under, so a sub-table header in the middle
    # of a table's own keys would reassign them.
    for key, value in table.items():
        if value is None or _is_table(value):
            continue
        lines.append(f"{toml_key(key)} = {toml_value(value)}")
    for key, value in table.items():
        if not _is_table(value):
            continue
        path = [*prefix, key]
        # A table of tables has no header of its own: `[state]` immediately
        # followed by `[state.data]` is a valid document and a confusing one, and
        # the spec's registry writes the leaf. An *empty* table is a leaf, not a
        # table of tables: `[bulk.chainstate]` is how a bulk volume is recorded as
        # having no configuration.
        has_scalars = any(not _is_table(item) and item is not None for item in value.values())
        if not value or has_scalars:
            if lines and lines[-1] != "":
                lines.append("")
            lines.append("[" + ".".join(toml_key(part) for part in path) + "]")
        _emit_table(value, path, lines)
