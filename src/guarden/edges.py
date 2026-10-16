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
from guarden import credentials, errors, paths, registry, tool
from guarden import manifest as manifest_mod

AUTH_DATABASE = "database"
AUTH_SECRET = "secret"
AUTH_NONE = "none"

ENGINE = "postgres"
PSQL_USER = "postgres"
MIN_VERSION = 100000
SQL_ON_STDIN = "-f -"
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
    return config.resolve_provider(environment, edge.service)


def check(consumer: str, document: manifest_mod.Manifest, environment: str,
          config: config_mod.Config) -> None:
    """Refuse an edge the provider does not offer, before anything is created.

    Both service names and both kinds are in the diagnostic, because "the edge is
    wrong" is not something a person can act on otherwise. The answer came from the
    provider's registry rather than from the input, so it is exit `1` and not a
    rejected input (spec 1.2, spec 4).

    This runs before identity and before the volumes, deliberately. `loom render`
    refuses the same edge and always will, but a mutator that discovered it at the end
    of its own ordering would leave a system user, a home and a subvolume behind on the
    way out — a service that exists on the box and in no registry.

    **A provider with no registry entry is not refused here.** A poke creates services
    in dependency order and a manifest may name one a later deploy brings into being
    (spec 4), so there is nothing to compare against, and the render is the right place
    to say so.
    """
    for edge in document.needs:
        provider = registry.load(resolve_name(config, environment, edge))
        if provider is None:
            continue
        _offered(consumer, edge, provider)


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
    """Raise unless the provider's `provides:` lists the kind the consumer wants."""
    if edge.prefix in provider.provides:
        return
    raise errors.GuardenError(
        f"{consumer} needs {edge.service!r} as {edge.prefix!r}, and {edge.service} offers "
        f"{', '.join(provider.provides) or 'nothing'}: the consumer wants the kind "
        f"{edge.prefix!r} and the provider does not list it",
        errors.HOST_NOT_AS_ASSUMED,
    )


def install(entry: registry.Registry, document: manifest_mod.Manifest,
            config: config_mod.Config) -> list[str]:
    """Every `needs:` entry: the publication it dials, its registry record and its
    credential. Mutates `entry.edges` in memory; returns the warnings.

    A provider with no registry entry is a warning, not a refusal: a poke creates
    services in dependency order and a manifest may name one a later deploy brings
    into being (spec 4). The edge is recorded with no publication, and `loom` is
    what refuses it — the manifest was fine and the answer came from the host, so
    the two answers stay in the two programs that own them.
    """
    warnings: list[str] = []
    for edge in document.needs:
        provider_name = resolve_name(config, entry.environment, edge)
        provider = registry.load(provider_name)
        publication: int | None = None
        if provider is None:
            warnings.append(
                errors.warn(
                    f"{entry.service} needs {edge.service!r} as {edge.prefix!r}, and there is "
                    f"no registry entry for it; the edge is recorded with no publication and "
                    f"no credential, and a deploy that creates the provider completes it"
                )
            )
        else:
            _offered(entry.service, edge, provider)
            container = _serving(provider, edge.port)
            publication, said = _publication(entry.service, edge, provider, container)
            warnings += said
            if publication is not None:
                warnings += _credential(entry, edge, provider, container, publication)
        entry.edges[edge_key(provider_name, edge.port, edge.prefix)] = {
            "port": edge.port,
            "as": edge.prefix,
            "auth": edge.auth,
            "databases": list(edge.databases),
            "publications": [] if publication is None else [publication],
        }
    return warnings


def _publication(
    consumer: str, edge, provider, container: str | None
) -> tuple[int | None, list[str]]:
    """The loopback port this edge is served on, from the provider's own registry.

    The provider names the container and the container's port in its own manifest,
    and that entry is what gave the container its publication when the provider was
    created (§7.4). Every reason the answer is `None` says itself, because a
    consumer whose edge records no publication is refused by the render, and the
    diagnostic here is the one that can still name the container.
    """
    if container is None:
        return None, [
            errors.warn(
                f"the manifest of {provider.service} names no container on port {edge.port}, "
                f"so {consumer} dials nothing: the edge is recorded with no publication, and "
                f"`loom render` refuses it until the provider names the container and its port"
            )
        ]
    held = provider.publication.get(container)
    if isinstance(held, int):
        return held, []
    return None, [
        errors.warn(
            f"the registry entry for {provider.service} allocates no publication for the "
            f"container {container!r} that serves port {edge.port}, so {consumer} dials "
            f"nothing: the edge is recorded with no publication, and a deploy of the "
            f"provider gives it one"
        )
    ]


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
    podman = ["runuser", "-u", provider.service, "--", "podman"]
    listing = [*podman, "ps", "--filter", f"name=^{container_name}$", "--format", "{{.Names}}"]
    running = tool.call(listing)
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
    done = tool.call([*psql, "-v", "ON_ERROR_STOP=1", SQL_ON_STDIN], stdin=ddl)
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
    if not password or not password.replace(VALUE_ALPHABET, "").isalnum():
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