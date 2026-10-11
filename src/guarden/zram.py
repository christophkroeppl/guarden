"""zram: a compressed block device, when the operator asks for one.

The knob is in root-owned `guarden.toml` and **absent by default**: absent means
absent, so this module's items are only built when the knob is there, and nothing
about zram exists on a host that did not ask for it.

**`systemd-zram-generator` is the implementation, and `zram-tools` is not.**
It is the distribution's own generator, on the same argument as every other
runtime dependency: no pip, no wheels, no third-party fetch. One of the two, and
this is the one.

**The device is read back from the kernel, never from the file guarden wrote** —
the same rule `ingress.alias` follows and for the same reason. `comp_algorithm`
brackets the algorithm in force, `disksize` is the size, and `swapon` reports
the priority. The **level is the exception, and honestly so**: the driver
declares `algorithm_params` write-only, so there is no sysfs read-back for it and
a check claiming one would be checking the file. What *is* observable is that the
driver accepted it — `zstd_setup_params` refuses a level outside zstd's own range
and `disksize_store` then fails, so a level the kernel rejected leaves no
initialised device at all, and the predicate below requires one.

**Size is a percentage of RAM and nothing else.** An absolute size is not
portable, so the expression is `ram * <percent> / 100`, and a percentage over 100
is refused: the generator would create a device larger than the memory backing it
and only *warns* about the ratio, which is not good enough for a value guarden is
about to write. The expected `disksize` is computed the way the generator
computes it — megabytes truncated, then the percentage applied in floating point,
then truncated again — because anything else is a `--check` that reports drift on
a device that is exactly right.

**zram is swap, and that is the answer to §8.** A zram device is RAM, so it does
not move the free-space floor snapper's `FREE_LIMIT` reads and the retention
story is unaffected. It does change `vm.swappiness`, so that key joins the
canonical sysctl set soil owns — and only when the knob is present, because
absent means absent down to the last sysctl.

**Converging in both directions needs a record.** A converge that only ever
creates cannot take down what it created, and nothing else on the box says which
of two zram devices guarden made. So the marker under `/var/lib/guarden/soil/`
says guarden owns this device; with the knob absent its absence *is* the teardown,
and with no marker either there was never anything to take down.
"""

from __future__ import annotations

import os
import time
from dataclasses import dataclass

from guarden import errors
from guarden import hosttool as h

# The table's name in guarden.toml, and the only shape it has.
ZRAM_TABLE = "zram"
ZRAM_KEYS = {"algorithm", "level", "size_percent"}

# One device, and the one the generator makes by default. guarden configures
# zram0 or nothing: a second device is a second thing whose size is an operator's
# arithmetic and is not this design's.
DEVICE = "zram0"
DEVICE_PATH = f"/dev/{DEVICE}"
SYSFS = ("sys", "block", DEVICE)
SETUP_UNIT = f"systemd-zram-setup@{DEVICE}.service"
SWAP_UNIT = f"dev-{DEVICE}.swap"
# The generator's hotplug control, and the device number it takes. A reset leaves
# `/sys/block/zram0` behind, which is a device an operator finds and a checker
# reads as still there, so the teardown has to take the node away as well.
ZRAM_CONTROL = ("sys", "class", "zram-control")

# The only algorithm offered. zstd is the one worth it on a small box; lz4 buys
# CPU and gives up most of the ratio, and offering it would be offering a
# tradeoff guarden cannot make for somebody.
ALGORITHMS = ("zstd",)
# zstd's own range, from the driver's own bounds check in `backend_zstd.c`.
LEVEL_MIN = 1
LEVEL_MAX = 22
LEVEL_DEFAULT = 6

# The generator's default priority, and the kernel's own default. Both are 100,
# so this value changes nothing about which device is preferred — zram is ahead
# of a disk swapfile whatever this says. It is written and checked anyway,
# because a value that is only a default can be changed by a package and this is
# what the comparison is against.
SWAP_PRIORITY = "100"
# Above 100 means "use this device in preference to disk, and do not use disk
# while this device has room". The kernel's default of 60 would keep preferring a
# disk swapfile over a RAM-backed device and leave the device idle, which is the
# one thing an operator who asked for it did not ask for.
SWAPPINESS = "180"
KERNEL_DEFAULT_SWAPPINESS = "60"

