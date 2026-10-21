"""The project manifest: `.guarden/service.yml`, read with `safe_load` and nothing else.

A repository is YAML because a developer editing their own infrastructure is
better served by the format they know and by one that allows comments in the
obvious place (spec 3). `safe_load` only, always: this is a document a stranger
wrote, and a loader that can construct an object is a loader that runs code.

**Every block has a closed key set, and an unknown key is refused by name**
(spec 4). The rule is stated twice in the spec because the first version covered
only the top level, so a typo in a nested key was silently dropped and a
manifest asking for `authentification: true` got a route with no auth on it and
no diagnostic saying so. A silent drop is the failure this parser exists to make
impossible, so the top-level check is here even for the keys this ticket does not
consume.

What this ticket consumes is the whole of it: `project`, `units`, `state`, `bulk`,
`provides`, `needs`, `ports`, `routes`, `widgets`, `firewall` and `schema`. The volumes are
what the mutator creates and what the registry records, the project is one of two
registry fields that may differ, and the remaining blocks are the renderer's
input — the edges it validates against the registry, the containers it looks up
in the unit source, and the keys whose credential *requests* it emits. A
`firewall:` block installs nothing and its three fields are recorded verbatim. The
deep shape of each block is validated here rather than in the renderer, because a
manifest is input and a manifest's failures are the ones nobody hears about.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path, PurePosixPath
from typing import Any

from guarden import errors, names, paths, rules

MANIFEST_REL = Path(".guarden") / "service.yml"

TOP_LEVEL_KEYS = {
    "project",
    "units",
    "state",
    "bulk",
    "needs",
    "provides",
    "ports",
    "routes",
    "widgets",
    "firewall",
    "schema",
    "scrub",
}

# Each block's own key set, closed. spec 4 is emphatic that the rule covers the
# keys *inside* a known one as well, and says why: a typo in a nested key was
# silently dropped, and a manifest asking for `authentification: true` got a route
# with no auth on it and no diagnostic saying so. Only the key sets are checked
# here — whether a container exists, whether a port is in range and whether a
# host is a label are the checks of the tickets that consume those blocks.
BLOCK_KEYS = {
    "needs": {"service", "as", "port", "auth", "databases"},
    "ports": {"container", "port"},
    "routes": {"container", "port", "host", "auth"},
    "widgets": {"container", "file"},
    "firewall": {"name", "chain", "rule"},
}

# `scrub:` is a MAPPING of two lists, and it is not in BLOCK_KEYS because that
# table is the list-of-entries blocks: the generic check there refuses anything
# that is not a list, and running `scrub:` through it read `scrub is not a list`
# for a block that is legal and correct. Its own closed key sets are below, and
# `_scrub` applies them.

# The `scrub:` block's own key sets, closed (ADR-0025).
#
# **A `tables:` entry says "every row of this table goes", and there is no
# second answer.** The transform is a filter over a plain dump, and the restored
# table is created and then filled from an empty COPY block either way — so a
# `truncate`/`delete` pair would be two spellings of one result, and a mode that
# cannot differ is a promise the verb cannot keep. A table where only SOME rows
# go is a `keys:` rule and not this one.
SCRUB_TABLE_KEYS = {"name"}
SCRUB_KEYS = {"table", "column", "prefix", "equals"}

# spec 4: an `environment` key is refused specifically, with a message saying who
# decides it. It is a key a developer would reach for, and the answer is never
# in the repository.
REFUSED_KEYS = {
    "environment": "the host decides the environment; it is recorded in /etc/guarden/guarden.toml",
    "track": "the host decides the track; it is a row in the [[environments]] table of "
    "/etc/guarden/guarden.toml",
    "fork_from": "lineage is a field on the track, and a repository cannot set it",
    "weight": "a resource weight is the track's, from /etc/guarden/guarden.toml",
    "cpu_weight": "a resource weight is the track's, from /etc/guarden/guarden.toml",
    "io_weight": "a resource weight is the track's, from /etc/guarden/guarden.toml",
    "memory": "a resource cap is the operator's, in a root-owned drop-in",
    "memory_max": "a resource cap is the operator's, in a root-owned drop-in",
    "memory_high": "a resource cap is the operator's, in a root-owned drop-in",
    "priority": "a build priority is the track's weight, which a manifest does not state",
    "build_priority": "a build priority is the track's weight, which a manifest does not state",
    "snapshot_priority": "a snapshot priority is an operator's, in overrides.toml or a pin",
    "retention": "retention is the track's default or the admin's override, not the manifest's",
    "keep_last": "retention is the track's default or the admin's override, not the manifest's",
    "free_limit": "retention is the track's default or the admin's override, not the manifest's",
    "data_source": "a data source is a path a container mounts, and the mounts are the admin's",
    "grants": "a grant is recorded in the root-owned overrides.toml, never in a repository",
    "open_ports": "a grant is recorded in the root-owned overrides.toml, never in a repository",
    "published_ports": "the published-port set is the renderer's, from the grants and the "
    "allocations",
    "mounts": "[mounts] allow in the root-owned overrides.toml is the only mount surface",
    "exposure": "exposure is an operator's act, recorded per service per "
                "environment with `weedr expose set` on the root-owned registry; "
                "the host decides it and a manifest cannot request it",
    "basicauth": "the default basic-auth middleware is on for every service, and turning it "
                 "off is the operator's per-service act: `weedr basicauth off <name>` records "
                 "it in the root-owned overrides.toml. A repository cannot remove the login in "
                 "front of its own route",
    "public": "public exposure is an operator's act recorded with `weedr expose "
              "set`, selectable only on a gated track; a manifest cannot place "
              "itself on the internet",
    "zram": "a zram device is host configuration, in the root-owned "
            "/etc/guarden/guarden.toml, and it is the operator's",
    "swap": "a swap device is host configuration, and it is the operator's",
    "swappiness": "vm.swappiness is a host kernel knob guarden converges from its own "
                  "configuration, never a manifest's",
}

VOLUME_RE = re.compile(r"^[a-z0-9][a-z0-9._-]*$")
# spec 4: `as:` is the variable name uppercased, so it is a name and not a
# string, and the closed form is what stops a manifest writing a prefix that
# becomes an odd environment variable.
AS_RE = re.compile(r"^[a-z][a-z0-9_]*$")
# A database name: the role and the database are named after it, so it has to
# be a valid postgres identifier.
DB_NAME_RE = re.compile(r"^[a-z_][a-z0-9_]*$")
# The route host, after the track's prefix, is a set of labels. The pattern is
# closed rather than a list of prohibitions because a wildcard was the shape that
# would have been dangerous.
HOST_RE = re.compile(r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$")
# What a provider may `provide:`. The first two are the CREDENTIAL kinds: a
# consumer edges to them with `auth: database` or `auth: secret` and receives a
# minted value, and the provider can verify it. The rest are REACHABILITY kinds:
# a consumer edges to them with `auth: none` and receives only the host and the
# port, which is what one service needs from a sibling that serves an HTTP or an
# RPC API. A kind is in this tuple or a provider cannot name it, so adding a
# service to the stack is adding a name here.
PROVIDES_KINDS = ("db", "secret", "bitcoin", "nbxplorer", "btcpay", "nostr")
AUTH_KINDS = ("database", "secret", "none")
PORT_MIN = 1
PORT_MAX = 65535


@dataclass(frozen=True)
class Edge:
    """One `needs:` entry: an edge to another service.

    `service` is a logical provider name. The host resolves it to a concrete
    service name per track via `[providers]` in `guarden.toml` — a manifest
    that names `postgres` resolves to `postgres-staging` in staging and
    `postgres-production` in production. An unresolved name is used unchanged,
    so a manifest naming a full service name keeps working.

    When `databases` is set, the edge provisions one role/database pair per
    name. The credential is minted once per edge and reused for all.
    """

    service: str
    prefix: str
    port: int
    auth: str
    databases: tuple[str, ...] = ()

    @property
    def variable(self) -> str:
        return self.prefix.upper()


@dataclass(frozen=True)
class Publication:
    """One `ports:` entry: a public port requested for a container of this service."""

    container: str
    port: int


@dataclass(frozen=True)
class Route:
    """One `routes:` entry: a container of this service the edge dials."""

    container: str
    port: int
    host: str
    auth: bool


@dataclass(frozen=True)
class Widget:
    """One `widgets:` entry: a file the dashboard copies, unparsed."""

    container: str
    file: str


def _check_widget_file(value: str, path: Path, container: str) -> None:
    """A widget's file is a name INSIDE the tree, and not a path.

    **The renderer reads this file as the `guarden` account, which is in the
    `guarden` group and can therefore read the host's configuration.** So a
    `file:` that names a path outside the tree turns a repository — the
    untrusted actor — into a reader of `/etc/guarden/guarden.toml`, of every
    service's registry record, and of every overrides file, and the content
    lands where a service's container can read it.

    The escape is a Python fact, not a guess: **`Path("/a/b") / "/etc/x"` is
    `/etc/x`**, because an absolute right operand discards the left one. And a
    traversal does the same without being absolute:

        >>> Path("/tree") / "/etc/passwd"
        PosixPath('/etc/passwd')
        >>> (Path("/tree") / "../../etc/passwd").resolve()
        PosixPath('/etc/passwd')

    So both shapes are refused here, and the rule is the same one `hose`
    applies to a member path (`hose._member_path`): a RELATIVE path, with no
    leading `/` and no `..` component.

    The check is on the NAME, before anything is read, so a refused widget
    costs a manifest parse and not a read.
    """
    if value.startswith("/"):
        raise errors.GuardenError(
            f"the manifest {path}: the widgets entry for {container!r} names "
            f"{value!r}, which is an absolute path; a widget's file is a name "
            f"inside the tree, not a path on this host"
        )
    parts = PurePosixPath(value).parts
    if ".." in parts:
        raise errors.GuardenError(
            f"the manifest {path}: the widgets entry for {container!r} names "
            f"{value!r}, which climbs out of the tree; a widget's file is a "
            f"name inside the tree, not a path on this host"
        )


@dataclass(frozen=True)
class RuleRequest:
    """One `firewall:` entry: the name a grant names, the chain, the rule text.

    `rule` is the line as the manifest wrote it, because that is the text a
    request is deduplicated by and the text `weedr firewall list` reports.
    """

    name: str
    chain: str
    rule: str


@dataclass(frozen=True)
class ScrubTable:
    """One `scrub: tables:` entry: a table whose every row goes."""

    name: str


@dataclass(frozen=True)
class ScrubKey:
    """One `scrub: keys:` entry: the rows of one table that go.

    **A prefix match and an equality match, and nothing else.** A rule that
    could name a row by an arbitrary predicate would be an arbitrary database
    write dressed as a policy, and the review a manifest block is for — a diff
    in a pull request — is worthless against arbitrary SQL (ADR-0025). A prefix
    on a named column says exactly "the rows of this table whose column starts
    with this", which is the operator's own rule ("every `ir_config_parameter`
    row whose key begins with `mail.`").
    """

    table: str
    column: str
    prefix: str | None = None
    equals: str | None = None


@dataclass(frozen=True)
class Scrub:
    """The whole `scrub:` block: the operator's policy for a cloned database."""

    tables: tuple[ScrubTable, ...] = ()
    keys: tuple[ScrubKey, ...] = ()

    def empty(self) -> bool:
        return not self.tables and not self.keys


