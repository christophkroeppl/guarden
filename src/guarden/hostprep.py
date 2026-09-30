"""The six phases, as lists of `Item`s.

A phase is a list of facts about the host, each of which can say whether it
already holds and can make itself hold. `--check` asks the first question of
every item, `--apply` asks the second. Nothing else decides what a phase means,
so the two modes cannot drift apart, and `--check` changing nothing is a
property of the shape rather than of care in each phase.

The order the phases run in is the order in spec 6.1, and it is not
interchangeable: `storage` creates the directories `install` writes into and the
registry `install` reads a track from.
"""

from __future__ import annotations

import hashlib
import os
import socket
import threading
from collections.abc import Iterable
from pathlib import Path

from guarden import hosttool as h
from guarden import packagelist, paths
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

# The one fetch from outside a distribution repository. Its version and SHA256
# are recorded in the repository and verified on install, and there is no
# version of guarden that fetches an unpinned artefact.
PODLET_RECORD_NAME = "podlet.release"
PODLET_RECORD = ("etc", "guarden", PODLET_RECORD_NAME)

# spec 6.1: the kernel owns the public ports and nothing unprivileged binds
# below 1024. Raising the threshold to the kernel default is a tightening;
# lowering it is what grants every unprivileged uid a privileged port.
IP_UNPRIVILEGED_PORT_START = "1024"

SNAPPER_CONFIG_DIR = ("etc", "snapper", "configs")

# The host's own two configurations and the subvolume each is for. `root` is
# what the package hook snapshots; `home` is the host's.
HOST_CONFIGURATIONS = {"root": "/", "home": "/home"}

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

# `root` and `home` get these four and nothing else: no track owns them, so
# there is no track to read a default from and their ladder is left as the
# distribution shipped it.
HOST_FIXED = (
    "EMPTY_PRE_POST_CLEANUP",
    "NUMBER_MIN_AGE",
    "NUMBER_CLEANUP",
    "TIMELINE_CLEANUP",
)

PACKAGED_CLEANUP = ("snapper-cleanup.timer", "snapper-cleanup.service")

SYSCTL_FILE = ("etc", "sysctl.d", "90-guarden.conf")
SYSTEMD_DIR = ("etc", "systemd", "system")
APT_DIR = ("etc", "apt", "apt.conf.d")
FIREWALL_DIR = ("etc", "guarden", "firewall")
REGISTRY_DIR = ("var", "lib", "guarden", "registry")
UNITS = (
    "guarden-snapshot.service",
    "guarden-snapshot.timer",
    "guarden-pin-sync.service",
    "guarden-pin-sync.timer",
)


# --------------------------------------------------------------------------
# packages
# --------------------------------------------------------------------------


def _installed(package: str, row: dict) -> bool:
    """Whether the family's own query says so, asked with the list's argv."""
    return packagelist.is_installed(package, row)


def _podlet_record() -> dict[str, str]:
    """The pin, read as TOML because it is a TOML file and a digest is quoted.

    A hand-rolled line split would compare the digest against a string carrying
    the quotes that were never part of it, and would call a correct pin a
    mismatch.
    """
    return h.read_config(hostpath(*PODLET_RECORD))


def _podlet_binary() -> Path:
    return paths.BIN / "podlet"


