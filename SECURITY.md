# guarden — security model

What this system actually protects, from what, and how — and, just as important, where the
protection stops. A security document that only lists strengths is worse than none, because
an operator will design around the wrong layer.

Everything here is verifiable from the design in [`docs/spec.md`](docs/spec.md) and the
decisions in [`docs/adr/`](docs/adr/). Where this file and those disagree, those are right.

---

## 1. The threat model

One operator, one VPS, a handful of services, one domain. There is no second tenant, no
customer data, and no hostile network position beyond the ordinary internet. The realistic
adversaries, in the order they are likely to matter:

1. **A compromised service.** Anything running a container the operator did not write, or a
   dependency of something they did. This is the adversary the design spends its effort on.
2. **A compromised repository.** A pull request merged without reading, a dependency
   compromised upstream, a CI key leaked. This reaches us as arbitrary repository content.
3. **A leaked CI key.** One ed25519 key per project, bound by a forced command.
4. **Physical or cloud access to the disk.** A stolen VPS, a disk image, a volume snapshot
   from the provider.
5. **Root on the box.** Out of scope. Nothing here defends against it, and the design says so
   rather than implying otherwise.

Non-goals: defending against root, defending against a malicious kernel, and defending against
an operator who has decided to shoot themselves in the foot.

---

## 2. The boundaries, strongest first

### 2.1 One root door

`soil` and `weedr` are the only guarden programs that run as root. Everything else — `loom`,
`roots`, `twig`, `furrow`, `stakes` — runs as a single unprivileged `guarden` user, and `hose`
has its own user because it is the only program a stranger can reach. `snapperd` is a root daemon
the distribution ships and the design depends on; the claim is about guarden's own programs.

Both sudoers rules are written out in full, once, in `docs/spec.md` §6.6 and §6.7 with their
runas targets. They are not repeated here: a rule duplicated across documents is a rule that
drifts, and this one has changed four times in the spec's own history. What matters *for this
document* is the consequence, which does not need the block: the `guarden` rule runs the
mutator verbs as **root** — so `guarden`, the user that runs `loom`, reaches root through
exactly the verb list, and the program that handles repository-supplied paths is not itself
a root program — while `hose`'s rule runs as **`(guarden)`**, so the default reading of "a
sudoers rule naming X is that X runs as root" is false here and would have made a
network-facing program a root one. `hose`'s only `weedr` verb is `weedr project list`;
`weedr service list` is deliberately absent because this rule's runas target is `guarden`
and that verb is a root read.

The `(root)` is the mutator, and the verbs named are exactly the lifecycle and read verbs plus
`weedr service build`. Never `weedr port open`, `weedr port close`, `weedr service purge`,
`weedr service rollback`, `weedr module add`, `weedr project add`, `weedr project grant`,
`weedr project revoke`. The rules name the long form of each verb, because a rule naming
`weedr service rm` would not match it.

**No verb on that rule carries a flag that widens authority, and that is what makes the
guarantees below true rather than aspirational.** A sudoers command with no argument
specification matches any arguments, and sudoers has no negation, so an earlier revision of this
document — which granted `weedr service add` and `weedr service remove` while stating in prose
that no invocation might carry `--grant-ports` or `--purge-state` — in fact granted both. There
was no argument specification that could have prevented it, because every legitimate call of
`add` carries a different staging path and a different sha. So the capabilities became verbs:
a grant is `weedr port open`, destruction is `weedr service purge`, and neither is on the rule.
`weedr service rollback` was removed from it entirely, because it replaces a service's current
volumes with a clone of an old snapshot and had been gated only by a `--yes` the rule could not
distinguish from any other argument. `furrow` never rolls anything back and the operator runs as
root, so nothing was given up.

**Every verb that is granted is granted whole.** That is the whole security property of the
sudoers file, and it is worth stating as a rule for future verbs: a capability that should not
be reachable from a deploy must never be a flag on a verb that is.

The `(guarden)` on `hose`'s rule is what makes "cannot reach a shell" true: a poke reaches a root
program only by way of a program that is itself unprivileged. So a poke cannot open a port,
cannot install a module, cannot grant credentials, cannot destroy data, and cannot become root.

The mutator is written in python rather than shell, because the fork-and-rollback path has more
failure-path branches than shell should be trusted with. That is a correctness argument with a
security edge, not a security control.

