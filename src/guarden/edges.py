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
# Every command below runs as the PROVIDER's own user, and a rootless podman
# enters the working directory as that uid before it reads anything — so the cwd
# has to be one every account can enter. The caller's is not: the first real
# execution of the psql half answered `cannot chdir to /home/ubuntu/guarden:
# Permission denied` with a correct DDL it never got to send, because the
# mutator had been started from a tree that is 0700 to somebody else.
SERVICE_CWD = "/tmp"
# A postgres identifier is truncated at 63 BYTES, silently. A derived name over
# that would be shortened into a name nobody chose — and two of them could be
# shortened into one — so it is refused where it is derived (spec 4).
MAX_IDENTIFIER = 63


def credential_key(kind: str, edge: manifest_mod.Edge) -> str:
    """`<AS>_SECRET` for a secret edge, `<AS>_PASSWORD` for a database one.

    The name IS the schema's key, which is what the gate's `@required` check and the
    example-placeholder comparison both match on, so it carries no port. Two edges
    of one service that shared a prefix would share a value, and `as:` being the
    prefix is what makes that unexpressible: the schema declares one credential per
    prefix. The PORT and the AS distinguish two edges in the REGISTRY (see
    `edge_key`), which is where two edges of one provider are told apart.
    """
    return key_of(kind, edge.variable)


def key_of(kind: str, prefix: str) -> str:
    """The same key from the prefix alone, for a caller that holds no `Edge`.

    `weedr service start` re-attempts step 10 from the consumer's registry entry
    (`provision_pending`), and a registry record carries `as:` rather than a
    parsed `needs:` entry — so the one rule for the name lives here and both
    callers read it.
    """
    suffix = "SECRET" if kind == AUTH_SECRET else "PASSWORD"
    return f"{prefix.upper()}_{suffix}"


def role_name(consumer: str) -> str:
    """The role a `database` edge creates in its provider: the consumer's own name.

    **One role per consumer, per provider.** The edge is the unit of
    authorization (spec 7.6), so the role is the consumer's identity inside the
    provider, and a second database is a second database OWNED by that one role
    rather than a second authority to revoke. That is what makes `databases:` a
    list of objects under one credential instead of several, and it is why the
    role does not carry the database's name.
    """
    return consumer


