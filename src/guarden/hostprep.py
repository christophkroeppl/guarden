"""The six phases, as lists of `Item`s.

A phase is a list of facts about the host, each of which can say whether it
already holds and can make itself hold. `--check` asks the first question of
every item, `--apply` asks the second. Nothing else decides what a phase means,
so the two modes cannot drift apart, and `--check` changing nothing is a
property of the shape rather than of care in each phase.

**A phase may also have one step that runs before any of its items, and only
`--apply` runs it.** That is `prepare_for`, and it exists for the one thing in
the whole set that is not a fact about the host: the distribution's package
index. A step with nothing to converge it against cannot be an `Item` — asking
whether a stale index holds would report drift on every host forever — so it is
outside the list, and a check that ran it would be a check that changed
something.

The order the phases run in is the order in spec 6.1, and it is not
interchangeable: `storage` creates the directories `install` writes into and the
registry `install` reads a track from.
"""

from __future__ import annotations

import hashlib
import lzma
import os
import platform
import shutil
import socket
import stat
import tarfile
import threading
import zipfile
from collections.abc import Callable, Iterable
from pathlib import Path, PurePosixPath

from guarden import conf, errors, packagelist, paths, users, zram
from guarden import hosttool as h
from guarden.hosttool import Item, hostpath, lock

# --------------------------------------------------------------------------
# the values spec 2.1 says these phases own
# --------------------------------------------------------------------------

# spec 2.1, one row each: a directory a program writes into is 0770, one it
# only reads is 0750, and /var/lib/guarden/services/ is 0711 so that listing it
# would not leak every workload name on the box.
STORAGE_DIRECTORIES = (
    (("var", "lib", "guarden"), 0o750, "root", "guarden"),
    (("var", "lib", "guarden", "services"), 0o711, "root", "root"),
    (("var", "lib", "guarden", "registry"), 0o750, "root", "guarden"),
    (("var", "lib", "guarden", "shared"), 0o750, "root", "guarden"),
    (("var", "lib", "guarden", "stakes"), 0o770, "root", "guarden"),
    (("var", "lib", "guarden", "share"), 0o750, "root", "guarden"),
    (("var", "lib", "guarden", "queue"), 0o770, "root", "guarden"),
    (("var", "lib", "guarden", "soil"), 0o750, "root", "guarden"),
    (("var", "lib", "guarden", "staging"), 0o755, "root", "root"),
)

INSTALL_DIRECTORIES = (
    # Named from the constants rather than spelled as path tuples: spec 2's FHS
    # rows are `paths`' to state, and a tuple here is the second copy of a
    # layout that moved. The tuples are the phase's shape -- (parts, mode,
    # owner, group) -- so each entry is the constant's parts under the prefix.
    (paths.USR_LIB_GUARDEN.relative_to(h.hostpath()).parts,
     0o755, "root", "root"),
    (paths.BIN.relative_to(h.hostpath()).parts, 0o755, "root", "root"),
    (paths.LIBDIR.relative_to(h.hostpath()).parts, 0o755, "root", "root"),
    (paths.MODULES.relative_to(h.hostpath()).parts, 0o755, "root", "root"),
    (paths.TEMPLATES.relative_to(h.hostpath()).parts, 0o755, "root", "root"),
    (("var", "lib", "guarden", "render"), 0o770, "guarden", "guarden"),
    (("run", "guarden"), 0o755, "root", "root"),
    (("run", "guarden", "locks"), 0o770, "root", "guarden"),
)

# The only two users and the only one group this host ever gets. There is no
# `soil users` phase, and no service identity: the two program users belong to
# `install`, and a service's own user belongs to `weedr service add`.
PROGRAM_USERS = ("guarden", "hose")
PROGRAM_GROUP = "guarden"

# The packages come from `packages/packages.toml` and not from a tuple here,
# because the cloud-init user-data is rendered from the same file and a second
# copy in code is a second copy that can drift: a host would install three
# things and converge on a fourth, and both machines would report success.
# Resolved per call rather than at import, so `soil --help` still answers on a
# host whose family this list has no row for.
def distribution_packages(family: str | None = None) -> tuple[str, ...]:
    """The packages this host's family needs, and the only list of them."""
    return packagelist.package_names(family)

# Every fetch from outside a distribution repository, and the shape all of them
# take (ADR-0015). A pin is a url and two digests: the artefact's, compared in
# the fetch temporary before anything is unpacked out of it, and the program's,
# re-read on every `--check` because the artefact is not kept. The mechanism is
# named for nothing in particular, because a second pinned binary reuses all of
# it and a second copy of a verified fetch is two places to get the property
# wrong.
#
# The pin file is `<name>.release` and the fetch temporary is `<name>.fetch`.
# Both are the artefact's own name, because two artefacts on one host are two
# files, and a name they shared would be one file overwritten by whichever of
# them ran last.
ARTEFACT_RECORD_SUFFIX = ".release"
ARTEFACT_FETCH_SUFFIX = ".fetch"

# One artefact's own name. Every function below takes the name as an argument
# rather than reading one out of this module, so the second pinned artefact is a
# name at a call site and not an edit to the mechanism.
PODLET = "podlet"

# The record carries one row per host architecture rather than one url, because a
# single url is a pin that cannot be correct on any host but the machine it was
# written on: installing the wrong row's bytes produces a file that exists, is
# executable, and is not a program, and refusing the fetch everywhere except one
# machine tells an operator nothing about which row is missing. The host's own
# `platform.machine()` picks the row, and both spellings of each architecture are
# accepted because a pin written on an amd64 machine says `x86_64` and one that
# calls itself `amd64` is the same machine. See the record's own comment.
_ARTEFACT_MACHINES = {
    "x86_64": "x86_64",
    "amd64": "x86_64",
    "aarch64": "aarch64",
    "arm64": "aarch64",
}

# What an artefact may be. A closed set, because the unpack reads the archive as
# the format says it is and a format nobody has looked at is a format nobody can
# claim is unpacked safely. `raw` is the vendor publishing the program itself with
# no archive around it: there is nothing to unpack, so the reader is the identity
# and the artefact's digest and the program's are the same number.
ARTEFACT_FORMATS = ("tar.xz", "zip", "raw")

# The four fields a row must carry, and the order a diagnostic names the first
# missing one in. Both digests are required: one is the artefact's, checked before
# anything is unpacked out of it, and one is the program's, re-read on every
# `--check` because the artefact is not kept.
ARTEFACT_FIELDS = ("format", "url", "sha256", "binary_sha256")

# Every artefact this host installs a pin for, in the order the phase installs
# them. A second name here is a second pinned artefact and nothing else: the
# fetch, the digest comparison and the unpack are the functions below, and they
# take the name rather than being written once per artefact.
PINNED_ARTEFACTS = (PODLET,)

# spec 6.1: the kernel owns the public ports and nothing unprivileged binds
# below 1024. Raising the threshold to the kernel default is a tightening;
# lowering it is what grants every unprivileged uid a privileged port.
IP_UNPRIVILEGED_PORT_START = "1024"

SNAPPER_CONFIG_DIR = ("etc", "snapper", "configs")

# The host's own configuration and the subvolume it is for. `root` is the whole
# of it: spec 6.1's layout is `@` for `/` and `@var` for `/var`, and `/home` is
# inside `@` rather than a subvolume of its own. snapper snapshots a subvolume,
# so a configuration for `/home` could not be created on that layout at all, and
# `_btrfs_layout_holds()` accepting it is what let that go unnoticed until a
# real machine ran the phase.
HOST_CONFIGURATIONS = {"root": "/"}

# spec 8.1's canonical set, in the order the table gives them. A `None` is a
# value that comes from somewhere else rather than a constant.
CANONICAL: tuple[tuple[str, str | None], ...] = (
    ("EMPTY_PRE_POST_CLEANUP", "no"),
    ("NUMBER_MIN_AGE", "3600"),
    ("NUMBER_CLEANUP", "yes"),
    ("TIMELINE_CLEANUP", "yes"),
    ("TIMELINE_LIMIT_HOURLY", "0"),
    ("TIMELINE_LIMIT_DAILY", None),
    ("TIMELINE_LIMIT_WEEKLY", "0-4"),
    ("TIMELINE_LIMIT_MONTHLY", "0-6"),
    ("TIMELINE_LIMIT_QUARTERLY", "0-2"),
    ("TIMELINE_LIMIT_YEARLY", "0"),
    ("NUMBER_LIMIT", "2-10"),
    ("NUMBER_LIMIT_IMPORTANT", "8-12"),
    ("FREE_LIMIT", None),
)

# The host's own configuration converges every canonical value that is **not**
# derived from a track: spec 8.1 converges "this fixed set of values into *every*
# configuration it can see", and the two that are not constants — the daily
# bucket's maximum and the free-space floor — are read from the `[[environments]]`
# row that owns the volume. No row owns `root`, so those two are left as the
# distribution shipped them and the other eleven are held.
HOST_FIXED = tuple(key for key, value in CANONICAL if value is not None)

PACKAGED_CLEANUP = ("snapper-cleanup.timer", "snapper-cleanup.service")

# The distribution's own apt timers, which mutate the index and the package set
# on a schedule. They are the packages phase's `PACKAGED_CLEANUP`, for the reason
# ADR-0007 gives snapper's: a packaging timer running on its own schedule is the
# same overlap as any other writer, and `apt-get` does not wait for a lock it
# cannot take — two concurrent `apt-get update` runs on the golden VM, one
# succeeded and the other answered `E: Could not get lock /var/lib/apt/lists/lock`
# and exit 100 rather than blocking, so a `soil packages` that met a timer mid
# refresh would fail the run rather than queue behind it.
#
# The `.service` names are here for the same reason `PACKAGED_CLEANUP` carries
# them: they are `static`, `systemctl disable` cannot act on them, and the check
# asks for "not enabled" rather than for one exact word.
#
# **This does not disable `unattended-upgrades.service`,** which measures enabled
# and active on the golden. That unit installs security updates unattended, and
# switching it off is a security-posture decision this phase does not get to make
# on an operator's behalf; `apt-daily-upgrade.timer` is what triggers it on a
# schedule, and that is the trigger this removes. The limit is real and it is
# stated: anything that starts that service deliberately can still meet a
# `soil packages` run, and the run reports it rather than retrying.
PACKAGED_APT = (
    "apt-daily.timer",
    "apt-daily.service",
    "apt-daily-upgrade.timer",
    "apt-daily-upgrade.service",
    "dpkg-db-backup.timer",
    "dpkg-db-backup.service",
)

SYSCTL_FILE = ("etc", "sysctl.d", "90-guarden.conf")
SYSTEMD_DIR = ("etc", "systemd", "system")
APT_DIR = ("etc", "apt", "apt.conf.d")
FIREWALL_DIR = ("etc", "guarden", "firewall")
CREDS_DIR = ("etc", "guarden", "creds")
REGISTRY_DIR = ("var", "lib", "guarden", "registry")
UNITS = (
    "guarden-snapshot.service",
    "guarden-snapshot.timer",
    "guarden-pin-sync.service",
    "guarden-pin-sync.timer",
    "guarden-pins.path",
    "guarden-share-reconcile.service",
    "guarden-share-reconcile.timer",
)

# The one module whose presence makes the share reconciler's timer meaningful. A
# host with no tunnel has no route a grant could name, so enabling the timer there
# would be a unit that runs every ten minutes to warn that `[share]` is unset —
# the ambient diagnostic `be4e498` removed for `tunnel_domain`. The units are
# installed everywhere (the tree ships them) and **enabled** only with the module.
SHARE_MODULE = "cloudflared"


# --------------------------------------------------------------------------
# packages
# --------------------------------------------------------------------------


