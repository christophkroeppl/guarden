# 284 — a consumer cannot have more than one database edge to one provider

Found 2026-10-14 while planning the `odoo-btc-bcr` deployment. **A real capability
gap, and it is the one that decides whether that stack can share a postgres.**

## What is measured

A consumer can declare **at most one** `auth: database` edge per provider, for two
independent reasons, each measured by ingesting a manifest on the deploy VM:

**1. `as:` must equal the provider's `provides:` kind, so a second edge cannot get
a distinct prefix.**

```yaml
needs:
  - {service: postgres-production, as: db,  port: 5432, auth: database}
  - {service: postgres-production, as: db2, port: 5432, auth: database}
```

```
error: dbtest2-staging needs 'postgres-production' as 'db2', and postgres-production
offers db: the consumer wants the kind 'db2' and the provider does not list it
```

`edges._offered` requires `edge.prefix in provider.provides`, and the only kinds are
`db` and `secret` (`manifest.PROVIDES_KINDS`). So both edges must say `as: db`.

**2. Two `as:` prefixes that are equal are refused.**

```
error: the manifest ...: two needs entries use `as: db`, and it is the prefix of the
generated variables, so it has to be unique
```

The prefix is the first half of every generated variable name, so it must be unique
per manifest.

So the two requirements are jointly unsatisfiable for a second database edge: the
prefix must be `db` (reason 1) and must be unique (reason 2). A manifest can ask a
provider for **one** database, and no more.

## What one database edge is *written* to mint

`edges._ddl` creates **one role and one database**, both named
`{provider.service}-{container}` — from `edges.provision`'s `name`, which is the
provider's own serving container. On this host that is `postgres-production-db`.
The name is not the consumer's, and it is not configurable.

## What one database edge *actually* minted here: nothing

Measured on the deploy VM after ingesting a consumer with the edge:

```
$ psql -U guarden -Atc "SELECT rolname FROM pg_roles WHERE rolname NOT LIKE 'pg\\_%'"
guarden
$ psql -U guarden -Atc "SELECT datname FROM pg_database"
postgres
guarden
template1
template0
umami
```