def _digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


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

    def podlet_installed() -> bool:
        record = _podlet_record()
        binary = _podlet_binary()
        if not record.get("sha256") or not binary.is_file():
            return False
        return _digest(binary) == record["sha256"]

    def install_podlet() -> None:
        record_path = hostpath(*PODLET_RECORD)
        record = _podlet_record()
        version = record.get("version", "")
        url = record.get("url", "")
        expected = record.get("sha256", "")
        if not (version and url and expected):
            # Absent and unfilled are different faults with different fixes, so
            # they are different messages. Both are exit 2: the record is a
            # repository input, and an unfilled pin is not a host that is out of
            # state -- it is a record nobody filled in.
            if not record_path.is_file():
                raise IncompleteRecord(
                    f"the pinned podlet record is absent: {record_path}, and `soil install` "
                    f"seeds it from the template"
                )
            raise IncompleteRecord(f"the pinned podlet record is incomplete: {record_path}")
        binary = _podlet_binary()
        binary.parent.mkdir(parents=True, exist_ok=True)
        fetched = binary.parent / "podlet.fetch"
        result = h.run("curl", "--fail", "--silent", "--show-error", "--location",
                       "--output", str(fetched), url)
        if not result.ok:
            raise IncompleteRecord(
                f"fetching podlet {version}: {result.err.strip() or result.code}"
            )
        if _digest(fetched) != expected:
            raise IncompleteRecord(
                f"podlet {version}: the SHA256 does not match {hostpath(*PODLET_RECORD)}"
            )
        os.replace(fetched, binary)
        os.chmod(binary, 0o755)

    return [*items, Item("the pinned podlet is installed and its SHA256 verified",
                         podlet_installed, install_podlet)]


def _install_packages(packages: Iterable[str], row: dict | None = None) -> None:
    """Install with the family's tool, named in the list and nowhere else.

    One package at a time, because the item that failed is the item that has to
    be reported: a single `apt-get install` of the whole list fails as a unit and
    says which of seven packages was missing only by parsing the distribution's
    prose.
    """
    for package in packages:
        h.run_or_die(*packagelist.install_argv([package], row))


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
    result = h.run("snapper", "-c", name, "get-config")
    values: dict[str, str] = {}
    for line in result.out.splitlines():
        key, _, value = line.partition("=")
        if key.strip():
            values[key.strip()] = value.strip()
    return values


def _write_snapper(name: str, values: dict[str, str]) -> None:
    """Merge and hand the whole thing back, so nothing else in it is rewritten.

    spec 8.1: the effective configuration is read with `get-config` and never by
    parsing /etc/snapper/configs/<name>, and the converged set is applied to what
    is already there rather than replacing it.
    """
    target = hostpath("run", "guarden", "snapper-merge.conf")
    target.parent.mkdir(parents=True, exist_ok=True)
    h.write_file(target, "".join(f"{k}={v}\n" for k, v in values.items()), 0o600)
    h.run_or_die("snapper", "-c", name, "modify", "-f", str(target))
    target.unlink(missing_ok=True)


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
    h.run_or_die("snapper", "-c", name, "create-config", "-f", "btrfs", "-p",
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
    for unit in PACKAGED_CLEANUP:
        if h.run("systemctl", "is-enabled", unit).line != "disabled":
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
    with lock("snapshots"):
        merged = {**_snapper_values(name), **desired}
        _write_snapper(name, merged)


def _template(name: str) -> str:
    return h.template(name)


# --------------------------------------------------------------------------
# sysctl
# --------------------------------------------------------------------------


def _sysctl_value(key: str) -> str:
    return h.run("sysctl", "-n", key).line


def _sysctl_items() -> list[Item]:
    interface = h.ingress_interface(h.read_config(h.config_path()) or h.shipped_config())
    wanted: list[tuple[str, str]] = [
        ("net.ipv4.ip_unprivileged_port_start", IP_UNPRIVILEGED_PORT_START),
        ("net.ipv6.conf.all.disable_ipv6", "1"),
        ("net.ipv6.conf.default.disable_ipv6", "1"),
    ]
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

DISTRIBUTION_FIREWALL_UNITS = ("ufw.service",)


def _distribution_firewall_disabled() -> bool:
    return all(h.run("systemctl", "is-enabled", unit).line == "disabled"
               for unit in DISTRIBUTION_FIREWALL_UNITS)


def _deadman_armed() -> bool:
    return h.run("systemctl", "is-active", "guarden-firewall-deadman.timer").line == "active"


def _module_ingress() -> list[tuple[str, str]]:
    """The enabled modules' declared ingress, with the publication each goes to.

    The publication is read from the service's registry rather than assumed,
    because it is allocated from `ingress.publication_range` and no number in
    this design is fixed. A module whose service is not installed yet contributes
    nothing, which is what "a fresh host has no ingress" means.
    """
    config = h.read_config(h.config_path()) or h.shipped_config()
    enabled = config.get("modules", {}).get("enabled", [])
    modules = paths.MODULES
    found: list[tuple[str, str]] = []
    for module in enabled:
        manifest = modules / module / "module.toml"
        if not manifest.is_file():
            continue
        for entry in h.read_config(manifest).get("services", []):
            service = entry.get("service", "")
            registry = h.read_config(hostpath(*REGISTRY_DIR, f"{service}.toml"))
            for port in entry.get("ingress", []):
                found.append((port, _publication_for(registry)))
    return [(port, publication) for port, publication in found if publication]


def _publication_for(registry: dict) -> str:
    """The container and port a forward lands on, for one service.

    `registry["publication"]` is the edge's own; an entry with `api = true` is
    the control surface and is never forwarded.
    """
    publication = registry.get("publication")
    if isinstance(publication, dict):
        return str(publication.get("port", ""))
    if isinstance(publication, list):
        for entry in publication:
            if isinstance(entry, dict) and not entry.get("api"):
                return str(entry.get("port", ""))
    return ""


def _ingress_nat(interface: str, ingress: list[tuple[str, str]]) -> str:
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
        "",
        "TABLE=nat",
        "CHAIN=PREROUTING",
        "",
    ]
    for port, publication in ingress:
        number, _, protocol = port.partition("/")
        lines.append(
            f"[ 'i {interface}' 'p {protocol}' '--dport {number}' ] "
            f"-j DNAT --to-destination 127.0.0.1:{publication}"
        )
    return "\n".join(lines) + "\n"