def _installed(package: str, row: dict) -> bool:
    """Whether the family's own query says so, asked with the list's argv."""
    return packagelist.is_installed(package, row)


def artefact_record_name(name: str) -> str:
    """The pin file for one artefact: `<name>.release`, in `/etc/guarden`."""
    return f"{name}{ARTEFACT_RECORD_SUFFIX}"


def artefact_record(name: str) -> tuple[str, ...]:
    return ("etc", "guarden", artefact_record_name(name))


def _artefact_record(name: str) -> dict:
    """The pin, read as TOML because it is a TOML file and a digest is quoted.

    A hand-rolled line split would compare the digest against a string carrying
    the quotes that were never part of it, and would call a correct pin a
    mismatch.
    """
    return h.read_config(hostpath(*artefact_record(name)))


def _artefact_binary(name: str) -> Path:
    return paths.BIN / name


def _machine() -> str:
    """This host's architecture, in the spelling the record's table is keyed by.

    `platform.machine()` rather than a subprocess: it is the standard library's own
    answer and `uname -m` is a second program on the path of a root converge, run
    for a string the interpreter already holds.
    """
    reported = platform.machine().lower()
    return _ARTEFACT_MACHINES.get(reported, reported)


def _artefact_pin(name: str, record: dict, record_path: Path) -> tuple[str, dict[str, str]]:
    """The version and this host's row, or a rejection naming what is missing.

    Every one of these is about the **record**, and none of them is about the
    host, which is what keeps them exit 2: the record is a repository input, and a
    pin that is unfilled, half-filled or silent about this machine is not a host
    out of state -- it is a pin nobody filled in. Each message names the key, so
    one diagnostic says which field to edit rather than that a file is incomplete.
    """
    version = str(record.get("version", "")).strip()
    if not version:
        raise IncompleteRecord(
            f"the pinned {name} record is incomplete: it names no version: {record_path}"
        )
    rows = record.get("artefacts")
    if not isinstance(rows, dict) or not rows:
        raise IncompleteRecord(
            f"the pinned {name} record is incomplete: it carries no [artefacts] table: "
            f"{record_path}"
        )
    machine = _machine()
    if machine not in rows:
        raise IncompleteRecord(
            f"the pinned {name} record is incomplete: it has no artefact for this host's "
            f"architecture ({machine}); it carries {', '.join(sorted(rows))}: {record_path}"
        )
    row = rows[machine]
    if not isinstance(row, dict):
        raise IncompleteRecord(
            f"the pinned {name} record is incomplete: [artefacts.{machine}] is not a "
            f"table: {record_path}"
        )
    for key in ARTEFACT_FIELDS:
        if not str(row.get(key, "")).strip():
            raise IncompleteRecord(
                f"the pinned {name} record is incomplete: [artefacts.{machine}] has no "
                f"{key}: {record_path}"
            )
    pin = {key: str(row[key]).strip() for key in ARTEFACT_FIELDS}
    if pin["format"] not in ARTEFACT_FORMATS:
        raise IncompleteRecord(
            f"the pinned {name} record names format {pin['format']!r} for "
            f"[artefacts.{machine}], which is not one of {', '.join(ARTEFACT_FORMATS)}: "
            f"{record_path}"
        )
    return version, pin


def _digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _fetch_artefact(name: str, fetched: Path, version: str, pin: dict[str, str]) -> None:
    """curl into the temporary, and nothing else.

    A fetch that does not happen is a **host** that is not in the state the
    request assumed -- the network, the URL and the release server are all host,
    and spec 1.2's dividing line puts the remote on that side of it. So this says
    one line naming the artefact and returns; the phase's own `--apply` then
    reports the item as drift and exits 1. It is not a rejection: nothing about
    the record is wrong, and a caller who read 2 here would go looking for a typo
    in a file that is correct.
    """
    result = h.run("curl", "--fail", "--silent", "--show-error", "--location",
                   "--output", str(fetched), pin["url"])
    if result.ok:
        return
    reason = errors.oneline(result.err.strip()) or str(result.code)
    h.error(f"fetching {name} {version} for this host: {pin['url']}: {reason}")


def _verify_artefact(name: str, fetched: Path, version: str, pin: dict[str, str],
                     record: Path) -> None:
    """The digest of the artefact as downloaded, before anything is unpacked.

    This is the whole of the pin. Nothing out of the archive is read into a file,
    renamed into place or run until it has matched, and the check is on the bytes
    that arrived rather than on anything derived from them.
    """
    found = _digest(fetched)
    if found == pin["sha256"]:
        return
    raise IncompleteRecord(
        f"{name} {version}: the SHA256 does not match {record}: the artefact fetched "
        f"from {pin['url']} is {found} and the record pins {pin['sha256']}"
    )


def _one_member(name: str, members: list, path_of, pin: dict[str, str], version: str,
                record: Path):
    """The single regular member named as the program, or a refusal naming the archive.

    Exactly one, because an archive with two members of that name is ambiguous and
    an archive with none is not the artefact the record pins. Both are one line
    naming the member that was wanted and the format the record says it is in; the
    ambiguous one names the **paths**, because two members whose basename is the
    same are not distinguishable by their basenames.
    """
    found = [
        member for member in members if PurePosixPath(path_of(member)).name == name
    ]
    if len(found) == 1:
        return found[0]
    if not found:
        raise IncompleteRecord(
            f"{name} {version}: the artefact {pin['url']} is a {pin['format']} archive "
            f"with no regular member named {name}, and {record} pins it as the "
            f"program this install puts in place"
        )
    names = ", ".join(sorted(path_of(member) for member in found))
    raise IncompleteRecord(
        f"{name} {version}: the artefact {pin['url']} is a {pin['format']} archive "
        f"with {len(found)} regular members named {name} ({names}), and {record} pins "
        f"it as the program this install puts in place"
    )


def _tar_xz_bytes(name: str, fetched: Path, pin: dict[str, str], version: str,
                  record: Path) -> bytes:
    with tarfile.open(fetched, "r:xz") as archive:
        regular = [member for member in archive.getmembers() if member.isfile()]
        member = _one_member(
            name, regular, lambda entry: entry.name, pin, version, record
        )
        stream = archive.extractfile(member)
        if stream is None:
            raise IncompleteRecord(
                f"{name} {version}: the artefact {pin['url']} carries no readable "
                f"contents for {name}, and {record} pins it as the program this "
                f"install puts in place"
            )
        with stream:
            return stream.read()


def _zip_regular(entry: zipfile.ZipInfo) -> bool:
    """Whether a zip member is a plain file carrying bytes.

    A zip says what a member **is** in the unix mode in the high half of
    `external_attr`, and that half is how a symlink is distinguishable at all:
    a zip stores a symlink as an ordinary file whose *content* is the target's
    name, so a reader that only asks `is_dir()` finds no directory, selects the
    member, and installs `/usr/lib/curl` as though it were the program. The
    record's comment says a symlink is not a candidate, and for the tar reader
    that is `isfile()` doing it; this is the zip half of the same claim.

    A zip written without unix modes leaves the high half zero, which is not a
    type anything claims, so it is a file. That is the honest default: the
    archive said nothing about the member, and refusing everything that said
    nothing would make a format guarden cannot read the one it refuses.
    """
    mode = entry.external_attr >> 16
    if mode == 0:
        return not entry.is_dir()
    return stat.S_ISREG(mode)


def _zip_bytes(name: str, fetched: Path, pin: dict[str, str], version: str,
               record: Path) -> bytes:
    with zipfile.ZipFile(fetched) as archive:
        regular = [entry for entry in archive.infolist() if _zip_regular(entry)]
        member = _one_member(
            name, regular, lambda entry: entry.filename, pin, version, record
        )
        return archive.read(member)


def _raw_bytes(name: str, fetched: Path, pin: dict[str, str], version: str,
               record: Path) -> bytes:
    return fetched.read_bytes()


ARTEFACT_UNPACK = {"tar.xz": _tar_xz_bytes, "zip": _zip_bytes, "raw": _raw_bytes}


def _unpacked_program(name: str, fetched: Path, pin: dict[str, str], version: str,
                      record: Path) -> bytes:
    """The program's bytes, and the program's bytes rather than the archive's.

    The archive is read into memory and the member is written out by `soil`, so
    **no member name is ever used as a path**: a name that is absolute and one
    that carries `..` are things this code cannot be asked about rather than
    things it checks.

    A member that is not a regular file is not a candidate, and each reader says
    so in its own vocabulary. The tar reader asks `isfile()`, which is false for a
    symlink, a hardlink, a directory, a fifo and a device alike. The zip reader
    cannot: a zip stores a symlink as an ordinary file whose content is the
    target's name, so it asks the unix mode (`_zip_regular`) — without that, an
    archive carrying a symlink named after the program installed the *path it
    pointed at* as the program, which is the exact state this install exists to
    prevent.

    A truncated or mislabelled archive is one diagnostic and not a traceback:
    every library that reads one raises its own error, and `curl` happily writes
    whatever the remote sent.
    """
    try:
        return ARTEFACT_UNPACK[pin["format"]](name, fetched, pin, version, record)
    except IncompleteRecord:
        raise
    except (OSError, EOFError, tarfile.TarError, zipfile.BadZipFile, lzma.LZMAError) as exc:
        raise IncompleteRecord(
            f"{name} {version}: the artefact fetched from {pin['url']} is not a "
            f"{pin['format']} archive this host can unpack: {errors.oneline(str(exc))}"
        ) from None


def _discard(path: Path) -> None:
    """Remove a temporary, and never raise: this runs where an install is failing.

    An exception here would replace the diagnostic that says what actually went
    wrong with an `OSError` about litter, and the exit code with it. A temporary
    that cannot be removed is worth one line and is not worth that.
    """
    try:
        path.unlink()
    except FileNotFoundError:
        return
    except OSError as exc:
        h.error(f"the temporary {path} could not be removed: {exc.strerror}")


def _packaged_apt_disabled() -> bool:
    """No distribution apt timer is enabled.

    The same predicate `_packaged_cleanup_disabled` uses and for the same reason:
    the `.service` names are `static`, so the literal word `disabled` is a
    requirement no real host can satisfy and the phase would report the same
    drift forever. Any answer that is not enabled means the timer will not fire.
    """
    for unit in PACKAGED_APT:
        if h.run("systemctl", "is-enabled", unit).line in ("enabled", "enabled-runtime"):
            return False
    return True


