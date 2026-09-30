# guarden — PRD

Status: draft, 2026-09-29. Product name **guarden**. Branch: `service-based`.

Companions: [`CONTEXT.md`](../CONTEXT.md) is the vocabulary and the source of truth for
names. [`docs/spec.md`](./spec.md) is the contract. [`docs/adr/`](./adr/) holds the decisions
that were hard to reverse.

This document is why. Where it disagrees with the spec, the spec is what gets built.

---

## 1. Problem

Several early-stage products run on one VPS. There is no deployment story: branches are
ad-hoc compose stacks started by hand, there is no way to put a project into a managed service
and have it survive a reboot, no shared database that does not cost one database container per
project, no protection for production data against snapshot pruning, no gate that stops a
production service from starting with an empty credential, no way to open a firewall port that
matches what is actually deployed, and no way to see, at three in the morning, what is
supposed to be running.

The difficulty is not any one of those. It is that the obvious fix for each is a distinction
rather than a mechanism, and a distinction enforced by nothing has to be enforced twice.

## 2. Goals

- A fresh Ubuntu box becomes a deployment host with one command per phase and a `--check` that
  can be run over ssh before touching anything.
- A project becomes a service with one command: a user, a home, units, state, credentials,
  routes, dashboard entries, and a firewall rule for each declared edge.
- Every service is separated from every other by a real user boundary, and services that share
  one loopback port namespace are policed by uid-matched rules on the edges they declared. The
  shared namespace is a deliberate trade against per-service address space, which rootless
  podman cannot deliver.
- Sign-in at the edge, for the routes that want it, with no application integrating with it.
- Services that are not web applications: a full node, a VPN endpoint, a database someone else
  connects to. A platform that can only run a web application is a web-application platform.
- Production data is snapshotted while it runs, and any snapshot can be cloned into a staging
  or preview service in constant time and constant space.
- Production cannot start with a missing or placeholder credential, and a failed build or a
  blocked gate leaves the running container running. A blocked gate leaves the *deploy* succeeding
  too — the service is installed and waiting, and CI is green while the operator plants the
  credential.
- Nothing in a repository can open a host port, choose its own environment, or read a
  credential.
- Optional gitops: a push pokes the box, the box builds and deploys, the box keeps no git
  state, and CI holds one ssh key and nothing else.
- Everything is a command and a file. There is no web UI, and no internal API between parts.

## 3. Non-goals

- Rolling deploys, blue-green, canary.
- Migrations as a separate step; a service migrates on start.
- Multi-host, Kubernetes, Swarm.
- Drift correction. A poke is the truth; a lost poke is fixed with an empty commit
  (ADR-0009).
- A second database engine. Postgres is the only engine-aware code in guarden, and it is one
  function.
- SELinux or AppArmor policy. The architecture must not block it: no guarden program runs a
  long-lived daemon as root, guarden has no daemon of its own, and every service is a distinct
  user. `snapperd` is a root daemon the distribution ships and the snapshot design depends on,
  so the claim is about guarden's own processes.
- A shared podman network. Rootless podman networks are per-user, and that is the reason the
  connectivity design is what it is (ADR-0004).
- Remote backup of snapshots, and off-box copies generally. The one off-box copy guarden assumes
  is the operator's own copy of the production credentials, because the host key is single and
  has no second copy anywhere.
- More than one operator, and more than one host.

## 4. The deployments, and what they found

One real instance of this host is not a web application. It is a blockchain node, a vault with
two authorisation domains, two agents with a terminal tool, a media server and a device-sync
decision. They are not guarden's scope, but they are the first things anyone ran against this
design, and they found the gaps that a web application never would have:

- **Nothing could be snapshotted selectively.** One `state` list meant either the chain state
  or the wallet directory had to be unprotected. The second declaration is not complexity; it
  is the only way both survive.
- **A service can be reachable from outside the host without going through the edge.** A full
  node's peer port is not an HTTP request, and a platform that cannot publish one cannot run a
  node. A grant is what makes that possible, and it is a translation of a public port to the
  service's own loopback publication — no service ever binds a non-loopback address, and there
  is no private-versus-public grant to get wrong.
