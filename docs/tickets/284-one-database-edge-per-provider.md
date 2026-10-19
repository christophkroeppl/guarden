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