def packages_items(family: str | None = None) -> list[Item]:
    row = packagelist.family(family)
    items = [
        Item(
            f"the {package} package is installed",
            lambda package=package: _installed(package, row),
            lambda package=package: _install_packages([package], row),
        )
        for package in distribution_packages(family)
    ]

    # The zram generator is the substrate's exception and the reason is the
    # knob's: "absent means absent — no package". So the item is only built when
    # the operator's own configuration asks for a device, and a host that never
    # asked carries no item, installs nothing and reports nothing about zram.
    if zram.knob(h.read_config(h.config_path())) is not None:
        for package in packagelist.conditional_names(zram.PACKAGE_ROLE, family):
            items.append(
                Item(
                    f"the {package} package is installed, because this host's configuration "
                    f"asks for a zram device",
                    lambda package=package: _installed(package, row),
                    lambda package=package: _install_packages([package], row),
                )
            )

    def artefact_installed(name: str) -> bool:
        """Whether the pinned release is on this host, and it is the pinned one.

        The digest compared is the **program's**, because the artefact is not
        kept: a host that installed the pin holds one file, and the claim
        `--check` makes is about that file. The artefact's own digest is checked
        once, by the install, before anything was unpacked out of it — so this is
        not a weaker check, it is the only one that can still be asked on a host
        that fetched it weeks ago.

        An absent or unfilled record is drift and not an error: `--check` reports
        what a host does not have yet and exits 1, and refusing to answer would
        make the phase's own reporting mode unusable on the host it is for.
        """
        record = _artefact_record(name)
        if not record:
            return False
        try:
            _, pin = _artefact_pin(name, record, hostpath(*artefact_record(name)))
        except IncompleteRecord:
            return False
        binary = _artefact_binary(name)
        if not binary.is_file() or not os.access(binary, os.X_OK):
            return False
        return _digest(binary) == pin["binary_sha256"]

    def install_artefact(name: str) -> None:
        record_path = hostpath(*artefact_record(name))
        record = _artefact_record(name)
        if not record_path.is_file():
            # Absent and unfilled are different faults with different fixes, so
            # they are different messages, and both are exit 2: the record is a
            # repository input, and a record nobody filled in is not a host that
            # is out of state.
            raise IncompleteRecord(
                f"the pinned {name} record is absent: {record_path}, and `soil install` "
                f"seeds it from the template"
            )
        version, pin = _artefact_pin(name, record, record_path)
        binary = _artefact_binary(name)
        binary.parent.mkdir(parents=True, exist_ok=True)
        # A sibling of the installed program rather than a path under /tmp: its
        # digest is compared from there, before anything is unpacked out of it,
        # and a file another process could see is not where that happens.
        fetched = binary.parent / f"{name}{ARTEFACT_FETCH_SUFFIX}"
        # One lock per artefact over the read of the record, the fetch, the unpack
        # and the install, because the installed program is a file `loom` reads
        # while this replaces it: spec 3.5 says every file one process may read
        # while another writes is written that way, with no exceptions. The write
        # itself goes through `write_bytes`, which is the same protocol — a
        # temporary in the target's own directory, fsync, rename.
        with lock(name):
            try:
                _fetch_artefact(name, fetched, version, pin)
                if not fetched.is_file():
                    return
                _verify_artefact(name, fetched, version, pin, record_path)
                h.write_bytes(binary,
                              _unpacked_program(name, fetched, pin, version, record_path),
                              0o755)
            finally:
                # Both temporaries, on every path. A failed unpack must leave
                # nothing that could be mistaken for an install: the `.fetch`
                # next to the programs and `.<name>.new` beside it are both
                # plausible-looking, and the second is a rename waiting to happen.
                _discard(fetched)
                _discard(binary.parent / f".{binary.name}.new")

    return [
        *items,
        Item(
            "the distribution's own apt timers are disabled, so nothing else "
            "mutates the package index underneath this phase",
            _packaged_apt_disabled,
            lambda: [h.run("systemctl", "disable", "--now", unit) for unit in PACKAGED_APT],
        ),
        *[
            Item(f"the pinned {name} is installed, and the SHA256 of the program "
                 f"on the host is the one the record pins",
                 lambda name=name: artefact_installed(name),
                 lambda name=name: install_artefact(name))
            for name in PINNED_ARTEFACTS
        ],
    ]


def _install_packages(packages: Iterable[str], row: dict | None = None) -> None:
    """Install with the family's tool, named in the list and nowhere else.

    One package at a time, because the item that failed is the item that has to
    be reported: a single `apt-get install` of the whole list fails as a unit and
    says which of seven packages was missing only by parsing the distribution's
    prose.
    """
    for package in packages:
        h.run_or_die(*packagelist.install_argv([package], row))


def prepare_for(phase: str, family: str | None = None) -> Callable[[], None] | None:
    """The step a phase runs before any of its items, or nothing at all.

    **This is `--apply` only, and the difference is the whole of it.** A step with
    nothing to converge it against cannot be an `Item`: `--check` asks every item
    whether it already holds, and the package index is not a piece of declared
    state — there is no file of guarden's that says how fresh it is, and a check
    that reported a stale index as drift would report it on every host forever
    and every morning after. So it is a step rather than an item, and the two
    modes cannot disagree about it because only one of them has it.

    One phase has one, and it is the packages phase. An install is resolved
    against the distribution's index, so the index is refreshed first: an apply
    against an index the mirror has moved past fails on a version that exists and
    is not the one available, and the failure reads as a package problem rather
    than as the host's own view of its mirror being weeks old.
    """
    if phase == "packages":
        return lambda: _refresh_package_index(family)
    return None


# The two phases that write a unit file into the system manager's search path.
# Neither reloaded afterwards, so a unit one of them wrote was on disk and unknown
# to systemd until the next boot: ADR-0011 step 5 assumes a reload and there was
# none anywhere in `src/`.
UNIT_PHASES = ("install", "units")


def finish_for(phase: str) -> Callable[[], None] | None:
    """The step a phase runs after its items, or nothing at all.

    **`--apply` only, for the same reason `prepare_for` is: a check that
    reloaded would be a check that changed something.** A reload is not an item
    because there is no file of guarden's to compare against — "the manager has
    read the units on disk now" has no declared state behind it, and an item
    asking it would answer `false` on every host forever and never hold, so
    `--check` would report drift no apply could clear.

    It runs *after* the items rather than before, and that ordering is the whole
    of it: a reload before the phase writes its units reloads the state that
    existed before, and the units just written stay unread.
    """
    if phase in UNIT_PHASES:
        return _reload_system_manager
    return None


def _reload_system_manager() -> None:
    """`systemctl daemon-reload`, once, after a phase wrote system units.

    A unit file systemd has not read is not a unit: the manager answers
    `not-found` for it, so the oneshot the path unit triggers never appears and
    a boot-time materialisation silently does not happen. The reload is what
    makes the converge mean what it says.

    Not fatal, and the reason is the host. A manager that cannot be reached is
    not a reason to refuse a converged install, and the items above it already
    reported whatever they could not converge; this one line says the reload
    did not happen so an operator is not told a unit is wanted when the manager
    has never heard of it.
    """
    result = h.run("systemctl", "daemon-reload")
    if not result.ok:
        detail = result.err.strip().splitlines()
        h.warn(
            "systemctl daemon-reload did not succeed, so the units this phase "
            "wrote are not read by the system manager: "
            + (detail[0] if detail else f"exit {result.code}")
        )


def _refresh_package_index(family: str | None) -> None:
    """Run the family's own refresh argv, from the list, once, before the installs.

    **The two failures here are different things and carry different codes.** An
    argv the list does not carry is a repository input nobody filled in, and it is
    exit `2`; a refresh that runs and fails is a host that cannot reach its own
    mirror, and it is exit `1` (spec 1.2's dividing line: the list is input, the
    mirror is the host). Getting that backwards would tell an operator to edit a
    file in this repository when the thing to fix is the network.
    """
    row = packagelist.family(family)
    argv = packagelist.update_argv(row)
    if not argv:
        raise errors.GuardenError(
            f"the package list at {packagelist.list_path()} carries no update argv for this "
            f"family, and an install is resolved against the distribution's index: an install "
            f"against an index nothing refreshed is a converge that fails on a version the "
            f"mirror has moved past",
            errors.REJECTED_INPUT,
        )
    result = h.run(*argv)
    if result.ok:
        return
    reason = result.err.strip().splitlines()
    raise errors.GuardenError(
        f"the package index could not be refreshed: {argv[0]} {' '.join(argv[1:])}: "
        f"{reason[0] if reason else result.code}, so nothing is installed against it",
        errors.HOST_NOT_AS_ASSUMED,
    )


class IncompleteRecord(Exception):
    """A pinned artefact guarden cannot install because its record is not filled in."""


# --------------------------------------------------------------------------
# storage
# --------------------------------------------------------------------------


def _subvolumes() -> list[str]:
    result = h.run("btrfs", "subvolume", "list", "/")
    if not result.ok:
        return []
    return [line.split()[-1] for line in result.out.splitlines() if line.strip()]


def _btrfs_layout_holds() -> bool:
    layout = _subvolumes()
    return "@" in layout and "@var" in layout


def _boot_is_ext4() -> bool:
    result = h.run("findmnt", "-no", "FSTYPE", "/boot")
    if not result.ok:
        # No separate /boot is the ordinary case and there is then nothing to
        # keep on ext4.
        return True
    return result.line == "ext4"


def _converged(values: dict[str, str], desired: dict[str, str]) -> bool:
    return all(values.get(key) == value for key, value in desired.items())


def _snapper_values(name: str) -> dict[str, str]:
    # snapper 0.10.6 renders `get-config` as a two-column table:
    #
    #     Key                    | Value
    #     -----------------------+------
    #     EMPTY_PRE_POST_CLEANUP | no
    #
    # with a header row, a rule row and padded empty values.
    result = h.run("snapper", "-c", name, "get-config")
    values: dict[str, str] = {}
    for line in result.out.splitlines():
        key, sep, value = line.partition("|")
        key = key.strip()
        if not sep or not key or key == "Key" or set(key) == {"-"}:
            continue
        values[key] = value.strip()
    return values


def _write_snapper(name: str, values: dict[str, str]) -> None:
    """Hand back the converged set and let snapper merge it.

    spec 8.1: the effective configuration is read with `get-config` and never by
    parsing /etc/snapper/configs/<name>, and the converged set is applied to what
    is already there rather than replacing it.

    `set-config` merges: it rewrites the keys it is given and leaves every other
    key in the configuration alone. That is the property this depends on, and it
    is measured rather than assumed — one key set leaves the other twenty-four
    exactly as they were.

    **It is handed only the converged keys, never the whole configuration read
    back.** Two reasons, and the first is the tool's: snapper 0.10.6 **refuses**
    `SUBVOLUME` and `FSTYPE` with `Invalid configdata` and exit `1`, because those
    two are what `create-config` established and the daemon will not have them
    rewritten. A read-modify-write therefore hands back two keys that cannot be
    written and fails on every configuration it converges, whatever else is in the
    set — an empty `ALLOW_USERS=` beside them is accepted and is not the fault.
    The second is spec §8.1's own: the phase converges a fixed set of values and
    **rewrites nothing else**, so the keys it did not come for are not its to
    send back.

    `modify` is not the verb for a configuration at all — it modifies a
    *snapshot*, by number — and it has no `-f`.
    """
    h.run_or_die("snapper", "-c", name, "set-config",
                 *[f"{k}={v}" for k, v in sorted(values.items())])


def _registry_services() -> list[str]:
    registry = hostpath(*REGISTRY_DIR)
    if not registry.is_dir():
        return []
    return sorted(path.stem for path in registry.glob("*.toml"))


def _service_for_configuration(name: str, services: list[str]) -> str | None:
    """The registry entry a configuration belongs to, or None.

    A configuration's name is opaque and nothing parses it, so the match is
    made against the actual registry entries rather than by splitting on `-`:
    the longest service name the configuration starts with wins, which is
    unambiguous for `myapp` and `myapp-preview` both being services. An
    instance's configuration is `<service>-<escaped-ref>-<volume>` and matches the
    same way.
    """
    matches = [service for service in services if name.startswith(f"{service}-")]
    if not matches:
        return None
    return max(matches, key=len)


def _retention_for(service: str, config: dict) -> tuple[int, str, dict[str, str]]:
    """`keep_last`, `free_limit` and the other buckets for a service's volumes.

    The service's own overrides win over the track's defaults, spec 3.3, and the
    ladder's other buckets are per-volume for the same reason: `keep_last = 0`
    turns off the daily bucket only, and an operator who wants a track to keep
    nothing sets them here.
    """
    registry = h.read_config(hostpath(*REGISTRY_DIR, f"{service}.toml"))
    row = h.track(config, registry.get("environment", ""))
    keep_last = int(row.get("keep_last", 0)) if row else 0
    free_limit = str(row.get("free_limit", "0.20")) if row else "0.20"
    buckets = {"weekly": "4", "monthly": "6", "quarterly": "2"}

    overrides = h.read_config(hostpath("etc", "guarden", "services", service, "overrides.toml"))
    retention = overrides.get("retention", {})
    if "keep_last" in retention:
        keep_last = int(retention["keep_last"])
    if "free_limit" in retention:
        free_limit = str(retention["free_limit"])
    for bucket in buckets:
        if bucket in retention:
            buckets[bucket] = str(retention[bucket])
    return keep_last, free_limit, buckets


