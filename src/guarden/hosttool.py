"""The shared half of soil's six phases.

soil is the only program that runs as root against the host, so what lives here
is deliberately small and each piece is one thing: run an external tool, take a
lock, write a file by the protocol in spec 3.5, read the host configuration, and
say what is wrong in one line.

**`GUARDEN_PREFIX` is a test seam and nothing else.** Every host path goes
through `hostpath()`, so the fast harness can point soil at a scratch
directory and assert on the files it wrote. It is an environment variable and
not a flag for two reasons: a flag on a phase is part of the interface the
spec and the sudoers lines both name, and a prefix only ever narrows what a run
can touch, so it can never widen authority. On a real host it is unset and every
path is the absolute one in spec 2.
"""

from __future__ import annotations

import fcntl
import grp
import os
import pwd
import shutil
import subprocess
import sys
import tomllib
from collections.abc import Callable, Iterator
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path

from guarden import paths

PREFIX = Path(os.environ.get("GUARDEN_PREFIX", "/"))

MODE_DIR = 0o755
MODE_DIR_LOCKS = 0o2770
MODE_CONFIG = 0o640

# The one group the lock files belong to, spelled once here because both lock
# implementations state it: spec 3.5's fixed set is taken by root and by
# `guarden` in either order.
LOCK_GROUP = "guarden"


def hostpath(*parts: str) -> Path:
    return PREFIX.joinpath(*parts)


# --------------------------------------------------------------------------
# diagnostics
# --------------------------------------------------------------------------


def warn(message: str) -> None:
    sys.stderr.write(f"warning: {message}\n")


def error(message: str) -> None:
    sys.stderr.write(f"error: {message}\n")


def drift_line(what: str) -> None:
    """One drift line, and the word the spec's `--check` contract names.

    **`what` is the converged state, so the line has to say which side of it the
    host is on.** An `Item` describes the state that holds once the phase has
    converged — "the ferm package is installed", "10-framework.conf carries the
    skeleton" — and the bare `drift: <that sentence>` reads as a claim about the
    present. An operator reading `error: drift: the ferm package is installed`
    cannot tell whether `ferm` is fine and something else is wrong, or whether
    `ferm` is missing and needs installing, and the two want opposite actions.

    The sentence is carried whole and the fact is one clause, rather than the
    other way round, for two reasons. The descriptions are not negotiable by any
    rule: one of the twenty-seven names a state that is *itself* a negative, so a
    mechanical negation would be wrong for it, and hand-negating twenty-seven
    heterogeneous sentences is twenty-seven chances to state a falsehood. And the
    requirement is the informative half — for the pinned artefact it is the
    compound "installed, and the SHA256 of the program on the host is the one the
    record pins", which is what tells a reader which of two conditions to go and
    look at.

    There is one producer of this line and both modes of `soil` go through it, so
    the shape cannot differ between `--check` and `--apply`.
    """
    error(f"drift: {what} — does not hold on this host")


# --------------------------------------------------------------------------
# the external tool seam
# --------------------------------------------------------------------------


@dataclass(frozen=True)
class Result:
    argv: tuple[str, ...]
    code: int
    out: str
    err: str

    @property
    def ok(self) -> bool:
        return self.code == 0

    @property
    def line(self) -> str:
        return self.out.strip()


def run(*argv: str) -> Result:
    """A tool that may be absent.

    **A missing tool is a host that is not in the assumed state, not a crash.**
    `subprocess.run` raises `FileNotFoundError` when the executable is not there,
    and that traceback reached the operator's terminal on the golden VM, where
    `podman` is genuinely not installed: an item called it, the exception
    escaped, and `soil install` died with a stack trace instead of the one line
    naming the tool and the item. Every one of the six phases calls out to tools
    the host may not carry — `ferm`, `snapper`, `btrfs` — so the guard belongs
    here rather than in each caller.
    """
    try:
        done = subprocess.run(argv, capture_output=True, text=True, check=False)
    except OSError as exc:
        return Result(tuple(argv), 127, "", f"{argv[0]} is not installed ({exc.strerror})")
    return Result(tuple(argv), done.returncode, done.stdout, done.stderr)


def run_or_die(*argv: str) -> Result:
    """A tool that had to work. Its failure is soil's failure, and is reported."""
    result = run(*argv)
    if not result.ok:
        reason = result.err.strip().splitlines()
        error(f"{argv[0]} {' '.join(argv[1:])}: {reason[0] if reason else result.code}")
    return result


# --------------------------------------------------------------------------
# converging
# --------------------------------------------------------------------------