- **A repository cannot mount a host socket.** The renderer refuses it, so it is a property of
  the system rather than a habit — though a refusal is a guardrail and the boundary is still
  the per-service user.
- **Removing a service does not destroy its data.** Volumes are moved, not deleted, and
  destroying them is a separate, confirmed act.
- **Sign-in was backlog** and turned out to be required by four of the five services.

The general lesson is in §5: a design tested only against a web application is not a design.

## 5. What shaped the design

Four constraints, each of which eliminated a plausible-looking option. They are the reason the
system is as small as it is.

**A distinction that lives in a string is not a distinction.** A prefix on a name, a field
nobody reads, a convention in a manifest: each has to be checked twice, and a check that is
only in one code path is a habit rather than a rule. So there is one class of deployable thing
and every remaining distinction is enforced by something that can fail: the environment is
parsed from the name and resolved against a root-owned table of tracks (ADR-0002), an edge is a
list in the manifest, a port is a grant in a root-owned file (ADR-0006), a data lineage is
decided by the track.

**Two facts about rootless containers decide connectivity.** A rootless container cannot join
another user's podman network, and a container's `127.0.0.1` is its own loopback — pasta
exposes the host's loopback at exactly one alias. So there is one shared namespace, and the
name a consumer resolves is written by the renderer as `AddHost=` into the consumer's own
units, with no name map and no `/etc/hosts`. The isolation that exists is uid-matched firewall
rules on declared edges, whose exact limits are stated in the ADR rather than implied
(ADR-0004).

**A security property is only as strong as the mechanism that enforces it, and the mechanism
is written down or it does not exist.** Root-owned configuration lives outside every user-owned
directory, because a mode on a file inside one says nothing about unlinking it. Credentials are
encrypted blobs rather than files, and are scoped one per edge rather than protected by secrecy.
No unprivileged process can bind a privileged port, because the kernel forwards the public
ports instead of the whole host being granted the capability. Each of these has a named
mechanism in the spec and a named limit in `SECURITY.md` (ADR-0003, 0005, 0006).

**A test that cannot fail is worse than no test.** The harness proves behaviour at the command
line, and the claims that fakes cannot establish — that a rootless container reaches a
dependency by name, that a non-member cannot connect to a declared port, that a clone of a live
data volume starts and recovers — are proven on a real machine or not claimed at all
(spec §11).

## 6. Architecture

| layer | programs | privilege | job |
|---|---|---|---|
| host | `soil` | root | packages, btrfs and snapper, sysctl, firewall framework, ingress forwarding, dead-man, install |
| control | `weedr` | root | the only mutator: identities, service roots, state volumes, units, credentials, ports, snapshots, forks, rollbacks |
| render | `loom` | unprivileged | manifest plus registry to units, host entries, environment, credential requests |
| render | `roots` | unprivileged | the edge's route configuration |
| render | `twig` | unprivileged | the dashboard's configuration |
| deploy | `furrow` | unprivileged | the build queue, and the deploy order |
| receive | `hose` | unprivileged, network-facing | pokes, ref to environment, calls furrow |
| safety | `stakes` | unprivileged | pins, and the seed references it derives from the registries |

Privilege has exactly two levels: root and not root. `soil` and `weedr` are root; the rest run
as the `guarden` user, except `hose`, which has its own user because it is the only program a
stranger can reach. The edge is an ordinary service named `traefik-production` that reads one
directory `roots` writes.

The reconciler that writes snapper's marks is `weedr pin sync`, a root action, and deliberately
not part of `stakes`: pins live in files and are queried unprivileged, writing snapper's metadata
is root, and one program running as two users on a schedule is how a privilege boundary quietly
stops being one (ADR-0007).

The mutator is python today and will probably not be tomorrow. Bash is for invoking programs and
sequencing them. The interface is the command line and the file formats, and the spec is written
so that it can be implemented twice (ADR-0012).

The environment set is a root-owned table in `/etc/guarden/guarden.toml`, not a list in the
code. Each row is a **track**, and it carries a name, a `host_prefix` for its route hosts, whether
it is `gated`, a `weight` baked into generated units as `CPUWeight=` and `IOWeight=`, a
`free_limit`, a `keep_last`, and a `kind` that is either `slot` (one service per workload) or
`instance` (one per ref, under `cap`). `cap` lives only on the `[[environments]]` block of an
instance track: a slot track must not carry one and an instance track must, and either mistake is
exit `2` naming the track. Three tracks ship — production, staging, preview — and appending a
fourth such as `preprod` is a configuration change.