**The role `postgres-production-db` does not exist, and no per-consumer role or
database exists at all.** So `provision`'s DDL has never run successfully on this
host. `provision` warns and returns without provisioning when the provider's
container is not running at ingest time ("the credential is planted either way, so
what the warning costs is the role and nothing else"), and the ingest that would
have re-attempted it is short-circuited by **ticket 275** (`converged`), so the
warning is emitted once and never again.

The consequence is bigger than the edge model: **every `auth: database` edge on
this host is decorative.** The consumer receives `DB_HOST`, `DB_PORT` and a
`DB_PASSWORD` secret, and the role and database that password belongs to were never
created. `umami-production` only works because it was given a hand-written literal
URL using the `guarden` superuser role and a hand-created `umami` database — it
does not use its edge credential at all. That is the finding this ticket should be
read for, and it is a **security** finding as much as a functional one: the
intended per-consumer role boundary does not exist, and every consumer that does
work is working as the superuser.

## Why this blocks odoo-btc-bcr

That stack needs **three** databases in one postgres — `odoo`, `btcpay` and
`nbxplorerregtest` (the latter two are read from the services' own connection
strings in `devel.yaml`). With one edge it is written to get one database; there is
no expression for the other two. The deployment cannot share `postgres-production`
as the instruction requires until either the edge model or the stack's database
count changes.

## What this ticket wants

- **First, make the edge provision at all.** The role and database must exist
  before anything else in this ticket matters, and today they do not. Whether the
  fix is re-attempting provisioning on a later command (275) or refusing the
  consumer until the provider is up, the current state — a planted credential
  naming objects that were never created — is the worst of the options.
- **Then, a way to name more than one database per consumer**, e.g.
  `databases: [odoo, btcpay, nbxplorerregtest]` on the edge, with the role
  remaining one per consumer. This keeps the edge the unit of authorization while
  letting one consumer own several databases, which is what a real application
  needs.
- **A distinct `as:` prefix that is not the kind** is *not* a fix on its own:
  reason 1 above is about the kind check, not the name.

## Measured again 2026-10-19 — the gap now produces posture debt, not just refusal

On the fresh box `e2e-fresh-scripts` (manual fleet deploy), umami-staging needed
postgres-staging's port and the edge model had no path for it, so the deploying
agent hand-wrote `PublishPort=0.0.0.0:5433:5432` into postgres-staging's quadlet
(the in-unit comment states the real reason a loopback bind does not work: one
service user's container cannot reach ANOTHER user's 127.0.0.1 host bind — cross-
service container traffic must arrive on a host-published port). Verified after:

```
ferm default-deny holds:  external TCP to <box-ip>:5433  DENIED
                          control: external TCP to <box-ip>:22 OPEN
bind itself:              0.0.0.0:5433 (posture rule says loopback unless a
                          publication is a recorded, gated-track act)
fleet MD verdict:         claimed "no deviations" — the bind was undisclosed
                          there, only in the unit's inline comments
```

So the failure mode has grown: with no edge path for a second service on one box,
an agent's fastest working move is a public bind whose only barrier is ferm. This
is the ticket's "what this ticket wants" in miniature — a cross-service edge on
one box needs the same treatment as the database edge: refused or provisioned,
never a hand-written 0.0.0.0.

## What the implementation settled

**The role is the consumer's, and there is one of it per consumer per provider.**
The ticket's "with the role remaining one per consumer" was not true of the
code: `_ddl` created **one role per database**, both named
`{provider.service}-{name}`, and in the single-database case the role AND the
database were named `{provider.service}-{container}` — the provider's own
container name, shared by every consumer of that provider. Two consumers of one
postgres could not both hold a working credential: the second `ALTER ROLE …
PASSWORD` took the first one's role over. The role is now `<consumer>` and the
databases are `<consumer>` (no `databases:` key) or `<consumer>-<name>` per
entry, which is the spec 5.3 step 10 text.

The prefix is guarden's for a stated reason: a database name is global inside
the provider's engine, so a staging and a production service of one workload
that both ask for `odoo` must be two databases. **A host that already has a
database under the old name finds the edge creating a new, empty one.** Nothing
migrates them, because the ticket's own measurement is that the DDL had never
run on the host it was measured on — but the rename is stated rather than
implied, and a database of the edge's own name that another role already owns is
refused instead of adopted (`ALTER DATABASE … OWNER TO` would move somebody
else's data).

**The rendered environment names what was created**: `<AS>_USER` (the role) and
`<AS>_DATABASE`, or one `<AS>_<NAME>_DATABASE` per entry. Before this the
environment named neither, which is why the `odoo-btc-bcr` deploy hand-wrote
`odoo@postgres-production:20000` and why the database name was not derivable
from anything guarden emitted. Both names come from `edges.role_name` and
`edges.database_names` — the same two functions the mutator creates the objects
with.

**The later command is `weedr service start`, not a re-ingest.** Spec 5.3 says a
converged `ingest`/`add` "changes nothing", so the re-attempt belongs on a verb
that does something anyway; start is the moment the container that needs the
role is about to run. `restart` runs it too. A provider that is still down is
the same warning and does not refuse the start.

**Two refusals joined it, both of the silent-drop class**: `databases:` on an
edge whose `auth:` is not `database` (that edge creates no database, so the list
would be a declaration that does nothing), and a derived name over postgres's
63-byte limit (postgres truncates silently, so two names could truncate into
one).

## Two defects the suite found, both in the code this ticket wrote

- **The psql half ran where the provider's user cannot enter.** `provision`
  passed `cwd="/tmp"` to `podman ps` and to none of the psql calls, so they
  inherited the mutator's working directory — and a rootless podman enters that
  directory as the provider's uid before it reads anything. The first execution
  against a real engine answered `cannot chdir to /home/ubuntu/guarden:
  Permission denied`. One `SERVICE_CWD` now covers all four calls.
- **The one-database render crashed.** `_environment_file` zipped
  `edge.databases` against `database_names(…)` with `strict=True`; with no
  `databases:` list the first is empty and the second is `(consumer,)`, so the
  installed `loom` raised `ValueError: zip() argument 2 is longer than argument
  1` and every consumer with a `database` edge and no list failed its ingest.
  `strict=True` is what turned a silently empty row set into a named crash.

## Status: verified

`tests/t454-database-edge.sh` measures all of it against a real `postgres:17`
started by the provider's own unit through the mutator: RED first (the ingest
warns while the provider is down, and the role is absent after the provider
comes up), then GREEN.

| the ticket's item | where it is measured |
| --- | --- |
| the edge provisions at all, and a later command finishes the job | the ingest warns with the provider down, the role does not exist, `weedr service start` on the consumer creates it, and a `scram` login as that role to each database succeeds |
| more than one database per consumer | `databases: [odoo, btcpay]` gives two databases `<consumer>-odoo` and `<consumer>-btcpay`, both owned by the one role `<consumer>` |
| the role remains one per consumer | asserted ABSENT: no role named after a database exists |
| the names the consumer dials are the names created | the rendered `guarden.env`'s `DB_USER`, `DB_ODOO_DATABASE` and `DB_BTCPAY_DATABASE` are the objects in the engine |
| no `databases:` means one database | a consumer with no list owns exactly `<consumer>`, and `DB_DATABASE` names it |
| another role's database is not taken over | created as `postgres`, then the ingest exits 1 naming both, the owner is unchanged and no role was created |
| `databases:` is a `database`-edge key | on `auth: none` the ingest exits 2 naming the key |
| a name asked for twice | exits 2 naming the duplicate |

