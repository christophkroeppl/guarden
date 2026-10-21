"""Rendering a service's units and installing them, root-side.

`loom` renders and `weedr` installs (spec 5.3 step 11). The renderer is
unprivileged and writes only into `/var/lib/guarden/render/<service>/`; this
copies the result into the service's own quadlet directory, installs the
root-owned `<name>.target` into the system path podman's generator reads, and
installs the shared slice `roots` and `twig` read.

The renderer runs as `guarden` and never as root, including over a module's own
shipped source: ADR-0012 is about who runs the code that reads configuration,
and the mutator itself never runs a converter over anything.
"""

from __future__ import annotations

import os
import shutil
import sys
from collections.abc import Iterator
from pathlib import Path

from guarden import conf, errors, paths, registry, tool, unitsource, users
from guarden import overrides as overrides_mod

GUARDEN_USER = "guarden"
GUARDEN_GROUP = "guarden"
LOOM = paths.BIN / "loom"
SHARED_MODE = 0o750
SHARED_FILE_MODE = 0o640
UNIT_MODE = 0o640
# The keep-id drop-in, in podman's uid-scoped search path (ADR-0019).
#
# **The mode is `0644`, and the reason is who reads it.** The generator reads
# this path as the SERVICE user, and so does the edge — the probe measured
# that a `root:root 0600` base unit in the system dir yields NO generated
# unit at all (`probe-quadlet-dropins.md` row 10). The service-owned `0640`
# would refuse the edge and every other uid the generator runs as, and the
# service-owned owner would refuse the generator too, because the generator
# runs as the service and the file is root-owned.
#
# So the file is `root:root 0644`: readable by every uid the generator may
# run as, writable by root alone, and nothing secret in it — a `UserNS=`
# line names a uid and a gid and is not a credential.
ADMIN_DROPIN_MODE = 0o644
# The directories of the search path, and the mode each one needs: the
# generator walks them as the service user, so every one of them is
# traversable (`0755`) and none of them is writable by anybody but root.
ADMIN_DIR_MODE = 0o755


def render_dir(service: str, escaped_ref: str | None = None) -> Path:
    base = paths.LIB / "render" / service
    return base / escaped_ref if escaped_ref else base


def unit_dir(service: str, escaped_ref: str | None = None) -> Path:
    home = paths.service_home(service)
    if escaped_ref:
        home = paths.instance_home(service, escaped_ref)
    return home / paths.QUADLET


def render_units(source: Path, service: str, escaped_ref: str | None = None) -> Path:
    """Run `loom` as `guarden` and return the directory it rendered into.

    The out directory belongs to `guarden` and is emptied by the renderer: the
    mutator never writes into a tree the unprivileged renderer owns, and it
    cannot create it either — a directory root owns is a directory `guarden`
    cannot render into.
    """
    out = render_dir(service, escaped_ref)
    gid = users.group_id(GUARDEN_USER)
    uid = users.passwd_entries()[GUARDEN_USER][0]
    paths.LIB.mkdir(parents=True, exist_ok=True)
    staging = paths.LIB / "render"
    staging.mkdir(parents=True, exist_ok=True)
    conf.set_owner(staging, (uid, gid))
    os.chmod(staging, 0o770)
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    conf.set_owner(out, (uid, gid))
    os.chmod(out, 0o700)

    argv = tool.runuser_as(
        GUARDEN_USER,
        str(LOOM),
        "render",
        str(source),
        "--service",
        service,
        "--out",
        str(out),
    )
    if escaped_ref:
        argv.extend(["--instance", escaped_ref])
    tool.run(argv, cwd="/tmp")
    if not out.is_dir():
        raise errors.GuardenError(
            f"{source} rendered nothing for {service}: {LOOM} wrote no units into {out}",
            errors.HOST_NOT_AS_ASSUMED,
        )
    return out