def _framework(interface: str) -> str:
    return "\n".join(
        [
            "# Written by soil firewall. The ferm skeleton: the policy baseline, the",
            "# dead-man timer and the ingress interface's route_localnet.",
            "#",
            "# The per-service filter set and any service's own forwarding are in",
            "# 30-services.conf, which the mutator writes and which is disjoint from",
            "# this file and from 20-ingress-nat.conf. Each has exactly one writer.",
            "#",
            f"# route_localnet is scoped to {interface} alone, and is persisted in",
            "# /etc/sysctl.d/90-guarden.conf. Without it the kernel treats a packet",
            "# addressed to 127.0.0.1 that arrived on a non-loopback interface as a",
            "# martian and drops it, which is the whole reason the forwarding works.",
            "",
            "TABLE=filter",
            "CHAIN=INPUT",
            "[ 'm conntrack' '--ctstate RELATED,ESTABLISHED' ] -j ACCEPT",
            "[ 'i lo' ] -j ACCEPT",
            "[ 'p tcp' '--dport 22' ] -j ACCEPT",
            "[ 'p tcp' '--dport 443' ] -j ACCEPT",
            "[ 'p udp' '--dport 443' ] -j ACCEPT",
            "-j DROP",
            "",
            "# The dead-man timer is 10-framework's business because it is the",
            "# framework's safety net: armed only by `soil firewall --apply",
            "# --deadman`, fifteen minutes, and it stops this service and puts the",
            "# distribution's own firewall back so ssh answers again. The unit is",
            "# guarden-firewall-deadman.timer and the effect is in its service.",
        ]
    ) + "\n"


