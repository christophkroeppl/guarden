# The snapshot-clone chain: a tmp container, a dump, a scrub and a load

guarden can take a snapshot, fork a service from one and roll one back. What it cannot do is the
operation an operator actually performs when a production database is cloned onto a staging one:
spin a throwaway container up from a pinned snapshot, dump it, strip the settings that must not
travel, and load the result into another service's bulk volume. That operation was performed by
hand on 2026-10-19 and took twelve steps, none of which had a verb
(`phase-a-snapshot-clone-testrun.md`, §9). This ADR designs the verbs that make it one.

## Status

accepted (2026-10-21) — implemented on branch `fix/t327-work`, ticket 327.

## The problem, in the operator's own sentence

> "a manual testrun of pinning a snapshot from pg and clone prod odoo db on staging pg and spin
> it up with staging odoo (spin up prod pg snapshot with tmp pg container, dump and push to
> staging pg)"

Read as a sequence, it is: pin a snapshot → clone it into a throwaway container → dump the
container → transform the dump → load it into another service → start that service against it.
Three of those steps have no verb at all (G3, G4, G6), one has no home for its policy (G12), and
two more are defects that make the flow impossible without hand-holding (F1, F4 in the testrun).

## Considered Options

- **A1 — one verb that does the whole chain (`weedr clone prod-to-staging`).** Rejected. The chain
  is not atomic: the operator dumps to a file they keep for an hour, scrubs it, reviews what was
  scrubbed, and only then loads it. A single verb would hide the step where the operator decides
  whether the scrub was right, and the scrub is the part that carries the operator's judgement.
- **A2 — extend `weedr service` with `dump`, `load` and `transform`.** Rejected, and the reason is
  the argument's shape. `weedr service` verbs act on a **service**: a name, a track, a lifecycle.
  A dump acts on a **snapshot** — a `<service>:<volume>@<number>` id — and a load acts on a
  **database inside a service**, which is neither the service nor its volumes. Putting them in the
  `service` group would make the group's meaning "things you can do to a deployed service", and
  three of them are not that.
- **A3 — a new top-level group `weedr clone`.** **Decided.** The group is named for the OPERATION
  (cloning data between services), not for the thing it acts on, because the chain crosses
  services: the snapshot belongs to the production service, the dump is written by the throwaway
  container, the load happens in the staging service, and the policy that governs the scrub is
  the staging service's own. No one of the four is the subject of the whole chain.

## The five verbs

```
weedr clone snapshot <service>:<volume>@<number> --as <name>   # a throwaway container from a snapshot
weedr clone dump <service> --db <name> --out <file> [--from <service>:<container>]
weedr clone transform <service> --from <file> --out <file>     # the scrub, and what it removed
weedr clone load <service> --db <name> --from <file>           # a dump into a service's database
weedr clone remove <service> --as <name>                       # the container and the clone
```

**`--out` and `--from` are file names inside a volume, never host paths.** A
dump is written into the TARGET's bulk volume, so the name is relative to it;
an absolute name or one carrying `..` is refused, because the verb runs as root
and its destination must not be repository input's to choose.

**`weedr clone snapshot` is the tmp container.** It clones one snapshot into a
throwaway subvolume, starts a container against it, and prints how to reach it.
The container is **not a service**: it has no unit, no publication, no registry
entry and no track, because it is a clone and guarden has exactly one class of
**deployed** thing. It lives in the SOURCE service's own podman store and runs
as the SOURCE service's user, so the data it serves is the data that service
owns.

**`weedr clone dump` and `weedr clone load` are engine-aware, and postgres is the engine.**
`edges.py` already holds engine-aware code — `provision`, the role and
database it creates in a `db` provider — and this chain sits next to it. A dump
is `pg_dump` to stdout; a load is `psql` reading the dump on stdin. **The engine
is a constant named in each module that speaks it**, as `edges.ENGINE` is, and a
service that provides the `db` kind is the only kind these verbs accept.

