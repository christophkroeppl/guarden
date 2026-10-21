"""The mutator's half of a declared edge: its publication and its credential.

spec 5.3 steps 6 and 10, spec 7.4 and §7.6. One `needs:` entry produces three
things: a loopback publication the provider binds and the consumer dials, a
record in the consumer's registry, and a credential scoped to that edge.

**The number is the provider's own allocation, copied into the consumer's edge.**
It cannot be a second allocation: the provider's container binds one
`PublishPort=127.0.0.1:<pub>:<port>` and the consumer's `<AS>_PORT` has to name
it, so two independent numbers are two ports where one is expected. The copy is
what `render.edge_publications` reads and what `firewall.consumer_uids` grants
against, so the variable, the rule and the bind cannot disagree.
"""

from __future__ import annotations

from guarden import config as config_mod
from guarden import credentials, edgeresolve, errors, paths, registry, tool
from guarden import manifest as manifest_mod

AUTH_DATABASE = "database"
AUTH_SECRET = "secret"
AUTH_NONE = "none"

ENGINE = "postgres"
PSQL_USER = "postgres"
MIN_VERSION = 100000
SQL_ON_STDIN: tuple[str, ...] = ("-f", "-")
VALUE_ALPHABET = "-_"


def credential_key(kind: str, edge: manifest_mod.Edge) -> str:
    """`<AS>_SECRET` for a secret edge, `<AS>_PASSWORD` for a database one.

    The name IS the schema's key, which is what the gate's `@required` check and the
    example-placeholder comparison both match on, so it carries no port. Two edges
    of one service that shared a prefix would share a value, and `as:` being the
    prefix is what makes that unexpressible: the schema declares one credential per
    prefix. The PORT and the AS distinguish two edges in the REGISTRY (see
    `edge_key`), which is where two edges of one provider are told apart.
    """
    suffix = "SECRET" if kind == AUTH_SECRET else "PASSWORD"
    return f"{edge.variable}_{suffix}"


def resolve_name(config: config_mod.Config, environment: str, edge: manifest_mod.Edge) -> str:
    """The concrete provider this edge dials: the host's pin, then the track's.

    The one consult point for a `needs:` entry's provider name, because the
    mutator writes the registry key from it and the renderer reads it back by
    the same name. See `edgeresolve` for the two tables and the order between
    them.
    """
    return edgeresolve.resolve(config, environment, edge.service)


def check(consumer: str, document: manifest_mod.Manifest, environment: str,
          config: config_mod.Config) -> None:
    """Refuse every edge the render would refuse, before anything is created.

    **The render runs in the same command that creates the service**, and it reads
    an edge's publication from the consumer's registry record: the provider's own
    allocation, copied in by `install`. It cannot invent one (§6.3), so an edge
    whose provider is absent, serves no container on that port, or allocates no
    publication for it has no unit the render can write. `service.create` renders
    after identity and after the volumes, so that refusal would land on a service
    that already exists on the box with a registry record and no units — hence this
    check, before identity and before the volumes, making the same answer first.

    A self-edge is the one refusal that is exit `2`: the manifest named the service
    that declares the edge, which is visible from the consumer's own name and is
    nearly always a copy-paste. Every other answer here came from the host's
    registry, so it is exit `1` (spec 1.2, spec 4).
    """
    for edge in document.needs:
        _installable(consumer, edge, environment, config)


def edge_key(provider: str, port: int, as_: str = "") -> str:
    """The key one `needs:` entry is recorded under.

    Three entries may name ONE provider, on two ports and one of them twice: a
    provider with a database and a vault container offers two publications, and a
    consumer may ask it for a database twice under two `as:` prefixes. The
    provider and the port alone told apart only the first two, so a second edge
    that shared the port silently replaced the first, and the consumer lost the
    publication and the credential the overwritten entry had. The `as:` prefix
    is the third part: it is the variable name a `needs:` entry declares, it is
    unique per manifest, and it is in every caller's hands beside the provider
    and the port.

    A key written by an earlier guarden carries only provider and port, and is
    still read, so `provider_of` reads it back and an empty prefix keeps it.
    """
    return f"{provider}:{port}:{as_}"


def provider_of(key: str) -> str:
    """The provider name inside an edge key."""
    return key.rsplit(":", 2)[0]


def _offered(consumer: str, edge, provider) -> None:
    """Raise unless the provider's `provides:` lists the kind the consumer wants.

    **The diagnostic names the CONCRETE provider, because that is the service
    the operator has to fix.** The manifest's `needs:` entry may carry a
    logical name, and the host resolves it per track; a refusal that named the
    logical name would send the operator looking for a service that does not
    exist on this host.
    """
    if edge.prefix in provider.provides:
        return
    raise errors.GuardenError(
        f"{consumer} needs {edge.service!r} as {edge.prefix!r}, and {provider.service} offers "
        f"{', '.join(provider.provides) or 'nothing'}: the consumer wants the kind "
        f"{edge.prefix!r} and the provider does not list it",
        errors.HOST_NOT_AS_ASSUMED,
    )