@dataclass
class Manifest:
    source: Path
    project: str | None
    units: str | None
    state: list[str] = field(default_factory=list)
    bulk: list[str] = field(default_factory=list)
    provides: list[str] = field(default_factory=list)
    needs: list[Edge] = field(default_factory=list)
    ports: list[Publication] = field(default_factory=list)
    routes: list[Route] = field(default_factory=list)
    widgets: list[Widget] = field(default_factory=list)
    firewall: list[RuleRequest] = field(default_factory=list)
    schema: str | None = None
    scrub: Scrub = field(default_factory=Scrub)

    def volume_kind(self, name: str) -> str:
        return "state" if name in self.state else "bulk"

    def volumes(self) -> list[tuple[str, str]]:
        """Every declared volume with its kind: `state` first, then `bulk`, each
        by name. A fixed order, so two renders agree byte for byte."""
        return [
            *((name, "state") for name in sorted(self.state)),
            *((name, "bulk") for name in sorted(self.bulk)),
        ]


def _yaml():
    """`pyyaml`, imported here and not at module scope.

    `--help` has to answer on a host where a runtime dependency is not installed
    yet, and a program that cannot print its own usage because a library is
    missing is a bad thing to hand someone over ssh. The import failure is
    therefore a diagnostic naming the distribution's package, which is what
    `soil packages` installs.
    """
    try:
        import yaml
    except ImportError:
        raise errors.GuardenError(
            "python3-yaml is not importable; it is the distribution's package, "
            "installed by `soil packages`",
            errors.HOST_NOT_AS_ASSUMED,
        ) from None
    return yaml