### 2.2 The per-service uid, and the `0700`

This is the real boundary. Each service is a distinct Linux user, and its entire tree under
`/var/lib/guarden/services/<name>` is `0700` and owned by that user — home, state volumes and
everything else under it, with no carve-out.

This is the single most important line in the design, and it is the one most easily lost. If
the tree were `0755`, any service could read every other service's database files directly from
the host filesystem, and every per-consumer credential and every uid-matched firewall rule
would be decorative. The `0700` is what makes the credential scoping below mean anything.

Two honest limits:

- **The boundary is between services, not between a service and its own containers.** Rootless
  podman means a container shares its service's uid, and podman's secret database for that
  service lives in that service's home. A container of `myapp-production` *is*
  `myapp-production` as far as the kernel is concerned.
- **Previews are one trust domain.** All instances of one preview service share a uid, a home,
  an image store, a secret store, and each other's directories. A compromised instance reads
  the others' credentials. This is accepted for now and may be revisited; the remedy available
  today is to narrow the project's allowlist so that only refs the operator controls get an
  instance, or to give an untrusted fork its own service.

### 2.3 Credentials: protected from everyone else, available to their own service

The mechanism is a `systemd-creds` blob: encrypted with `systemd-creds --with-key=host` against
a host key at `/var/lib/systemd/credential.secret`, or with `--with-key=tpm2` to bind the key to
the machine's TPM. The key is chosen once and stated once. The `auto` setting is not used,
precisely because its meaning varies with the hardware: it prefers a TPM2 key when it finds one,
so a box with a TPM would silently encrypt with a different key than every document here
describes. The blob lives at `/etc/guarden/creds/<name>/<KEY>.cred` mode `0600` and is
materialised into the owning service's per-user podman secret store.

Decryption happens once, root-side, in the credential materialiser — a path unit on
`/etc/guarden/creds/` and a boot-time oneshot, two units for the whole host and not one pair per
service. That is why the unit exists, and it is why a generated service unit does not.

The renderer emits `Secret=<KEY>,type=file` in the `[Container]` table **and nothing else**.
Podman resolves `<KEY>` from that service's own secret store and presents it inside the container
at `/run/secrets/<KEY>`. A key whose application insists on a variable gets `type=env` instead.

**The generated unit carries no `LoadCredentialEncrypted=`, and must not.** These units run in
the *service user's* user manager, which cannot read the system host key: it is `0600 root`, and
a user manager has no business holding it. By the time the renderer runs, the value is already a
podman secret and the renderer only names it.

What that buys, precisely:

- **Not in any file.** No value is written anywhere readable, and none is in a snapshot, because a
  service's home is not snapshotted.
- **Not in a backup of `/etc`.** A `tar` of `/etc` yields an encrypted blob and nothing else.
  Binding the credential key to the host's TPM rather than a host key file strengthens this
  further, and trades the operator's recovery path for hardware binding.
- **In a backup of `/var/lib`, and this is a deliberate limitation rather than an oversight.**
  The encrypted blob is not the only copy: the credential materialiser writes the value into the
  owning service's per-user podman secret store, and podman keeps secrets in the clear —
  `0700` on the home is the protection, not encryption. A stolen disk, a disk image, a provider
  volume snapshot or a `tar` of `/var/lib` therefore yields every credential in the clear for
  every service. A runbook claimed otherwise and the operator drew exactly the wrong conclusion
  about what may leave the host. The accurate statement is: `systemd-creds` protects the value
  at rest on the host filesystem, and deliberately does not protect it from the service that
  owns it, because that service's container is the same principal.
- **Not readable by another service.** The podman secret store is inside another service's
  `0700` home, and the blobs are `0600 root`.
- **Not in git, and not in CI.** The tracked schema holds names, types and example values. A
  poke key is the only secret a project's workflow holds.

What it does **not** buy, and the document set says so wherever it matters:

- **Not protection from the service's own container or its own user.** That is the same
  principal, and no at-rest scheme can change that, because the service needs the credential
  to do its job.
- **Not protection from root on the box.** A host-key credential is decryptable by root, and
  this document will not pretend otherwise. It is a claim about theft and casual filesystem
  access, not about an attacker who has already won.
