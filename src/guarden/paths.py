"""Every absolute path guarden uses, in one place.

spec 2 and 2.1 are the table; this module is that table as code, so a path is
written once and the two can be checked against each other.

`GUARDEN_PREFIX` relocates the whole tree. It exists because the fast harness
has to run the mutator on a machine that is not a guarden host: the programs
write `/etc/guarden`, `/var/lib/guarden`, `/run/guarden` and `/etc/snapper`,
none of which a test may touch, and a bind mount needs privileges the harness
does not have and would not be a "fast" harness if it had them. Every root goes
through it, `/proc/sys` included, so that a test can stage the value a host
invariant is checked against. With it unset — which is how the box runs it —
every path is the real one.

It is a poor candidate for widening authority. `sudo` resets the environment by
default, so a value arriving down the poke path cannot be set by a workflow key;
and a program not reached through sudo was already running with whatever
authority its caller held, because a caller who can set an environment variable
for a root process has already had the root process.
"""

from __future__ import annotations

import os
from pathlib import Path

PREFIX = Path(os.environ.get("GUARDEN_PREFIX") or "/")

# /etc
ETC = PREFIX / "etc"
ETC_GUARDEN = ETC / "guarden"
GUARDEN_TOML = ETC_GUARDEN / "guarden.toml"
ETC_SERVICES = ETC_GUARDEN / "services"
PROJECTS_TOML = ETC_GUARDEN / "projects.toml"
FIREWALL = ETC_GUARDEN / "firewall"
# spec 2: the credential blobs, `0700 root`. One directory per service, one
# `<KEY>.cred` per key, and the pair is the whole of what a value is on this host
# outside the service that owns it.
CREDS = ETC_GUARDEN / "creds"
ALLOW_GATED_DROP = ETC_GUARDEN / "allow-gated-drop"
SNAPPER_CONFIGS = ETC / "snapper" / "configs"
SUBUID = ETC / "subuid"
SUBGID = ETC / "subgid"
GROUP = ETC / "group"
ADMIN_UNITS = ETC / "containers" / "systemd" / "users"

# /var/lib/guarden
LIB = PREFIX / "var" / "lib" / "guarden"
SERVICES = LIB / "services"
REGISTRY = LIB / "registry"
REMOVED = LIB / "removed"
STAGING = LIB / "staging"
SHARED = LIB / "shared"
STAKES = LIB / "stakes"
EDGE_DYNAMIC = LIB / "edge" / "dynamic"

# /usr/lib/guarden and /usr/bin, spec 2's FHS rows.
#
# Guarden's own files live under /usr/lib/guarden, which is root-owned and never
# written by a deploy; /usr/bin carries one symlink per program so each is
# runnable by name. The split is what makes the tree reinstallable: the programs
# can be replaced under /usr/lib/guarden without touching what an operator's
# PATH resolves to, and a link that pointed into a checkout would break the
# moment that checkout moved.
USR_LIB = PREFIX / "usr" / "lib"
USR_LIB_GUARDEN = USR_LIB / "guarden"
BIN = USR_LIB_GUARDEN / "bin"
LIBDIR = USR_LIB_GUARDEN / "lib"
MODULES = USR_LIB_GUARDEN / "modules"
USR_BIN = PREFIX / "usr" / "bin"

# /run and /proc
LOCKS = PREFIX / "run" / "guarden" / "locks"
PROC_SYS = PREFIX / "proc" / "sys"

# podman's uid-scoped rootless quadlet search path, which is also where admin
# units and drop-ins go (ADR-0003): the home's own directory is searched first,
# so a root-owned drop-in here survives a regeneration.
QUADLET = Path(".config/containers/systemd")

# /usr/lib/guarden/templates, where `soil install` puts them. The override is
# the same kind of seam as GUARDEN_PREFIX and for the same reason: the render has
# to be checkable against a template set that is not the one in the checkout. It
# is the least powerful seam in the tree — it can only change the bytes a render
# produces, and every decision the render makes about a unit is in the renderer
# rather than in a template — so it widens no authority.
TEMPLATES = Path(os.environ.get("GUARDEN_TEMPLATES") or (PREFIX / "usr/lib/guarden/templates"))


def overrides(service: str) -> Path:
    return ETC_SERVICES / service / "overrides.toml"


def creds(service: str) -> Path:
    """One service's blobs, root-owned and unreadable by any service user."""
    return CREDS / service


def cred_blob(service: str, key: str) -> Path:
    """`<KEY>.cred`, mode `0600`. The key is a name from the project's own schema
    and is validated before it reaches this function, so it is never a path."""
    return CREDS / service / f"{key}.cred"


def registry(service: str) -> Path:
    return REGISTRY / f"{service}.toml"


def service_tree(name: str) -> Path:
    return SERVICES / name


def service_home(name: str) -> Path:
    return service_tree(name) / "home"


def unit_dir(name: str) -> Path:
    return service_home(name) / QUADLET


def manifest_in_home(name: str) -> Path:
    """The service's own copy of its manifest, which is where it lives (spec 6.6)."""
    return service_home(name) / ".guarden" / "service.yml"


def instance_home(name: str, escaped_ref: str) -> Path:
    return service_home(name) / escaped_ref


def instance_tree(name: str, escaped_ref: str) -> Path:
    """An instance's own tree: a sibling of the service's volumes, never a child (spec 2)."""
    return service_tree(name) / "instances" / escaped_ref


def volume(name: str, kind: str, vol: str, escaped_ref: str | None = None) -> Path:
    """A volume's host path, always derived and never written by a manifest (spec 4)."""
    base = instance_tree(name, escaped_ref) if escaped_ref else service_tree(name)
    return base / kind / vol


def snapper_config(name: str, vol: str, escaped_ref: str | None = None) -> str:
    """`<service>-<volume>`, or `<service>-<escaped-ref>-<volume>` on an instance track.

    spec 8.1: the name is opaque and nothing parses it, because workload and
    volume names may both contain `-`.
    """
    if escaped_ref:
        return f"{name}-{escaped_ref}-{vol}"
    return f"{name}-{vol}"


def removed(service: str, when: str, vol: str) -> Path:
    return REMOVED / service / when / vol


def snapshot(name: str, vol: str, number: int, escaped_ref: str | None = None) -> Path:
    """The subvolume a snapshot is, inside the configuration's own layout.

    snapper's own convention, `.snapshots/<number>/snapshot` under the volume, and
    it is the path `weedr service immutable` sets `chattr +i` on (spec 8.2). The
    runbook quotes it because a hand-rolled `chattr` leaves no record, and the
    verb is here so that nobody has to.
    """
    return volume(name, STATE, vol, escaped_ref) / ".snapshots" / str(number) / "snapshot"


def lock_path(name: str) -> Path:
    return LOCKS / f"{name}.lock"


def sysctl(name: str) -> Path:
    return PROC_SYS / Path(name)


NO_LOGIN_SHELL = "/usr/sbin/nologin"

# The two volume kinds, and the directory each lives under (spec 2). They are
# here rather than in `volumes.py` because `volumes` imports this module, and a
# layout constant a second module had to be read for would be the copy that
# drifts: `state/` and `bulk/` are split so that a snapshotted subvolume is
# never a parent of an unsnapshotted one.
STATE = "state"
BULK = "bulk"