def read(path: Path) -> Manifest:
    """Read one manifest. A repository that ships a broken one is rejected input.

    **This reads the DOCUMENT, and it does not judge the DECLARATION.** The
    document's own shape is validated here — the closed key sets, the volume
    names, the `provides:` kinds — and those are properties of the file, so
    they hold wherever the file is read from.

    The one rule that is about the *declaration* rather than the document — a
    `db` provider declares a volume or it is refused — is in `accept()`, and
    the two are different things: §4 governs "`.guarden/service.yml` at the
    repository root", and §1.2 puts "the installed services" on the **host**
    side of the dividing line. A rule that fired on every read would refuse to
    read back the operator's own running service — `start`, `gate`, `build`,
    `secret list` and the firewall render all read the manifest in a service's
    home — so it would break the box it was written to protect. The operator's
    staging postgres, the very service ticket 326 is about, is such an
    installed service.
    """
    yaml = _yaml()
    try:
        text = path.read_text()
    except FileNotFoundError:
        raise errors.GuardenError(f"the manifest {path} does not exist") from None
    except OSError as exc:
        raise errors.GuardenError(f"the manifest {path} could not be read: {exc.strerror}") from exc

    try:
        document = yaml.safe_load(text)
    except yaml.YAMLError as exc:
        raise errors.GuardenError(
            f"the manifest {path} is not valid YAML: {errors.oneline(str(exc))}"
        ) from exc

    if document is None:
        document = {}
    if not isinstance(document, dict):
        raise errors.GuardenError(f"the manifest {path} is not a mapping")

    for key in document:
        if key in REFUSED_KEYS:
            raise errors.GuardenError(f"the manifest {path} has a {key!r} key: {REFUSED_KEYS[key]}")
    unknown = sorted(set(document) - TOP_LEVEL_KEYS)
    if unknown:
        raise errors.GuardenError(
            f"the manifest {path} has an unknown key {unknown[0]!r}; "
            f"the keys are: {', '.join(sorted(TOP_LEVEL_KEYS))}"
        )
    _check_blocks(document, path)

    state = _volumes(document.get("state", []), "state", path)
    bulk = _volumes(document.get("bulk", []), "bulk", path)
    both = sorted(set(state) & set(bulk))
    if both:
        raise errors.GuardenError(
            f"the manifest {path} lists {both[0]!r} as both a state and a bulk volume"
        )

    provides = _provides(document.get("provides", []), path)

    return Manifest(
        source=path,
        project=_project(document.get("project"), path),
        units=_units(document.get("units"), path),
        state=state,
        bulk=bulk,
        provides=provides,
        needs=_needs(document.get("needs", []), path),
        ports=_publications(document.get("ports", []), path),
        routes=_routes(document.get("routes", []), path),
        widgets=_widgets(document.get("widgets", []), path),
        firewall=_firewall(document.get("firewall", []), path),
        schema=_schema(document.get("schema"), path),
        scrub=_scrub(document.get("scrub"), path),
    )