def _desired_for(name: str, config: dict) -> dict[str, str]:
    service = _service_for_configuration(name, _registry_services())
    if service is None:
        return {key: value for key, value in CANONICAL if key in HOST_FIXED and value}

    keep_last, free_limit, buckets = _retention_for(service, config)
    derived = {
        "TIMELINE_LIMIT_HOURLY": "0",
        "TIMELINE_LIMIT_DAILY": f"0-{keep_last}",
        "TIMELINE_LIMIT_WEEKLY": f"0-{buckets['weekly']}",
        "TIMELINE_LIMIT_MONTHLY": f"0-{buckets['monthly']}",
        "TIMELINE_LIMIT_QUARTERLY": f"0-{buckets['quarterly']}",
        "TIMELINE_LIMIT_YEARLY": "0",
        "FREE_LIMIT": free_limit,
    }
    return {
        key: derived.get(key, value)
        for key, value in CANONICAL
        if value is not None or key in derived
    }


def _create_configuration(name: str) -> None:
    # The subvolume is positional. snapper 0.10.6 has no `-p` for create-config
    # and answers "Unknown option '-p'", which a fake built to match this call
    # hid: the fake accepted the flag because the code used it.
    h.run_or_die("snapper", "-c", name, "create-config", "-f", "btrfs",
                 HOST_CONFIGURATIONS[name])


def _configuration_exists(name: str) -> bool:
    """Whether snapper holds a configuration, asked the way spec 8.1 reads one.

    `get-config` and never a stat of /etc/snapper/configs/<name>: the effective
    configuration is snapper's answer, and a converger that believed its own
    file was the configuration would converge a file nothing reads.
    """
    return h.run("snapper", "-c", name, "get-config").ok


def _configurations_on_disk() -> list[str]:
    """Every configuration name snapper's directory carries, guarden's or not.

    This is the only place soil looks inside that directory, and it looks at the
    names alone: the values come from `get-config` and the track comes from the
    registry, because a configuration's name is opaque and nothing parses it.
    """
    directory = hostpath(*SNAPPER_CONFIG_DIR)
    if not directory.is_dir():
        return []
    return sorted(path.name for path in directory.iterdir() if path.is_file())


def _visible_configurations() -> list[str]:
    return sorted(set(HOST_CONFIGURATIONS) | set(_configurations_on_disk()))


def _cleanup_unit_holds() -> bool:
    installed = hostpath(*SYSTEMD_DIR, "guarden-snapper-cleanup.service")
    return installed.is_file() and installed.read_text(encoding="utf-8") == _cleanup_unit(
        _visible_configurations()
    )


def _cleanup_unit(configurations: list[str]) -> str:
    """One ExecStart per configuration, each taking the snapshots lock.

    The unit is rendered rather than shipped because the set of configurations
    is a fact about the host, and a shipped unit would have to name them. The
    lock is the reason the unit exists at all: spec 8.5, snapper takes none that
    `snapper modify` participates in and its cleaner reuses one reference to the
    snapshot list across all three passes.
    """
    lines = [
        "[Unit]",
        "Description=guarden snapshot cleanup",
        "Documentation=file:///usr/share/doc/guarden/",
        "Requires=snapperd.service",
        "After=snapperd.service",
        "",
        "[Service]",
        "Type=oneshot",
    ]
    if not configurations:
        lines.append("# No snapper configuration on this host yet.")
    for name in configurations:
        for algorithm in ("number", "timeline", "space"):
            lines.append(
                f"ExecStart=/usr/bin/flock -w 30 /run/guarden/locks/snapshots.lock "
                f"/usr/bin/snapper -c {name} cleanup {algorithm}"
            )
    return "\n".join(lines) + "\n"


def _packaged_cleanup_disabled() -> bool:
    """The packaged cleaner must not be enabled.

    `snapper-cleanup.service` is a `static` unit: `systemctl is-enabled` answers
    "static" for it and `systemctl disable` refuses to act on it at all. Asking
    for the literal word "disabled" of every name in PACKAGED_CLEANUP is a check
    no real host can satisfy, so the phase reported the same drift forever. Any
    answer that is not enabled is fine — disabled, static and masked all mean the
    distribution's cleaner will not run.
    """
    for unit in PACKAGED_CLEANUP:
        if h.run("systemctl", "is-enabled", unit).line in ("enabled", "enabled-runtime"):
            return False
    return True


def storage_items() -> list[Item]:
    config = h.read_config(h.config_path()) or h.shipped_config()
    items: list[Item] = [
        Item(
            "btrfs with the @ and @var subvolumes",
            _btrfs_layout_holds,
            lambda: h.error("btrfs has no @ and @var subvolume: convert the root "
                            "filesystem before running this phase again"),
        ),
        Item(
            "/boot is on ext4, so the kernel keeps booting after a btrfs conversion",
            _boot_is_ext4,
            lambda: h.error("/boot is not on ext4: /boot shares the filesystem that "
                            "becomes btrfs and the next boot would not find a kernel"),
        ),
        *[
            h.directory_item(
                f"/{'/'.join(parts)} is {mode:04o} {owner}:{group}",
                hostpath(*parts), mode, owner, group,
            )
            for parts, mode, owner, group in STORAGE_DIRECTORIES
        ],
        h.text_item(
            "the package hook snapshots root before every transaction",
            hostpath(*APT_DIR, "80guarden-snapper"),
            _template("80guarden-snapper"),
        ),
        Item(
            "the distribution's snapper cleanup timer is disabled",
            _packaged_cleanup_disabled,
            lambda: [h.run("systemctl", "disable", "--now", unit) for unit in PACKAGED_CLEANUP],
        ),
        h.text_item(
            "the snapper cleanup timer is installed",
            hostpath(*SYSTEMD_DIR, "guarden-snapper-cleanup.timer"),
            _template("guarden-snapper-cleanup.timer"),
        ),
        Item(
            "the snapper cleanup oneshot takes the snapshots lock, once per configuration",
            lambda: _cleanup_unit_holds(),
            lambda: h.write_file(
                hostpath(*SYSTEMD_DIR, "guarden-snapper-cleanup.service"),
                _cleanup_unit(_visible_configurations()),
                0o644,
            ),
        ),
        Item(
            "the convert state and the reboot marker directory",
            lambda: hostpath("var", "lib", "guarden", "soil").is_dir(),
            lambda: h.install_directory(hostpath("var", "lib", "guarden", "soil"), 0o750,
                                        "root", "guarden"),
        ),
    ]

    for name in sorted(HOST_CONFIGURATIONS):
        items.append(
            Item(
                f"the {name} snapper configuration exists",
                lambda name=name: _configuration_exists(name),
                lambda name=name: _create_configuration(name),
            )
        )

    # Every configuration soil can see: the host's own two, and whatever else
    # the directory carries. The existence item above has already created the
    # first two by the time this converges them, because `--apply` walks the
    # list in order and re-checks each item.
    for name in _visible_configurations():
        if name in HOST_CONFIGURATIONS:
            desired = {k: v for k, v in CANONICAL if k in HOST_FIXED}
        elif _service_for_configuration(name, _registry_services()) is None:
            # spec 8.1's third case, and it is a warning rather than a skip in
            # silence: a rule that skipped whatever it did not recognise would
            # silently drop a configuration the operator owns.
            h.warn(f"the snapper configuration {name} is not guarden's; left alone")
            continue
        else:
            desired = _desired_for(name, config)
        items.append(
            Item(
                f"the snapper configuration {name} carries the canonical values",
                lambda name=name, desired=desired: _converged(_snapper_values(name), desired),
                lambda name=name, desired=desired: _converge_configuration(name, desired),
            )
        )
    return items


def _converge_configuration(name: str, desired: dict[str, str]) -> None:
    # The converged keys and nothing else. Reading the whole configuration back
    # and handing it to `set-config` again looks like the polite thing to do and
    # is what put `SUBVOLUME` and `FSTYPE` in an argv snapper refuses; see
    # `_write_snapper`, and spec 8.1's "rewrites nothing else in them".
    with lock("snapshots"):
        _write_snapper(name, desired)


def _template(name: str) -> str:
    return h.template(name)


# --------------------------------------------------------------------------
# sysctl
# --------------------------------------------------------------------------


def _sysctl_value(key: str) -> str:
    return h.run("sysctl", "-n", key).line


def _sysctl_items() -> list[Item]:
    config = h.read_config(h.config_path()) or h.shipped_config()
    interface = h.ingress_interface(config)
    wanted: list[tuple[str, str]] = [
        ("net.ipv4.ip_unprivileged_port_start", IP_UNPRIVILEGED_PORT_START),
        ("net.ipv6.conf.all.disable_ipv6", "1"),
        ("net.ipv6.conf.default.disable_ipv6", "1"),
    ]
    if zram.knob(config) is not None:
        # `vm.swappiness` is in the canonical set rather than beside it, and it
        # is here **only when the knob is**, for the reason the rest of the phase
        # is "never from a manifest" in reverse: a zram device is faster than a
        # disk swap, so the kernel's default of 60 would keep preferring the disk
        # and leave the device idle. Absent means absent down to the last sysctl,
        # so a host with no device does not get soil writing a knob that only
        # means something when the device exists. The value is guarden's and not
        # the operator's: it is a property of having a compressed device at all,
        # and one knob an operator cannot state is one knob they cannot break.
        wanted.append(("vm.swappiness", zram.SWAPPINESS))
    if interface:
        # Scoped to the ingress interface and never to conf.all: the deny is
        # scoped to one interface because a packet DNATed to 127.0.0.1 that
        # arrives on any other interface is a martian, and the key that stops
        # that is per-interface.
        wanted.insert(0, (f"net.ipv4.conf.{interface}.route_localnet", "1"))

    items = []
    for key, desired in wanted:
        items.append(
            h.value_item(
                f"{key} is {desired}",
                lambda key=key: _sysctl_value(key),
                desired,
                lambda key=key, desired=desired: _set_sysctl(key, desired),
            )
        )

    persisted = _sysctl_file_content(wanted)
    items.append(
        h.text_item(
            f"{'/' + '/'.join(SYSCTL_FILE)} persists soil's keys and nothing else",
            hostpath(*SYSCTL_FILE),
            persisted,
        )
    )
    return items


def _set_sysctl(key: str, value: str) -> None:
    h.run_or_die("sysctl", "-w", f"{key}={value}")


def _sysctl_file_content(wanted: list[tuple[str, str]]) -> str:
    lines = [
        "# Written by soil sysctl. Every key here is one soil converges, and a",
        "# key in this file that soil does not own is a key soil will delete.",
    ]
    lines.extend(f"{key} = {value}" for key, value in wanted)
    return "\n".join(lines) + "\n"