**`weedr clone dump` without `--from` dumps the service's own database
container.** The container unit is the one that mounts a `state` volume, because
that is where a database's data is; a service whose units leave more than one
candidate is refused rather than guessed at.

**`weedr clone transform` is the scrub.** See "Where the scrub rule lives" below.

## Where the scrub rule lives

**The scrub rule is the operator's POLICY, and it lives in the manifest, in a `scrub:` block.**

The three candidates were:

- **`overrides.toml`** — rejected. That file is the admin's *grant* surface: the ports, firewall
  rules, groups, mounts and retention an admin has agreed to. A scrub is not a grant; it grants
  nothing and authorises nothing.
- **the registry** — rejected. The registry is the host's *record* of a service: what it owns, what
  it published, what it was forked from. A policy the operator writes is not a fact about the host.
- **the manifest** — **decided**. The manifest is "the only thing a project declares about
  itself" (spec 4), and "what this database's rows look like when they are cloned" is a fact about
  the project. It is versioned with the deployment, it is reviewable in a pull request, and it
  travels with the code it describes.

**A repository states the rule; only an operator may run it.** The manifest is the right home
because the rule is the project's, and the verb is root's because running it rewrites data.

The block, in the manifest's own vocabulary:

```yaml
scrub:
  tables:
    - name: ir_mail_server
  keys:
    - table: ir_config_parameter
      column: key
      prefix: "mail."
```

**A `tables:` entry empties the table, and there is no mode.** An earlier draft
offered `truncate` and `delete`; the transform is a filter over a plain dump, and
the restored table is created and then filled from an empty `COPY` block either
way, so the two modes would be two spellings of one result. A mode that cannot
differ is a promise the verb cannot keep, and the operator's own rule — "empty
`ir_mail_server`" — is exactly the one behaviour.

**`keys:` is a prefix match on a column, and it is narrow on purpose.** The operator's rule was
"every `ir_config_parameter` row whose key begins with `mail.`". A prefix match on a named column
of a named table says exactly that, and says nothing else: it cannot name a row by value, so it
cannot be used to delete "the row whose value is this secret" — which is a different operation
with a different blast radius. An `equals:` match is the same shape for a key that is one exact
value.

**The transform reports what it removed, and the report is the point.** A scrub that silently
removed twelve rows is a scrub nobody can review. Every removal is named with its table — and for
a `keys:` rule, with the value of the column that matched — and the count is in the summary line.

## What the transform is not

**The transform is NOT a query language.** It does not accept SQL, and it does not accept a
predicate. A rule that could express arbitrary SQL would be an arbitrary database write dressed as
a policy, and the review that a manifest block is for — a diff in a pull request — is worthless
against arbitrary SQL. The three things a rule can say are "empty this table", "delete the rows of
this table whose column starts with this" and "delete the rows of this table whose column equals
this". A table the block does not name is kept, and that is the only "keep" there is.

## The chain, and the ownership each step has

| step | reads | writes | whose data |
|---|---|---|---|
| `clone snapshot` | a snapshot of the source service's state volume | a throwaway subvolume and a container | the source's |
| `clone dump` | a running container of the service | a file | the service's |
| `clone transform` | a dump file | a transformed dump file | the operator's policy |
| `clone load` | a dump file | a bulk volume, then a database | the target's |

**The dump is written to the target's bulk volume, not to the host's `/tmp`.** The bulk volume is
exactly the concept the operator named — "staging pg (bulk volume)" — and a bulk volume is a
subvolume that is never snapshotted, so a dump in it does not enter any snapshot and does not
appear in a fork. `podman cp` cannot write into `/var/lib/guarden` (measured: `chmod /: operation
not permitted`), which is why the testrun used a tar stream over a pipe. **The verb does not put a
file in `/tmp` and does not use `podman cp` either**: `pg_dump` writes to stdout, the mutator (root)
writes those bytes into a temporary file in the target's bulk volume through the §3.5 protocol, and
chowns the result to the service user. The container's file system is never the handoff, so the
tar-stream workaround is not in the product.