def _is_declaration(path: Path) -> bool:
    """Whether this manifest is a repository's DECLARATION or a document guarden holds.

    **The two are different documents, and the difference is the whole scope of
    the `db`-provider rule.** A declaration is a manifest guarden is being asked
    to take as the shape of a service. A held document is the copy guarden keeps
    in an installed service's home — and the staged copy of one, which is the
    same document under another name.

    The rule is on the declaration, and the reason is the spec's own shape:
    §4 governs "`.guarden/service.yml` at the repository root", and §1.2 puts
    "the installed services" on the **host** side of the dividing line between
    input and host. A rule that fired on a held document would refuse to read
    back the operator's own running service — `start`, `gate`, `build`,
    `secret list` and the firewall render all read that copy — so it would
    break the box it was written to protect. The operator's staging postgres,
    the very service ticket 326 is about, is such an installed service.

    **The test is the tree the document is in**, and not the caller's intent,
    because the caller is not always able to say: the same read happens for a
    repository tree and for an installed service's home, and the two are told
    apart by where they live. `/var/lib/guarden/services/<name>/` is the
    installed services' tree, and everything under it is a document guarden
    holds. `/var/lib/guarden/staging/` is a poke's tree.

    **The staged copy of a held document is under `render-source/<service>/`,
    and the guided creator's staged DECLARATION is under `render-source/guided/`.**
    They are told apart by the directory under `render-source`, because they are
    different documents: one is the copy of a manifest guarden already holds,
    and the other is a tree the operator wrote and guarden is about to accept.
    A rule that reached the guided tree would never fire on it — the guided
    creator asks for the volumes separately from `provides:`, so a `db` service
    created that way is exactly the declaration the rule is for.

    A manifest anywhere else — a repository tree, an operator's own tree, a
    template — is a declaration.
    """
    try:
        resolved = path.resolve()
    except OSError:  # pragma: no cover - a resolve that cannot answer
        return True
    if _under(resolved, paths.SERVICES):
        return False
    if _under(resolved, paths.LIB / "render-source"):
        # `render-source/guided/` is the operator's own tree, staged for the
        # renderer to read; `render-source/<service>/` is the copy of a document
        # guarden already holds. Only the second one is a held document.
        relative = resolved.relative_to(paths.LIB / "render-source")
        return bool(relative.parts) and relative.parts[0] == "guided"
    return True