A track is a row with fields, so "what does this environment imply" is a question the table
answers once, and adding a track is not writing a branch. Previews being a path prefix on a
single host rather than a host per ref is the same mechanism's consequence: no wildcard
certificate and no per-ref DNS.

## 7. Security posture

Stated as what the mechanisms deliver, and no further. Where a mechanism is weaker than the
phrase usually attached to it, that is the phrase's fault.

- The isolation boundary is the **per-service uid**. One user per service, `0700` on its whole
  tree, and an `AddHost=` entry plus a uid-matched firewall rule per declared edge. Everything
  below is a guardrail against accidents layered on top of that boundary, not a replacement for
  it.
- A render-time check is a guardrail, not a defence against an adversary. `loom` refusing a
  host path, a privileged flag or an undeclared volume stops a manifest from doing it by
  mistake. It does not make a hostile repository safe: the repository's code runs as the
  service user, and a service cannot be defended from the user it runs as. The renderer's job
  is to make the dangerous thing impossible to write by accident and obvious in review, and
  that is all it is for.
- A root-owned unit drop-in in `/etc/containers/systemd/users/<uid>/` guarantees **survival
  across regeneration** — a cap or a device the operator added is not clobbered by the next
  render. It does not give immunity from the service user, which can still write a file in its
  own home and affect the resulting unit.
- One root-facing program for service state, and a sudoers rule naming verbs for the one
  network-facing program. The rules carry their runas target, and that is what makes the claim a
  property of the file: `guarden ALL=(root)` for the mutator, and `hose ALL=(guarden)` for the
  deploy queue, so a poke reaches a root program only by way of a program that is itself
  unprivileged. A poke cannot reach a shell, and cannot name a removal verb that removes a
  service in a gated track.
- A repository cannot open a host port and cannot choose its own environment: both are
  root-owned decisions (ADR-0006). It also cannot state a build priority, a snapshot priority, a
  data source, a lineage, a resource cap or a weight. Those are spec rules (spec §10, §6.6,
  §8.1, §8.3) and there is no ADR behind them.
- A service that did not declare an edge cannot *connect* to the provider, enforced by
  uid-matched firewall rules, and authenticates with its own minted credentials (ADR-0004).
  Bindings are the exception: nothing polices what a service listens on at runtime, so two
  compromised services can talk over any port they both choose. Install-time refusal of a
  duplicate publication is all that is there.
- Credentials are systemd-encrypted blobs, materialised into per-user podman secrets. The trust
  boundary is exact: **protected from other services and from a backup of `/etc`; NOT protected
  from a backup of `/var/lib`**, because the materialised podman secret store in the service's
  home is cleartext and the home's `0700` is the protection. It is deliberately available to its
  own service, because a rootless container shares that service's uid. Scoping and rotation are
  the real controls — one least-privilege credential per declared edge, and rotation is
  `weedr secret set` plus a restart. On a gated track the gate refuses a start with a missing,
  empty or example value, and it is checked before the old container stops; on a track with
  `gated = false` the same condition is one `warning:` line and the start proceeds. The key is
  chosen once — a host key or the machine's TPM — and `auto` is avoided precisely because its
  meaning varies with the hardware. Decryption happens once, root-side; a service's unit names
  the secret and podman resolves it, because the unit runs in a user manager that cannot read a
  `0600 root` host key.
- No guarden program runs a daemon as root, and the mutator never runs a converter, or any other
  program, over repository input. The build is a mutator verb for the same reason the mutator
  exists: an unprivileged `furrow` cannot become the service user, and the subuid range belongs
  to the service user and only it may map container-root into it.