# The generator's main configuration file, the one an administrator owns, and
# the marker this module writes to say the device is guarden's.
CONF = ("etc", "systemd", "zram-generator.conf")
MARKER = ("var", "lib", "guarden", "soil", "zram")

# The role the package list carries the generator under. It is not in the
# substrate list because "absent means absent: no package", so it is installed by
# the phase that owns packages, and only when the knob is there.
PACKAGE_ROLE = "zram"


@dataclass(frozen=True)
class Zram:
    """One `[zram]` table: the algorithm, its level, and the size."""

    algorithm: str
    level: int
    size_percent: int

    @property
    def algorithm_value(self) -> str:
        """What goes in `compression-algorithm`, and the level rides with it."""
        return f"{self.algorithm}(level={self.level})"

    @property
    def size_expression(self) -> str:
        """What goes in `zram-size`. `ram` is the generator's megabytes."""
        return f"ram * {self.size_percent} / 100"

    @property
    def expected_bytes(self) -> int:
        """The `disksize` this device will hold, computed the generator's way.

        The generator reads `MemTotal` in kilobytes, divides by 1024 as an
        `f64`, **truncates that to `u64`**, evaluates `ram * percent / 100` in
        `f64`, multiplies by 1024 twice and **truncates to `u64` again**. The
        driver then rounds up to a page. Doing the arithmetic any other way —
        including in integers, which is the obvious reading — gives a different
        number on most hosts, and the difference is a `--check` reporting drift
        forever against a device that is exactly the size it was asked for.
        """
        megabytes = float(_memtotal_kb() // 1024)
        return _page_align(int(megabytes * self.size_percent / 100 * 1024 * 1024))


def _page_align(size: int) -> int:
    page = os.sysconf("SC_PAGE_SIZE")
    return -(-size // page) * page


def _memtotal_kb() -> int:
    """`MemTotal` from `/proc/meminfo` in kilobytes, or zero if it is unreadable."""
    for line in _read(h.hostpath("proc", "meminfo")).splitlines():
        key, _, rest = line.partition(":")
        if key.strip() == "MemTotal":
            fields = rest.split()
            if fields:
                return int(fields[0])
    return 0


def _read(path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except OSError:
        return ""


# --- the knob ---------------------------------------------------------------


def knob(config: dict, where: str = "guarden.toml") -> Zram | None:
    """The `[zram]` table, or nothing. Absent is the default and is not an error.

    Two exit codes and the split is the one `config.py` states: a value of the
    wrong type is the host and is `1`, and a well-formed value that breaks a rule
    this table states is a rejected input and is `2`.
    """
    table = config.get(ZRAM_TABLE)
    if table is None:
        return None
    if not isinstance(table, dict):
        raise _typed(where, "a table")
    extra = sorted(set(table) - ZRAM_KEYS)
    if extra:
        raise _typed(where, f"a table with an unknown key {extra[0]!r}")
    return _zram(table, where)


def _typed(where: str, what: str) -> errors.GuardenError:
    return errors.GuardenError(f"{where}: [zram] is {what}", errors.HOST_NOT_AS_ASSUMED)


def _zram(table: dict, where: str) -> Zram:
    algorithm = table.get("algorithm", ALGORITHMS[0])
    if not isinstance(algorithm, str):
        raise _typed(where, "a table whose algorithm is a string")
    if algorithm not in ALGORITHMS:
        raise errors.GuardenError(
            f"{where}: [zram] algorithm is {algorithm!r}, and the algorithms guarden "
            f"offers are {', '.join(ALGORITHMS)}; which one compresses a given box's "
            f"memory best is the operator's, so the set is short and closed"
        )
    level = table.get("level", LEVEL_DEFAULT)
    if isinstance(level, bool) or not isinstance(level, int):
        raise _typed(where, "a table whose level is an integer")
    if not LEVEL_MIN <= level <= LEVEL_MAX:
        raise errors.GuardenError(
            f"{where}: [zram] level is {level}, and {algorithm} runs "
            f"{LEVEL_MIN}-{LEVEL_MAX}"
        )
    percent = table.get("size_percent")
    if isinstance(percent, bool) or not isinstance(percent, int):
        raise _typed(where, "a table whose size_percent is an integer")
    if not 1 <= percent <= 100:
        raise errors.GuardenError(
            f"{where}: [zram] size_percent is {percent}, and it is a percentage of this "
            f"host's RAM: over 100 asks for a device larger than the memory backing it, "
            f"which the generator warns about rather than refusing"
        )
    return Zram(algorithm=algorithm, level=level, size_percent=percent)


# --- what the host holds ----------------------------------------------------


def conf_path():
    return h.hostpath(*CONF)


def marker_path():
    return h.hostpath(*MARKER)


def sysfs(name: str):
    return h.hostpath(*SYSFS, name)


def present() -> bool:
    """Whether a zram DEVICE is there, by the kernel's own word for it.

    Not whether the sysfs node is: a hot-remove takes the device out of service
    and the kernel leaves `/sys/block/zram0` in place, `comp_algorithm` and all.
    Measured on the machine after a teardown — node present, `disksize` 0, no swap
    — so asking about the node could never be satisfied by a teardown that worked,
    and every `--check` afterwards reported drift forever.
    """
    return disksize() > 0


def algorithm_in_force() -> str:
    """The bracketed entry of `comp_algorithm`.

    The kernel lists every backend it was built with and brackets the one this
    device is using, which is why this is parsed rather than compared whole.
    """
    text = _read(sysfs("comp_algorithm"))
    start = text.rfind("[")
    end = text.rfind("]")
    return text[start + 1 : end] if 0 <= start < end else ""


def disksize() -> int:
    return int(_read(sysfs("disksize")).strip() or 0)


def swap_priority() -> str:
    """`swapon`'s own answer for this device, or an empty string when it is not
    swap. `swapon` is the kernel's report and not a file on the box."""
    result = h.run("swapon", "--show=NAME,PRIO", "--noheadings")
    if not result.ok:
        return ""
    for line in result.out.splitlines():
        fields = line.split()
        if len(fields) == 2 and fields[0] == DEVICE_PATH:
            return fields[1]
    return ""


# --- the two files ----------------------------------------------------------


def generator_conf(device: Zram) -> str:
    """`/etc/systemd/zram-generator.conf`, the whole of what soil writes there.

    `fs-type = swap` is stated rather than left to the default because the
    generator's other mode is a compressed filesystem mounted at a directory,
    and a reader of this file should not have to know which one guarden meant.
    `host-memory-limit = none` is stated for the same reason: the percentage is
    the only ceiling, and it is not a size for a box to be above.
    """
    return "\n".join(
        [
            "# Written by soil install, and by nothing else. One device, one table:",
            f"# {device.algorithm} at level {device.level}, {device.size_percent} percent of",
            "# this host's RAM, and it is swap.",
            f"[{DEVICE}]",
            f"zram-size = {device.size_expression}",
            f"compression-algorithm = {device.algorithm_value}",
            f"swap-priority = {SWAP_PRIORITY}",
            "fs-type = swap",
            "host-memory-limit = none",
        ]
    ) + "\n"


def marker(device: Zram) -> str:
    """The record that this device is guarden's.

    It exists because the converge has to work in both directions and nothing
    else on the box says which of two zram devices guarden made. It is not a
    grant and it records nothing an operator set that guarden does not also
    converge: it restates the knob, and its *absence* is what tells the teardown
    there is nothing to take down.
    """
    return "\n".join(
        [
            "# Written by soil install. Its presence is how a later run knows this",
            "# zram device is guarden's to take down again.",
            f"device = {DEVICE}",
            f"algorithm = {device.algorithm}",
            f"level = {device.level}",
            f"size_percent = {device.size_percent}",
        ]
    ) + "\n"


# --- converge ---------------------------------------------------------------


def items(config: dict) -> list[h.Item]:
    """The install phase's zram items, or nothing at all.

    Absent is the whole of the answer when the knob is absent and the marker is
    absent: no item is built, so `--check` says nothing about zram and `--apply`
    writes nothing, installs nothing and enables nothing.
    """
    device = knob(config)
    if device is None:
        return [_teardown_item()] if marker_path().is_file() else []
    return [
        h.text_item(
            f"/{'/'.join(CONF)} carries the operator's zram device and nothing else",
            conf_path(),
            generator_conf(device),
        ),
        h.text_item(
            f"/{'/'.join(MARKER)} records that this zram device is guarden's",
            marker_path(),
            marker(device),
        ),
        _device_item(device),
    ]


def _device_item(device: Zram) -> h.Item:
    return h.Item(
        f"/dev/{DEVICE} is initialised with {device.algorithm} at "
        f"{device.size_percent}% of RAM and is swap at priority {SWAP_PRIORITY}, "
        f"as /sys/block/{DEVICE} and swapon report it",
        lambda: _device_holds(device),
        lambda: _converge_device(),
    )


def _device_holds(device: Zram) -> bool:
    """The device, read back from the kernel rather than from the file.

    The algorithm is `comp_algorithm`'s bracketed entry, the size is `disksize`
    against the percentage, and the priority is `swapon`'s. The level is not in
    this predicate and cannot be: the driver exposes no way to read it back.
    What stands in for it is that a device exists at all, because a level the
    backend rejects fails `disksize_store` and leaves nothing initialised.
    """
    return (
        present()
        and algorithm_in_force() == device.algorithm
        and disksize() == device.expected_bytes
        and swap_priority() == SWAP_PRIORITY
    )


def _converge_device() -> None:
    """Start the device from whatever state it is in, not from none.

    A `disksize` cannot be written to an initialised device and a `comp_algorithm`
    cannot either, so a changed percentage converges only if the old one is torn
    down first. Doing that unconditionally rather than only when the size differs
    is what makes "converge without depending on what it was" true here: the
    steps are each safe on an absent device, and the reload is what runs the
    generator that turns the file guarden wrote into `dev-zram0.swap`.
    """
    _tear_down()
    h.run("systemctl", "daemon-reload")
    h.run_or_die("systemctl", "start", SWAP_UNIT)
    _await_device()


def _await_device(timeout: float = 10.0) -> None:
    """Wait for `swapon` to carry the device, which is the fact the item asserts.

    Bounded, and silent on expiry: whether the device arrived is `_device_holds`
    to judge, and a message here would name a timeout rather than the reason,
    which is in the generator's journal.
    """
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if swap_priority():
            return
        time.sleep(0.1)


def _await_reset(timeout: float = 5.0) -> None:
    """Wait for `disksize` to reach 0 after `zramctl --reset`.

    `zramctl --reset` returns success as soon as the ioctl is issued, but the
    kernel may not have zeroed the `disksize` sysfs attribute yet. Under load
    (a full gate running 52 concurrent machines), the gap is wide enough that
    a subsequent read sees a non-zero value and the teardown appears to have
    left the device in place.
    """
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not present():
            return
        time.sleep(0.1)


def _tear_down() -> None:
    """Take a device off the host's swap and out of its sysfs, whatever state.

    Every step is safe on a device that is not there, which is what lets the same
    call be the converge path's first step and the teardown's only step.
    """
    h.run("systemctl", "stop", SWAP_UNIT)
    h.run("systemctl", "stop", SETUP_UNIT)
    if not present():
        return
    h.run("swapoff", DEVICE_PATH)
    h.run_or_die("zramctl", "--reset", DEVICE_PATH)
    _await_reset()
    control = h.hostpath(*ZRAM_CONTROL, "hot_remove")
    try:
        control.write_text(f"{DEVICE.removeprefix('zram')}\n", encoding="utf-8")
    except OSError as exc:
        h.warn(f"the zram device {DEVICE_PATH} was reset but not hot-removed: {exc.strerror}")


def _teardown_item() -> h.Item:
    """The knob is gone and the marker says this device was guarden's.

    The device is swapped off, reset and hot-removed rather than merely
    disabled, and the two files go with it: "the knob is gone" has to mean the
    device is gone and the host says nothing about zram again.
    """
    return h.Item(
        f"the zram device is gone: /{'/'.join(CONF)}, /{'/'.join(MARKER)} and "
        f"/dev/{DEVICE} are all absent, because the knob is absent",
        _gone,
        _teardown,
    )


def _gone() -> bool:
    # The sysfs node and not merely the swap entry: `zramctl --reset` leaves
    # `/sys/block/zram0` behind with a size of zero, and a node an operator finds
    # and a checker reads as present is not a device that has gone away. If the
    # hot-remove was refused, this stays drift, which is the honest report.
    return (
        not conf_path().exists()
        and not marker_path().exists()
        and not present()
    )


def _teardown() -> None:
    _tear_down()
    conf_path().unlink(missing_ok=True)
    marker_path().unlink(missing_ok=True)
    h.run("systemctl", "daemon-reload")
    h.run("sysctl", "-q", "-w", f"vm.swappiness={KERNEL_DEFAULT_SWAPPINESS}")
