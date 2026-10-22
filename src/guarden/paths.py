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
#
# **It is the ONLY path to an admin's own configuration** (ADR-0024). There is
# no staging copy of it: no program reads an admin's file from somewhere else
# and copies it in, and no program stages one for the mutator to install.
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

# The checkout a host's programs are installed FROM, and the tree `soil install`
# converges a stale copy from. `GUARDEN_REPO_DIR` is the variable
# `tools/install.sh` already takes, so a host whose checkout is elsewhere
# converges from the tree it cloned.
CHECKOUT = Path(os.environ.get("GUARDEN_REPO_DIR") or (PREFIX / "usr/local/src/guarden"))


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


def app_root(home: Path, app: str = "") -> Path:
    """The app root inside a service's — or an instance's — home.

    The home holds the WHOLE tree, because the home is the build context (§6.6),
    so an app's root is a path inside it and not a copy of it. `app` is the root
    as the tree spells it (`apps/web`), and the empty string is the tree root,
    which is the shape every single-app repository has.

    **One definition, because a reader that spelled this itself got it wrong.**
    `_unit_source` looked for `<home>/.guarden/service.yml` and nothing else, so a
    multi-app service — manifest at `home/apps/web/.guarden/service.yml` — had no
    unit source at all, and its first `start` failed in `ensure_owner_line` with
    "no manifest in <home> and no module source".
    """
    return home.joinpath(*app.split("/")) if app else home


def app_home(name: str, app: str = "") -> Path:
    """A service's app root: the tree's root, or the app's directory inside it."""
    return app_root(service_home(name), app)


def manifest_in_home(name: str, app: str = "") -> Path:
    """The service's own copy of its manifest, which is where it lives (spec 6.6)."""
    return app_home(name, app) / ".guarden" / "service.yml"


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

# A `state` volume's DATA lives one level down inside the subvolume, in this
# directory, and the container mounts THAT rather than the subvolume root
# (ADR-0020).
#
# **Why the data is not at the subvolume's root.** snapper puts its own
# `.snapshots` subtree inside the subvolume it owns, `0750 root:root`, and the
# container is rootless: its `uid 0` is the *service* uid through
# `/etc/subuid`, so it cannot chown a directory owned by the real host root.
# Every image whose entrypoint runs `chown -R` over its data directory
# therefore fails against a `state` volume -- the stock `postgres` image among
# them, and with it `mariadb`, `mysql` and `elasticsearch`. The failure is
# structural rather than a race: the volume always carries snapper's
# root-owned subtree.
#
# **So the container never sees `.snapshots` at all**, because what it mounts is
# the payload directory and `.snapshots` is its SIBLING, not its child. The
# image's own data path lands inside the payload, so the image's convention
# wins and guarden's layout makes room for it: the repository's mount target
# is unchanged and no environment value has to be set.
#
# **A `bulk` volume has no payload directory**, because it carries no snapper
# configuration and therefore no `.snapshots` subtree to keep out of the way.
# Its mount source is the subvolume itself. ADR-0020 says so, and the rule
# that changed every volume would be a rule about a problem only `state` has.
DATA = "data"


def payload_at(tree: Path, kind: str) -> Path:
    """The path inside a volume's own tree that its container mounts (ADR-0020).

    **A `state` volume is mounted from its PAYLOAD, one level down inside the
    subvolume.** The subvolume is snapper's volume and it carries snapper's
    `.snapshots` subtree, which is root-owned and which the container's root
    cannot chown; the payload is the subvolume's data without that subtree, and
    it is what the container sees. A `bulk` volume is mounted from the tree
    itself, because it carries no snapper configuration and therefore no such
    subtree.

    **The rule is stated once and asked from two places.** The renderer writes
    this path into every `Volume=` line, and `weedr clone` mounts a clone of one
    volume root at the same point in the container; a caller that derived the
    path itself would be a second statement of ADR-0020, which is how `clone`
    fell behind the render in the first place.
    """
    return tree / DATA if kind == STATE else tree


def mount_source_at(base: Path, kind: str, vol: str) -> Path:
    """The path a declared volume is mounted from, under `base` (ADR-0020)."""
    return payload_at(base / kind / vol, kind)


def mount_base(name: str, escaped_ref: str | None = None) -> Path:
    """The tree a declared volume's mount source sits in (ADR-0020).

    **One definition, because two readers of it must not disagree.** `mount_source`
    builds the path from it, and the `[ownership]` walk uses it as the bound a
    granted volume has to stay inside: that walk chowns as root, so a link
    anywhere between the tree and the volume would hand something outside the
    service's own tree to the granted uid.
    """
    return instance_tree(name, escaped_ref) if escaped_ref else service_tree(name)


def mount_source(
    name: str, kind: str, vol: str, escaped_ref: str | None = None
) -> Path:
    """The host path a declared volume is mounted from (ADR-0020)."""
    return mount_source_at(mount_base(name, escaped_ref), kind, vol)


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

# The clone's own directory, beside `state/` and `bulk/` (ADR-0025).
#
# **It is not under `state/`, and that is the point.** `state/` holds nothing
# but snapshotted subvolumes — that is why it is split from `bulk/` at all —
# and a clone has no snapper configuration, so a clone under `state/` would be
# an unsnapshotted tree in the snapshotted one, which is the mistake the split
# exists to prevent.
#
# **It is under the service's own tree**, because the clone holds the service's
# data and the tree is `0700` to the service user. A clone under a shared
# directory would be readable by whoever holds that directory.
CLONES = "clones"