def accept(path: Path, held: bool = False) -> Manifest:
    """Read a manifest as a repository's DECLARATION, and refuse one that breaks the rule.

    **This is the acceptance, and it is the only place the `db`-provider rule
    fires for a document guarden already holds.** A caller that is taking a
    manifest as the shape of a service calls this; a caller that is reading
    back a document guarden already holds calls `read()`.

    The difference is not cosmetic, and the reason is the spec's own shape:
    §4 governs "`.guarden/service.yml` at the repository root", and §1.2 puts
    "the installed services" on the **host** side of the dividing line. A rule
    that fired on every read would refuse to read back the operator's own
    running service — `start`, `gate`, `build`, `secret list` and the firewall
    render all read the manifest in a service's home — so it would break the
    box it was written to protect. The operator's staging postgres, the very
    service ticket 326 is about, is such an installed service.

    **`held` says the document is a held one being taken as a declaration.**
    `weedr service add --from <service>` copies the source's manifest into a
    new service, and that copy IS the new service's declaration: a `db`
    provider that declares no volume is a new service with ephemeral data,
    which is the whole of what this rule is for. The path cannot say so — the
    source's home is under the installed services' tree, and so is the copy the
    new service gets — so the caller says it, because the caller knows which of
    the two it is doing.

    **The staged copy of a held document is not a declaration**, and the path
    says so: it is under `render-source/<service>/` and not
    `render-source/guided/`. A re-render of an installed service reads that
    copy, and it must keep working — or every re-render of every installed
    service would fail.
    """
    document = read(path)
    if held or _is_declaration(path):
        _check_provider_volume(document.provides, document.state, document.bulk, path)
    return document


def _under(path: Path, root: Path) -> bool:
    """Whether `path` is `root` or is under it."""
    try:
        return path == root or root in path.parents
    except OSError:  # pragma: no cover - a resolve that cannot answer
        return False


def _check_provider_volume(
    provides: list[str], state: list[str], bulk: list[str], path: Path
) -> None:
    """A `db` provider that declares no volume is refused (spec 4).

    The rule, its reasons and its limits are in the spec, and this is the
    check that carries it: **a manifest that provides the `db` kind declares
    a volume or it is refused.** The `db` kind is the one guarden writes into
    itself — the role and the database a consumer's edge asks for are created
    in the provider's own engine — and a container with no declared volume
    keeps its data in podman's anonymous volume, which podman's garbage
    collector removes when the container is recreated.

    The check is on the **declaration** and not on the path, because the path
    is often the image's own `VOLUME` and guarden cannot read an image: the
    renderer is unprivileged and pure, and the image is not pulled until a
    start. A repository that names no path at all is refused by this same
    line as one that names a path it did not declare.

    `state:` and `bulk:` both satisfy it: a `bulk` volume is a subvolume the
    collector never touches, and `state:` adds the rollback on top.

    **It runs on an ACCEPTANCE and not on every read.** `read()` calls it only
    when the caller says the document is being accepted, and the reason is the
    difference between a repository's declaration and the host: the copy of a
    manifest in an installed service's home is a document guarden has already
    accepted, and refusing to read it back would make the operator's own
    running service unstartable and unmanageable — which is a rule that breaks
    the box it was written to protect. The scope is in the spec (spec 4).
    """
    if "db" not in provides:
        return
    if state or bulk:
        return
    raise errors.GuardenError(
        f"the manifest {path} provides the kind 'db' and declares no volume: a container with no "
        f"volume keeps its data in an anonymous volume in the service's image store, which podman "
        f"removes when the container is recreated, so the data is gone after a re-ingest and "
        f"nothing says so. Declare a `state:` volume (snapshotted, and what `weedr service "
        f"rollback` restores from) or a `bulk:` volume (not snapshotted) and mount that name in "
        f"the unit source. The new volume starts EMPTY: move the data across yourself"
    )


def _check_blocks(document: dict, path: Path) -> None:
    """The closed key set of each list-of-entries block, refused by name.

    A `service:` key inside a `routes:`, `ports:` or `widgets:` block is checked
    **first** and gets its own message, because it is the one mistake the block
    structure exists to make impossible and an "unknown key" diagnostic would
    not say which of the two things a developer has to tell apart went wrong.

    A REFUSED_KEYS name (`environment`, `exposure`, …) is checked second and
    gets its own message for the same reason the top-level check gives it one:
    the generic "unknown key" line names the key but not who owns the decision,
    and a developer who reaches for `exposure:` inside a route entry is asking
    the question the refusal exists to answer.
    """
    for block in ("ports", "routes", "widgets"):
        entries = document.get(block)
        if not isinstance(entries, list):
            continue
        for entry in entries:
            if isinstance(entry, dict) and "service" in entry:
                raise errors.GuardenError(
                    f"the manifest {path}: a {block} entry has a `service:` key; a {block} "
                    f"entry names a container inside this service, and `service:` is how you "
                    f"tell the two apart"
                )
    for block, allowed in BLOCK_KEYS.items():
        entries = document.get(block)
        if entries is None:
            continue
        if not isinstance(entries, list):
            raise errors.GuardenError(f"the manifest {path}: {block} is not a list")
        for entry in entries:
            if not isinstance(entry, dict):
                raise errors.GuardenError(
                    f"the manifest {path}: a {block} entry is not a mapping; a bare "
                    f"string is not a valid entry"
                )
            refused = sorted(key for key in entry if key in REFUSED_KEYS)
            if refused:
                raise errors.GuardenError(
                    f"the manifest {path}: a {block} entry has a {refused[0]!r} key: "
                    f"{REFUSED_KEYS[refused[0]]}"
                )
            extra = sorted(set(entry) - allowed)
            if extra:
                raise errors.GuardenError(
                    f"the manifest {path}: a {block} entry has an unknown key "
                    f"{extra[0]!r}; the keys are: {', '.join(sorted(allowed))}"
                )


