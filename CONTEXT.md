# guarden

Glossary. Single-VPS deployment platform. This file is the vocabulary; the names here are
not negotiable mid-change. If a change needs a word that is not here, the change is wrong.

## Language

**service**:
One deployed thing on the host, named `<workload>-<environment>`, owning exactly one Linux
user of the same name, one home, one quadlet unit directory, and any state it declares. A
service is not a container: a service may run three.
_Avoid_: stack, deployment

**container**:
One container inside a service. `compose.yaml` calls these `services:`; guarden calls them
containers, and the two words never mean the same thing.
_Avoid_: service (when you mean one process), unit

**app**:
A directory in a project that holds `.guarden/service.yml`, and the containers that manifest
declares. Discovery is by the file's location, never by a list at the project root, because a list
is a second declaration that goes stale and an app it forgets silently never deploys. Its name is
the directory's last path component, and the app at the tree root carries the empty name. An app is
not a container: its manifest names a quadlet directory, and that directory may hold two (`pgprov`
runs a database and a vault). It is not a service either — how many services an app's containers
become is `grouping`'s answer, not the app's.
_Avoid_: service (when you mean the directory), container (when you mean the directory), project
(when you mean one app of a multi-app project), module

**grouping**:
How a project's apps become services. A declaration, never a heuristic: nothing infers this from
the directory layout. `one-service` puts every app's containers into one service — one Linux user,
one home, one pod — which is what a monorepo whose apps are one deployment wants.
`one-service-per-app` gives each app its own service, and so its own Linux user and its own pod,
which buys per-app isolation at the price of a user per app.
_Avoid_: mode, layout, topology, default (when you mean the grouping)

**pod**:
The one network namespace a service's containers share, named by the manifest's `[pod] name` and
defaulting to the service's workload, so its members reach one another on `127.0.0.1` and only what
a route or an edge publishes leaves the pod. It is not a network two services share, and it is not a
name map. A pod is a per-user podman object, so it never spans two services: two services are two
Linux users, and no quadlet `Pod=` unit crosses a user manager. Its containers also share ONE user
namespace, so a `keep-id` pin is a pod-level pin — one image uid and container root reach the
service user, and every other uid lands on a subuid, which is why a pod whose members disagree on a
uid is refused rather than rendered.
_Avoid_: network, namespace (when you mean the pod), group, stack, subnet, cluster

**project**:
A repository. The thing you promote through tracks. Its name is the manifest's `project` field,
defaulting to the project the `--from` source belongs to. It is not the same thing as the
workload and the two may differ.
_Avoid_: repo, service (when you mean the repository)

**workload**:
The service name without its environment segment: `other-app-production` is workload `other-app`.
It is what a track holds one service per, and what an instance cap is counted against. A
workload and a project may differ; a workload that comes from an app is the project and the app.
_Avoid_: service (when you mean the part before the dash), project

**track**:
A named row in the root-owned environment table in `/etc/guarden/guarden.toml`, carrying its own
host prefix, gate, weight, retention defaults and instance-or-slot kind. A service is deployed
*into* a track; the track's `name` is the service's `environment` segment. `production`, `staging`
and `preview` ship; the set is a table and adding one is a configuration change. A track with
`kind = "instance"` carries `cap`, a track with `kind = "slot"` must not.
_Avoid_: environment table (for one row), stage, tier, kind

**environment**:
The track's `name`, carried as the last `-`-separated segment of a service name. The host
decides which one a service runs in; the manifest never says. Lineage is a field on the track —
each row's `fork_from` names the track it forks from, and an empty one starts empty — so which
track forks from which is configuration and not a fact guarden knows about the name
`production`.
_Avoid_: stage, env, tier, track (when you mean the string)

**instance**:
One running copy of a preview: `myapp-preview/feature-x`, where `<ref>` is the branch, taken
raw and escaped internally. An instance is not a service — it is a directory inside one, and
instances of one preview service share their service's single user.
_Avoid_: ref, slot, sandbox

