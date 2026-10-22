# ADR-0026 — one repository holds apps, and one app is one service

Status: accepted. Narrows spec 5.1, 5.3, 6.6 and 7.3. Ticket 307's design decision.

## The question

Ticket 307 came from the operator: "we may need to make platform changes to deploy
multiple apps from monorepos like supplements". A repository held exactly one
`.guarden/service.yml`, at its root, so one repository was one service — and every
other fact about a service (one user, one home, one unit directory, one registry
record) was built on that.

Three questions decided the shape, and this ADR answers all three so an implementer
does not have to re-open them:

1. Where does an app boundary live in the tree?
2. One unix user per app, or one user per repository?
3. Is the build context the whole staged tree or the app's subtree?

## The decision

**1. An app is a directory holding `.guarden/service.yml`, and discovery is by the
file's location.** No `apps:` list, no index file, no `[apps]` table. A list is a
second declaration that can go stale in one direction only: the tree ships an app
and the list forgets it, so the app silently never deploys. The tree's own shape is
the index, and an app that exists is an app that deploys.

The app name is the app root's last path component, and the tree-root app's name is
the empty string. Two app directories with the same last component name one service
twice, and that is a refusal that names both directories rather than a rule that
picks one: whichever the implementation picked, the other app's deploy would land on
a service carrying a manifest from a different tree.

**2. One user per service, and one service per app — so one user per app.** The
question "one unix user per app or one for the repository" is answered by the
existing invariant rather than by a new trade: a service *is* one user, one home,
one unit directory and one row in the registry (spec 5.3), and the `0700` on its tree
is the isolation boundary between services. Collapsing several apps into one user
would put two applications' trees, volumes and podman stores behind one `0700` and
would make two services one service in the registry. So a repository that ships
`apps/web` and `apps/api` deploys two services, each with its own user, home and
subvolumes, and each copies the whole tree into its own home.

The trade is stated because it is real: the same source is on disk twice, and a
change to a file outside both app roots redeploys both. Ticket 307's digest-and-tag
work (`dependencies:` and the per-app image digest) is what makes the second part
stop being true; until it lands, the whole-tree hash is the honest answer, because
the whole tree *is* the build context.

**3. The build context stays the whole staged tree.** The home holds the whole tree,
`podman build` reads the home, and a Containerfile that `COPY`s a path outside its
own app — a shared `Cargo.toml`, a `packages/shared` directory — must still build.
Narrowing the context to the app root would silently break exactly the monorepo the
ticket exists for. What moves is where the **Containerfile is read from**: the app
root, like the manifest, the schema and the unit source.

### The name

**The service name is `<project>-<app>-<environment>`, and `<project>-<environment>`
for the tree-root app.** The last `-`-separated segment of a service name is its
environment (spec 5.1) and that does not change: an app whose own name carries
dashes is still unambiguous because the project is known from the deploy that
carries it, not from counting segments. `<project>--<environment>` is refused —
an empty middle is how the tree-root app would be spelled, and the tree-root app is
spelled without the second hyphen.

The name is the mutator's whole interface for a poke, so it is the name that says
which app: `weedr service ingest <name> --from poke <project>@<sha>` resolves the
app out of `<name>` against the project the poke carries. There is no `--app` flag,
and there could not be one on a granted verb without granting it (spec 5.1).

The registry carries the app root as `app` — a path inside the tree, the empty
string at the root, absent in every record written before this decision (which is
the root, and is a state rather than a gap). It is what locates the manifest, the
schema and the unit source in the home, and it is part of what the convergence check
compares.

### One poke, several services

`hose` asks `furrow deploy` for `<project>-<environment>`, which is the project and
its track and carries no app. `furrow` reads the staged tree, discovers its apps,
and writes **one queue request per app**, providers before consumers — the order the
apps' own `needs: app:` graph gives, which is why a sibling edge can be installed by
the same poke that creates both services. A request naming an app deploys that app.

A repository with one app at its root is the same rule: its one app *is* the tree
root, the name carries no app segment, and the deploy is bit-for-bit what it was.
That is the regression the change is judged by, and it is why the app name in the
registry is `""` rather than a special value.

### A sibling app is an edge, not a `siblings:` entry

`needs: - app: api` names another app of the same repository, and guarden resolves
it to `<project>-api-<environment>` — the consumer's own project and the track its
own deploy is on. **No host table is consulted**, neither `[providers]` nor
`[edge_overrides]`: a sibling is a fact about the repository, and a host-side pin
that could point staging's `api` at production's would be the promotion this design
refuses everywhere else.

It renders through the **same** path a `siblings:` entry uses — `AddHost=<name>:<alias>`
in every unit of the consumer and `<AS>_HOST`/`<AS>_PORT` in the environment file,
with the port being the provider's allocated publication — so the two cannot
disagree about what a name and a port mean. What differs is who names the provider:
a container of the same unit source, or another service of the same repository.

An `app:` entry is reached, never provisioned: `auth: none` (or `auth: secret` for a
shared token) and no `databases:`, because a role and a database are created in a
`db` provider's engine and a sibling app is not one. The provider app declares
`provides: [http]`; the consumer's `as:` is only a variable prefix, because one app
may offer several ports.

### Renaming an app

Renaming an app directory renames its service. A deploy that asks for the old name
is **refused, and the refusal names the apps the tree now ships** — so the operator
meets a sentence instead of a service that quietly keeps its old tree. The old
service is not deleted automatically: its volumes are its own data, and guarden
destroys data only through `weedr service purge`, typed at a terminal. `weedr
service list` is the inventory, and `weedr service remove` is the verb for the
service nobody wants any more.

## What this does not decide

- **Per-app image digests and `dependencies:`** — ticket 307e. Until then the
  whole-tree hash defines convergence, so any change in the tree redeploys every app
  of it.
- **Pods.** One container per unit, one user per service, is unchanged; grouping
  app containers into a pod is 307c and is a decision about a uid, not about this.