def _volumes(value: Any, key: str, path: Path) -> list[str]:
    if not isinstance(value, list):
        raise errors.GuardenError(f"the manifest {path}: {key} is not a list")
    out = []
    for item in value:
        if not isinstance(item, str) or not VOLUME_RE.match(item):
            raise errors.GuardenError(
                f"the manifest {path}: {key} entry {item!r} must be a name matching "
                f"{VOLUME_RE.pattern}"
            )
        out.append(item)
    return out


def _provides(value: Any, path: Path) -> list[str]:
    if not isinstance(value, list):
        raise errors.GuardenError(f"the manifest {path}: provides is not a list")
    out = []
    for item in value:
        if not isinstance(item, str):
            raise errors.GuardenError(
                f"the manifest {path}: a provides entry is a single string naming a kind, "
                f"and {item!r} is not a string"
            )
        if item not in PROVIDES_KINDS:
            raise errors.GuardenError(
                f"the manifest {path}: provides names the kind {item!r}, and the kinds are "
                f"{', '.join(PROVIDES_KINDS)}"
            )
        out.append(item)
    return out


def _project(value: Any, path: Path) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or not names.NAME_RE.match(value):
        raise errors.GuardenError(
            f"the manifest {path}: project {value!r} must match {names.NAME_RE.pattern}"
        )
    return value


def _units(value: Any, path: Path) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or not value.strip():
        raise errors.GuardenError(f"the manifest {path}: units is not a path")
    return value


def _schema(value: Any, path: Path) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or not value.strip():
        raise errors.GuardenError(f"the manifest {path}: schema is not a path")
    return value


def _needs(value: Any, path: Path) -> list[Edge]:
    """`needs:` entries: a provider service, a prefix, a port and an auth kind.

    **The parser checks the shape and nothing about the host.** Whether the
    provider exists, names a container on the port and holds an allocation for it
    is the mutator's answer before it creates anything (`edges.check`) and the
    renderer's when a document is rendered directly — both against the provider's
    registry, and both exit `1` because the answer came from the host.
    """
    entries = _entries(value, "needs", path)
    out: list[Edge] = []
    seen: dict[str, int] = {}
    for entry in entries:
        service = entry.get("service")
        if not isinstance(service, str) or not names.NAME_RE.match(service):
            raise errors.GuardenError(
                f"the manifest {path}: a needs entry names {service!r} as its service, and "
                f"a service is a name matching {names.NAME_RE.pattern}"
            )
        prefix = entry.get("as")
        if not isinstance(prefix, str) or not AS_RE.match(prefix):
            raise errors.GuardenError(
                f"the manifest {path}: the needs entry for {service!r} has `as: "
                f"{prefix!r}`, and it is the prefix of the generated variables, so it must "
                f"match {AS_RE.pattern}"
            )
        if prefix in seen:
            raise errors.GuardenError(
                f"the manifest {path}: two needs entries use `as: {prefix}`, and it is the "
                f"prefix of the generated variables, so it has to be unique"
            )
        seen[prefix] = 1
        auth = entry.get("auth")
        if auth not in AUTH_KINDS:
            raise errors.GuardenError(
                f"the manifest {path}: the needs entry for {service!r} has `auth: {auth!r}`, "
                f"and there is no default: it is one of {', '.join(AUTH_KINDS)}"
            )
        databases = _databases(entry.get("databases"), service, path)
        out.append(
            Edge(
                service=service,
                prefix=prefix,
                port=_port(entry.get("port"), f"the needs entry for {service!r}", path),
                auth=str(auth),
                databases=databases,
            )
        )
    return out


def _databases(value: Any, service: str, path: Path) -> tuple[str, ...]:
    """Parse the optional `databases:` key on a needs entry.

    Returns a tuple of database names (possibly empty). Each name becomes a
    role+database pair in the provider. Names must be valid postgres
    identifiers and must be unique within the edge.
    """
    if value is None:
        return ()
    if not isinstance(value, list):
        raise errors.GuardenError(
            f"the manifest {path}: the needs entry for {service!r} has a "
            f"`databases` key that is not a list"
        )
    out: list[str] = []
    seen: set[str] = set()
    for item in value:
        if not isinstance(item, str) or not DB_NAME_RE.match(item):
            raise errors.GuardenError(
                f"the manifest {path}: a databases entry {item!r} for "
                f"{service!r} must be a name matching {DB_NAME_RE.pattern}"
            )
        if item in seen:
            raise errors.GuardenError(
                f"the manifest {path}: the databases list for {service!r} "
                f"contains {item!r} more than once"
            )
        seen.add(item)
        out.append(item)
    return tuple(out)


