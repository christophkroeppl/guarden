"""The service user: one per service, allocated by the system, read back loudly.

ADR-0003 and spec 4 step 2. A service owns a Linux user of the same name, a home
under the service tree, linger enabled, and a subuid/subgid range the **system**
allocates rather than guarden inventing.

Two rules that look like belt and braces and are not:

- **The read-back is the point.** `useradd --add-subuids-for-system` succeeding
  is the tool's word for it; `/etc/subuid` holding the range is the fact. An
  unallocated range is a container that starts and then cannot map its own root,
  which is a long way from the cause, so a missing range is exit `1` naming the
  service.
- **One hardcoded range for every service is not a fallback, it is
  unacceptable.** `100000:65536` for everyone maps every container's root to the
  same host uid, and the moment two services share a directory the ownership is
  ambiguous and the firewall's uid matching stops meaning what it says. So the
  fallback path picks the first *free* block, and every service's range is
  checked against every other line in the file: a range another user already
  holds is exit `1`, not a silent collision.

Supplementary groups are reconciled, never created: a group that exists is
added, one that does not is reported and skipped, because the groups a service
may need belong to the system and the distribution rather than to guarden.
"""

from __future__ import annotations

import grp
from dataclasses import dataclass
from pathlib import Path

from guarden import errors, paths, tool

SUBUID_BASE = 100000
SUBUID_SIZE = 65536


@dataclass(frozen=True)
class Identity:
    uid: int
    gid: int
    subuid: str
    subgid: str


def passwd_entries() -> dict[str, tuple[int, int]]:
    """`name:uid:gid` from /etc/passwd. A file read, not a tool call, so it
    costs nothing in the call log and cannot be a stale process's idea."""
    entries: dict[str, tuple[int, int]] = {}
    for line in _read(paths.PREFIX / "etc" / "passwd"):
        parts = line.split(":")
        if len(parts) >= 4 and parts[0]:
            try:
                entries[parts[0]] = (int(parts[2]), int(parts[3]))
            except ValueError:
                continue
    return entries


def owner_pair(uid: int) -> tuple[int, int] | None:
    """The pair an account with this uid carries, or `None` when the host has none."""
    for entry_uid, gid in passwd_entries().values():
        if entry_uid == uid:
            return (uid, gid)
    return None


def group_names() -> set[str]:
    out: set[str] = set()
    for line in _read(paths.GROUP):
        parts = line.split(":")
        if parts and parts[0]:
            out.add(parts[0])
    return out


def group_id(name: str) -> int:
    """The gid a group-owned file needs. The `guarden` group is created by
    `soil install` and is load-bearing rather than tidiness: the registry, every
    `overrides.toml` and all of `/etc/guarden` are `root:guarden` and the
    unprivileged programs read them through it.

    **Asked of the host, not of `paths.GROUP`.** `groupadd` writes the real
    `/etc/group` and cannot be staged, so a `GUARDEN_PREFIX` that points
    elsewhere has a staged `etc/group` that nothing maintains. Asking the kernel
    is the only question with a truthful answer under any prefix — and a gid is a
    property of the system, not of a tree a test stages.
    """
    try:
        return grp.getgrnam(name).gr_gid
    except KeyError:
        raise errors.GuardenError(
            f"the {name} group does not exist on this host; `soil install` creates it",
            errors.HOST_NOT_AS_ASSUMED,
        ) from None


def _read(path: Path) -> list[str]:
    try:
        return [line.rstrip("\n") for line in path.read_text().splitlines() if line.strip()]
    except OSError:
        return []