def host_mounts(source: Path) -> list[str]:
    """Every absolute host path the shipped unit source bind-mounts.

    Read from guarden's own file, so a module grants nothing by this: the paths
    are what its unit already names, and the renderer refuses anything outside
    the service's own volumes, `/etc/guarden` and this allow list (spec 6.3).
    The edge reads the directory `roots` writes, and that is the one mount it has.
    """
    out: list[str] = []
    if not source.is_dir():
        return out
    for path in sorted(source.rglob("*.container")):
        unit = unitsource.parse(path)
        for value in unit.get("Container", "Volume"):
            target = value.split(":")[0]
            if target.startswith("/") and target not in out:
                out.append(target)
    return sorted(out)


def allow_mounts(source: Path, service: str) -> list[str]:
    """Record the source's own host paths in the service's root-owned allow list."""
    wanted = host_mounts(source)
    if not wanted:
        return []
    granted = overrides_mod.load(service)
    missing = [path for path in wanted if path not in granted.mounts]
    if not missing:
        return []
    with conf.lock("overrides"):
        granted = overrides_mod.load(service)
        granted.mounts = sorted([*granted.mounts, *missing])
        overrides_mod.save(service, granted, (0, users.group_id(GUARDEN_GROUP)))
    return missing


def _converge(path: Path, owner: tuple[int, int]) -> bool:
    """One directory inside a service's home, converged to the tree's rule.

    The mode is `0700` and the owner is the service's own uid and gid. **The
    comparison is read from the host and not assumed**, so a directory that
    already holds the rule is not touched, and a repair can say what it
    actually changed instead of what it walked.

    A link is left alone: the tree's rule is about the directories guarden
    made, and a link's target is the target's.
    """
    if path.is_symlink():
        return False
    try:
        info = path.stat()
    except OSError:
        return False
    if (info.st_uid, info.st_gid) == owner and (info.st_mode & 0o7777) == paths.TREE_MODE:
        return False
    conf.set_owner(path, owner)
    os.chmod(path, paths.TREE_MODE)
    return True


def _chain_up(root: Path, home: Path) -> Iterator[Path]:
    """A directory and every level above it, up to the home and not past it.

    The chain is what the installer made: `conf.write_file`'s
    `mkdir(parents=True)` creates the leaf AND the levels above it, and every
    level it makes carries the mutator's umask and root's ownership. A repair
    that owned the leaf and left the levels above it root-owned inside a `0700`
    home would be the defect it exists to prevent, one level up.
    """
    try:
        parts = root.relative_to(home).parts
    except ValueError:
        yield root
        return
    for index in range(len(parts), 0, -1):
        yield home.joinpath(*parts[:index])


def own_directory(path: Path, owner: tuple[int, int]) -> list[Path]:
    """A directory inside a service's home, owned by that service's user.

    `conf.write_file` creates the parent with `mkdir(parents=True)` and
    nothing else, so a directory it creates is root-owned with the mutator's
    umask — and the mode depends on who invoked the mutator. That is wrong
    for a directory inside a service's home: the spec says nothing root-owned
    lives there, and the service cannot write its own quadlet tree without it.

    The mode is `0700`, the tree's own mode: the directory holds one file the
    service owns, inside a directory only the service can enter.

    **Every directory this call creates is owned, and not only the leaf.** The
    leaf's own parent may be missing too — `home/.config/containers` is
    created by the same `mkdir` — and `mkdir(parents=True)` gives every level
    it makes the mutator's umask and root's ownership. A helper that owned
    the leaf and left the levels above it root-owned inside a `0700` home
    would be the defect it exists to prevent, one level up. So the chain is
    walked up to the first directory that already exists, and each level this
    call makes is created, owned and moded in turn.

    **A directory that already exists is CONVERGED, and not left alone.** The
    tree's rule is `0700` to the service user (spec 2.1), and it is the
    tree's rule whether guarden made the directory now or found it there: a
    host that ran an older guarden carries directories this helper made wrong,
    and the installer is the only writer that made one (ticket 334). The leaf
    is the one this call is about, so the leaf is the one it converges.

    Returns the directories it changed, so a caller can say what it repaired.
    """
    missing: list[Path] = []
    probe = path
    while not probe.exists():
        missing.append(probe)
        probe = probe.parent
    for directory in reversed(missing):
        directory.mkdir(parents=True, exist_ok=True)
        conf.set_owner(directory, owner)
        os.chmod(directory, paths.TREE_MODE)
    return [path] if _converge(path, owner) else []