- **Not protection from losing the encryption key.** There is one key and no second copy of it on
  the box, and no mechanism for one. Lose `/var/lib/systemd/credential.secret` — or the machine
  that held the TPM-sealed key — and every credential on the host is unrecoverable, and each has
  to be re-planted with `weedr secret set` from the operator's own offline copy. That is the same
  single-point property as losing the values, and it is why the operator keeps them.

**The real control is scoping, not secrecy.** One credential and one least-privilege role per
declared edge, so a compromised service gains only what its own role can do. Rotation is
`weedr secret set` plus a restart, and it is cheap precisely because nothing is stored
centrally to be updated. Injection defaults to a file rather than an environment variable,
because an environment variable is visible in `/proc/<pid>/environ`, is routinely echoed by
frameworks in stack traces, and is inherited by every child process.

A state volume's snapshot contains no credential, which is what makes cloning and rolling back
safe to automate.

### 2.4 The gate on a gated track

A service in a track with `gated = true` will not start when a `@required` key is missing, empty,
prefixed `EXAMPLE-`, or equal to `changeme`. The message names the key.

That is the whole difference between a gated track and one that is not, and there are exactly two
outcomes. On a track with `gated = false`, the same condition produces one `warning:` line naming
the key, and the start proceeds.

The gate is evaluated **before** the old container is stopped, and so is the image build. A
deploy that fails either leaves the running service untouched. This is the difference between
a gate that protects production and one that merely reports.

Its limits, stated: `EXAMPLE-` and `changeme` are conventions, not a specification. A schema
whose `@example` does not follow them gets past the gate. It is a seatbelt against the common
mistake of shipping the example value, not a proof that a credential is correct.

### 2.5 Ports and firewall rules: a repository cannot open one, and cannot install one

A manifest may *request* a public port with `ports:`. The request is legitimate and says nothing
on its own. The grant lives in a root-owned `overrides.toml` that the repository cannot write, in
a key that *records* a grant — which is the rule, and it is not "a manifest may not have
`ports:`". A poke never grants; it leaves the port pending, prints a `warning:` line naming the
ports and the exact command, which reaches the pull request's log, and the pending state is
sticky in `weedr service list` until an admin acts or the manifest drops the request.

Every grant is public ingress and every one is address translation: no service ever binds a
non-loopback address, and there is no private-versus-public grant. The grant names a public
port, and it becomes a translation of that port to the service's loopback publication.

The renderer owns the published-port set completely: it strips every `PublishPort` in the unit
source — from Compose and from hand-written quadlet alike — and regenerates the set. Without
that, a Compose `ports:` entry becomes a `PublishPort=` line verbatim and the grant model is
advisory.

**A `firewall:` entry is the same shape of thing: a request, and an admin's grant behind it.**
The request is a named rule line, it installs nothing, and the install is `weedr firewall open` —
root, by hand, and on no sudoers rule, so a poke creates the request and leaves it pending
exactly as it leaves a port pending. The renderer writes no firewall rule at all: it validates
the entry's shape, records the request in the registry, and stops there, because a renderer that
emitted rules would be a second writer on the file the `firewall` lock exists to protect. A
request is additive only — it may add a rule to a chain guarden owns and may not flush a chain,
set a policy, reorder guarden's rules or land after the default deny.

**What the grant is worth is exactly the rule, and that is the honest limit.** An admin agrees to
one line, not to a service's intentions; a rule whose match is broader than its author expected
reaches everything the match covers. And because a granted rule renders **above** the default
deny — a grant that could never match would be worse than useless — **a rule matching `-o lo`
and accepting does reopen loopback for exactly the match it names.** The deny is still the last
line of the chain and every other part of the loopback posture is unchanged; this is the one
door in, and it is opened by a person with root on purpose (ADR-0013, spec §7.7).

### 2.5b The tunnel and a shared grant: a third way in, and guarden answers for it

A **tunnel** (ADR-0015) is a second terminator and it is **egress-only**: it dials out and is
reached by nobody, binds no port and appears in no forwarding rule, so it adds no ingress path
and the firewall's ingress set is unchanged by its existence. A route on a track whose `expose`
is `tunnel` is therefore reached *through* the tunnel and not on the public edge.