def _publications(value: Any, path: Path) -> list[Publication]:
    """`ports:` entries. A bare `"8080/tcp"` string is not a valid entry: a grant
    is a translation to a publication, and a publication is per container, so an
    entry that named only a public number named no destination."""
    out: list[Publication] = []
    for entry in _entries(value, "ports", path):
        container = entry.get("container")
        if not isinstance(container, str) or not container.strip():
            raise errors.GuardenError(
                f"the manifest {path}: a ports entry names {container!r} as its container"
            )
        out.append(
            Publication(
                container=container,
                port=_port(entry.get("port"), f"the ports entry for {container!r}", path),
            )
        )
    return out


def _routes(value: Any, path: Path) -> list[Route]:
    out: list[Route] = []
    for entry in _entries(value, "routes", path):
        container = entry.get("container")
        if not isinstance(container, str) or not container.strip():
            raise errors.GuardenError(
                f"the manifest {path}: a routes entry names {container!r} as its container"
            )
        host = entry.get("host")
        if not isinstance(host, str) or not HOST_RE.match(host):
            raise errors.GuardenError(
                f"the manifest {path}: the routes entry for {container!r} has `host: "
                f"{host!r}`, and it is a label rather than a domain — the full name is the "
                f"track's host_prefix plus this, and it must match {HOST_RE.pattern}"
            )
        out.append(
            Route(
                container=container,
                port=_port(entry.get("port"), f"the routes entry for {container!r}", path),
                host=host,
                auth=bool(entry.get("auth", False)),
            )
        )
    return out


def _widgets(value: Any, path: Path) -> list[Widget]:
    out: list[Widget] = []
    for entry in _entries(value, "widgets", path):
        container = entry.get("container")
        if not isinstance(container, str) or not container.strip():
            raise errors.GuardenError(
                f"the manifest {path}: a widgets entry names {container!r} as its container"
            )
        file = entry.get("file")
        if not isinstance(file, str) or not file.strip():
            raise errors.GuardenError(
                f"the manifest {path}: the widgets entry for {container!r} has no file"
            )
        _check_widget_file(file, path, container)
        out.append(Widget(container=container, file=file))
    return out


def _firewall(value: Any, path: Path) -> list[RuleRequest]:
    """`firewall:` entries: a name, a chain and one iptables-shaped rule line.

    **A request installs nothing.** The whole of what this block does is produce
    three fields the mutator records, and the closed shape is what makes that
    safe: `rules` admits only options that add a rule, so there is no key here
    that could flush a chain, set a policy or take a position. `chain` may be
    omitted and defaults to the chain guarden jumps to from `filter OUTPUT`, so
    a manifest that names no chain asks for a rule in guarden's own chain
    rather than having the entry refused for a key nobody had to write.

    `rules.parse` is where the line is checked, and it is called here rather
    than in the renderer because a manifest's failures are the ones nobody hears
    about (spec 4). The `Request` it returns is discarded: what a request is
    written down as is the text the manifest wrote, not the re-derived shape,
    because that text is the identity deduplication is by.
    """
    out: list[RuleRequest] = []
    seen: set[str] = set()
    if not isinstance(value, list):
        raise errors.GuardenError(f"the manifest {path}: firewall is not a list")
    for entry in value:
        name = rules.validate_name(entry.get("name"), f"the manifest {path}")
        if name in seen:
            raise errors.GuardenError(
                f"the manifest {path}: two firewall entries are both named {name!r}, and it is "
                f"what a grant names, so a grant would be ambiguous"
            )
        seen.add(name)
        where = f"the firewall entry {name!r} in the manifest {path}"
        chain = rules.validate_chain(entry.get("chain"), where)
        out.append(
            RuleRequest(
                name=name,
                chain=chain,
                rule=rules.parse(entry.get("rule"), where).rule,
            )
        )
    return out


def _entries(value: Any, block: str, path: Path) -> list[dict]:
    if not isinstance(value, list):
        raise errors.GuardenError(f"the manifest {path}: {block} is not a list")
    for entry in value:
        if isinstance(entry, dict) and "service" in entry and block != "needs":
            raise errors.GuardenError(
                f"the manifest {path}: a {block} entry has a `service:` key; a {block} entry "
                f"names a container inside this service, and `service:` is how you tell the "
                f"two apart"
            )
    return value