def sysctl_items() -> list[Item]:
    items = _sysctl_items()
    # The two invariants and the alias are reported, never corrected: an operator
    # who set a sysctl on purpose is not a machine to argue with, and either
    # fact puts the box outside what the golden VM proved. Only the port
    # threshold is soil's to converge, and it is converged by the item above.
    recorded = h.read_config(h.config_path()).get("ingress", {}).get("alias", "")
    if recorded:
        # The remedy is in the drift line rather than in the apply, because the
        # line is what an operator reads: the fix is to re-measure with the
        # probe, never to edit the file by hand.
        items.append(
            Item(
                f"ingress.alias is the address the default route resolves to "
                f"({recorded}); re-run `soil install --apply` so the probe re-measures it",
                lambda recorded=recorded: h.default_route_gateway() == recorded,
                lambda: None,
                correctable=False,
            )
        )
    else:
        h.warn("ingress.alias is empty: `soil install --apply` measures it, and the "
               "edge does not start without it")
    return items


# --------------------------------------------------------------------------
# firewall
# --------------------------------------------------------------------------

                                                                          
                                                            
FRAMEWORK_CHAIN = "guarden-in"
# The SSH accept chain - separate so the operator can edit the port without
# it being overwritten. 00-ssh.conf is seed-once, mode 0600 root:root.
SSH_CHAIN = "guarden-ssh"

# What `iptables --version` prints for each variant. Measured on the golden:
# `iptables v1.8.11 (nf_tables)` and `iptables v1.8.11 (legacy)`.
_VARIANT_MARKERS = {"legacy": "(legacy)", "nft": "(nf_tables)"}


def _host_variant(family: str | None = None) -> str:
    """Which variant the host's own iptables is, or its raw version line."""
    result = h.run(*packagelist.variant_argv("report", family))
    if not result.ok:
        return ""
    reported = result.line.lower()
    for variant_name, marker in _VARIANT_MARKERS.items():
        if marker in reported:
            return variant_name
    return result.line


def _variant_selected(family: str | None = None) -> bool:
    return _host_variant(family) == packagelist.variant_name(family)


def _select_variant(family: str | None = None) -> None:
    """Point the host's own iptables at the variant the list states.

    Necessary but NOT sufficient, which is the whole of this note's finding: ferm
    2.7 does not use the alternatives system. `find_tool` in the ferm binary
    matches `^(.*tables)(.*)$` and prefers `$1-legacy$2` across `/usr/sbin`,
    `/sbin` and `$PATH`, so the list states the variant ferm WRITES rather than
    the one an operator is used to. `_rendered_rules_readable` is what proves the
    two agree.
    """
    argv = packagelist.variant_argv("set", family)
    if not argv:
        h.error("the package list states no argv that selects the iptables variant, so "
                "nothing was selected")
        return
    result = h.run(*argv)
    if result.ok:
        return
    reason = result.err.strip().splitlines()
    h.error(f"{argv[0]} {' '.join(argv[1:])}: "
            f"{reason[0] if reason else result.code}, so this host still names an iptables "
            f"variant guarden did not choose")


def _rendered_rules_readable(family: str | None = None) -> bool:
    """Whether `iptables` names guarden's own chain on this host.

    Asked of the rules and never of the alternatives: alternatives records which
    variant `/usr/sbin/iptables` NAMES, ferm decides which one it WRITES, and
    only this answers "where is the firewall".

    An absent chain is not claimed as a mismatch — the unit may simply never have
    run — so this holds only on a positive answer and the unit item reports the
    rest.
    """
    return h.run("iptables", "-S", "guarden-in").ok


def _firewall_applied(family: str | None = None) -> bool:
    """The unit is holding the box AND the chain is readable. One item, both halves.

    An `active (exited)` unit over an absent chain is a converge that reported
    success and stopped nothing. The unit is asked first because the chain cannot
    exist without it, so a stopped unit reads as "nothing to judge" rather than
    as a mismatch.
    """
    if h.run("systemctl", "is-active", "guarden-firewall.service").line != "active":
        return False
    return _rendered_rules_readable(family)


def _ssh_conf_path() -> Path:
    return hostpath(*FIREWALL_DIR, "00-ssh.conf")


def _ssh_conf_exists() -> bool:
    """Check that 00-ssh.conf exists, is mode 0600, and owned root:root."""
    path = _ssh_conf_path()
    if not path.is_file():
        return False
    try:
        stat = path.stat()
        if (stat.st_mode & 0o777) != 0o600:
            return False
        if stat.st_uid != 0 or stat.st_gid != 0:
            return False
    except OSError:
        return False
    return True


def _seed_ssh_conf() -> None:
    """Seed 00-ssh.conf only on first-ever apply. Never recreate if deleted later."""
    path = _ssh_conf_path()
    if path.is_file():
        # File exists (possibly edited by operator) - seed-once: do not overwrite
        return
    
    # Check if this is the first apply by looking for other firewall files
    # If 10-framework.conf exists, this is not the first apply - the file was deleted
    framework_path = hostpath(*FIREWALL_DIR, "10-framework.conf")
    if framework_path.is_file():
        # Firewall has been applied before but 00-ssh.conf is missing - do not recreate
        # This will cause verification to fail
        return
    
    # First ever apply - create the file
    path.parent.mkdir(parents=True, exist_ok=True)
    from guarden import conf
    conf.write_file(path, _ssh_conf(), 0o600, (0, 0))


def _verify_ssh_accept_position() -> bool:
    """
    Verify at apply time that:
    1. 00-ssh.conf exists, mode 0600, owned root:root
    2. The first rule of INPUT after conntrack+lo is 'jump guarden-ssh'
    3. The first rule of guarden-ssh is 'proto tcp dport XXXX jump ACCEPT;' (any port)

    This is the whole point: do not trust position, verify it as root at apply time.
    A missing, mis-owned, or reordered file must fail loudly.
    """
    # 1. Check file exists with correct mode and ownership
    if not _ssh_conf_exists():
        return False

    path = _ssh_conf_path()
    try:
        content = path.read_text(encoding="utf-8")
    except OSError:
        return False

    # Check guarden-ssh chain has an accept as first rule (any port)
    lines = content.splitlines()
    in_ssh_chain = False
    first_rule_in_ssh_chain = None
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("chain guarden-ssh {"):
            in_ssh_chain = True
            continue
        if in_ssh_chain:
            if stripped == "}":
                break
            if stripped and not stripped.startswith("#"):
                first_rule_in_ssh_chain = stripped
                break

                                                             
    if not first_rule_in_ssh_chain or not first_rule_in_ssh_chain.startswith("proto tcp dport ") or not first_rule_in_ssh_chain.endswith(" jump ACCEPT;"):
        return False

    # Now check the assembled ruleset via ferm --shell /dev/null
    # We need to verify the first rule in INPUT after conntrack+lo is 'jump guarden-ssh'
    # The framework file is 10-framework.conf which we control
    framework_path = hostpath(*FIREWALL_DIR, "10-framework.conf")
    if not framework_path.is_file():
        return False

    try:
        framework_content = framework_path.read_text(encoding="utf-8")
    except OSError:
        return False

    lines = framework_content.splitlines()
    in_input = False
    found_conntrack = False
    found_lo = False
    found_ssh_jump = False
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("chain INPUT {"):
            in_input = True
            continue
        if in_input:
            if stripped == "}":
                break
            if stripped and not stripped.startswith("#"):
                if not found_conntrack:
                    if stripped.startswith("mod conntrack ctstate"):
                        found_conntrack = True
                        continue
                    return False
                if not found_lo:
                    if stripped.startswith("if lo"):
                        found_lo = True
                        continue
                    return False
                if not found_ssh_jump:
                    if stripped == f"jump {SSH_CHAIN};":
                        found_ssh_jump = True
                        continue
                    return False
                # After finding the ssh jump, we can stop checking order
                break

    if not (found_conntrack and found_lo and found_ssh_jump):
        return False

    return True


def _module_ingress() -> list[tuple[str, str, str]]:
    """The enabled modules' declared ingress, each with the publication it lands on.

    `(port, protocol, publication)`, in the order the modules declare it. The
    publication is read from the service's registry rather than assumed,
    because it is allocated from `ingress.publication_range` and no number in
    this design is fixed; the registry key is the **entrypoint**, so `80/tcp`
    and `443/tcp` land on two different entrypoints' publications and only
    `443/udp` shares `443/tcp`'s.

    A module whose service is not installed yet contributes nothing, which is
    what "a fresh host has no ingress" means, and a module whose declared
    entrypoint has no allocated publication yet is the same case: the edge is
    being created and the nat rules arrive with the next converge.
    """
    config = h.read_config(h.config_path()) or h.shipped_config()
    found: list[tuple[str, str, str]] = []
    for module in [str(name) for name in config.get("modules", {}).get("enabled", [])]:
        where = paths.MODULES / module / "module.toml"
        if not where.is_file():
            continue
        document = h.read_config(where)
        for entry in document.get("services", []):
            service = str(entry.get("service", ""))
            record = h.read_config(hostpath(*REGISTRY_DIR, f"{service}.toml"))
            publications = record.get("publication") or {}
            if not isinstance(publications, dict):
                continue
            for value in entry.get("ingress", []):
                endpoint, _, number = str(value).partition(":")
                port, _, protocol = number.partition("/")
                publication = publications.get(endpoint.strip())
                if publication:
                    found.append((port, protocol, str(publication)))
    return found


def _ingress_nat(interface: str, ingress: list[tuple[str, str, str]]) -> str:
    """The edge's forwarding rules, and nothing else.

    Three of them, because `443/udp` is a different protocol and a different
    nat rule. There is no POSTROUTING masquerade here and there must never be
    one: after the PREROUTING translation the destination is local, so the
    packet goes to INPUT and never reaches POSTROUTING, and a masquerade
    written as `-d 127.0.0.1 --dport <pub>` matches no packet in either
    direction. The whole requirement is route_localnet on the ingress interface.
    """
    lines = [
        "# Written by soil firewall, and by nothing else. A module change converges",
        "# this by calling `soil firewall --apply`, never by writing the file.",
        "#",
        "# A forwarded port is a PREROUTING DNAT and nothing else. There is no",
        "# POSTROUTING masquerade: the destination is local after the translation,",
        "# so the packet is delivered to INPUT and never reaches POSTROUTING, and",
        "# conntrack rewrites the reply's source to the public address dialled.",
        "#",
        "# Only DNAT, never REDIRECT: redirect rewrites the destination to the",
        "# incoming interface's own address, and the edge listens on loopback only.",
        "",
        "table nat",
        "chain PREROUTING {",
        "",
    ]
    for port, protocol, publication in ingress:
        lines.append(
            f"    if {interface} proto {protocol} dport {port} "
            f"DNAT to 127.0.0.1:{publication};")
    lines.append("}")
    return "\n".join(lines) + "\n"


def _ssh_conf() -> str:
    """The SSH accept chain in its own file, seed-once, mode 0600 root:root."""
    return "\n".join([
        "# Written by soil firewall. The SSH accept chain, separate from the",
        "# framework so the operator can edit the port without it being overwritten.",
        "#",
        "# This file is SEED-ONCE: soil install writes it only if absent. It must",
        "# NEVER overwrite an existing file, because the operator may have edited",
        "# the port to a non-standard one. Re-running soil install must not wipe",
        "# that edit.",
        "#",
        "# Mode 0600, owner root:root. ferm loads it as root, and",
        "# firewall.installed() reads every root-owned *.conf, this one included",
        "# (8c78126). It is deliberately tighter than every other config file in",
        "# the tree (which are root:guarden 0640). 0600 is an existing convention",
        "# here -- see credentials.py BLOB_MODE.",
        "",
        "table filter",
        f"chain {SSH_CHAIN} {{",
        "    proto tcp dport 22 jump ACCEPT;",
        "}",
        "",
    ]) + "\n"