def _installable(consumer: str, edge, environment: str, config: config_mod.Config,
                 ) -> tuple[str, registry.Registry, str, int]:
    """The concrete provider, the container serving the edge's port, and the
    publication the consumer dials — or the refusal that says why it cannot.

    One answer for the two callers that need it: `check` asks before anything is
    created and discards it, `install` asks again because the answer is what the
    edge's record has to carry. They are the same question, and a second copy of it
    would be a second answer about which port an edge dials. The provider's own
    manifest is readable here and nowhere else: its tree is `0700` to the provider
    and the mutator is root.
    """
    name = resolve_name(config, environment, edge)
    if name == consumer:
        raise errors.GuardenError(
            f"{consumer} needs {edge.service!r} as {edge.prefix!r} on port {edge.port}, which "
            f"resolves to {name!r} — the service that declared it: a self-edge has no consumer "
            f"and is nearly always a copy-paste"
        )
    provider = registry.load(name)
    if provider is None:
        raise errors.GuardenError(
            f"{consumer} needs {edge.service!r} as {edge.prefix!r} on port {edge.port}, and there "
            f"is no registry entry for {name}: an edge dials the provider's own allocated "
            f"publication, so {name} has to exist before the service that dials it — a poke "
            f"creates services in dependency order",
            errors.HOST_NOT_AS_ASSUMED,
        )
    _offered(consumer, edge, provider)
    container = _serving(provider, edge.port)
    if container is None:
        raise errors.GuardenError(
            f"the manifest of {provider.service} names no container on port {edge.port}, so "
            f"{consumer} has nothing to dial: a provider has to name the container that serves "
            f"that port before its consumer is created",
            errors.HOST_NOT_AS_ASSUMED,
        )
    publication = provider.publication.get(container)
    if not isinstance(publication, int) or isinstance(publication, bool):
        raise errors.GuardenError(
            f"the registry entry for {provider.service} allocates no publication for the "
            f"container {container!r} that serves port {edge.port}, so {consumer} has nothing to "
            f"dial: a deploy of {provider.service} gives it one, and the consumer is created "
            f"after that",
            errors.HOST_NOT_AS_ASSUMED,
        )
    return name, provider, container, publication


def install(entry: registry.Registry, document: manifest_mod.Manifest,
            config: config_mod.Config) -> list[str]:
    """Every `needs:` entry: the publication it dials, its registry record and its
    credential. Mutates `entry.edges` in memory; returns the warnings.

    `check` has already refused every edge that cannot be installed, and this asks
    the same question again because its answer is what the record carries: the
    provider's own allocation, which its registry entry holds and no manifest does.
    The warning that survives is `_credential`'s — a provider whose container is not
    running gets a credential planted and its role deferred.
    """
    warnings: list[str] = []
    for edge in document.needs:
        name, provider, container, publication = _installable(
            entry.service, edge, entry.environment, config)
        warnings += _credential(entry, edge, provider, container, publication)
        entry.edges[edge_key(name, edge.port, edge.prefix)] = {
            "port": edge.port,
            "as": edge.prefix,
            "auth": edge.auth,
            "databases": list(edge.databases),
            "publications": [publication],
        }
    return warnings


def _serving(provider: registry.Registry, port: int) -> str | None:
    """The container of the provider that serves `port`, from the provider's own
    manifest. The tree is `0700` to the provider and the mutator is root, so this is
    readable here and nowhere else — and it is read from the provider, never from the
    consumer, because a consumer cannot know which container answers a port it does
    not own."""
    path = paths.manifest_in_home(provider.service)
    if not path.is_file():
        return None
    document = manifest_mod.read(path)
    for entry in [*document.routes, *document.ports]:
        if entry.port == port:
            return entry.container
    return None


def _credential(entry: registry.Registry, edge, provider, container, publication) -> list[str]:
    """One minted value per edge, and `auth: none` plants nothing at all.

    A `secret` edge is planted in both stores because the provider has to be able to
    verify it. The provider's copy is planted only when nothing is there, so a second
    consumer of one provider never takes the first one's value away; the collision that
    leaves is two consumers sharing one `as:` prefix, and no document says how one
    provider names two of the same edge.
    """
    if edge.auth == AUTH_NONE:
        return []
    key = credential_key(edge.auth, edge)
    if credentials.planted(entry.service, key):
        stored = credentials.value(entry.service, key) or ""
    else:
        stored = credentials.generated_value()
        credentials.plant(entry.service, key, stored)
    if edge.auth == AUTH_SECRET and not credentials.planted(provider.service, key):
        credentials.plant(provider.service, key, stored)
    if edge.auth == AUTH_DATABASE:
        return provision(entry.service, provider, container, stored, edge.databases)
    return []