def firewall_items(deadman: bool) -> list[Item]:
    config = h.read_config(h.config_path()) or h.shipped_config()
    interface = h.ingress_interface(config)
    items: list[Item] = [
        Item(
            "the distribution's own firewall is disabled",
            _distribution_firewall_disabled,
            lambda: [h.run("systemctl", "disable", "--now", unit)
                     for unit in DISTRIBUTION_FIREWALL_UNITS],
        ),
        *[
            h.text_item(f"/{unit} is installed", hostpath(*SYSTEMD_DIR, unit),
                        _template(unit), 0o644)
            for unit in ("guarden-firewall.service", "guarden-firewall-deadman.service",
                         "guarden-firewall-deadman.timer")
        ],
        h.text_item(
            "10-framework.conf carries the skeleton, the dead-man timer and the "
            "ingress interface's route_localnet",
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

    if deadman:
        items.append(
            Item(
                "the dead-man timer is armed for fifteen minutes",
                _deadman_armed,
                lambda: h.run_or_die("systemctl", "start", "guarden-firewall-deadman.timer"),
            )
        )
    else:
        # A plain apply disarms it. An armed timer opens the firewall in fifteen
        # minutes, and one that outlives its drill is a surprise rather than a
        # safety net.
        items.append(
            Item(
                "the dead-man timer is not armed, because a plain apply never arms it",
                lambda: not _deadman_armed(),
                lambda: h.run("systemctl", "stop", "guarden-firewall-deadman.timer"),
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
    h.run_or_die("install", "-m", "0644", "-o", "root", "-g", "root",
                 str(source / "guarden" / "cli.py"), str(paths.LIBDIR))


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
        h.write_file(binaries / program, f"{SHEBANG}\n{body}", 0o755)
    h.run_or_die("chown", "-R", "root:root", str(binaries))


def _templates_installed() -> bool:
    installed = paths.TEMPLATES
    source = _source_tree() / "guarden" / "templates"
    return all((installed / path.name).is_file() for path in source.iterdir())


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


def _user_exists(name: str) -> bool:
    return h.run("getent", "passwd", name).ok


def _group_exists(name: str) -> bool:
    return h.run("getent", "group", name).ok


def _invoking_user() -> str:
    return os.environ.get("SUDO_USER") or os.environ.get("USER") or "root"


def _seed_config() -> None:
    with lock("modules"):
        h.write_file(h.config_path(), h.template("guarden.toml"), 0o644)


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
        h.write_file(
            h.config_path(),
            h.set_string_list(_read_text(h.config_path()), "modules", "enabled", merged),
            0o644,
        )


def _admin_user() -> str:
    return h.read_config(h.config_path()).get("host", {}).get("admin_user", "")


def _record_admin_user(user: str) -> None:
    # A write to guarden.toml takes the modules lock and rewrites one key, like
    # every other writer of that file: three of them share it and two of them
    # share `[modules] enabled`, so a write re-reads under the lock rather than
    # trusting what it saw before it.
    with lock("modules"):
        h.write_file(
            h.config_path(),
            h.set_string_key(_read_text(h.config_path()), "host", "admin_user", user),
            0o644,
        )


def install_items(modules: list[str] | None = None) -> list[Item]:
    # Nothing in here touches the filesystem while the list is being built. An
    # item that seeded a file on the way to asking whether the file was there
    # would make `--check` write, and `--check` changes nothing.
    modules = list(modules or [])
    config_path = h.config_path()

    # The `guarden` group comes first, before any directory that names it as
    # their group: `install -d -o root -g guarden` fails with `invalid group` on a
    # host where the group does not exist yet, and a directory whose group is
    # load-bearing is exactly the one that would fail. The golden VM found this;
    # the fast harness stages a `guarden` group already, so it could not.
    #
    # Ordering rather than a filter, because a directory this run cannot own yet
    # still has to be created — dropping it from the list would leave a fresh
    # host without `/var/lib/guarden` and report a clean phase.
    items: list[Item] = [
        Item(
            f"the {PROGRAM_GROUP} group exists, and it is the only group this phase makes",
            lambda: _group_exists(PROGRAM_GROUP),
            lambda: h.run_or_die("groupadd", "--system", PROGRAM_GROUP),
        ),
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
        # The pin is seeded, not converged: an operator fills in a digest once and
        # it is theirs from then on, so a converge to the shipped template would
        # erase the only thing that makes the fetch reachable. Same rule as
        # guarden.toml's `admin_user`: this phase fills a value that is empty and
        # leaves it alone afterwards.
        Item(
            "the pinned podlet record exists, and a missing digest means no fetch",
            lambda: hostpath(*PODLET_RECORD).is_file(),
            lambda: h.write_file(hostpath(*PODLET_RECORD), _template(PODLET_RECORD_NAME), 0o644),
        ),
        h.text_item("the tmpfiles entry recreates /run/guarden at every boot",
                    hostpath(*SYSTEMD_DIR, "guarden-tmpfiles.conf"),
                    _template("guarden-tmpfiles.conf")),
        # The program users follow the group, for the same reason the group leads
        # the directories: `useradd --gid guarden` needs the group to exist.
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
        h.text_item(
            "the credential materialiser unit is installed, and it decrypts once in the "
            "system manager",
            hostpath(*SYSTEMD_DIR, "guarden-credential-materialiser@.service"),
            _template("guarden-credential-materialiser@.service"),
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
        Item(
            "ingress.alias holds an address the probe measured; the edge does not "
            "start without it, and a wrong one answers every route with a 502",
            lambda: bool(_alias()),
            lambda: alias_probe(),
        ),
    ]
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

    gateway = _probe_gateway(network)
    if not gateway:
        h.error("alias probe 1 of 4: the container's default route names no gateway")
        return 1
    if not _probe_reaches_host(gateway, network):
        h.error(f"alias probe 2 of 4: a socket bound to 127.0.0.1 on the host is not "
                f"reachable from the container at {gateway}")
        return 1
    owner, source = _probe_socket_owner()
    if not owner:
        h.error("alias probe 3 of 4: the connection did not arrive with a uid as the "
                "socket owner, so the OUTPUT accept rules could not match it")
        return 1
    if source != "127.0.0.1":
        h.error(f"alias probe 4 of 4: the source on the host side is {source} and not "
                f"127.0.0.1, so a rule matching the alias would match nothing")
        return 1

    with lock("modules"):
        h.write_file(
            h.config_path(),
            h.set_string_key(_read_text(h.config_path()), "ingress", "alias", gateway),
            0o644,
        )
    return 0


def _podman_argv(network: str, *command: str) -> tuple[str, ...]:
    return ("podman", "run", "--rm", "--network", f"pasta:{network}", h.PROBE_IMAGE, *command)


def _probe_gateway(network: str) -> str:
    result = h.run(*_podman_argv(network, "ip", "-4", "route", "show", "default"))
    if not result.ok:
        return ""
    fields = result.line.split()
    if "via" in fields:
        return fields[fields.index("via") + 1]
    return ""


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


def _probe_socket_owner() -> tuple[int, str]:
    """The socket owner and the peer address, read from the kernel on the host."""
    result = h.run("ss", "-tnp", "state", "established")
    if not result.ok:
        return 0, ""
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
        return owner, fields[3].rsplit(":", 1)[0]
    return 0, ""


# --------------------------------------------------------------------------
# units
# --------------------------------------------------------------------------


def units_items() -> list[Item]:
    items = [
        h.text_item(f"/{unit} is installed", hostpath(*SYSTEMD_DIR, unit), _template(unit), 0o644)
        for unit in UNITS
    ]
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
    return items


# --------------------------------------------------------------------------
# the phases
# --------------------------------------------------------------------------

PHASES = ("packages", "storage", "sysctl", "firewall", "install", "units")


def items_for(
    phase: str, deadman: bool = False, family: str | None = None,
    modules: list[str] | None = None,
) -> list[Item]:
    if phase == "packages":
        return packages_items(family)
    if phase == "storage":
        return storage_items()
    if phase == "sysctl":
        return sysctl_items()
    if phase == "firewall":
        return firewall_items(deadman)
    if phase == "install":
        return install_items(modules)
    if phase == "units":
        return units_items()
    h.error(f"unknown phase: {phase}")
    return []


def what_for(phase: str) -> str:
    return {
        "packages": "the distribution packages, and the one pinned podlet release",
        "storage": "btrfs layout, the snapper value set, root and home, the cleanup timer",
        "sysctl": "route_localnet on the ingress interface, IPv6 off, the port threshold",
        "firewall": "ferm, fail2ban, 10-framework.conf, 20-ingress-nat.conf, the dead-man timer",
        "install": "guarden into /usr/lib/guarden, the two program users, the alias probe",
        "units": "the system units of the unprivileged programs",
    }[phase]