def _framework(interface: str) -> str:
    return "\n".join(
        [
            "# Written by soil firewall. The ferm skeleton: the policy baseline and",
            "# the ingress interface's route_localnet.",
            "#",
            "# The per-service filter set and any service's own forwarding are in",
            "# 50-services.conf, which the mutator writes and which is disjoint from",
            "# this file and from 20-ingress-nat.conf. Each has exactly one writer.",
            "#",
            "# guarden-in is declared here and jumped to above INPUT's own drop, and",
            "# 50-services.conf fills it. The chain and the jump are skeleton: no",
            "# port, no protocol and no grant appears in this file, and a grant",
            "# cannot reach anything here.",
            "#",
            f"# route_localnet is scoped to {interface} alone, and is persisted in",
            "# /etc/sysctl.d/90-guarden.conf. Without it the kernel treats a packet",
            "# addressed to 127.0.0.1 that arrived on a non-loopback interface as a",
            "# martian and drops it, which is the whole reason the forwarding works.",
            "#",
            "# SSH access is guaranteed structurally: 00-ssh.conf is root-owned and",
            "# seed-once, its accept is the first rule of its own chain, and",
            "# `soil firewall --apply` refuses to load a ruleset in which that is not",
            "# true. There is no lockout failsafe and no timer; this is the guarantee.",
            "",
            "table filter",
            f"chain {FRAMEWORK_CHAIN} {{",
            "}",
            "",
            "table filter",
            "chain INPUT {",
            "    mod conntrack ctstate (ESTABLISHED RELATED) jump ACCEPT;",
            "    if lo jump ACCEPT;",
            f"    jump {SSH_CHAIN};",
            "    proto tcp dport 443 jump ACCEPT;",
            "    proto udp dport 443 jump ACCEPT;",
            f"    jump {FRAMEWORK_CHAIN};",
            "    jump DROP;",
            "}",
            "",
        ]
    ) + "\n"


def _admin_dropin() -> str:
    """The admin/module drop-in file for extra firewall rules.

    This file is managed by soil when firewall.admin_dropin is enabled.
    Admins and modules may add rules here that will be loaded by ferm.
    """
    return "\n".join(
        [
            "# Written by soil firewall. Admin/module drop-in for extra firewall rules.",
            "#",
            "# This file is installed when [firewall] admin_dropin = true (the default).",
            "# An admin may edit this file directly, or a module may add rules during install.",
            "# Rules in this file are loaded by ferm between 20-ingress-nat.conf and 50-services.conf.",
            "#",
            "# The file is owned by root:guarden with mode 0640. Edit with care --",
            "# changes here take effect on the next `soil firewall --apply` or when",
            "# guarden-firewall.service reloads.",
            "",
            "# Example rule (uncomment and modify):",
            "# table filter",
            "# chain guarden-svc {",
            "#     mod owner uid-owner 1001 daddr 127.0.0.1 proto tcp dport 20123 jump ACCEPT;",
            "# }",
        ]
    ) + "\n"


def firewall_items(family: str | None = None) -> list[Item]:
    config = h.read_config(h.config_path()) or h.shipped_config()
    interface = h.ingress_interface(config)
    items: list[Item] = [
        *[
            h.text_item(f"/{unit} is installed", hostpath(*SYSTEMD_DIR, unit),
                        _template(unit), 0o644)
            for unit in ("guarden-firewall.service",)
        ],
        # 00-ssh.conf is seed-once: write only if absent, mode 0600 root:root.
        # The operator may edit the port; re-running soil install must not wipe that edit.
        Item(
            "00-ssh.conf exists and is mode 0600 root:root",
            lambda: _ssh_conf_exists(),
            lambda: _seed_ssh_conf(),
            correctable=False,
        ),
        h.text_item(
            "10-framework.conf carries the skeleton and the ingress interface's "
            "route_localnet",
            hostpath(*FIREWALL_DIR, "10-framework.conf"),
            _framework(interface),
        ),
        h.text_item(
            "20-ingress-nat.conf carries one PREROUTING DNAT per forwarded port and "
            "no POSTROUTING masquerade",
            hostpath(*FIREWALL_DIR, "20-ingress-nat.conf"),
            _ingress_nat(interface, _module_ingress()),
        ),
    ]

    # The drop-in is on by default and is a table in guarden.toml, so it is read
    # from the same dict every other table is read from. An admin who turns it
    # off is saying "no sibling files in the firewall directory", which is a
    # legitimate posture for a host that wants the directory to be guarden's
    # alone.
    if config.get("firewall", {}).get("admin_dropin", True):
        items.append(
            h.text_item(
                "30-admin.conf carries admin/module firewall drop-in rules",
                hostpath(*FIREWALL_DIR, "30-admin.conf"),
                _admin_dropin(),
            )
        )
    # Ordering, not a filter: the variant is selected before the unit starts,
    # because starting it is what makes ferm resolve the binary and load the
    # policy. The readability check follows the start, because before it there
    # is nothing to read.
    items.append(
        Item(
            f"this host's own iptables is the {packagelist.variant_name(family)} variant "
            f"guarden converges, so an operator's `iptables -S` reads the rules ferm writes",
            lambda: _variant_selected(family),
            lambda: _select_variant(family),
        )
    )
    items.append(
        Item(
            "guarden-firewall.service is enabled, and is running with guarden's rules "
            "readable through this host's own iptables rather than in another table",
            lambda: _firewall_applied(family),
            lambda: h.run_or_die("systemctl", "enable", "--now",
                                 "guarden-firewall.service") and None,
        ),
    )

    # Apply-time verification: refuse to apply unless 00-ssh.conf is present,
    # mode 0600, owned root:root, and the first rule of INPUT is the jump to
    # guarden-ssh, and the first rule of guarden-ssh is the SSH accept.
    # This is the whole point -- do not trust position, verify it as root at
    # apply time. A missing, mis-owned or reordered file must fail loudly
    # rather than silently load a ruleset that can lock someone out.
    def _verify_and_raise() -> None:
        if not _verify_ssh_accept_position():
            h.error("apply-time verification failed: 00-ssh.conf position check failed")
            from guarden import errors
            raise errors.GuardenError(
                "apply-time verification failed: 00-ssh.conf position check failed",
                errors.HOST_NOT_AS_ASSUMED,
            )

    items.append(
        Item(
            "00-ssh.conf is first in INPUT and its accept is first in guarden-ssh",
            lambda: _verify_ssh_accept_position(),
            _verify_and_raise,
            correctable=False,
        )
    )
    return items


# --------------------------------------------------------------------------
# install
# --------------------------------------------------------------------------

_PROGRAMS = ("soil", "weedr", "loom", "roots", "twig", "furrow", "hose", "stakes")

# The interpreter line the installed programs carry. The programs are modules in
# the checkout (spec 11: a Python module with a `main`, exposed as a console
# script, and no shell entry point), and a module has no shebang because nothing
# executes it directly. The *installed* copy is executed directly, through
# spec 2's `/usr/bin` symlink, and a symlink to a file with no interpreter line
# is a link to something the kernel cannot run.
SHEBANG = "#!/usr/bin/env python3"

# Inserted after the docstring and any `__future__` line: without it an installed
# program cannot import its own package when PYTHONPATH is not inherited.
BOOTSTRAP = (
    "import sys, pathlib\n"
    "_guarden_lib = pathlib.Path(__file__).resolve().parent.parent / 'lib'\n"
    "sys.path.insert(0, str(_guarden_lib if (_guarden_lib / 'guarden').is_dir()\n"
    "                      else pathlib.Path(__file__).resolve().parent.parent))\n"
)


def _with_bootstrap(body: str) -> str:
    """The module's own text, able to import the package it ships beside."""
    lines = body.split("\n")
    at = 0
    if lines and lines[0].startswith('"""'):
        at = 1
        while at < len(lines) and not lines[at].rstrip().endswith('"""'):
            at += 1
        at += 1
    while at < len(lines) and (
        not lines[at].strip() or lines[at].startswith(("from __future__", "#"))
    ):
        at += 1
    head, tail = "\n".join(lines[:at]), "\n".join(lines[at:])
    return f"{head}\n{BOOTSTRAP}\n{tail}"


def _source_tree() -> Path:
    return Path(__file__).resolve().parent.parent


def _install_programs() -> None:
    source = _source_tree()
    binaries = paths.BIN
    binaries.mkdir(parents=True, exist_ok=True)
    for program in _PROGRAMS:
        h.run_or_die("install", "-m", "0755", "-o", "root", "-g", "root",
                     str(source / "guarden" / f"{program}.py"),
                     str(binaries / program))
    # The whole package, not just cli.py: every program imports more of it.
    h.run_or_die("install", "-d", "-m", "0755", "-o", "root", "-g", "root",
                 str(paths.LIBDIR / "guarden"))
    for module in sorted((source / "guarden").glob("*.py")):
        h.run_or_die("install", "-m", "0644", "-o", "root", "-g", "root",
                     str(module), str(paths.LIBDIR / "guarden" / module.name))
    templates = source / "guarden" / "templates"
    if templates.is_dir():
        h.run_or_die("cp", "-r", "-T", str(templates), str(paths.TEMPLATES))


def _programs_installed() -> bool:
    binaries = paths.BIN
    return all((binaries / program).is_file() for program in _PROGRAMS)


def _programs_runnable() -> bool:
    """Whether each installed program starts with an interpreter line.

    A `/usr/bin/soil` symlink to a file that begins with a docstring is a link to
    something the kernel cannot execute: the shell that claims it runs the
    docstring and reports `command not found` for whatever arguments followed.
    The programs are modules (spec 11, no shell entry point), so they carry no
    shebang in the checkout; the installed copy is a *program* and needs one, and
    prepending it is what makes spec 2's symlink a working command rather than a
    file that exists.
    """
    binaries = paths.BIN
    return all(
        (binaries / program).is_file()
        and (binaries / program).read_text(encoding="utf-8").startswith("#!")
        for program in _PROGRAMS
    )


def _make_programs_runnable() -> None:
    """Prepend `#!/usr/bin/env python3` to each installed program.

    Written through the spec 3.5 protocol like every other file, and rebuilt from
    the checkout each time rather than edited in place: a second apply must be a
    no-op, and appending a second shebang to an already-prefixed file would not
    be one. The interpreter is the distribution's `python3`, which is what the
    runtime dependencies assume and what `python3-yaml` and `python3-jinja2` are
    installed for.
    """
    source = _source_tree()
    binaries = paths.BIN
    for program in _PROGRAMS:
        body = (source / "guarden" / f"{program}.py").read_text(encoding="utf-8")
        h.write_file(binaries / program, f"{SHEBANG}\n{_with_bootstrap(body)}", 0o755)
    h.run_or_die("chown", "-R", "root:root", str(binaries))


def _templates_installed() -> bool:
    """Whether the installed templates are the checkout's, contents and all.

    Contents, not existence, for the reason `_modules_installed` gives.
    """
    installed = paths.TEMPLATES
    source = _source_tree() / "guarden" / "templates"
    for path in sorted(source.iterdir()):
        if not path.is_file():
            continue
        target = installed / path.name
        if not target.is_file() or target.read_bytes() != path.read_bytes():
            return False
    return True


def _link_target(program: str) -> str:
    """Where `/usr/bin/<program>` points, as a root-absolute path.

    Absolute rather than relative to the link so that `readlink` on the host
    answers the same thing an operator reading `/usr/bin/soil` would, and so a
    link is comparable as text in `--check` — a relative target would hold
    correctly while pointing somewhere the checker computed differently.
    """
    return str(paths.BIN / program)


def _program_linked(program: str) -> bool:
    """Whether `/usr/bin/<program>` is a symlink into the installed tree."""
    link = paths.USR_BIN / program
    if not link.is_symlink():
        return False
    return os.readlink(link) == _link_target(program)