- **Nothing unprivileged binds a port below 1024, and nothing is granted a capability.** The
  kernel owns the public ports: `soil firewall` writes `20-ingress-nat.conf`, whose nat
  PREROUTING DNAT on the ingress interface sends `80/tcp` to the edge's publication and
  `443/tcp` and `443/udp` to its TLS one, and `soil sysctl` sets `route_localnet=1` on that
  interface so the kernel does not treat the DNATed destination as a martian. That is three
  forwarding rules, not two, because a forwarded udp port is a different protocol and a
  different rule. **There is no `POSTROUTING` masquerade**, and this document previously
  required one: the claim was that a DNAT to `127.0.0.1` delivers to a loopback socket, so the
  reply leaves with a loopback source and an external client discards it. That is wrong — after
  the DNAT the packet is local and never reaches `POSTROUTING`, and conntrack rewrites the reply's
  source to the public address the client dialled. What does hold is that a request the box makes
  to itself never traverses `PREROUTING`, so an on-box check passes whether or not forwarding
  works; the golden-VM criterion is therefore that a forwarded port answers *from off the box*.
  The mutator writes
  any service's own granted forwarding into `30-services.conf`, and the two files are disjoint.
  `REDIRECT` cannot do this job: it
  rewrites the destination to the incoming interface's own address and the edge listens on
  loopback only. The edge is an ordinary service that binds loopback publications and nothing
  else. `soil sysctl` sets and owns `net.ipv4.ip_unprivileged_port_start=1024`, so there is no
  exception anywhere in the system and nothing to reason about at three in the morning.
  The check is against the value `1024`, not against the distribution's default, because a
  base image that ships `0` satisfies the default and breaks the invariant; `soil sysctl
  --check` and `weedr service list` both report drift against the value guarden converges.
  `443/udp` is HTTP/3 served by
  the edge from the same TLS entrypoint, and it is an additive optimisation: a client that
  cannot use it loses nothing, and nothing else in the design depends on it.

## 8. Known accepted risks

Not a backlog list. Things the design does not solve, stated so nobody discovers them at three
in the morning.

**Instances of one preview service are one trust domain.** Every instance of a workload in a
preview track shares a uid, a home, an image store, a podman secret store, and each other's
directories. An allowlist of `*` creates an instance for any ref a poke names, including a
fork from outside the operator's own repositories, and that instance can read the others'
credentials. This is accepted for v1 and we may revisit it; nothing in the design mitigates it.
The remedy is one line of configuration: narrow the allowlist for a repository that has outside
contributors, or make the fork its own service.

**Nothing polices what a service binds.** The firewall restricts who may *connect*, not what
may listen. Two compromised services can talk over any port they both choose, and a service
that binds a port it was never granted is caught by nothing. This is accepted: the port
allocator refuses a duplicate at install time and that is the whole of it.

**A pin is a budget, not a promise.** Retention belongs to snapper's own cleanup algorithms and
guarden runs no delete loop. A root reconciler reads the registries and the pin files and marks
what must survive with snapper's `important` userdata, but `NUMBER_LIMIT_IMPORTANT` is a
min-max range and the free-space pass uses the minimum. A marked snapshot can therefore be
reaped when the disk is nearly full, oldest first. That is accepted: it only happens when the disk
is nearly full, which is itself the signal worth having. The floor under pressure is one number —
the low end of the range — which `soil` owns in the state volume's snapper configuration and no
manifest can state; the shipped default keeps eight marked snapshots. The operational reading is
fixed here so nobody reads it the other way at three in the morning — a preview that cannot be
re-forked from an old snapshot means the disk is filling, not that something is broken.

**One snapshot can be made unreapable, at a cost.** `chattr +i` on a snapshot's subvolume makes
the btrfs delete ioctl return `EPERM`, which no limit can override, and a fork still works
because btrfs does not inherit immutability. It is a deny rather than a keep-N: snapper's cleaner
deletes candidates with no per-item error handling, so the first candidate it cannot delete
aborts that configuration's whole cleanup for the run, and the configuration stops auto-pruning while
that snapshot is a candidate. It is a per-snapshot operator decision, it is recorded, and
`chattr -i` reverses it.

**Nothing is forwarded back into the box from itself.** Locally generated traffic does not
traverse PREROUTING, so a health check, a smoke test or the lockout drill has to address
`127.0.0.1:<publication>` rather than the public host name. There is also no hairpin NAT, so a
machine on the same local network cannot reach the box by its public name. Accepted: the box is
reached from the internet, and neither case is a path guarden needs.

---

## 9. Portability