def _subid_ranges(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    for line in _read(path):
        parts = line.split(":")
        if len(parts) == 3 and parts[0]:
            out[parts[0]] = f"{parts[1]}:{parts[2]}"
    return out


def _used_blocks(path: Path) -> list[tuple[int, int]]:
    blocks = []
    for span in _subid_ranges(path).values():
        first, _, count = span.partition(":")
        try:
            blocks.append((int(first), int(count)))
        except ValueError:
            continue
    return blocks


def _overlaps(start: int, first: int, count: int) -> bool:
    """Whether the block at `start` and the line at `first` claim a uid in common.

    Both halves are load-bearing, and asking for only one of them is the loop
    that was here. Asking whether `start` fell *inside* a line answers true of
    every later `start` too once the base is covered, so the walk never advanced
    past the line that covered it.
    """
    return start < first + count and start + SUBUID_SIZE > first


def free_block(path: Path) -> str:
    """The first free `<first>-<last>` at the system's base, for the fallback path.

    **The bound is the file.** A candidate overlaps a line in it only while the
    candidate starts below that line's end, and the lines are finite, so the walk
    stops at the latest the first slot past the highest end in the file — it is a
    walk, not a search that can come back. The staged harness empties
    `/etc/subuid`, so its `taken` is empty and this loop has never run there; a
    host whose `/etc/subuid` holds one range at the system's base has always run
    it, which is why the defect that lived here could only be seen on a machine.
    """
    taken = _used_blocks(path)
    start = SUBUID_BASE
    while any(_overlaps(start, first, count) for first, count in taken):
        start += SUBUID_SIZE
    return f"{start}-{start + SUBUID_SIZE - 1}"


def ensure(name: str, home: Path, home_mode: int = 0o700) -> Identity:
    """Create the user if it is absent, and return its identity, allocated and read back."""
    existing = passwd_entries()
    if name not in existing:
        _create(name, home, home_mode)
        existing = passwd_entries()
    if name not in existing:
        raise errors.GuardenError(
            f"{name} was created but is not in {paths.PREFIX / 'etc' / 'passwd'}",
            errors.HOST_NOT_AS_ASSUMED,
        )
    uid, gid = existing[name]
    _enable_linger(name)
    return Identity(
        uid=uid,
        gid=gid,
        subuid=_require_range(name, paths.SUBUID),
        subgid=_require_range(name, paths.SUBGID),
    )


def _create(name: str, home: Path, home_mode: int) -> None:
    base = [
        "useradd",
        "--system",
        "--no-create-home",
        "--home-dir",
        str(home),
        "--shell",
        paths.NO_LOGIN_SHELL,
    ]
    if tool.check([*base, "--add-subuids-for-system", name]):
        return
    tool.run([*base, name])
    span = free_block(paths.SUBUID)
    tool.run(["usermod", "--add-subuids", span, name])
    tool.run(["usermod", "--add-subgids", span, name])


def _enable_linger(name: str) -> None:
    tool.run(["loginctl", "enable-linger", name])


def _require_range(name: str, path: Path) -> str:
    """The range for this user, or exit `1` naming the service."""
    ranges = _subid_ranges(path)
    span = ranges.get(name)
    if span is None:
        raise errors.GuardenError(
            f"{name} has no subid range in {path}, so a container of its service could "
            f"not map its own root",
            errors.HOST_NOT_AS_ASSUMED,
        )
    first, _, count = span.partition(":")
    for other, other_span in sorted(ranges.items()):
        if other != name and other_span == span:
            raise errors.GuardenError(
                f"{name} and {other} share the subid range {span} in {path}, so every "
                f"container of either service maps its root to the same host uid",
                errors.HOST_NOT_AS_ASSUMED,
            )
    return f"{first}:{count}"


def reconcile_groups(name: str, wanted: list[str]) -> list[str]:
    """Add the supplementary groups that exist; return a `warning:` line for each
    one that does not.

    No group is ever created. The groups a service needs belong to the system and
    the distribution — `video` for a transcoder — and a mutator that could create
    one could grant a service a group the operator never meant to hand out. A
    missing group is a warning and not a failure, because it is a host
    configuration fact rather than a rejected input.
    """
    known = group_names()
    missing: list[str] = []
    present: list[str] = []
    for group in wanted:
        (present if group in known else missing).append(group)
    if present:
        tool.run(["usermod", "--append", "--groups", ",".join(present), name])
    return [
        errors.warn(
            f"the supplementary group {group!r} is not on the host; {name} was not added to it"
        )
        for group in missing
    ]


def destroy(name: str, uid: int) -> None:
    """Take the account away, and the user manager that is holding it.

    Every service's user has linger enabled (spec 5.3, and a service's units have
    to run without anybody logging in), and **a lingering user has a
    `systemd --user` running for its uid** — measured on the machine: right after
    an ingest, `user@<uid>.service` is active, `loginctl show-user` says
    `State=lingering`, and `userdel <name>` answers `user <name> is currently used
    by process <pid>` and exits 8. So the manager is stopped first, which is what
    takes the process away; `userdel` then does its work.
    """
    tool.run(["systemctl", "stop", f"user@{uid}.service"])
    tool.run(["userdel", name])


def tree_owner(identity: Identity) -> tuple[int, int]:
    return (identity.uid, identity.gid)
