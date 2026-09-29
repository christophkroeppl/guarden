# One privileged mutator, everything else unprivileged

One VPS, one operator: the privileged surface is a single program. `weedr` is the only thing
that runs as root against service state — it creates and removes users, homes, state volumes
and units, plants credentials, grants ports, and takes snapshots. Everything else is
unprivileged and talks to it, or does not need it.

`loom`, `roots`, `twig`, `furrow` and `stakes` run as the single `guarden` user. `hose` gets
its own user, because it is the only program reachable from the network. The edge reads one
directory that `roots` writes; they share no user and the directory is one-way
(owner `guarden`, group `edge`, mode `2750`), so a compromise of either side can read the
other's output but only the writer can replace it. Root executes only root-owned copies of
guarden's own programs, so no deploy-writable code ever runs as root. Converting a project's
Compose file into units is `loom`'s work and happens unprivileged: the mutator never runs a
converter, or any other program, over repository input.

"No daemon runs as root" is a claim about guarden's own programs, and it is stated that way
throughout the document set: guarden has no daemon at all, every recurring job is a `.path` or a
`.timer` running a oneshot, and `snapperd` is a root daemon the distribution ships that the
snapshot design depends on.

The mutator is python. A fork moves the old subvolumes aside, clones, clears the read-only
flag, changes ownership, records the seed, starts, and on any failure puts the old subvolumes
back and starts anyway. A rollback is that path pointed the other way. That is more
failure-path branching than shell should be trusted with, and every branch is a place a
service could be left half-replaced. Shell is used to invoke programs and to sequence them,
and for nothing that has to be right.

Why: sudo should be one narrow door, every mutation should be a command we can log and test
at the command-line seam, and "this runs unprivileged" should be checkable by reading a user
column. Consequence: a program that needs privilege asks weedr, and if weedr cannot do it,
that is a signal to add a verb rather than to run something else as root.

The door is narrow because the rules that open it name verbs, and they name their runas target
too. Written out, because the default reading of "a sudoers rule naming X" is that X runs as
root — which would have made `furrow`, the program that handles repository-supplied paths, a root
program:

```
guarden ALL=(root) NOPASSWD: /usr/lib/guarden/bin/weedr service ingest, \
    /usr/lib/guarden/bin/weedr service remove, /usr/lib/guarden/bin/weedr service gate, \
    /usr/lib/guarden/bin/weedr service start, \
    /usr/lib/guarden/bin/weedr service stop, /usr/lib/guarden/bin/weedr service restart, \
    /usr/lib/guarden/bin/weedr service snapshot, \
    /usr/lib/guarden/bin/weedr service build, \
    /usr/lib/guarden/bin/weedr secret list, /usr/lib/guarden/bin/weedr port list, \
    /usr/lib/guarden/bin/weedr service list, /usr/lib/guarden/bin/weedr service status, \
    /usr/lib/guarden/bin/weedr module list
```

`furrow` is unprivileged and calls root `weedr` to install units and start services, and it is
permitted exactly the verbs above. It is never permitted `weedr port open`, `weedr port close`,
`weedr service purge`, `weedr service rollback`, `weedr project add`, `weedr project grant`,
`weedr project revoke`, `weedr module add`, or any invocation of the verbs it is permitted
carrying a flag that widens authority. The rules name the long form of each verb, because a
rule naming `weedr service rm` would not match it.

**That last clause is the whole of the mechanism, and it is why the flags are gone rather than
documented.** An earlier version of this rule granted `weedr service add` and `weedr service
remove` and then stated in prose that no invocation may carry `--grant-ports` or
`--purge-state`. It could not mean it: a sudoers command with no argument specification matches
any arguments, and sudoers has no negation, so the grant already permitted
`weedr service add --grant-ports` and `weedr service remove --purge-state`. Restricting arguments
was not available either — sudoers matches a fixed argument set, and every legitimate call of
`add` carries a different staging path and a different sha. So the capabilities became verbs.
A grant is `weedr port open`; destruction is `weedr service purge`; neither is on the rule. The
first of those is ADR-0006's rule arriving through the mechanism that enforces it rather than
through a convention nobody reads. The second means no program that answers a poke can destroy
data, and the file is where that is true.

`weedr service fork` and `weedr service add` were removed from the rule for the same reason, and
for a stronger one: both carry a *source*, and the source is the only thing that can change where
a service's tree or data comes from. The automatic fork on a `fork_from` track is a step inside
`weedr service ingest` rather than a verb a deployer calls, so there is no `fork --from` for a
poke to reach and `production`, whose `fork_from` is empty, always starts empty. An operator
forking a staging database into production does it by hand with the root verb, deliberately and in
the call log.

`weedr service rollback` was removed from the rule for the same reason. It replaces a service's
current volumes with a clone of an old snapshot and was gated only by a `--yes` the rule could
not distinguish from any other argument, so a rule that granted it granted the ability to
destroy a production service's data. `furrow` never rolls anything back — the deploy sequence in
ADR-0011 has no such step — and the operator runs as root, so nothing was lost.

`weedr service build` is on that list for the same reason the mutator exists at all: the build
runs as the service user, an unprivileged `furrow` cannot become the service user, and the subuid
range belongs to the service user and only it may map container-root into it.

`hose` gets its own, smaller surface, and it is `(guarden)` — the deploy queue, not the mutator.
Dropping a preview instance reaches the mutator only through `furrow preview drop`, and a poke
can only ask for `furrow deploy` or that one drop, so a repository's workflow can never arrive at
the removal of a service in a gated track. `hose` cannot run a `weedr` verb that changes anything. Because the rule
names `(guarden)` explicitly, "a poke cannot reach a shell" is a property of the file rather than
of a reader's assumption about how sudoers works.

The door may be several programs wide. `weedr` may become a dispatcher over more than one
binary as long as no verb, flag, exit code, output line or written file changes: the surface
an operator or another program observes is the same, and the tests cannot tell the difference.
The root door stays one door and each door behind it is small enough to read.