def provision(consumer: str, provider: registry.Registry, container: str,
              password: str, databases: tuple[str, ...] = ()) -> list[str]:
    """One role and one database in the provider, both named after the consumer.

    When `databases` is non-empty, one role+database pair is created per name,
    named `{provider.service}-{db_name}`. The password is minted once per edge
    and reused for all databases.

    **That sharing is a deliberate simplification and not a free one.** The edge
    gets one credential, so every database it provisions is reachable with the
    same password: a leak of the consumer's secret is a leak of all of them, and
    there is no per-database isolation. Nor is there a rotation path —
    `credentials.plant` plants only what is absent, so the value minted on the
    first ingest is the value until the service is removed. A deployment that
    needs isolation between its databases must either give each its own edge
    (possible only when the provider offers the kind twice, which today it does
    not) or mint its own credentials outside guarden. Written down here because
    the shape of the rendered variables — one `DB_PASSWORD` for several
    databases — reads like a per-database secret and is not.

    **The only engine-aware code in guarden, and it is this function.** `ENGINE` is a
    constant named here and nowhere else, and a provider older than `MIN_VERSION` is
    refused rather than degraded to. A container which is not running is a warning and
    not a refusal: a poke installs the provider and the consumer in that order and the
    container starts after the command returns, so refusing here would make every edge
    a two-command deploy. The credential is planted either way, so what the warning
    costs is the role and nothing else.
    """
    container_name = f"{provider.service}-{container}"
    if databases:
        db_names = [f"{provider.service}-{db_name}" for db_name in databases]
    else:
        db_names = [container_name]
    podman = tool.runuser_as(provider.service, "podman")
    listing = [*podman, "ps", "--filter", f"name=^{container_name}$", "--format", "{{.Names}}"]
    running = tool.call(listing, cwd="/tmp")
    if container_name not in running.stdout.split():
        return [
            errors.warn(
                f"the container {container_name} of {provider.service} is not running, "
                f"so no role and no "
                f"database were created for {consumer}; the credential is planted and a deploy "
                f"that starts {provider.service} creates them"
            )
        ]
    psql = [*podman, "exec", "-i", container_name, "psql", "-U", PSQL_USER, "-d", PSQL_USER]
    _check_version(container_name, [*psql, "-Atc", "SHOW server_version_num"])
    ddl = "\n".join(_ddl(name, password) for name in db_names)
    done = tool.call([*psql, "-v", "ON_ERROR_STOP=1", "-f", "-"], stdin=ddl)
    if not done.ok:
        raise errors.GuardenError(
            f"{container_name}: {ENGINE} refused the role and the database for {consumer}: "
            f"{errors.oneline(done.stderr.strip() or done.stdout.strip())}",
            errors.HOST_NOT_AS_ASSUMED,
        )
    return []


def _check_version(name: str, argv: list[str]) -> None:
    """The one feature check. Refusing an older server is better than issuing a
    statement whose behaviour is not the one this was written against."""
    reported = tool.call(argv)
    if not reported.ok:
        raise errors.GuardenError(
            f"{name}: {ENGINE} did not answer its version: "
            f"{errors.oneline(reported.stderr.strip() or reported.stdout.strip())}",
            errors.HOST_NOT_AS_ASSUMED,
        )
    try:
        version = int(reported.stdout.strip())
    except ValueError:
        raise errors.GuardenError(
            f"{name}: {ENGINE} answered {reported.stdout.strip()!r} for its version",
            errors.HOST_NOT_AS_ASSUMED,
        ) from None
    if version < MIN_VERSION:
        raise errors.GuardenError(
            f"{name} runs {ENGINE} {version // 10000} and guarden creates a role and a "
            f"database on {MIN_VERSION // 10000} and later only",
            errors.HOST_NOT_AS_ASSUMED,
        )


def _ddl(role: str, password: str) -> str:
    """Idempotent: each object is created only when absent, and the password is then
    set so a re-run converges.

    The password goes on the pipe rather than in argv, where every process list on the
    box would show it, and it is interpolated only because a minted value is
    `[A-Za-z0-9_-]` — the one assumption this function makes about its own input, so it
    is checked here rather than trusted.
    """
    if not password or not all(c.isalnum() or c in VALUE_ALPHABET for c in password):
        raise errors.GuardenError(
            f"the minted password for the role {role!r} is not [A-Za-z0-9_-]",
            errors.HOST_NOT_AS_ASSUMED,
        )
    return "\n".join(
        [
            f"SELECT 'CREATE ROLE \"{role}\" LOGIN' WHERE NOT EXISTS"
            f" (SELECT 1 FROM pg_roles WHERE rolname = '{role}')\\gexec",
            f"ALTER ROLE \"{role}\" LOGIN PASSWORD '{password}';",
            f"SELECT 'CREATE DATABASE \"{role}\" OWNER \"{role}\"' WHERE NOT EXISTS"
            f" (SELECT 1 FROM pg_database WHERE datname = '{role}')\\gexec",
        ]
    ) + "\n"