Getting somebody to such a route is `weedr share issue`, and it is deliberately priced as a
**grant**: it is on no sudoers rule, `hose` cannot reach it, and no deploy path does either. The
record of who may reach what is guarden's — one file per issuance under
`/var/lib/guarden/share/`, `0750 root:guarden`, holding an **absolute** deadline — and the
vendor's Access policy is a **projection** of that record, never the record. Deleting a policy by
hand in the Cloudflare dashboard makes no local issuance live, and `weedr share reconcile` puts
it back.

**The limit is the reconciler timer, and it is stated rather than implied.** An Access policy has
no `expir*` field, so removing the address from the policy is the act that ends a grant, and it is
`weedr share reconcile` — a root-owned timer, every ten minutes — that removes it. **If that
timer stops, an expired grant's address stays in the policy.** A live session still ends when
`session_duration` expires (guarden sets it to `[share] max`), but the customer can sign in again
while the email remains. This is the same class of failure as a stopped mark reconciler: the
record is correct and the vendor has drifted, and `systemctl is-active
guarden-share-reconcile.timer` is the first thing to check.

**A leaked API token reaches exactly one application's Access policies.** The token is read from
`/etc/guarden/share.api-token` (`0600 root`) and is the only thing in guarden that calls the
vendor; `[share] scopes` in `guarden.toml` records what it needs (`Access: Apps and Policies
Write`) so an operator can audit what a leaked one would reach. It can rewrite the policies of
the one application named by `[share] app`. It **cannot** mint, extend or revoke a grant on its
own: those are `weedr share` verbs, they are on no sudoers rule, and a poke cannot reach them.

### 2.6 What a service can reach

Two layers, with their exact limits.

**The loopback is closed to the service uids, and the publications are the only way in.** The
rendered rule set is a **default deny on all of loopback for every service uid** in `OUTPUT`,
where an owner match matches the socket's owner and is reliable, with an accept rule per
(publication, allowed uid) above it — the edge for every route publication, a consumer for each
edge it declared, `host.admin_user` for the edge's API, the service itself for its own granted
port. A service that did not declare an edge cannot connect to a declared one, and a service
cannot reach a port nobody published at all, including `sshd`. The rule renders the accept set
first and the single deny last, and the order is the whole of it.

**Binds are not policed.** Nothing prevents a service from binding a loopback port it was never
granted a publication for, and two compromised services can talk over any port they both choose.
"Two services must not hold the same publication" is enforced by the allocator and is
cooperative, not structural.

The owner match is deliberately **not** used in `INPUT`. A forwarded packet has no socket, so
an owner match there is unreliable and would drop the edge's traffic.

**How a container reaches another service is a measurement, not an assumption — and what the
host firewall matches on is not the measured value.** Rootless containers cannot reach a host
loopback address other than the one pasta exposes, and per-service `127.x` blocks are
unreachable from inside them by construction. From `pasta(1)`, that one address is the container's
**default gateway**, mapped onto the host's loopback in userspace: "Packets from the guest to
`addr` will be redirected to the host. On the host such packets will appear to have both source
and destination of `127.0.0.1` or `::1`."

Two things follow, and the second is the one that has been got wrong before:

- The alias is a **name the consumer resolves** in `AddHost=`, and it is derived from the host's
  default route rather than chosen by guarden. Ticket 15 measures it, `soil install` records it
  as `ingress.alias`, and `soil sysctl --check` reports drift when the recorded value no longer
  matches the route.
- **Every host-side rule matches `127.0.0.1`, not the alias.** The translation is done by pasta
  in userspace before the kernel's packet path, so no rule in any table could match the alias
  even in principle, and the only host control that sees this hop at all is the `owner` match in
  `OUTPUT` — pasta's sockets are owned by the service user.

**The loopback is closed to service uids by default, and the publications are the only way in.**
Because pasta's mapping is on by default, a container can otherwise open a connection to any
host loopback port through the alias — `sshd` on 22, a database the operator runs by hand,
anything. So the rendered `OUTPUT` set is a **default deny on the whole of loopback for every
service uid**, with the per-publication accept rules above it, and the order is the whole of it.

