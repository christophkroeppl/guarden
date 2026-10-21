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

ETC = PREFIX / "etc"
ETC_GUARDEN = ETC / "guarden"
GUARDEN_TOML = ETC_GUARDEN / "guarden.toml"
# spec 3.1b: the operator's edge overrides, `0640 root:guarden`, written by no
# program. It sits beside `guarden.toml`; `soil install` seeds it empty once, so
# the path exists for an operator to edit, and every later read of it is a read
# and takes no lock (spec 3.5). The unprivileged programs run as `guarden` and
# read it, which is why it is group-readable.
OVERRIDES_TOML = ETC_GUARDEN / "overrides.toml"
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
# Guarden's own drop-in, the one file the mutator writes in the admin path
# (ADR-0019). **The name is the whole of the ordering rule**: quadlet merges
# drop-ins in alphabetical order and the last one wins, so an admin's own
# file — `90-admin.conf` — overrides the pin without guarden ever touching it.
KEEPID_DROPIN = "50-guarden-keepid.conf"

LIB = PREFIX / "var" / "lib" / "guarden"
SERVICES = LIB / "services"
REGISTRY = LIB / "registry"
REMOVED = LIB / "removed"
STAGING = LIB / "staging"
SHARED = LIB / "shared"
STAKES = LIB / "stakes"
EDGE_DYNAMIC = LIB / "edge" / "dynamic"
# `guarden`-owned rather than root-owned like every other `shared/` directory,
# because `twig` runs as `guarden` and `shared/<name>/` is read-only to it.
DASHBOARD = SHARED / "dashboard"

TUNNEL = LIB / "tunnel"
TUNNEL_CONFIG = TUNNEL / "config.yml"

# The issuance record: one file per issuance, named by its id. It is not a
# ledger — nothing aggregates it — and the projection the reconciler writes to
# the vendor is recomputed from it on every run. The store is `0750 root:guarden`
# like the registry, because it describes who may reach what and only root writes
# it.
SHARE = LIB / "share"

# The Cloudflare API token the share reconciler holds, root-owned and unreadable
# by any service user. The value is never in `guarden.toml`; that file records the
# token's *name* and the scopes beside it, so an operator can audit what a leaked
# token would reach.
SHARE_TOKEN = ETC_GUARDEN / "share.api-token"

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
# The one package list, where the installed programs read it: packagelist
# searches `parents[2]/packages/` from the installed copy, which is here.
PACKAGES = USR_LIB_GUARDEN / "packages"
USR_BIN = PREFIX / "usr" / "bin"

LOCKS = PREFIX / "run" / "guarden" / "locks"
PROC_SYS = PREFIX / "proc" / "sys"

# podman's uid-scoped rootless quadlet search path, which is also where admin
# units and drop-ins go (ADR-0003): the home's own directory is searched first,
# so a root-owned drop-in here survives a regeneration.
QUADLET = Path(".config/containers/systemd")
# podman's own store inside a service's home. Root-relative, the way QUADLET is:
# a walk of the service tree must leave it exactly as podman made it.
PODMAN_STORE = Path(".local/share/containers")

# /usr/lib/guarden/templates, where `soil install` puts them. The override is
# the same kind of seam as GUARDEN_PREFIX and for the same reason: the render has
# to be checkable against a template set that is not the one in the checkout. It
# is the least powerful seam in the tree — it can only change the bytes a render
# produces, and every decision the render makes about a unit is in the renderer
# rather than in a template — so it widens no authority.
TEMPLATES = Path(os.environ.get("GUARDEN_TEMPLATES") or (PREFIX / "usr/lib/guarden/templates"))

# The checkout a host is installed FROM. Not under the prefix, which relocates
# what a run writes; `GUARDEN_REPO_DIR` is `tools/install.sh`'s own variable.
CHECKOUT = Path(os.environ.get("GUARDEN_REPO_DIR") or "/usr/local/src/guarden")


def overrides(service: str) -> Path:
    return ETC_SERVICES / service / "overrides.toml"


def admin_parents() -> list[Path]:
    """Every directory of the uid-scoped search path, outermost first.

    The generator reads through all of them as the service user, so each one
    has to be traversable by a uid that is neither root nor in the `guarden`
    group — which is a stated mode and not the umask's answer (spec 2.1).
    """
    return [
        ETC / "containers",
        ETC / "containers" / "systemd",
        ADMIN_UNITS,
    ]


def admin_dropin_dir(uid: int, unit: str) -> Path:
    """One unit's drop-in directory in podman's uid-scoped search path.

    `unit` is the unit's NAME as the generator sees it — the entry stem, so
    an instance's own `<unit>-<escaped-ref>` and not the `<unit>` its
    directory holds.
    """
    return ADMIN_UNITS / str(uid) / f"{unit}.container.d"


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


def volume_root(name: str, escaped_ref: str | None = None) -> Path:
    """The tree every one of this unit's volumes lives under.

    An instance's own tree when there is one, else the service's.
    """
    return instance_tree(name, escaped_ref) if escaped_ref else service_tree(name)


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


# snapper's fixed subvolume name, one constant because three modules match on
# it: `paths` builds paths through it, `lineage` creates and measures the
# subvolume, and `service`'s tree walks skip it -- a snapshot inside is a
# read-only btrfs subvolume, so a chown there is an EROFS (measured
# 2026-10-12) and snapper's subtree is never the service's to own.
SNAPSHOTS = ".snapshots"


def snapshot(name: str, vol: str, number: int, escaped_ref: str | None = None) -> Path:
    """The subvolume a snapshot is, inside the configuration's own layout.

    snapper's own convention, `.snapshots/<number>/snapshot` under the volume, and
    it is the path `weedr service immutable` sets `chattr +i` on (spec 8.2). The
    runbook quotes it because a hand-rolled `chattr` leaves no record, and the
    verb is here so that nobody has to.
    """
    return volume(name, STATE, vol, escaped_ref) / SNAPSHOTS / str(number) / "snapshot"


def lock_path(name: str) -> Path:
    return LOCKS / f"{name}.lock"


def sysctl(name: str) -> Path:
    return PROC_SYS / Path(name)


NO_LOGIN_SHELL = "/usr/sbin/nologin"

# The mode of a service's tree, and of every directory under it (spec 2.1).
#
# **It lives here and not in one program.** The rule is the tree's, and the
# tree is walked by `service.py` and converged by `units.py` — two writers,
# one rule, and a second constant would be a second statement of it.
TREE_MODE = 0o700

# The two volume kinds, and the directory each lives under (spec 2). They are
# here rather than in `volumes.py` because `volumes` imports this module, and a
# layout constant a second module had to be read for would be the copy that
# drifts: `state/` and `bulk/` are split so that a snapshotted subvolume is
# never a parent of an unsnapshotted one.
STATE = "state"
BULK = "bulk"