def owner_of(record) -> tuple[int, int]:
    """The uid and gid a service's own files carry.

    The service's own uid, and its own gid where the host gave it one — the
    same pair `install` writes with, so a repair and an install cannot
    disagree about who owns a directory.
    """
    service = record.service
    return (
        record.uid,
        users.group_id(service) if service in users.group_names() else record.uid,
    )


def repair_unit_dirs(
    service: str, owner: tuple[int, int], refs: list[str]
) -> list[Path]:
    """The unit directories of a service and of every instance it holds,
    converged to the tree's rule (ticket 334).

    **What is repaired is the unit directories: the service's own and every
    instance's.** Those are the directories the INSTALLER made — the quadlet
    directory, the levels above it, and the drop-in directory under it — and
    it made them by `conf.write_file`'s `mkdir(parents=True)`, so they carry
    the mutator's umask and root's ownership. Every other directory in the
    tree was made by `_make_tree`'s walk, which owns it, and the walk runs on
    every create that is not converged.

    **The FILES are not repaired, and that is deliberate.** A unit file's mode
    is ticket 320's question — two writers disagree about it and suites pin
    the answer it has not yet been given. A repair that re-moded the files
    would settle that question by side effect, and this is not that ticket.

    Returns the directories it changed, so a caller can say what it repaired.
    """
    home = paths.service_home(service)
    roots = [unit_dir(service)]
    roots += [unit_dir(service, ref) for ref in refs]
    changed: list[Path] = []
    for root in roots:
        if not root.is_dir():
            continue
        for path in _chain_up(root, home):
            if _converge(path, owner):
                changed.append(path)
        for path in sorted(root.glob("*.container.d")):
            if path.is_dir() and _converge(path, owner):
                changed.append(path)
    return changed


def install(source: Path, service: str, escaped_ref: str | None = None) -> list[str]:
    """Render, then copy into place: units, the order target, the shared slice."""
    out = render_units(source, service, escaped_ref)
    record = registry.load(service)
    if record is None:
        raise errors.GuardenError(
            f"{service} has no registry entry, so there is nothing to install units into",
            errors.HOST_NOT_AS_ASSUMED,
        )
    owner = (
        record.uid,
        users.group_id(service) if service in users.group_names() else record.uid,
    )
    written: list[str] = []

    for path in sorted(_files(out / "units")):
        relative = path.relative_to(out / "units")
        body = path.read_text(encoding="utf-8")
        target = unit_dir(service, escaped_ref) / relative
        own_directory(target.parent, owner)
        conf.write_file(target, body, UNIT_MODE, owner)
        written.append(str(target))
        entry = search_entry(relative, escaped_ref)
        if entry is not None:
            mirror = unit_dir(service) / entry
            own_directory(mirror.parent, owner)
            conf.write_file(mirror, body, UNIT_MODE, owner)
            written.append(str(mirror))

    for path in sorted(_files(out / "system")):
        target = paths.PREFIX / "etc" / "systemd" / "system" / path.name
        conf.write_file(target, path.read_text(encoding="utf-8"), UNIT_MODE)
        written.append(str(target))

    _install_admin_dropins(out, service, escaped_ref, written)

    shared = out / "shared"
    if shared.is_dir():
        gid = users.group_id(GUARDEN_GROUP)
        # The slice target carries the instance: an instance's render installs
        # under `shared/<service>/instances/<escaped-ref>/` and the service's
        # own files stay the slot's (spec 2), so two instances of one service
        # neither clobber each other's routes nor overwrite the slot's slice —
        # which is ticket 295's folded-in wrong-path finding (264:87).
        service_dir = paths.SHARED / service
        directories = [service_dir]
        if escaped_ref:
            directories.append(service_dir / "instances")
            directories.append(service_dir / "instances" / escaped_ref)
        for directory in directories:
            directory.mkdir(parents=True, exist_ok=True)
            conf.set_owner(directory, (0, gid))
            os.chmod(directory, SHARED_MODE)
        target_dir = directories[-1]
        for path in sorted(_files(shared)):
            target = target_dir / path.relative_to(shared)
            conf.write_file(target, path.read_text(encoding="utf-8"), SHARED_FILE_MODE,
                            (0, gid))
            written.append(str(target))

    reload_system()
    return written