@dataclass(frozen=True)
class Item:
    """One fact about the host, in two voices.

    `holds` answers "is this already true", which is what `--check` asks, and
    `converge` makes it true without depending on what it was, which is what
    `--apply` asks. A phase is a list of these and nothing else, so the two
    modes cannot disagree about what converged state means.

    `correctable = False` marks the fact that is reported and never corrected.
    spec 6.1 is explicit that the two host invariants are of that kind: an
    operator who set a sysctl on purpose is not a machine to argue with. Such an
    item is drift for `--check` and nothing at all for `--apply`, because a
    converge that could not fix it and still reported it would make every run on
    such a host fail.
    """

    what: str
    holds: Callable[[], bool]
    converge: Callable[[], None]
    correctable: bool = True


def value_item(
    what: str, current: Callable[[], str], desired: str, set_: Callable[[], None]
) -> Item:
    return Item(what, lambda: current() == desired, set_)


def text_item(what: str, path: Path, content: str, mode: int = MODE_CONFIG) -> Item:
    """A file whose whole content is soil's, compared as text."""
    return Item(
        what,
        lambda: path.is_file() and path.read_text(encoding="utf-8") == content,
        lambda: write_file(path, content, mode),
    )


def directory_item(
    what: str, path: Path, mode: int, owner: str = "root", group: str = "root"
) -> Item:
    """A directory, its mode and its owner.

    Ownership is applied through one `install -d -o -g` call **and compared**:
    a mode-only comparison let a directory whose mode already matched keep the
    wrong owner forever -- measured 2026-10-12, the firewall directory's
    soft-chown `root:root` (the group does not exist until `install` creates
    it) survived a converged install whose own row for it says `root:guarden`.
    `stat` reports ownership to every caller, so comparing it costs no
    privilege; a group that does not exist yet resolves to "does not hold",
    which is honest, and the converge that follows the group's own item fixes
    it.
    """

    def ids() -> tuple[int, int] | None:
        try:
            return pwd.getpwnam(owner).pw_uid, grp.getgrnam(group).gr_gid
        except KeyError:
            return None

    def holds() -> bool:
        wanted = ids()
        if wanted is None or not path.is_dir():
            return False
        info = path.stat()
        return (info.st_mode & 0o7777) == mode and (info.st_uid, info.st_gid) == wanted

    return Item(what, holds, lambda: install_directory(path, mode, owner, group))


# --------------------------------------------------------------------------
# the filesystem and the write protocol
# --------------------------------------------------------------------------


def install_directory(path: Path, mode: int, owner: str = "root", group: str = "root") -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    result = run("install", "-d", "-m", f"{mode:04o}", "-o", owner, "-g", group, str(path))
    if not result.ok:
        error(f"install -d {path}: {result.err.strip()}")
        return
    try:
        os.chmod(path, mode)
    except OSError as exc:
        error(f"chmod {path} {mode:04o}: {exc.strerror}")


def write_file(target: Path, content: str, mode: int = MODE_CONFIG) -> None:
    """A file whose content is soil's, written by the protocol below."""
    write_bytes(target, content.encode("utf-8"), mode)


