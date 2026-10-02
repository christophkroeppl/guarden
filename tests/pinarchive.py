#!/usr/bin/env python3
"""Build a staged artefact for the pinned-release tests.

The pin's install is fetch, verify the artefact's digest, then unpack one member
out of it, and the refusals around that are only reachable with an archive whose
contents a test chooses. This builds one.

**The payload is a real program off the machine, not a stand-in for anything.**
What the tests need to tell apart is an installed file that is a program from one
that is an archive with a program's name, and the only honest way to have the
first is to put a real ELF executable in the archive and then run it. There is no
fake here to put on `PATH` and no call log: the file that comes out is a copy of
a program the machine already had, and the assertion is that running the copy
answers.

usage: pinarchive.py <format> <payload> <archive> [member] [kind]

`format` is `tar.xz` or `zip` — the two the record's `format` key accepts, so a
test can drive both unpackers. `member` is the name the program carries *inside*
the archive and defaults to `podlet-x86_64-unknown-linux-gnu/podlet`, which is
what the real release uses and which is why the install matches a member by its
basename rather than by its whole path.

`kind` is the member's own kind, and it is the second thing the refusals are
about. A `regular` member is the payload's bytes, which is the shape every
published release has. The others are the members the install must never treat as
a candidate — a `symlink`, a `hardlink`, a `device`, a `fifo` and a `directory`
— built as a member header rather than as a file on disk, because the machine
has no device node to hand a `tar.add` and a test that made one would be building
a device. A payload that is a directory produces a `directory` member on its own,
which is how the existing directory case is reached.

`zip` expresses a `symlink` and a `directory` and neither of the other three: a
zip has no member types for them, so a test that asks for one under `zip` is told
so rather than being handed a file that claims to be something it is not.
"""

from __future__ import annotations

import stat
import sys
import tarfile
import zipfile
from pathlib import Path

FORMATS = ("tar.xz", "zip")
DEFAULT_MEMBER = "podlet-x86_64-unknown-linux-gnu/podlet"
KINDS = ("regular", "directory", "symlink", "hardlink", "device", "fifo")

# What a zip can actually express. A symlink is a file whose content is the
# target's name, which is exactly why a reader that only asks "is this a
# directory?" installs the target's *path* as though it were the program; the
# refusal for it is in hostprep, and this is how a test reaches it.
ZIP_KINDS = ("regular", "directory", "symlink")

TAR_TYPES = {
    "symlink": tarfile.SYMTYPE,
    "hardlink": tarfile.LNKTYPE,
    "device": tarfile.CHRTYPE,
    "fifo": tarfile.FIFOTYPE,
}


def build(kind: str, payload: Path, archive: Path, member: str, shape: str) -> None:
    if kind == "tar.xz":
        _tar(payload, archive, member, shape)
        return
    _zip(payload, archive, member, shape)


def _tar(payload: Path, archive: Path, member: str, shape: str) -> None:
    with tarfile.open(archive, "w:xz") as tar:
        if shape in ("regular", "directory"):
            tar.add(payload, arcname=member)
            return
        if shape in ("symlink", "hardlink"):
            # The link's target is a member of this archive rather than a name
            # that points nowhere, so the archive is the shape the refusal is
            # about rather than a dangling entry that happens to be refused.
            tar.add(payload, arcname=payload.name)
        info = tarfile.TarInfo(member)
        info.type = TAR_TYPES[shape]
        info.linkname = payload.name
        if shape == "device":
            info.devmajor, info.devminor = 1, 3
        info.size = 0
        tar.addfile(info)


def _zip(payload: Path, archive: Path, member: str, shape: str) -> None:
    with zipfile.ZipFile(archive, "w") as zipped:
        if shape == "regular":
            zipped.write(payload, arcname=member)
            return
        if shape == "symlink":
            zipped.write(payload, arcname=payload.name)
        name = f"{member}/" if shape == "directory" else member
        if shape == "symlink":
            mode = stat.S_IFLNK | 0o777
        else:
            mode = stat.S_IFDIR | 0o755
        info = zipfile.ZipInfo(name)
        info.external_attr = mode << 16
        zipped.writestr(info, payload.name if shape == "symlink" else b"")


def main(argv: list[str]) -> int:
    if not 4 <= len(argv) <= 6:
        sys.stderr.write(f"usage: {argv[0]} <format> <payload> <archive> [member] [kind]\n")
        return 2
    kind, payload, archive = argv[1], Path(argv[2]), Path(argv[3])
    member = argv[4] if len(argv) == 5 else DEFAULT_MEMBER
    shape = argv[5] if len(argv) == 6 else "regular"
    if kind not in FORMATS:
        sys.stderr.write(f"error: {kind!r} is not one of {', '.join(FORMATS)}\n")
        return 2
    if shape not in KINDS:
        sys.stderr.write(f"error: {shape!r} is not one of {', '.join(KINDS)}\n")
        return 2
    if kind == "zip" and shape not in ZIP_KINDS:
        sys.stderr.write(
            f"error: a zip cannot carry a {shape} member; it can carry "
            f"{', '.join(ZIP_KINDS)}\n"
        )
        return 2
    if shape not in ("symlink", "hardlink") and not payload.exists():
        sys.stderr.write(f"error: the payload {payload} is not there to put in the archive\n")
        return 2
    archive.parent.mkdir(parents=True, exist_ok=True)
    build(kind, payload, archive, member, shape)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