QUADLET_KINDS = (".container.d", ".container")


def _install_admin_dropins(
    out: Path, service: str, escaped_ref: str | None, written: list[str]
) -> None:
    """Guarden's own drop-in, into podman's uid-scoped search path (ADR-0019).

    **One file, one writer, one place.** The render's `admin/` directory
    holds `50-guarden-keepid.conf` and nothing else, and this writes it into
    `/etc/containers/systemd/users/<uid>/<unit>.container.d/` — the
    directory the generator reads for a unit whose base file lives in the
    service's home (measured, `probe-quadlet-dropins.md` row 8).

    **The admin's own `90-admin.conf` in that directory is never written and
    never deleted.** It is the human's file, and the alphabetical order is
    what makes it win: `50-` merges before `90-`, and the last value of a
    scalar key is the effective one. This function writes one named file and
    touches nothing else in the directory — it does not clear the directory,
    and it does not remove a file it did not write.

    **The instance's own unit is a separate file.** An instance's units are
    given an entry in the service's own quadlet directory named
    `<unit>-<escaped-ref>` (`entry_stem`), and the generator reads THAT
    name — so the instance's drop-in is named for the entry, not for the
    unit's own stem. A drop-in written under the plain stem would sit in a
    directory the generator never reads for an instance.

    The mode is `0644` and the owner root, because the generator reads this
    path as the service user and a root-owned `0600` file there yields no
    generated unit at all (measured: `probe-quadlet-dropins.md` row 10).
    """
    admin = out / "admin"
    record = registry.load(service)
    if record is None or not record.uid:
        return
    rendered = {
        path.name[: -len(".container")]
        for path in sorted(_files(out / "units"))
        if path.name.endswith(".container")
    }
    # The units this render gave a pin to — the ones with a drop-in of their
    # own in the render's `admin/` directory. The difference from `rendered`
    # is the set of units whose file must go: the ones the record does not
    # answer any more.
    pinned = {
        path.relative_to(admin).parts[0][: -len(".container.d")]
        for path in sorted(_files(admin))
        if path.relative_to(admin).parts[0].endswith(".container.d")
    }
    for parent in paths.admin_parents():
        parent.mkdir(parents=True, exist_ok=True)
        os.chmod(parent, ADMIN_DIR_MODE)
    for path in sorted(_files(admin)):
        relative = path.relative_to(admin)
        # `relative` is `<unit>.container.d/<file>` — the unit's own name and
        # the drop-in's file name, which is exactly the shape of the target.
        stem = relative.parts[0]
        if not stem.endswith(".container.d"):
            continue
        unit = stem[: -len(".container.d")]
        if escaped_ref:
            unit = entry_stem(unit, escaped_ref)
        directory = paths.admin_dropin_dir(record.uid, unit)
        directory.mkdir(parents=True, exist_ok=True)
        os.chmod(directory, ADMIN_DIR_MODE)
        target = directory / path.name
        conf.write_file(target, path.read_text(encoding="utf-8"), ADMIN_DROPIN_MODE)
        written.append(str(target))
    _drop_stale_admin_dropins(record.uid, rendered, escaped_ref, pinned)


