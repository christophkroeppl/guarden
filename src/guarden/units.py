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
from pathlib import Path

from guarden import conf, errors, paths, registry, tool, unitsource, users
from guarden import overrides as overrides_mod

GUARDEN_USER = "guarden"
GUARDEN_GROUP = "guarden"
LOOM = paths.BIN / "loom"
SHARED_MODE = 0o750
SHARED_FILE_MODE = 0o640
UNIT_MODE = 0o640


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

    argv = [
        "runuser",
        "-u",
        GUARDEN_USER,
        "--",
        str(LOOM),
        "render",
        str(source),
        "--service",
        service,
        "--out",
        str(out),
    ]
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
        conf.write_file(target, body, UNIT_MODE, owner)
        written.append(str(target))
        entry = search_entry(relative, escaped_ref)
        if entry is not None:
            mirror = unit_dir(service) / entry
            conf.write_file(mirror, body, UNIT_MODE, owner)
            written.append(str(mirror))

    for path in sorted(_files(out / "system")):
        target = paths.PREFIX / "etc" / "systemd" / "system" / path.name
        conf.write_file(target, path.read_text(encoding="utf-8"), UNIT_MODE)
        written.append(str(target))

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