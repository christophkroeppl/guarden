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
UNIT_MODE = 0o644


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
    tool.run(argv)
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
        target = unit_dir(service, escaped_ref) / path.relative_to(out / "units")
        conf.write_file(target, path.read_text(encoding="utf-8"), UNIT_MODE, owner)
        written.append(str(target))

    for path in sorted(_files(out / "system")):
        target = paths.PREFIX / "etc" / "systemd" / "system" / path.name
        conf.write_file(target, path.read_text(encoding="utf-8"), UNIT_MODE)
        written.append(str(target))

    shared = out / "shared"
    if shared.is_dir():
        gid = users.group_id(GUARDEN_GROUP)
        target_dir = paths.SHARED / service
        target_dir.mkdir(parents=True, exist_ok=True)
        conf.set_owner(target_dir, (0, gid))
        os.chmod(target_dir, SHARED_MODE)
        for path in sorted(_files(shared)):
            target = target_dir / path.relative_to(shared)
            conf.write_file(target, path.read_text(encoding="utf-8"), SHARED_FILE_MODE,
                            (0, gid))
            written.append(str(target))

    reload_system()
    return written


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