The host layout and the phase structure are distro-neutral: `/usr/lib/guarden`,
`/etc/guarden`, `/var/lib/guarden`, `/run/guarden` and the six soil phases do not name a
distribution. Every path is a constant in `guarden/paths.py` and is written there once, because a
path spelled twice is the copy that drifts.

What is still Ubuntu-only is the install path, and it is four things:

1. the dracut hook for the btrfs convert;
2. the `DPkg::Pre-Invoke` hook at `/etc/apt/apt.conf.d/80guarden-snapper`;
3. the names of the distribution's packaged snapper units;
4. cloud-init.

Everything else is behind a capability probe with a documented fallback. **The package list is the
one place the difference is concentrated**, and it is per family rather than one list of one
distribution's names: `packages/packages.toml` carries a row per family, each with its own install
argv, its own query argv, and its own answer to "is it installed" — which is a separate key because
that is where families differ most sharply, and a probe that asks the wrong question reports a
package that is absent as present. The family itself is probed by `ID_LIKE` in `/etc/os-release`,
then by the query tool on `PATH`; neither probe runs a command. A family the list does not carry is
exit 2 naming the families it has, never a guess at the nearest one.

That list is **the** list. `soil packages` converges its `packages` rows and the cloud-init
user-data is rendered from them, so a package added to one and not the other is a box that installs
three things and converges on a fourth with both machines reporting success. `tools/golden-vm`
re-renders before it boots and refuses a committed document that has drifted from the list, so the
file a reviewer reads in the repository is the file the machine boots.

There is no PyPI and no wheel anywhere on the boot path: every package in the list is a
distribution package, and the one artefact fetched from outside a distribution repository is the
pinned `podlet` release, verified against the SHA256 recorded in the repository.

The install target is stated once, in the README: *Ubuntu 26.04 (the layout is portable; the
install path is not yet).*

---

## 10. Backlog

- Building the lane count from observed load. The override exists.
- Resource caps. guarden sets priorities and no caps: `CPUWeight=` and `IOWeight=` come from
  the environment's `weight`, and `MemoryMax=` or `TasksMax=` is a systemd setting the operator
  writes into the root-owned drop-in directory `/etc/containers/systemd/users/<uid>/`. Whether
  the box needs them is a capacity question rather than a platform one.
- Off-box snapshot backup with a pin-aware guard.
- Sanitising previews: fork, then rewrite. Forking is now instant, so this becomes cheap.
- A second database engine, if one is ever needed.
- `podlet` maintained in-tree rather than pinned, so a unit can be fixed without a binary
  release.
- Disk-usage and snapshot-count monitoring. The data it needs is already exposed by
  `weedr service list --json`, which is a root read and reports per state volume the total
  snapshots, the marked snapshots, the oldest, the newest, and the effective `NUMBER_LIMIT` and
  `NUMBER_LIMIT_IMPORTANT` read back from snapper with `snapper get-config` rather than from the
  file guarden believes it wrote. `stakes list --json` is the other half and is deliberately not
  the source for these figures: `stakes` runs as `guarden` and a service's tree is `0700` to that
  service, so it cannot read a state volume; it reports the pin files it owns and the services
  naming each as a seed. A monitoring job polls the first for disk and snapshot counts and the
  second for what is pinned. Collecting and alerting is backlog, and it subsumes the
  per-service disk alarms below.
- Per-service disk alarms before a preview farm fills a small VPS.
- A second edge, if one is ever needed. `roots` is Traefik-specific by decision and has no
  intermediate route format, so replacing the edge means replacing one unprivileged program
  (spec §6.4).

## 11. Open questions

- Whether the pasta host-loopback alias is reliable enough to be the whole of inter-service
  name resolution, or whether a loopback DNS server is needed. The alias is the container's
  default gateway, which pasta maps onto the host's loopback in userspace by default, so the
  question is narrower than it was: the address is derived from the host's route rather than
  chosen, and it drifts. The golden VM must answer it before anything is built
  on top of it.
- Whether a btrfs-progs 5.14 clone of a live snapshot recovers acceptably for a database
  larger than anything on the current box.
- Whether `keep_last` should be per state volume rather than per service.
- Whether a second edge implementation belongs in v1, or whether the queue should stay
  synchronous until there is a demonstrated need.