def database_names(consumer: str, databases: tuple[str, ...] = ()) -> tuple[str, ...]:
    """The databases one `database` edge owns: the consumer's, or one per name.

    `<consumer>` alone when the manifest names none, so a consumer keeps the one
    database named after itself; `databases: [odoo, btcpay]` gives
    `<consumer>-odoo` and `<consumer>-btcpay`.

    **The consumer's name is the prefix because the provider is SHARED.** A
    staging and a production service of one workload both asking for `odoo` are
    two databases and not one, and a database name is a global name inside the
    provider's engine — so the half the manifest chooses is the suffix only, and
    the half that keeps two consumers apart is guarden's. The name is what the
    consumer is told to dial (`<AS>_DATABASE`), and the renderer derives it from
    this same function, so the two cannot disagree.
    """
    if not databases:
        return (consumer,)
    return tuple(f"{consumer}-{name}" for name in databases)


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

    **The derived names are checked here too, and for the same reason.** A
    `database` edge's role and database names are the consumer's, and postgres
    truncates an identifier at 63 bytes — so a name that would be shortened is a
    rejected input, and it is refused before a user, a home and a subvolume exist
    for a service whose own edge could never be created.
    """
    for edge in document.needs:
        _identifiers(consumer, edge)
        provider = registry.load(resolve_name(config, environment, edge))
        if provider is None:
            continue
        _offered(consumer, edge, provider)


def _identifiers(consumer: str, edge: manifest_mod.Edge) -> None:
    """Raise unless every name this edge derives is an identifier postgres keeps."""
    if edge.auth != AUTH_DATABASE:
        return
    for name in (role_name(consumer), *database_names(consumer, edge.databases)):
        if len(name.encode()) <= MAX_IDENTIFIER:
            continue
        raise errors.GuardenError(
            f"the manifest gives {consumer!r} a {ENGINE} name {name!r} that is "
            f"{len(name.encode())} bytes long, and {ENGINE} truncates an identifier at "
            f"{MAX_IDENTIFIER}; the name it kept would not be the name written here, so "
            f"it is refused rather than shortened",
            errors.REJECTED_INPUT,
        )


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
    leaves is two consumers of one provider sharing one `<AS>_SECRET`, and no document
    says how one provider names two of the same edge. A `database` edge plants in the
    consumer's store alone (spec 5.3 step 10) and the role it creates is the
    consumer's own, so no two consumers of one provider can collide there.
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
    """One role named after the consumer, and one database per name the edge declares.

    **One role, several databases** (spec 5.3 step 10). The role is the
    consumer's identity inside the provider and the databases are its objects, so
    every database is owned by the one role and reached with the one credential
    the edge minted. That is deliberate and it is not free: a leak of the
    consumer's secret is a leak of all its databases, and there is no per-database
    isolation. Nor is there a rotation path — `credentials.plant` plants only what
    is absent, so the value minted on the first ingest is the value until the
    service is removed. A deployment that needs isolation between its databases
    must mint its own credentials outside guarden; the manifest has no second edge
    to give it, because a second `database` edge to one provider is refused by the
    provider's own kind list (spec 4). Written down because the rendered
    variables — one `<AS>_PASSWORD` over several `<AS>_<DB>_DATABASE` names —
    would otherwise read like a per-database secret.

    **The only engine-aware code in guarden, and it is this function.** `ENGINE` is a
    constant named here and nowhere else, and a provider older than `MIN_VERSION` is
    refused rather than degraded to. A container which is not running is a warning and
    not a refusal: a poke installs the provider and the consumer in that order and the
    container starts after the command returns, so refusing here would make every edge
    a two-command deploy. The credential is planted either way, so what the warning
    costs is the role and nothing else — and `provision_pending` is the other half of
    that bargain: the command that starts the consumer creates what this one could not.
    """
    role = role_name(consumer)
    names = database_names(consumer, databases)
    container_name = f"{provider.service}-{container}"
    podman = tool.runuser_as(provider.service, "podman")
    listing = [*podman, "ps", "--filter", f"name=^{container_name}$", "--format", "{{.Names}}"]
    running = tool.call(listing, cwd=SERVICE_CWD)
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
    # **The ownership check runs BEFORE the DDL**, so a name this edge cannot
    # have costs nothing: a role created for a database that is then refused
    # would be a name with no objects behind it, and the next attempt would meet
    # it as an existing role and have to decide what to do with it.
    _refuse_foreign(container_name, psql, role, names)
    done = tool.call(
        [*psql, "-v", "ON_ERROR_STOP=1", "-f", "-"], stdin=_ddl(role, password, names),
        cwd=SERVICE_CWD,
    )
    if not done.ok:
        raise errors.GuardenError(
            f"{container_name}: {ENGINE} refused the role and the databases for {consumer}: "
            f"{errors.oneline(done.stderr.strip() or done.stdout.strip())}",
            errors.HOST_NOT_AS_ASSUMED,
        )
    return []


def provision_pending(record: registry.Registry) -> list[str]:
    """Step 10 again, for a service that is already installed (spec 5.3).

    A consumer's ingest normally runs before its provider's container is up — a
    poke installs the provider and the consumer in that order and neither ingest
    starts anything — so `provision` warns, creates no role, and is never asked
    again: the deploy that would re-run step 10 answers `converged` and installs
    nothing. What is left on the box is a credential naming a role nobody made,
    which is the state ticket 284 measured — every `auth: database` edge on the
    host decorative, and every working consumer talking to its provider as the
    superuser instead.

    **`weedr service start` is the later command**, and it is the right one: it
    is the moment the container that needs the role is about to run, the provider
    it dials is up by then, and `provision` is idempotent — a role and a database
    that exist are left as they are and the password is set to the value the edge
    already holds. Nothing here can create a second credential: the value is read
    from the consumer's own store, which is where the ingest planted it.
    """
    warnings: list[str] = []
    for key in sorted(record.edges):
        entry = record.edges[key] or {}
        if entry.get("auth") != AUTH_DATABASE:
            continue
        provider = registry.load(provider_of(key))
        if provider is None:
            warnings.append(
                errors.warn(
                    f"{record.service} has a database edge to {provider_of(key)} and there is "
                    f"no registry entry for it, so the role was not created; a deploy of "
                    f"{provider_of(key)} completes it"
                )
            )
            continue
        port = entry.get("port")
        container = _serving(provider, port) if isinstance(port, int) else None
        if container is None:
            warnings.append(
                errors.warn(
                    f"{record.service} has a database edge to {provider.service} on port "
                    f"{port}, and the manifest of {provider.service} names no container on "
                    f"it, so the role was not created"
                )
            )
            continue
        prefix = str(entry.get("as") or "")
        if not prefix:
            continue
        password = credentials.value(record.service, key_of(AUTH_DATABASE, prefix)) or ""
        if not password:
            warnings.append(
                errors.warn(
                    f"{record.service} has a database edge recorded with no planted "
                    f"{key_of(AUTH_DATABASE, prefix)}, so the role in {provider.service} was "
                    f"not created; `weedr service ingest` plants it"
                )
            )
            continue
        databases = tuple(str(name) for name in (entry.get("databases") or ()))
        warnings += provision(record.service, provider, container, password, databases)
    return warnings


def _refuse_foreign(name: str, psql: list[str], role: str, databases: tuple[str, ...]) -> None:
    """Refuse a database of this edge's own name that another role already owns.

    `CREATE DATABASE` is conditional on the name being ABSENT, so a database that
    already exists and belongs to somebody else is the one case the DDL passes
    over in silence — and the consumer would then hold a credential for a
    database it cannot write to, which is the failure mode ticket 284 is about.
    The alternative, `ALTER DATABASE ... OWNER TO`, would take the other
    consumer's data, so the name is refused and both names are printed.
    """
    listed = ", ".join(f"'{database}'" for database in databases)
    query = (
        "SELECT datname || ' (owner ' || pg_get_userbyid(datdba) || ')' FROM pg_database "
        f"WHERE datname IN ({listed}) AND pg_get_userbyid(datdba) <> '{role}'"
    )
    held = tool.call([*psql, "-Atc", query], cwd=SERVICE_CWD)
    if not held.ok:
        raise errors.GuardenError(
            f"{name}: {ENGINE} did not answer which role owns the databases of {role!r}: "
            f"{errors.oneline(held.stderr.strip() or held.stdout.strip())}",
            errors.HOST_NOT_AS_ASSUMED,
        )
    foreign = "; ".join(
        errors.oneline(line) for line in held.stdout.splitlines() if line.strip()
    )
    if foreign:
        raise errors.GuardenError(
            f"{name}: the edge of {role!r} would own a database another role already has: "
            f"{foreign}; a database name is global inside the provider, so the edge refuses "
            f"it rather than taking it over",
            errors.HOST_NOT_AS_ASSUMED,
        )


def _check_version(name: str, argv: list[str]) -> None:
    """The one feature check. Refusing an older server is better than issuing a
    statement whose behaviour is not the one this was written against."""
    reported = tool.call(argv, cwd=SERVICE_CWD)
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


def _ddl(role: str, password: str, databases: tuple[str, ...]) -> str:
    """Idempotent: each object is created only when absent, and the password is then
    set so a re-run converges.

    One role, and one `CREATE DATABASE ... OWNER` per name, so an edge's databases
    belong to the edge's role and to nothing else. The `\\gexec` form is what
    makes a create conditional — `CREATE DATABASE` has no `IF NOT EXISTS` — and
    each statement runs on its own, which is required: `CREATE DATABASE` cannot
    run inside a transaction block.

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
    lines = [
        f"SELECT 'CREATE ROLE \"{role}\" LOGIN' WHERE NOT EXISTS"
        f" (SELECT 1 FROM pg_roles WHERE rolname = '{role}')\\gexec",
        f"ALTER ROLE \"{role}\" LOGIN PASSWORD '{password}';",
    ]
    for database in databases:
        lines.append(
            f"SELECT 'CREATE DATABASE \"{database}\" OWNER \"{role}\"' WHERE NOT EXISTS"
            f" (SELECT 1 FROM pg_database WHERE datname = '{database}')\\gexec"
        )
    return "\n".join(lines) + "\n"