**A load refuses a target with no bulk volume.** The chain's target is a bulk volume by
definition: it is a landing area, not a store, and a dump loaded into a `state:` volume would be a
copy in a snapshot's history. A service with no `bulk:` volume is refused, naming the volume the
operator should declare.

## The load does not create the role

**`clone load` restores into a database that already exists, and refuses one that does not.**

The role and the database are guarden's own — `edges.provision` creates them, idempotently, and
`ALTER ROLE … PASSWORD` converges the password. That is G7 in the testrun's list, and it is a
**separate defect** from this chain: the edge's credential must be re-provisioned after the
provider's data was recreated, and today the only way to do that is `remove` + re-ingest, which
takes the service's home with it.

**This ADR does not fix G7.** The chain's verbs make the clone possible; the credential
re-provision is a separate ticket, because it is a defect in the edge's provisioning and not a
missing verb in the chain. A load that recreated the role would be doing the edge's job in a
place where the edge is not, and the role's password would then be the dump's password rather
than the edge's minted one.

## The tmp container's lifetime

**`weedr clone snapshot` prints the container's name and leaves it running.** It does not remove
it on exit, for the same reason the dump is not removed: the operator needs to `psql` into it.

**The cleanup is a separate verb, because the operator's own list has eight items to undo and
each of them needs its own command** (testrun §7). `weedr clone remove <service> --as <name>`
removes the container and the clone's subvolume, and it is refused when the clone is not there —
a `0` that reported work it did not do would be the one thing `0` may not mean. It removes only
the subvolume under the service's own `clones/` directory, which is guarden's by construction;
anything else is data, and `weedr service purge` is the verb that destroys data.

## Consequences

- **The program surface grows by one group and five verbs.** `weedr clone` is new; `weedr service`
  is unchanged, and its verb list stays closed (the `assert_verbs` helper in `tests/lib.sh`
  checks it). `clone remove` is the only `remove` outside the two already there, so it carries
  the one alias guarden has (`rm`).
- **The verbs are root-only and on no sudoers rule.** A clone reads production data and a load
  writes it; neither is reachable from a poke. `sudoers.GUARDEN_MAY` is unchanged, and a clone
  verb is not added to it.
- **The engine is a constant per module.** `postgres` is the only engine, named in
  `edges.ENGINE` and in `clone.ENGINE`, and the two names are the same engine: the edge creates a
  role and a database in it, and this chain dumps and restores through it.
- **The manifest gains a `scrub:` block**, and a manifest carrying one is accepted by the parser
  and refused by name for every other key, as every other block is.
- **The clone's container runs the source service's image**, read from the source's own installed
  unit, so the tmp container is the same postgres the source runs and not a second image the
  operator has to name.
- **F1 (a postgres whose data is a guarden state volume cannot start) is NOT fixed here.** It is
  ticket 325, and it is a renderer defect: the image's entrypoint chowns `$PGDATA` and walks into
  snapper's `.snapshots`, whose subvolume is read-only. **A clone does not have that defect and
  does not need the fork's repair.** btrfs does not carry a nested subvolume into a snapshot, so
  the clone's `.snapshots` arrives as an empty plain directory, and a `chown` reaches a writable
  directory and stops there. A clone of a snapshot has no snapshots of its own to protect, which
  is why `weedr clone snapshot` creates no `.snapshots` subvolume where `lineage._clone` does.
- **F4 (a postgres whose compose declares no data volume loses its data) is NOT fixed here.** It
  is ticket 326, and it is a manifest rule that already landed.

## What is NOT in this ADR

- **The credential re-provision (G7).** A separate ticket: it is a defect in `edges.provision`, not
  a missing verb in the chain.
- **The start-time credential materialisation (G8).** A separate ticket: it is a defect in
  `weedr service start`, not a missing verb.
- **The admin wiring that a `remove` destroys (G9).** A separate ticket: it is about
  `overrides.toml` gaining a surface, not about the chain.
- **A file handoff verb (G10).** The chain does not need one: `clone dump` writes the file itself,
  as the service user, into the target's bulk volume. The general "move a file into a service's
  space" verb is a different operation and is not designed here.