**unit**:
A systemd unit. Rootless quadlet generates one per container; a declared volume is not a
unit of its own, and the container's unit carries a `Volume=` line naming the path the
mutator made (spec §6.3).
_Avoid_: container, unit file (when you mean one container's unit)

**publication**:
A loopback port guarden allocates, from `ingress.publication_range`, for a container a route, a
port, a sibling or an edge names. Publications are the only ports anything in guarden binds, and
they are never a door from outside: a granted public port is translated to one of them. Every
publication carries a uid-matched accept set and a drop for every other uid.
_Avoid_: port (when you mean the allocated loopback number), ingress, endpoint

**sibling**:
A container of the *same* unit source that another container of it may dial, declared under the
manifest's `siblings:` block with the port it serves **inside** its own container. The renderer
writes `AddHost=<container>:<ingress.alias>` into every unit of the source and
`<NAME>_HOST`/`<NAME>_PORT` into the environment file, where the port is the sibling's
**publication** and not the container port the manifest named. A sibling never leaves the source:
it is not a service name, no other service's units carry it, and it is not a grant — `overrides`
has nothing to say about it.
_Avoid_: service, dependency (it is neither: no edge, no grant, no unit tree of its own)

**port**:
A TCP/UDP number. A manifest *requests* a public one; a root-owned `overrides.toml` grants it;
the grant is rendered as a `DNAT` from the public port to the service's publication, together
with the `route_localnet` on the ingress interface that a `127.0.0.1` destination requires. There
is no masquerade: the translated packet is delivered locally and never reaches `POSTROUTING`, and
connection tracking unwinds the translation on the reply. Publications and grants are
deduplicated into one firewall render.
_Avoid_: ingress, opening, endpoint

**ferm**:
The firewall guarden runs, and the only one on the host. Every rule in `/etc/guarden/firewall/`
is a ferm stanza, for every service however it was deployed, and `iptables-save` reads what ferm
compiled them into. `ufw` is uninstalled on a guarden host. **guarden never writes, reads or
reconciles a `ufw` rule.**
_Avoid_: ufw, netfilter, nftables (as a second engine), iptables (it is the target, not the
engine)

**firewall rule**:
One iptables-shaped rule line a manifest **asks** for, under `firewall:`, by a name. A request
installs nothing: it is recorded in the registry and stays pending until an admin acts. Purely
additive — a request may add a rule to a chain guarden owns and may not open, close, flush,
rename or set a policy on anything. Most services never need one, because most traffic goes
through the edge; the ones that do are speaking a protocol the edge cannot.
_Avoid_: grant, port, policy, snippet

**rule grant**:
The root-owned decision that one service's requested firewall rule is installed. Recorded by
**name** in `overrides.toml`'s `[firewall] allow` and applied by `weedr firewall open`. Counted
by name and **deduplicated by content**: two services asking for the same rule text get one rule
with both names on it, and closing one leaves it while the other still asks. It is the same
authority class as a port grant — root, made by hand, on no sudoers rule.
_Avoid_: firewall rule (for the decision), port, override, ufw rule

**gate**:
The credential check on a track with `gated = true`: every key the schema requires must exist in
the service's own podman secret store with a real value, and one that is still an example does not
count. It is a **state, not a moment** — recorded in the registry as `ready`, `blocked` or
`not-required` — because a service may be deployed, installed and waiting for its operator to
plant credentials, and that is a successful deploy rather than a failed one. `weedr service gate`
evaluates it; `weedr service start` re-evaluates it every time. A poke therefore never leaves a
red build waiting on a human. On a track with `gated = false` the same condition is one
`warning:` line and the start proceeds, which is the only difference between the two tracks.
_Avoid_: disabled service, hold, release

**secret**:
A value that must not be readable at rest. Encrypted as a systemd credential, materialised
into the owning service's podman secret store, and injected into a container as a file by
default; an environment variable only when the application insists. A podman secret's name is
the variable it becomes.
_Avoid_: key, token, env var (when you mean the secret's value)

**manifest**:
`.guarden/service.yml` at the root of an app, and an app is a directory in a project's tree. The
only thing an app declares about itself: units, the pod, state, declared edges, requested ports,
routes, widgets, the shape of its secrets, and the rule for a cloned copy of its data (`scrub:`).
_Avoid_:  config, spec

**state volume**:
A btrfs subvolume declared by the manifest holding what a service must not lose, with a
snapper configuration of its own. A `bulk` declaration is the same subvolume with neither:
regenerable, too large to snapshot, or too slow to clone. There are no config subvolumes:
config is root-owned under `/etc/guarden` or regenerated, so it is never precious.
_Avoid_: data volume, persistent volume

**bulk volume**:
A btrfs subvolume declared by the manifest holding data whose *history* is worthless — a
blockchain's chain state, which is expensive to rebuild and worthless at any particular
instant. Identical to a state volume in every way except that it never gets a snapper
configuration, is never snapshotted, is never a fork or rollback source, and is **an empty
subvolume after a fork**: a bulk volume is never cloned from a live volume, because a copy as of
an instant is not reproducible afterwards and two targets that quietly disagreed would be worse
than two empty ones. It is a subvolume on every path, the fork included — never a plain
directory. A container mounts it from the subvolume itself: the unit carries a `Volume=` line
naming that path, and there is no `.volume` unit (spec §6.3). Size is not what makes a
volume bulk: a two-terabyte media library is a state volume, because a film somebody deleted has
to come back. The point of the second word is that "never snapshotted" is a name rather than a
flag somebody forgets.
_Avoid_: state volume, scratch, cache

**snapshot**:
A point-in-time copy of one state volume, taken atomically while the service runs. A service
with several state volumes has one snapshot per volume, individually consistent and possibly
microseconds apart; btrfs cannot do better. A clone of a snapshot becomes a **fork** when it
replaces a service's state volume; the clone the snapshot-clone chain cuts is the same
copy-on-write subvolume with no service behind it, and is not a fork. Two kinds, tagged
differently because two different mechanisms govern them: a **routine** snapshot is
`timeline`-tagged and lives by the ladder, and an **on-demand** snapshot — a fork source or an
operator's own — is `number`-tagged and is what the marks protect.

**clone**:
A copy-on-write subvolume made from a snapshot, never a copy of its data. A **fork** is a clone
that becomes a service's live volume; `weedr clone snapshot` makes the other kind — a throwaway
clone under the source service's own `clones/` tree, with a container running against it, no
unit, no publication, no registry entry, and no snapper configuration. It is writable, carries
no `.snapshots` of its own, and `weedr clone remove` is what deletes it.
_Avoid_: fork (that is the service-making kind), copy

**scrub**:
The `scrub:` rule in a manifest: what a cloned database must not carry. A `tables:` entry empties
a table; a `keys:` entry removes the rows whose named column starts with a prefix or equals one
value. `weedr clone transform` applies it to a plain dump, never to a live database, and reports
every removal. It is a policy, not SQL, and it cannot name a row by a value it was not given.
_Avoid_: transform script, anonymisation

**ladder**:
A state volume's retention schedule: how many snapshots to keep per time bucket, aged between
buckets as they get older — daily, weekly, monthly, quarterly. A nightly snapshotter with a
ladder keeps a bounded, spread-out history; without one it keeps the newest N whatever their age.
`keep_last` is the daily bucket's maximum, so `keep_last = 7` on a production volume means seven
daily snapshots aged up into the weekly, monthly and quarterly buckets. Not a garden metaphor: it
is the standard name for a tiered retention schedule, and it is a per-volume property the admin
owns through `overrides.toml`.
_Avoid_: retention policy, snapshot policy, tier

**pin**:
A statement that one snapshot must survive. It is a file named by
`<service>:<volume>@<number>` and by nothing else, owned by `stakes`, and a mark in snapper's own
metadata is derived from the pin files plus the service registries. A pin is a priority with a
budget, not a promise: under disk pressure a marked snapshot can be reaped.
_Avoid_: backup (unless it has left the box), ledger, refcount

**edge**:
The service that terminates public traffic on the kernel's forwarded ports,
`traefik-production`. Routes are rendered into a directory it reads. An ordinary service with
no capability: `soil firewall` forwards 80/tcp, 443/tcp and 443/udp to its published loopback
ports with `DNAT`, each relying on the `route_localnet` set once on the ingress interface, so
the kernel owns the public ports and it binds only loopback ones. It is the **only door**: the
kernel forwards public ports to it, so anything on the internet can address it. A **tunnel**
(ADR-0015) terminates traffic too and is **not a door** — it dials out and is reached by nobody,
so it binds no port and no forwarding rule names it.
_Avoid_: gate, proxy, ingress controller

**alias**:
The one address a rootless container can reach the host on. Pasta maps the container's default
gateway to the host's loopback, so the alias is that gateway address and it is a *name a consumer
resolves* — `AddHost=<provider>:<alias>` — never a firewall destination. It is pinned, not
measured: `soil install` derives it from the `-g` in `[network] pasta_options` and writes it into
`guarden.toml`, so it is a constant no host's route can drift (ADR-0018).
_Avoid_: host-gateway, host.containers.internal, publication

**probe**:
The one reading of an image's own user, done at a start that has no answer yet: `podman image
inspect` for `Config.User`, the image's own `/etc/passwd` and `/etc/group` for the numbers that
declaration names, and the entrypoint's own words for the user it hands execution to. The
answer is a pair — a uid and a gid — and it is recorded, not applied: nothing is chowned, and
the pair becomes a line in the unit.
_Avoid_: detection, scan, inspector

**owner**:
The uid and gid an image's user was read as, and the record fields that hold them:
`owner_uid` and `owner_gid` for a service whose units name one image, plus `owner_image` (the
image the pair was read from) and — for a service whose units name more than one image — an
`owner_units` table of per-unit image/uid/gid. The pair is true of the image it was read from:
an image that changed is the probe's condition again, and a build that re-tags a reference
takes the answer away.
_Avoid_: pin, uid, mapping

**keep-id**:
The user-namespace line guarden writes into a unit, `UserNS=keep-id:uid=…,gid=…`: it moves
the probed pair onto the service identity, so the container's writes land on the service's
tree instead of in its subuid band. It is guarden's own line and the only one that may carry
the directive — a repository's `Userns=`/`UserNS=` is refused — and it is rendered from the
record, never hand-written.
_Avoid_: userns, idmap, chown

## Programs

Garden names are for guarden's own programs and nothing else.

**soil**:
The host converger. `--check` and `--apply` over the host: packages, storage, sysctl, firewall,
install, units. The only other program with two modes. It creates no service identity of any kind
and has no `users` phase.
_Avoid_: base, bootstrap

**weedr**:
The privileged mutator and the only one. Identities, service roots, state volumes, unit
installation, credentials, ports, firewall rule grants, snapshots, forks, rollbacks, image
builds, status. The build is
here because an unprivileged program cannot become the service user, and the subuid range is
the service user's alone.
_Avoid_: admin

**loom**:
The renderer. Manifest plus a registry in, quadlet units, environment files, `AddHost=` entries
into the consumer's own units and credential requests out — never a credential value, because it
has none. Also emits the shared slices the mutator installs for `roots` and `twig`. Refuses to
render what it cannot resolve. Runs unprivileged.
_Avoid_: renderer, podlet (that is one of its tools), builder

**roots**:
Writes the edge's route configuration from the `routes:` sections of every service's manifest.
Traefik-specific by decision, and it has no intermediate format: if the edge is replaced, `roots`
is replaced. Unprivileged.
_Avoid_: traefik, router, gateway

**twig**:
Writes the dashboard configuration from every service's widgets. Unprivileged.
_Avoid_: homepage, dashboard

**furrow**:
The deploy queue. One build at a time, by track weight, debounced and deduplicated. Ensures the
service exists, renders, builds through `weedr service build`, gates, then stops, installs and
starts — the gate and the build both land before the stop. Unprivileged, and the only program
that calls weedr on a schedule; it never touches podman itself.
_Avoid_: queue, deployer, ci

**hose**:
The optional gitops receiver. Accepts a poke over ssh, maps a ref to a track from a root-owned
allowlist, and calls furrow. Keeps no git state. Unprivileged, and the only program reachable
from the network.
_Avoid_: webhook, gitops, ci

**stakes**:
The pin registry, and nothing else. One file per pinned snapshot, plus queries. It runs
unprivileged and owns those files; `weedr pin sync` is the privileged bridge that turns them
into snapper marks, because snapper has no cleanup hook and writing its metadata needs root. It
cannot read a service's snapshots and does not pretend to: a service's tree is `0700` to that
service, so `stakes list` reports its own pin files and the registries, both readable, and every
figure that needs a state volume comes from `weedr service list --json` instead.
_Avoid_: pin registry, retention, backup

## Module

A named bundle of shipped services and the shared programs they switch on, listed in
`/etc/guarden/guarden.toml` and installed with `weedr module add`. `gate-traefik` (the edge) and
`homepage` are on by default; `auth-authelia` is not implemented in v1. Modules never write each
other's files — they communicate through documented root-owned files.
_Avoid_: addons, base, plugins

## Resolved naming facts

- Service: `<workload>-<environment>`, lowercase, no spaces, at most 31 characters. `myapp-production`,
  `other-app-staging`, `postgres-production`, `traefik-production`, `homepage-production`.
  The environment is the last `-`-separated segment; the workload may contain dashes. The Linux
  user, the home, the service directory and the registry file all carry it. There is no suffix,
  no alias and no second name: a consumer resolves the service's own name, and a route target
  is `<name>:<publication>`.
- An instance: `<service>/<ref>`, with the ref taken raw by every verb and escaped by
  `systemd-escape` for directories and unit names. `feature/x` and `feature-x` are different
  instances.
- A state volume's snapper configuration is named `<service>-<volume>`; a snapshot id is
  `<service>:<volume>@<number>`, and so is the pin file that protects it.
- Guarden's own state is never a state volume. `/var/lib/guarden` is one btrfs subvolume and is
  **not** snapshotted: only a service's declared state volumes carry a snapper configuration.