The deny matches `-d 127.0.0.0/8` and does not touch outbound traffic: a package update and
a git fetch leave on the real interface. **It does touch name resolution, and an earlier
revision of this document said it did not**, on the grounds that pasta's DNS forward is
excluded from the loopback mapping. That is true of traffic from *inside* a container;
`podman pull` is on the **host**, as the service user, its packet leaves through `OUTPUT`, and
the deny is on the network the stub listener at `127.0.0.53` belongs to. Measured on a real
machine by reading the deny's own packet counter across one UDP send from a service uid to
`127.0.0.53:53` — it moved, 0 then 1 — so the resolver was unreachable from every service uid
and **no first deploy of a new workload could complete.** spec §7.6 renders the one accept that
fixes it: `127.0.0.53` port 53, `udp` and `tcp`, owner-matched to service uids, above the deny,
and nothing else on loopback (ADR-0015). The claim survived because the runbook told the
operator that `iptables -S` could not see the firewall because the files were ferm source.
Ferm compiles to iptables. The live rules are always inspectable.

**There is no `[loopback] allow` table.** A table whose whole content is a destination would be a
second way to grant one beside the publication set, and two ways to grant a thing are two ways
for it to be wrong. `overrides.toml` is `[ports]`, `[firewall]`, `[retention]`, `[groups]` and
`[mounts]`, and the `[firewall]` one is different in kind: it holds the **names** of rules a
manifest asked for, not destinations (§2.5). The stub resolver's accept is different in kind
again: it is **one** destination guarden derives from the host rather than a key an operator
fills in, so adding another is a change to the code and to the spec rather than a configuration
change (ADR-0015). Making that daemon a service is still the right
answer for a host loopback port that is not a publication — a granted rule is the door for the
cases where it is not possible, and it is opened by root on purpose.

What this does **not** do is stop a service *binding* a port of its own choosing. Two
compromised services can still talk over a port neither declared. What is enforced is that a
service which did not declare an edge cannot connect to one.

### 2.7 Ingress without a capability

**The host firewall is `ferm`. `ufw` is uninstalled on a guarden host.** `soil packages`
installs `ferm`; `ufw` is removed during installation. No `ufw` rule is written, read or
reconciled anywhere in guarden. The dead-man timer does not re-enable `ufw` — it stops
`guarden-firewall.service` and clears guarden's own chains. That failsafe is strictly weaker:
it can open the firewall but cannot restore the previous ruleset, because there is no previous
ruleset to restore. Every other rule on the host, for every service however it was deployed, is
in one ferm ruleset, and that ruleset is inspectable with `iptables-save` because ferm compiles
to iptables (ADR-0013).

No unprivileged process on the host may bind a port below 1024, and no process is granted a
capability. `soil firewall` writes `20-ingress-nat.conf` with address translation for 80/tcp,
443/tcp and 443/udp onto the edge's published loopback ports, which requires `route_localnet`
scoped to the ingress interface and nothing else. The mutator writes any service's own forwarding
and any service's own granted firewall rules into `30-services.conf`; the two files are
disjoint.

**There is no masquerade, and this document previously claimed there was one.** The claim was
that without a `nat POSTROUTING` masquerade the forwarding rules "deliver exactly nothing from
anywhere" while every on-box check passed. That was false, and it is worth saying why the
reasoning looked sound: after the `PREROUTING` DNAT the packet's destination is a local address,
so it is delivered to `INPUT` and never reaches `POSTROUTING` at all; and on the way back
connection tracking unwinds the destination translation and rewrites the reply's source to the
public address the client dialled, which is exactly what an external client requires. A rule
written as `-o <ingress-if> -d 127.0.0.1 --dport <pub> -j MASQUERADE` matches **no packet in
either direction** — the forwarded packet is local, and the reply's destination is the client.

The load-bearing requirement is `route_localnet` alone. Without it the kernel treats a packet
addressed to `127.0.0.1` arriving on a non-loopback interface as a martian and drops it.

What did survive is a real operational property, and it is kept: **a request the box makes to
itself cannot tell you whether forwarding works**, because locally generated traffic never
traverses `PREROUTING`. So a loopback health check on the publication and a `systemctl status`
on the edge both pass on a box where the edge is unreachable from anywhere, and the only
diagnostic that distinguishes them is a connection from a second machine. That is the
golden-VM criterion, and it is a test rather than a proof.