def _drop_stale_admin_dropins(
    uid: int, rendered: set[str], escaped_ref: str | None, pinned: set[str]
) -> None:
    """Guarden's own file, gone for a unit the render gives no pin to.

    **A stale pin is worse than a missing one.** The record answers a unit
    with no pair — the image changed, or the record was edited to say the
    image declares no user — and the render then produces no drop-in for it.
    The file left behind would still carry a `UserNS=` line, the generator
    would still merge it, and the mapping it names would still be in force:
    the container would run under a pin the record no longer claims.

    So the file guarden owns is removed for every unit THIS render produced
    and gave **no** drop-in to. `pinned` is the set this render DID write, and
    a unit in it is left alone — which is what keeps this from deleting the
    file that was written a moment ago.

    The removal is narrow on purpose: another unit's directory — the
    service's own `<unit>.container.d` beside an instance's
    `<unit>-<ref>.container.d` — is not this render's business, and neither
    is the admin's own file, which is never touched at all.
    """
    root = paths.ADMIN_UNITS / str(uid)
    if not root.is_dir():
        return
    for stem in sorted(rendered - pinned):
        unit = entry_stem(stem, escaped_ref)
        stale = paths.admin_dropin_dir(uid, unit) / paths.KEEPID_DROPIN
        if stale.is_file():
            stale.unlink()


def entry_stem(unit: str, escaped_ref: str | None) -> str:
    """The unit name podman's generator makes from an instance's unit — the
    ONE statement of that rule.

    An instance's units live in the instance's own quadlet directory (spec 2),
    which is a subdirectory of the service's home — and the generator reads
    `$XDG_CONFIG_HOME/containers/systemd` and the uid-scoped system paths and
    nothing below them (podman-systemd.unit(5)), so a declaration only there is
    a declaration systemd never makes: `systemctl start` answers
    "Unit <name> not found" (measured, ticket 295). So the instance's units are
    ALSO given an entry in the service's own quadlet directory, named after the
    unit and the instance's escaped ref — the same escaped form that names the
    instance's directory, its registry key and its deploy lock (spec 5.2) — and
    every reader and writer of that name goes through THIS function: install
    writes it, `weedr service start`/`stop` translate to it, and
    `drop_instance_entries` derives what to delete from it. Three expressions
    of one rule would be three things to keep agreeing, and the disagreement
    would surface as a start that fails silently in one direction.

    The unit itself when there is no instance: nothing is suffixed, and
    `search_entry` (which decides whether there is a second file to write at
    all) is the one caller that asks that separately.
    """
    if not escaped_ref:
        return unit
    return f"{unit}-{escaped_ref}"


def _is_instance_entry(unit: str, escaped_ref: str) -> bool:
    """Whether a unit name in the admin search path is THIS instance's.

    An instance's drop-in directory is named after the ENTRY STEM, so it is
    `<unit>-<escaped-ref>.container.d` — the service's own is
    `<unit>.container.d`, and another instance's is `<unit>-<other-ref>
    .container.d`. The question is therefore "does this name carry THIS
    instance's ref suffix?", which the suffix answers.

    The comparison this replaces asked the opposite question — "is this name
    the BASE unit?" — and `entry_stem` answers that with "no" for every
    instance, because it appends the ref to the name it is given. So the guard
    skipped every directory and the instance's own drop-in survived the
    instance (spec 5.3: an instance that is removed takes its own directory
    with it).

    The suffix is compared against the END of the name and the base unit must
    be non-empty, so a unit literally named `-<ref>` is not this instance's
    entry: there is no unit before the suffix.
    """
    if not escaped_ref:
        return False
    suffix = f"-{escaped_ref}"
    if not unit.endswith(suffix):
        return False
    return len(unit) > len(suffix)