# --- the `scrub:` block ------------------------------------------------------
#
# **The rule is a POLICY and the manifest is its home** (ADR-0025). It is the
# operator's statement of what a cloned database must not carry, and the
# manifest is where a project declares what it is — so the rule is versioned
# with the deployment, reviewable in a pull request, and travels with the code
# it describes. It is not in `overrides.toml` (that is the admin's GRANT
# surface, and a scrub grants nothing) and not in the registry (that is the
# host's record of a service, not a policy).


def _scrub(value: Any, path: Path) -> Scrub:
    """The `scrub:` block, and every way of writing one that is not one."""
    if value is None:
        return Scrub()
    if not isinstance(value, dict):
        raise errors.GuardenError(f"the manifest {path}: scrub is not a mapping")
    extra = sorted(set(value) - {"tables", "keys"})
    if extra:
        raise errors.GuardenError(
            f"the manifest {path}: scrub has an unknown key {extra[0]!r}; the keys are: "
            f"keys, tables"
        )
    tables = _scrub_tables(value.get("tables"), path)
    keys = _scrub_keys(value.get("keys"), path)
    return Scrub(tables=tuple(tables), keys=tuple(keys))


def _scrub_tables(value: Any, path: Path) -> list[ScrubTable]:
    if value is None:
        return []
    if not isinstance(value, list):
        raise errors.GuardenError(f"the manifest {path}: scrub tables is not a list")
    out: list[ScrubTable] = []
    for entry in value:
        if not isinstance(entry, dict):
            raise errors.GuardenError(
                f"the manifest {path}: a scrub tables entry is not a mapping"
            )
        extra = sorted(set(entry) - SCRUB_TABLE_KEYS)
        if extra:
            raise errors.GuardenError(
                f"the manifest {path}: a scrub tables entry has an unknown key {extra[0]!r}; "
                f"the keys are: name"
            )
        name = entry.get("name")
        if not isinstance(name, str) or not name.strip():
            raise errors.GuardenError(
                f"the manifest {path}: a scrub tables entry has no `name:`, and a table is "
                f"what the rule acts on"
            )
        out.append(ScrubTable(name=name))
    return out


def _scrub_keys(value: Any, path: Path) -> list[ScrubKey]:
    if value is None:
        return []
    if not isinstance(value, list):
        raise errors.GuardenError(f"the manifest {path}: scrub keys is not a list")
    out: list[ScrubKey] = []
    for entry in value:
        if not isinstance(entry, dict):
            raise errors.GuardenError(f"the manifest {path}: a scrub keys entry is not a mapping")
        extra = sorted(set(entry) - SCRUB_KEYS)
        if extra:
            raise errors.GuardenError(
                f"the manifest {path}: a scrub keys entry has an unknown key {extra[0]!r}; the "
                f"keys are: column, equals, prefix, table"
            )
        table = entry.get("table")
        column = entry.get("column")
        if not isinstance(table, str) or not table.strip():
            raise errors.GuardenError(
                f"the manifest {path}: a scrub keys entry has no `table:`, and a table is what "
                f"the rule acts on"
            )
        if not isinstance(column, str) or not column.strip():
            raise errors.GuardenError(
                f"the manifest {path}: a scrub keys entry has no `column:`, and the column is "
                f"the one the rule matches on"
            )
        prefix = entry.get("prefix")
        equals = entry.get("equals")
        if prefix is None and equals is None:
            raise errors.GuardenError(
                f"the manifest {path}: the scrub keys entry for the table {table!r} names "
                f"neither a `prefix:` nor an `equals:`, so it matches every row of the table — "
                f"and a rule that empties a table is a `tables:` rule, not a `keys:` one"
            )
        if prefix is not None and equals is not None:
            raise errors.GuardenError(
                f"the manifest {path}: the scrub keys entry for the table {table!r} names both "
                f"a `prefix:` and an `equals:`, and a rule matches one way"
            )
        if prefix is not None and not isinstance(prefix, str):
            raise errors.GuardenError(
                f"the manifest {path}: the scrub keys entry for the table {table!r} has a "
                f"`prefix:` that is not a string"
            )
        if equals is not None and not isinstance(equals, str):
            raise errors.GuardenError(
                f"the manifest {path}: the scrub keys entry for the table {table!r} has an "
                f"`equals:` that is not a string"
            )
        out.append(
            ScrubKey(table=table, column=column, prefix=prefix, equals=equals)
        )
    return out


def _port(value: Any, where: str, path: Path) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise errors.GuardenError(
            f"the manifest {path}: {where} has `port: {value!r}`, which is not a number"
        )
    if not PORT_MIN <= value <= PORT_MAX:
        raise errors.GuardenError(
            f"the manifest {path}: {where} has port {value}, and a port is "
            f"{PORT_MIN}-{PORT_MAX}"
        )
    return value