The alternative — lowering the unprivileged port threshold — would have granted **every**
unprivileged uid on the host the right to bind any privileged port, for as long as the setting
was there, which is not narrow and would survive the removal of the service that motivated it.

**guarden sets the threshold to `1024` and checks against that value, not against the
distribution's default.** Both halves were previously wrong. The check said "no longer at the
distribution's default", so a base image that ships `0` — common in container images, and the
setting a lot of tooling lowers for convenience — passed the check while every unprivileged
process on the box could bind a privileged port; the predicate has to be the invariant, not the
baseline. And guarden declined to set the value at all, which meant the invariant was a
convention somebody had to honour. It conflates two different acts: *lowering* the threshold
grants every unprivileged uid a privileged port and is refused, while *raising* it to the kernel
default is a tightening that makes "nothing unprivileged binds below 1024" a value guarden
converges, like the snapshot retention values. `soil sysctl --check` reports drift against
`1024`.
With translation the kernel owns the public port, so nothing can intercept it even while the
edge is restarting.

### 2.8 Root-owned configuration cannot be reached by a service

Admin configuration and admin units live in `/etc/guarden` and in podman's uid-scoped rootless
quadlet path, `/etc/containers/systemd/users/<uid>/`. Neither is inside a service's home, so
the service user cannot unlink, replace or symlink over them. Placement is the whole mechanism:
a mode on a file inside a directory the user owns says nothing about unlinking it.

The honest limit: the service user's own quadlet directory is searched *before* the
administrative one, so the guarantee is that an admin override **survives regeneration and is
not silently clobbered** — not that the service user cannot change the resulting unit. Anyone
who needs the stronger property needs the stronger mechanism, and the documents do not claim
it.

### 2.9 Credential materialisation

Two units, not two per service: a path unit on `/etc/guarden/creds/` and one boot-time oneshot.
`/etc/guarden/creds/` is `0700 root`. The pair is the only place a blob is decrypted, and it is
root because the key is.

### 2.10 Input handling

A poke's tar archive is unpacked into `/var/lib/guarden/staging/<project>/<sha>/`, `0755`
root-owned with `0644` files, as a non-root user under `umask 022`, with no absolute member
names, no `..` component, no preserved ownership, and no symlink followed. A member that escapes
the target directory is refused and the poke fails without touching a service. A malformed ref or
sha shape is refused the same way. The staged tree contains no secret, because a repository
contains none, and it is removed after the deploy.

**A poke's project comes from the key, never from the request.** The forced command carries
`--project <name>` and the verb's own signature has no project argument at all, so there is
nothing for a client to supply or override. The alternative — `hose --project <name> <project>
<ref> <sha>` — was not equivalent: sshd *appends* the client's command to the forced command, so
a key holder for project A could send `--project B …`, and a conventional argument parser takes
the **last** occurrence of a repeated option, so the client would have won. `hose` refuses a
`--project` argument outright. `hose drop` likewise never accepts a service name: it derives one
from the project and the ref, so a key for one project cannot drop another project's instance.

**No verb takes a path, so there is nothing for a caller to point somewhere else.** This
replaced a staging-confinement design that was correct and needless. `--from <dir>` made the
caller choose a location, and the only question was how much checking to wrap around it — a
`realpath` resolution, a symlink refusal, a uid-conditional allowance, a confinement clause in
the mutator as well as the deployer because `guarden` could write the queue and hand the root
mutator a tree it controlled. A service's tree now comes from exactly two places and neither is a
location: a poke's staged tree, via `weedr service ingest <name> --from poke <project>@<sha>`,
where the mutator builds the path itself from a project validated against `projects.toml` and a
hex sha; or a copy of another service's, via `weedr service add <name> --from <service>`, which
is root-only. `weedr service build` takes no `--from` at all, which also closes the
`podman-build` escalation it previously was — a build may only ever build the service's own tree.

Because `--from <service>` is root-only and is not on the `guarden` rule, a branch cannot create
a service out of another service's tree, and a compromised `guarden` program cannot promote a
staging manifest into production. And because there is no `--from git <url>`, the box never
authenticates to a forge: CI holds the credential, pushes a tarball, and `hose` receives it, so
a private repository needs no deploy key, no token and no `.netrc` on the host.

## 2.11 Write discipline