def search_entry(relative: Path, escaped_ref: str | None) -> Path | None:
    """The same unit where podman's generator reads it, for an instance —
    built on `entry_stem`, the rule's one home.

    `None` for anything that is not a quadlet source: `guarden.env` is read by
    the path the unit carries, not found by search, and a ref is always present
    here or there is no instance at all.
    """
    if not escaped_ref:
        return None
    head = relative.parts[0]
    for kind in QUADLET_KINDS:
        if head.endswith(kind):
            stem = entry_stem(head[: -len(kind)], escaped_ref)
            return Path(f"{stem}{kind}", *relative.parts[1:])
    return None


def drop_instance_entries(service: str, escaped_ref: str) -> None:
    """Every search-path entry one instance's units were given, gone with it.

    Called from the one path that forgets an instance (spec 5.3), so a dropped
    preview does not leave a declaration behind for a container whose volumes,
    publications and registry entry are all gone — the generator would keep
    making a unit out of it.

    The entries are **derived from the instance's own quadlet directory**
    through `entry_stem` rather than matched by suffix in the shared directory:
    a suffix match is a second expression of the naming rule, and two
    expressions are two things that can drift (review finding 5). The caller
    therefore runs this while the instance's directory still exists.
    """
    own = unit_dir(service, escaped_ref)
    directory = unit_dir(service)
    if not own.is_dir() or not directory.is_dir():
        return
    for path in sorted(own.iterdir()):
        for kind in QUADLET_KINDS:
            if not path.name.endswith(kind):
                continue
            stem = entry_stem(path.name[: -len(kind)], escaped_ref)
            target = directory / f"{stem}{kind}"
            if target.is_dir():
                shutil.rmtree(target)
            elif target.exists():
                target.unlink()
            break
    _drop_instance_admin_dropins(service, escaped_ref)


def _drop_instance_admin_dropins(service: str, escaped_ref: str) -> None:
    """An instance's keep-id drop-in, gone with the instance (ADR-0019).

    **An instance OWNS its drop-in directory, and the service's own is a
    different one.** The instance's units are given an entry in the service's
    own quadlet directory named `<unit>-<escaped-ref>`, and the generator
    reads that name — so the instance's drop-in lives in
    `<unit>-<escaped-ref>.container.d/` beside the service's own
    `<unit>.container.d/`, and the two are separate directories with
    separate pins. Two instances of one service therefore have two pins, and
    neither lands in the other's.

    So an instance that goes takes its own directory with it. **The admin's
    own file in it is left alone**, by the same rule the service's removal
    follows: guarden takes the file it wrote and nothing else. The instance's
    directory is only removed when the admin left nothing in it.
    """
    record = registry.load(service)
    if record is None or not record.uid:
        return
    root = paths.ADMIN_UNITS / str(record.uid)
    if not root.is_dir():
        return
    for path in sorted(root.iterdir()):
        if not path.is_dir() or not path.name.endswith(".container.d"):
            continue
        unit = path.name[: -len(".container.d")]
        if not _is_instance_entry(unit, escaped_ref):
            continue
        for dropin in sorted(path.iterdir()):
            if dropin.is_file() and dropin.name == paths.KEEPID_DROPIN:
                dropin.unlink()
        if not any(path.iterdir()):
            shutil.rmtree(path, ignore_errors=True)


def _files(directory: Path) -> list[Path]:
    return [path for path in sorted(directory.rglob("*")) if path.is_file()] if (
        directory.is_dir()
    ) else []


def reload_system() -> None:
    result = tool.call(["systemctl", "daemon-reload"])
    if not result.ok:
        detail = errors.oneline(result.stderr.strip() or result.stdout.strip())
        raise errors.GuardenError(
            f"systemctl daemon-reload did not succeed after writing units, so they are on disk "
            f"and unknown to systemd: {detail}",
            errors.HOST_NOT_AS_ASSUMED,
        )


def report(written: list[str]) -> None:
    for path in written:
        sys.stdout.write(f"installed {path}\n")