def write_bytes(target: Path, payload: bytes, mode: int = MODE_CONFIG) -> None:
    """spec 3.5: flock, a temporary file in the same directory, fsync, rename.

    The temporary file is a sibling rather than a path elsewhere because rename
    is only atomic within a filesystem, and because a temporary file in /tmp
    would be a file another process could see.

    One implementation for text and for bytes rather than two, because the pinned
    program is bytes -- it arrives out of an archive and is never decoded -- and a
    second copy of this protocol would be a second thing to keep true. The caller
    takes the lock; this is the write half of it.
    """
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.parent / f".{target.name}.new"
    with open(temporary, "wb") as handle:
        handle.write(payload)
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(temporary, mode)
    os.replace(temporary, target)
    directory = os.open(target.parent, os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def write_config(target: Path, table: str, key: str, value: str) -> None:
    """Rewrite one key of one table, and nothing else in the file.

    The host configuration is read with the standard library's read-only parser,
    so a surgical edit is a text edit: spec 3.5 requires that a writer rewrites
    only the keys it owns, and re-rendering the file from a parsed copy would
    discard whatever else the operator put in it.
    """
    text = target.read_text(encoding="utf-8") if target.is_file() else ""
    write_file(target, set_string_key(text, table, key, value), MODE_CONFIG)


def set_string_key(text: str, table: str, key: str, value: str) -> str:
    return _edit_table(text, table, [(key, _string_value(value))])


def set_string_list(text: str, table: str, key: str, values: list[str]) -> str:
    rendered = ", ".join(_string_value(item) for item in values)
    return _edit_table(text, table, [(key, f"[{rendered}]")])


def _string_value(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def _edit_table(text: str, table: str, keys: list[tuple[str, str]]) -> str:
    lines = text.splitlines()
    header = f"[{table}]"
    try:
        start = lines.index(header) + 1
    except ValueError:
        return _append_table(text, header, keys)

    end = len(lines)
    for index in range(start, len(lines)):
        if lines[index].lstrip().startswith("["):
            end = index
            break

    for key, rendered in keys:
        replacement = f"{key} = {rendered}"
        for index in range(start, end):
            if lines[index].split("=")[0].strip() == key:
                lines[index] = replacement
                break
        else:
            lines.insert(end, replacement)
            end += 1
    return "\n".join(lines) + "\n"


def _append_table(text: str, header: str, keys: list[tuple[str, str]]) -> str:
    body = [header, *(f"{key} = {rendered}" for key, rendered in keys)]
    if not text.strip():
        return "\n".join(body) + "\n"
    return text.rstrip("\n") + "\n\n" + "\n".join(body) + "\n"


@contextmanager
def lock(name: str) -> Iterator[None]:
    """`flock` on /run/guarden/locks/<name>.lock, spec 3.5's fixed set.

    The directory is created here rather than assumed, because the one thing a
    lock must never do is fail to be taken; the mode is re-converged here for
    the same reason, and it is the mode `soil install` states for the directory
    (spec 2.1: `2770`, setgid so a file created by either caller is group
    `guarden`). A lock file's own mode is stated too, because `open`'s is
    filtered by the caller's umask and the other caller is not the file's
    owner: the creating caller sets `0664`, anyone else's chmod is a no-op it
    must not fail on.
    """
    directory = hostpath("run", "guarden", "locks")
    directory.mkdir(parents=True, exist_ok=True)
    # The mode and the owner are stated, softly, exactly as `conf.lock` states
    # them: the statement is owed because a lock can be taken long before
    # `install` runs -- the storage phase takes `snapshots` on a host with no
    # group yet -- on a directory no item can have converged, and soft so the
    # twins fail alike (`hostprep` is the only importer today; a caller that
    # cannot state either value proceeds on what exists).
    try:
        os.chmod(directory, MODE_DIR_LOCKS)
    except OSError:
        pass
    try:
        shutil.chown(directory, group=LOCK_GROUP)
    except (OSError, LookupError):
        pass
    target = directory / f"{name}.lock"
    handle = open(target, "w", encoding="utf-8")
    try:
        os.chmod(target, 0o664)
    except OSError:
        pass
    try:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
        handle.close()


# --------------------------------------------------------------------------
# the host configuration
# --------------------------------------------------------------------------

GUARDEN_TOML = ("etc", "guarden", "guarden.toml")


def read_config(path: Path) -> dict:
    if not path.is_file():
        return {}
    try:
        return tomllib.loads(path.read_text(encoding="utf-8"))
    except tomllib.TOMLDecodeError as exc:
        error(f"{path}: {exc}")
        return {}


def config_path() -> Path:
    return hostpath(*GUARDEN_TOML)


def template_path(*parts: str) -> Path:
    return paths.TEMPLATES.joinpath(*parts)


def template(name: str) -> str:
    """A shipped template, from the source tree or from the installed copy.

    The source tree comes first because that is where the file being read and
    the file being edited are the same one during development, and a converge
    that read a stale installed template would be a different program on a
    developer's box than on a host.
    """
    for candidate in (Path(__file__).parent / "templates" / name, template_path(name)):
        if candidate.is_file():
            return candidate.read_text(encoding="utf-8")
    error(f"the template {name} is missing from this installation")
    return ""


def shipped_config() -> dict:
    """The default host configuration, which every phase reads when none exists."""
    text = template("guarden.toml")
    try:
        return tomllib.loads(text)
    except tomllib.TOMLDecodeError as exc:
        error(f"the shipped guarden.toml does not parse: {exc}")
        return {}


def track(config: dict, name: str) -> dict | None:
    for row in config.get("environments", []):
        if row.get("name") == name:
            return row
    return None


def ingress_interface(config: dict) -> str:
    """`host.interface`, or the interface the default route leaves by."""
    configured = config.get("host", {}).get("interface", "")
    if configured:
        return configured
    return default_route_device()


def default_route() -> str:
    return run("ip", "-4", "route", "show", "default").line


def default_route_device() -> str:
    route = default_route()
    fields = route.split()
    if "dev" in fields:
        return fields[fields.index("dev") + 1]
    error("the default route names no interface: no ingress interface to converge")
    return ""