Every file more than one process may read while another writes is written lock → temporary file
in the same directory → `fsync` → `rename`. A reader takes no lock and never sees a torn file.
The `firewall` lock covers the whole render, diff and install, because without it two
concurrent grants each render and the stale one installs last, silently dropping the other's
rule. The `snapshots` lock covers both the mark reconciler and the cleanup unit, because
snapper takes no lock that `snapper modify` participates in and a mark written during a
running cleanup is lost with no error anywhere.

`guarden.toml` is not exempt because little writes it, but it has **three** writers rather than
the one previously claimed: `weedr module add` appends to `[modules] enabled`, and `soil install`
writes both the measured `ingress.alias` and the `[modules] enabled` list it seeds from
cloud-init. Two of the three share a key, so the rule is that every write takes the `modules`
lock, goes through the protocol, and re-reads the file under the lock rather than trusting what it
saw before it. The file has no unprotocolled writer. A `kind = "instance"` track
deploys each of its instances separately, and one `deploy-<service>` lock per service would
serialise every preview behind every other preview, so an instance's deploy takes
`deploy-<service>-<escaped-ref>`; the ref uses the same escaped form as the registry key and
never a raw one. The `queue` lock covers enqueue
and dequeue; lanes bound builds, `deploy-<service>` bounds deploys, and the two are not the same
knob.

---

## 3. What this does not protect against

Stated plainly, because a reader who knows the edges can use the system correctly.

| not protected | why, and what to do instead |
|---|---|
| **A malicious repository's unit source** | The renderer's refusals — `PodmanArgs=`, `--privileged`, capabilities, devices, host network, out-of-tree host binds — are **guardrails against accidents, not a boundary.** A unit source is arbitrary configuration and a text check cannot be a boundary. The boundary is the per-service uid and the `0700` on its tree. Do not design around the refusal. |
| **A container of the service that owns a credential** | It is the same principal, by design. Scope the credential to one least-privilege role per edge and rotate it. |
| **An instance of a preview service reading its siblings** | They share a uid. Narrow the allowlist for a repository with outside contributors, or give the fork its own service. |
| **Root on the box** | Out of scope. A host-key credential is decryptable by root. |
| **A dependency compromise inside a container** | The per-service uid contains it to that service. It does not contain what the service itself can reach. |
| **A leaked CI key reaching a production deploy** | A poke *may* create and deploy a service in a gated track — including `production`, and that is forced by the architecture rather than chosen: with no git clone and no `add --from <service>` reachable from CI, the staged tree a poke carries is the only way code reaches a workload that does not exist yet. What stands between a push and a running production container is the gate, not the creation: the service exists, builds and installs, and **does not start** until an operator plants its credentials and runs `weedr service start` as root. The gate is a mutator verdict precisely so the thing that starts a production service is never reachable from a workflow key. The gate then holds the start — the deploy exits `0` and the service waits, with the reason in the registry, until the operator plants credentials and runs `weedr service start`. A CI key cannot open a production service's gate: the gate is a mutator verdict and only `weedr service start` lifts it, and a start needs root. It may never drop one in a gated track, and it may never open a port or destroy data. Each of those is a verb the sudoers rule does not name, and no verb the rule does name carries a flag that reaches one. The refusal to drop is enforced root-side in `weedr service remove` against `/etc/guarden/allow-gated-drop` and has no override flag; `hose` never reads that file, and never reaches that verb directly. |
| **A full disk** | Under real disk pressure, marked snapshots are reaped oldest first, and the ladder's ranges are ranges, so the free-space pass keeps only their minimum too. That is intended: it means the disk is nearly full, which is the signal worth having. `weedr service list --json` reports the per-volume counts and the effective limits; `stakes list --json` reports the pin files and the services naming each as a seed, because `stakes` cannot read a state volume. Disk monitoring is backlog. |
| **Malformed configuration being acted on** | The reconciler stops rather than clearing anything when its state cannot be read, and a renderer refuses rather than guesses. Both fail towards doing less. |

---

## 4. Reporting a vulnerability

This system has one operator and no external users, so there is no disclosure process. If you
find something that breaks a boundary described above, the fix is the priority: change the
code, then change this file and the ADR it contradicts, in the same change. A boundary that is
documented and not implemented is worse than one that is neither, because it is trusted.