def _link_programs() -> None:
    """One symlink per program in `/usr/bin`, pointing into `/usr/lib/guarden`.

    spec 2. Without this a program is installed and cannot be run by name: the
    eight console scripts are the interface, and a box where `loom` exists under
    `/usr/lib/guarden/bin` and not on `PATH` is a box whose interface is a
    directory listing.

    The link is replaced rather than followed: `ln -sfn` is idempotent, so a
    converged host re-links nothing, and a `/usr/bin/loom` that something else
    put there is corrected rather than silently kept.
    """
    paths.USR_BIN.mkdir(parents=True, exist_ok=True)
    for program in _PROGRAMS:
        h.run_or_die("ln", "-sfn", _link_target(program), str(paths.USR_BIN / program))


def _install_templates() -> None:
    source = _source_tree() / "guarden" / "templates"
    for path in sorted(source.iterdir()):
        h.run_or_die("install", "-m", "0644", "-o", "root", "-g", "root",
                     str(path), str(paths.TEMPLATES))


def _install_modules() -> None:
    source = _modules_source()
    for module in sorted(path for path in source.iterdir() if path.is_dir()):
        target = paths.MODULES / module.name
        h.run_or_die("install", "-d", "-m", "0755", "-o", "root", "-g", "root", str(target))
        for path in sorted(module.rglob("*")):
            relative = path.relative_to(module)
            if path.is_dir():
                h.run_or_die("install", "-d", "-m", "0755", "-o", "root", "-g", "root",
                             str(paths.MODULES / module.name / relative))
                continue
            mode = "0755" if os.access(path, os.X_OK) else "0644"
            h.run_or_die("install", "-D", "-m", mode, "-o", "root", "-g", "root",
                         str(path), str(paths.MODULES / module.name / relative))
    h.run_or_die("chown", "-R", "root:root", str(paths.MODULES))


def _modules_source() -> Path:
    """The checkout's `modules/`, or the installed copy on a host that has one.

    Same shape as the template lookup: a development checkout is where the
    module being edited and the module being read are the same file, and a
    converge that read a stale installed copy would be a different program on a
    developer's box than on a host.
    """
    beside = _source_tree().parent / "modules"
    return beside if beside.is_dir() else paths.MODULES


def _modules_installed() -> bool:
    """Whether the installed modules are the checkout's, contents and all.

    Contents, not existence: an edited file kept its name and was never
    re-installed, so the host kept the old bytes.
    """
    source = _modules_source()
    if source == paths.MODULES:
        return True
    for path in sorted(source.rglob("*")):
        if not path.is_file():
            continue
        installed = paths.MODULES / path.relative_to(source)
        if not installed.is_file():
            return False
        if installed.read_bytes() != path.read_bytes():
            return False
    return True


def _user_exists(name: str) -> bool:
    return h.run("getent", "passwd", name).ok


def _group_exists(name: str) -> bool:
    return h.run("getent", "group", name).ok


def _invoking_user() -> str:
    return os.environ.get("SUDO_USER") or os.environ.get("USER") or "root"


def _seed_config() -> None:
    with lock("modules"):
        gid = users.group_id(PROGRAM_GROUP)
        conf.write_file(h.config_path(), h.template("guarden.toml"), 0o640, (0, gid))


def _enabled_modules() -> list[str]:
    """The modules `[modules] enabled` currently records, in file order."""
    enabled = h.read_config(h.config_path()).get("modules", {}).get("enabled", [])
    return [str(name) for name in enabled]


def _selection_recorded(selection: list[str]) -> bool:
    """Whether every module the caller named is already enabled.

    A subset test and not an equality one, and that is the whole claim: once a
    choice is recorded it is never narrowed, so a `weedr module add` that
    appended to `[modules] enabled` keeps what it appended and the next
    `soil install --apply` calls that drift-free rather than erasing it. Two
    writers share one key; this one seeds and then yields.
    """
    recorded = set(_enabled_modules())
    return all(module in recorded for module in selection)


def _seed_modules(selection: list[str]) -> None:
    """Record the selection under the `modules` lock, re-reading under it.

    spec 3.5: two writers share `[modules] enabled`, so the write takes the lock
    and re-reads the file under it rather than trusting what it saw before it. A
    `weedr module add` that appended while this waited for the lock is therefore
    still in the list, and this writer adds its selection alongside it rather
    than replacing the key — which is what makes the two writers compose instead
    of overwriting one another.
    """
    with lock("modules"):
        merged = list(dict.fromkeys([*_enabled_modules(), *selection]))
        gid = users.group_id(PROGRAM_GROUP)
        conf.write_file(
            h.config_path(),
            h.set_string_list(_read_text(h.config_path()), "modules", "enabled", merged),
            0o640,
            (0, gid),
        )


def _admin_user() -> str:
    return h.read_config(h.config_path()).get("host", {}).get("admin_user", "")


def _record_admin_user(user: str) -> None:
    # A write to guarden.toml takes the modules lock and rewrites one key, like
    # every other writer of that file: three of them share it and two of them
    # share `[modules] enabled`, so a write re-reads under the lock rather than
    # trusting what it saw before it.
    with lock("modules"):
        gid = users.group_id(PROGRAM_GROUP)
        conf.write_file(
            h.config_path(),
            h.set_string_key(_read_text(h.config_path()), "host", "admin_user", user),
            0o640,
            (0, gid),
        )


def install_items(modules: list[str] | None = None) -> list[Item]:
    # Nothing in here touches the filesystem while the list is being built. An
    # item that seeded a file on the way to asking whether the file was there
    # would make `--check` write, and `--check` changes nothing.
    modules = list(modules or [])
    config_path = h.config_path()

    # The `guarden` group comes first, before anything that names it: a directory
    # is installed `root:guarden` and a program user is created `--gid guarden`,
    # and `install -d -g guarden` fails with `invalid group` and `useradd --gid`
    # fails with `invalid group` on a host where the group does not exist yet.
    # The golden VM found this; the fast harness stages a `guarden` group already,
    # so it could not.
    #
    # Ordering rather than a filter, because a thing this run cannot own yet still
    # has to be created — dropping it from the list would leave a fresh host
    # without `/var/lib/guarden` and report a clean phase.
    #
    # The program users come second, and before the directories for the same
    # reason one step further along: `/var/lib/guarden/render` is `guarden:guarden`
    # (spec 2.1), and `install -d -o guarden` fails with `invalid user` on a host
    # where `guarden` does not exist yet. So a converge in the other order left
    # the one directory whose owner is a program user missing from a fresh host,
    # while every later item succeeded and the phase still reported its drift —
    # which is the shape of a report nobody reads. Group, users, directories: the
    # only order in which all three fit.
    items: list[Item] = [
        Item(
            f"the {PROGRAM_GROUP} group exists, and it is the only group this phase makes",
            lambda: _group_exists(PROGRAM_GROUP),
            lambda: h.run_or_die("groupadd", "--system", PROGRAM_GROUP),
        ),
        *[
            Item(
                f"the {user} user exists, and it is a program user rather than a service",
                lambda user=user: _user_exists(user),
                lambda user=user: h.run_or_die(
                    "useradd", "--system", "--no-create-home", "--shell", "/usr/sbin/nologin",
                    "--gid", PROGRAM_GROUP, user,
                ),
            )
            for user in PROGRAM_USERS
        ],
        *[
            h.directory_item(
                f"/{'/'.join(parts)} is {mode:04o} {owner}:{group}",
                hostpath(*parts), mode, owner, group,
            )
            for parts, mode, owner, group in INSTALL_DIRECTORIES
        ],
    ]
    items += [
        Item("the host configuration exists", lambda: config_path.is_file(), _seed_config),
        Item("guarden's programs are installed root-owned", _programs_installed,
             _install_programs),
        # The installed copies carry an interpreter line, which is what makes
        # spec 2's `/usr/bin` symlinks into working commands rather than links to
        # files the kernel cannot execute. Separate from "installed" because they
        # are different facts about the same file and a host can hold one without
        # the other.
        Item(
            "every installed program starts with an interpreter line, so /usr/bin "
            "runs it rather than the shell quoting it",
            _programs_runnable,
            _make_programs_runnable,
        ),
        # One symlink per program in /usr/bin, so each is runnable by name. The
        # eight are the interface and they are listed together because a
        # partially-linked set is a box where some commands work and others do
        # not, which is the worst shape for an operator to discover.
        Item(
            "every program is on PATH as a symlink into /usr/lib/guarden/bin",
            lambda: all(_program_linked(program) for program in _PROGRAMS),
            _link_programs,
        ),
        Item("guarden's templates are installed", _templates_installed, _install_templates),
        # The module directory is guarden's own installation and root-owned: a
        # module is data that ships with the programs, and `weedr module add`
        # reads it months after this phase last ran.
        Item(
            "guarden's module definitions are installed, and a module can be added without "
            "re-running this phase",
            _modules_installed,
            _install_modules,
        ),
        # The pins are seeded, not converged: an operator fills in a digest once
        # and it is theirs from then on, so a converge to the shipped template
        # would erase the only thing that makes the fetch reachable. Same rule as
        # guarden.toml's `admin_user`: this phase fills a value that is empty and
        # leaves it alone afterwards. One item per artefact, because each is its
        # own file and its own template.
        *[
            Item(f"the pinned {name} record exists, and a missing digest means no fetch",
                 lambda name=name: hostpath(*artefact_record(name)).is_file(),
                 lambda name=name: h.write_file(
                     hostpath(*artefact_record(name)),
                     _template(artefact_record_name(name)),
                     0o644))
            for name in PINNED_ARTEFACTS
        ],
        h.text_item("the tmpfiles entry recreates /run/guarden at every boot",
                    hostpath(*SYSTEMD_DIR, "guarden-tmpfiles.conf"),
                    _template("guarden-tmpfiles.conf")),
        # spec 6.9 / ADR-0005: two units do this for the whole host. This is the
        # instantiable one the `.path` triggers per blob; `guarden-creds-boot` is
        # the boot oneshot. It is triggered by the path unit, never enabled, so
        # it carries no [Install].
        h.text_item(
            "the credential materialiser unit is installed, and it decrypts once in the "
            "system manager",
            hostpath(*SYSTEMD_DIR, "guarden-credential-materialiser@.service"),
            _template("guarden-credential-materialiser@.service"),
        ),
        h.text_item(
            "the credential materialiser's path unit is installed, and it watches "
            "/etc/guarden/creds/",
            hostpath(*SYSTEMD_DIR, "guarden-creds.path"),
            _template("guarden-creds.path"),
            0o644,
        ),
        h.text_item(
            "the credential materialiser's boot oneshot is installed, and it "
            "re-materialises everything",
            hostpath(*SYSTEMD_DIR, "guarden-creds-boot.service"),
            _template("guarden-creds-boot.service"),
            0o644,
        ),
        h.directory_item(
            "/etc/guarden/creds is 0700 root: every blob under it is 0600, and the "
            "directory is the reason",
            hostpath(*CREDS_DIR), 0o700, "root", "root",
        ),
        # Enabled here rather than in `units`, because `install` is the phase that
        # installs the two units: enabling a unit this phase has not written yet
        # is a phase asking its predecessor for something. A rotated value would
        # otherwise sit in a blob until the next boot.
        Item(
            "the credential materialiser's path unit is enabled, or a rotated value "
            "would sit in a blob until the next boot",
            lambda: h.run("systemctl", "is-enabled", "guarden-creds.path").line == "enabled",
            lambda: h.run("systemctl", "enable", "guarden-creds.path"),
        ),
        # **The boot oneshot is enabled, and it was not.** It carries
        # `WantedBy=multi-user.target`, so `enable` is the only thing that makes
        # boot materialisation happen: the path unit answers a *change* under
        # /etc/guarden/creds/ and never fires on a host nobody wrote to, so after
        # a reboot every planted value stayed encrypted and unread. Not `--now`:
        # the oneshot re-materialises the whole tree, and this item is a claim
        # about the unit being wanted, not about running it on services that may
        # not exist yet.
        Item(
            "the credential materialiser's boot oneshot is enabled, or a reboot "
            "materialises nothing and every planted value stays unread",
            lambda: h.run("systemctl", "is-enabled", "guarden-creds-boot.service").line
            == "enabled",
            lambda: h.run("systemctl", "enable", "guarden-creds-boot.service"),
        ),
    ]

    # The module selection, when the caller gave one. It is an item rather than a
    # write so that `--check` reports it and changes nothing, and it holds as
    # soon as any choice is recorded so that a later `weedr module add` is not
    # drift that the next apply would erase.
    if modules:
        items.append(
            Item(
                "[modules] enabled records a selection nobody has to choose twice",
                lambda: _selection_recorded(modules),
                lambda: _seed_modules(modules),
            )
        )

    items += [
        Item(
            "host.admin_user records the invoking user, so the edge's API has one uid",
            lambda: bool(_admin_user()),
            lambda: _record_admin_user(_invoking_user()),
        ),
    ]

    # The zram device, when the operator asked for one and when they did not.
    # `zram.items` returns nothing at all for a host with no knob and no marker,
    # which is what makes "absent means absent: no package, no unit, no config,
    # no sysctl write, and `--check` reports nothing" a property of the shape
    # rather than of a conditional in each of the five places it could have gone.
    #
    # **Before the probe, so the probe stays last.** Two suites assert that the
    # probe is the last item in the phase by counting the drift lines on a host
    # where everything else has converged, and an item appended after it would
    # make that count a property of whether the knob was present.
    items += zram.items(h.read_config(h.config_path()))
    items.append(
        Item(
            "ingress.alias holds an address the probe measured; the edge does not "
            "start without it, and a wrong one answers every route with a 502",
            lambda: bool(_alias()),
            lambda: alias_probe(),
        )
    )
    return items


def _read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.is_file() else ""


def _alias() -> str:
    return h.read_config(h.config_path()).get("ingress", {}).get("alias", "")


def alias_probe() -> int:
    """The four facts of spec 6.1, and what to do about the ones that fail.

    None of the four may be assumed, so each is established by running
    something and reading the result. A failure names which one and leaves
    `ingress.alias` empty rather than recording an address that does not mean
    this host: a container that cannot reach the host answers every route with a
    cause-less 502, and an alias that is wrong is worse than an alias that is
    absent, because the edge refuses to start without it.
    """
    config = h.read_config(h.config_path()) or h.shipped_config()
    network = ",".join(config.get("network", {}).get("pasta_options", []))

    # A tool that is not installed is the host, not a crash: `podman` is a
    # `packages` item, so a host that has not run that phase cannot measure the
    # alias, and the answer to that is one line naming the tool (spec 1.2: the
    # host is exit 1, and a diagnostic names the thing it is about). Letting the
    # interpreter's traceback out of here instead made `soil install --apply` on
    # such a host exit 1 with nothing on stderr but a stack, which is the one
    # outcome an operator cannot act on and a test cannot assert about.
    #
    # **Each probe carries its own reason back, and that is not cosmetic.**
    # `h.run` hands a missing tool back as a non-ok result rather than raising,
    # and collapsing every non-ok result into the fact that failed told an
    # operator their route was wrong on a host where nothing had installed podman
    # yet. The remedy differs per cause -- `soil packages --apply` for one, the
    # probe image for another, the route for a third -- so the cause travels with
    # the answer.
    try:
        gateway, why = _probe_gateway(network)
        if not gateway:
            h.error(f"alias probe 1 of 4: {why}")
            return 1
        if not _probe_reaches_host(gateway, network):
            h.error(f"alias probe 2 of 4: a socket bound to 127.0.0.1 on the host is not "
                    f"reachable from the container at {gateway}")
            return 1
        owner, source, unreadable = _probe_socket_owner()
    except OSError as exc:
        h.error(f"alias probe: this host could not run the probe: {exc}")
        return 1
    if unreadable:
        h.error(f"alias probe 3 of 4: the connection could not be read on the host: {unreadable}")
        return 1
    if not owner:
        h.error("alias probe 3 of 4: the connection did not arrive with a uid as the "
                "socket owner, so the OUTPUT accept rules could not match it")
        return 1
    if source != "127.0.0.1":
        h.error(f"alias probe 4 of 4: the source on the host side is {source} and not "
                f"127.0.0.1, so a rule matching the alias would match nothing")
        return 1

    with lock("modules"):
        gid = users.group_id(PROGRAM_GROUP)
        conf.write_file(
            h.config_path(),
            h.set_string_key(_read_text(h.config_path()), "ingress", "alias", gateway),
            0o640,
            (0, gid),
        )
    return 0


def _podman_argv(network: str, *command: str) -> tuple[str, ...]:
    return ("podman", "run", "--rm", "--network", f"pasta:{network}", h.PROBE_IMAGE, *command)


def _probe_gateway(network: str) -> tuple[str, str]:
    """The container's default gateway, and why there is none when there is not.

    **The reason is the point, and it is why this returns two values.** `h.run`
    reports a tool that is not installed as a non-ok result rather than raising,
    and an earlier version of this returned `""` for every non-ok result -- so a
    host with no `podman` was told its route named no gateway, when the remedy is
    `soil packages --apply`.

    **"Is the tool installed" is asked of `PATH`, not of an exit code.** `h.run`
    invents `127` for a missing host binary, and an OCI runtime reports a missing
    command *inside* the container as `127` too (126 for not-executable) -- so a
    probe image without `ip` would have produced a remedy that cannot apply to
    that cause, which is the very defect this replaced. `shutil.which` answers the
    question directly and the exit code never has to.
    """
    if shutil.which("podman") is None:
        return "", ("podman is not installed, so this host cannot measure the alias; "
                    "`soil packages --apply` installs it")
    result = h.run(*_podman_argv(network, "ip", "-4", "route", "show", "default"))
    if not result.ok:
        reported = result.err.strip().splitlines()
        first = reported[0] if reported else f"podman exited {result.code}"
        return "", f"the probe container did not run: {first}"
    fields = result.line.split()
    if "via" in fields:
        return fields[fields.index("via") + 1], ""
    return "", "the container's default route names no gateway"


def _probe_reaches_host(gateway: str, network: str) -> bool:
    """Bind a loopback port on the host and connect to it from the container.

    The listener is on the host and the client is in the container, which is the
    only direction that proves anything: a container reaching its own loopback
    would prove nothing at all.
    """
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    listener.settimeout(30)
    port = listener.getsockname()[1]
    reached: list[bool] = []

    def accept() -> None:
        try:
            connection, _ = listener.accept()
            reached.append(True)
            connection.close()
        except OSError:
            reached.append(False)

    thread = threading.Thread(target=accept)
    thread.start()
    h.run(
        *_podman_argv(
            network,
            "python3", "-c",
            f"import socket;socket.create_connection(('{gateway}',{port}),10).close()",
        )
    )
    thread.join(35)
    listener.close()
    return bool(reached) and reached[0]


def _probe_socket_owner() -> tuple[int, str, str]:
    """The socket owner, the peer address, and why they could not be read.

    Same shape and same reason as `_probe_gateway`: `ss` is a `packages` item, and
    a host without it must be told which tool is missing rather than that its
    connection "did not arrive with a uid as the socket owner", which describes a
    kernel rule and not a missing binary. The question is asked of `PATH` for the
    same reason it is there -- an exit code cannot distinguish a missing host tool
    from a missing command inside a container.
    """
    if shutil.which("ss") is None:
        return 0, "", ("ss is not installed, so this host cannot read the socket; "
                       "`soil packages --apply` installs it")
    result = h.run("ss", "-tnp", "state", "established")
    if not result.ok:
        reported = result.err.strip().splitlines()
        return 0, "", reported[0] if reported else f"ss exited {result.code}"
    for line in result.out.splitlines()[1:]:
        fields = line.split()
        if len(fields) < 5:
            continue
        owner = 0
        if "uid:" in line:
            try:
                owner = int(line.split("uid:")[1].split()[0])
            except (IndexError, ValueError):
                owner = 0
        return owner, fields[3].rsplit(":", 1)[0], ""
    return 0, "", "no established connection was found to read"


# --------------------------------------------------------------------------
# units
# --------------------------------------------------------------------------


def units_items() -> list[Item]:
    items = [
        h.text_item(f"/{unit} is installed", hostpath(*SYSTEMD_DIR, unit), _template(unit), 0o644)
        for unit in UNITS
    ]
    # spec 6.9's trigger table: the marks are recomputed when a pin or a seed
    # changes, and the pin store and the registry are the two places either does.
    # A `.path` rather than a longer timer period, because a pin is a thing an
    # operator does at three in the morning and expects to have taken effect
    # before the next command they type.
    items.append(
        Item(
            "the pin path unit is enabled, or a mark an operator just wrote waits for "
            "the next hourly timer",
            lambda: h.run("systemctl", "is-enabled", "guarden-pins.path").line == "enabled",
            lambda: h.run("systemctl", "enable", "guarden-pins.path"),
        )
    )
    items.append(
        Item(
            "the recurring jobs are enabled, so a converged host keeps its ladder",
            lambda: h.run("systemctl", "is-enabled", "guarden-snapshot.timer").line == "enabled",
            lambda: [
                h.run_or_die("systemctl", "enable", "--now", timer)
                for timer in ("guarden-snapshot.timer", "guarden-pin-sync.timer",
                              "guarden-snapper-cleanup.timer")
            ],
        )
    )
    # The share reconciler runs only on a host that has the tunnel module: a
    # grant names a tunnel route, and a host with no tunnel has no such route. The
    # module is read from `[modules] enabled` here rather than passed in, because
    # `soil units` is a phase an operator runs on its own and it has to converge
    # the same host `soil --apply` would.
    if SHARE_MODULE in _enabled_modules():
        items.append(
            Item(
                "the share reconciler is enabled, or an expiry waits for a reboot",
                lambda: h.run(
                    "systemctl", "is-enabled", "guarden-share-reconcile.timer"
                ).line == "enabled",
                _enable_share_reconciler,
            )
        )
    return items


def _enable_share_reconciler() -> None:
    h.run_or_die("systemctl", "enable", "--now", "guarden-share-reconcile.timer")


# --------------------------------------------------------------------------
# the phases
# --------------------------------------------------------------------------

PHASES = ("packages", "storage", "sysctl", "firewall", "install", "units")


def items_for(
    phase: str, family: str | None = None,
    modules: list[str] | None = None,
) -> list[Item]:
    if phase == "packages":
        return packages_items(family)
    if phase == "storage":
        return storage_items()
    if phase == "sysctl":
        return sysctl_items()
    if phase == "firewall":
        return firewall_items(family)
    if phase == "install":
        return install_items(modules)
    if phase == "units":
        return units_items()
    h.error(f"unknown phase: {phase}")
    return []


def what_for(phase: str) -> str:
    return {
        "packages": "the distribution's apt timers, the package index, the distribution "
                    "packages, and the pinned releases",
        "storage": "btrfs layout, the snapper value set, root and home, the cleanup timer",
        "sysctl": "route_localnet on the ingress interface, IPv6 off, the port threshold, "
                  "and vm.swappiness when this host asked for a zram device",
        "firewall": "ferm, fail2ban, 10-framework.conf, 20-ingress-nat.conf",
        "install": "guarden into /usr/lib/guarden, the two program users, the alias probe, "
                   "and the zram device when this host asked for one",
        "units": "the system units of the unprivileged programs",
    }[phase]
