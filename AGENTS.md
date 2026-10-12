# AGENTS.md

Working notes for humans and agents modifying this repo. Read [`CONTEXT.md`](CONTEXT.md)
first — the glossary is the vocabulary, and the names are not negotiable mid-change.
[`docs/spec.md`](docs/spec.md) is the contract; where the code and the spec disagree, the code
is wrong. Where two documents disagree the order of authority is spec, then ADR, then ticket,
so a ticket that contradicts the spec is wrong until a decision says otherwise.

## Layout

**This repository is documents only today. No program below exists yet.** `docs/` is the
contract and everything else is written to it; the work list is `docs/tickets/`, and ticket 10
creates the first directory.

```
soil/     the host converger (--check / --apply)          not yet written
weedr/    the only privileged mutator                      not yet written
loom/     the renderer: manifest + registry -> units       not yet written
roots/    the edge's route configuration                   not yet written
twig/     the dashboard's configuration                    not yet written
furrow/   the build queue and the deploy order             not yet written
hose/     the optional gitops receiver                     not yet written
stakes/   the pin registry, unprivileged; the reconciler that marks snapshots is `weedr pin sync`
tools/    golden-vm, the throwaway-machine harness
modules/  shipped module definitions: gate-traefik, homepage, auth-authelia, cloudflared
tests/    the one test seam                               created by ticket 10
fixtures/ guarden*.toml inputs and project manifests. `fixtures/bin/` and
           `fixtures/lib/` were deleted with the fakes (ticket 35, ADR-0014) and
           stay deleted: a stand-in for a system tool is not added without being
           asked for by name
docs/     spec, ADRs, PRD, runbook, tickets, notes
justfile  the task runner: `just test`, `just lint`, `just check`, `just golden-vm`
```

There is no `Makefile`. Tasks run through `justfile`, and `just` with no argument lists the
recipes.

Project repositories carry `compose.yaml` at the root or quadlet units in `.guarden/quadlet/`
— exactly one, enforced by pre-commit — plus `.guarden/service.yml`, `.guarden/widgets/`, and
`.guarden/.env.schema`.

Parts talk over files and paths. There is no internal HTTP API and no socket between them
(ADR-0012).

## Binding decisions

`docs/adr/0001`–`0016` are binding. `docs/spec.md` is the contract, and where the code and the
spec disagree the code is wrong. Do not re-litigate them in a change; if one is wrong, write
a new ADR that supersedes it. The short version:

- One privileged mutator. `soil` and `weedr` run as root; `loom`, `roots`, `twig`, `furrow`
  and `stakes` run as `guarden`; `hose` has its own user because it is network-facing. No
  guarden program runs a long-lived daemon as root, and guarden has no daemon of its own —
  `snapperd` is a root daemon the design depends on and does not claim otherwise. The image
  build is a mutator verb, `weedr service build <name>`, which takes no `--from`: an unprivileged `furrow`
  cannot become the service user, and the subuid range belongs to the service user and only it
  may map container-root into it. `furrow` never touches podman.
- Everything deployed is a **service**: one user, one home, one unit directory, declared state.
  A database is a service. The edge is a service. There is no second class.
- The name carries the environment: `<workload>-<track-name>`. The last `-`-separated segment is
  the environment. The environment set is the root-owned `[[environments]]` table in
  `guarden.toml` and those three rows ship as defaults, not a list in the code, so `preprod` is a
  configuration change. A row is a **track**, and it carries its own host prefix, gate, weight,
  retention defaults and `slot`/`instance` kind. There is no `--env` flag, and `weedr service
  add` with no environment defaults to **staging**, never a gated track.
- Previews are **instances**, not services: one service per workload, one directory per ref
  under its home, refs taken raw and escaped internally so they cannot collide, capped by the
  instance track's `cap` — which is counted per service, never per project, because two
  repositories may declare the same project name. `weedr service remove <name>/<ref>` removes
  one instance — the verb the cap's eviction and `furrow preview drop` both call — and
  `weedr service remove <name>` is refused while any instance exists, naming them.
  `weedr service purge <name>` — a separate verb, not a flag — is refused for an instance,
  because an instance's volumes are the service's.
- Lineage is derived from the track's `fork_from` field and cannot be set by a repository or by
  `overrides.toml`: production starts empty, staging forks from production, a preview forks from
  staging. The automatic fork is a step inside `weedr service ingest` with no argument, and
  `weedr service fork --from` — the override — is **root only and off the guarden rule**, so a
  poke can never fork a production service from staging. An operator who wants that does it by
  hand, deliberately and in the call log.
- **A poke may create a service in a gated track, including production, and that is forced rather
  than chosen.** With no git clone and no `add --from <service>` reachable from CI, the staged
  tree a poke carries is the only way code reaches a workload that does not exist yet. What stands
  between a push and a running production container is the gate, not the creation.
- Connectivity is one loopback namespace. A declared edge produces an `AddHost=` entry in the
  consumer's own units, a uid-matched firewall rule and a per-consumer credential. There is no
  shared podman network, no name map, and no per-group address space.
- **A host user's group membership is not a container's.** A rootless container's group numbers are
  translated through `/etc/subgid`, so container group `981` means host group `232053`, and no
  `--group-add <gid>` reaches a host group that sits below the window — the number to name does not
  exist. The edge reads `/var/lib/guarden/edge/dynamic/`, which is `guarden:edge 2750` and stays
  that way, so **the edge's own unit carries `GroupAdd=keep-groups` and it is the only unit that
  does** (ADR-0017). The blanket form stays refused: a service holding `[groups] add` grants would
  carry every one of them into its container, and a second service that needs to read a directory
  it does not own needs its own decision rather than this one.
- **The loopback is closed to service uids by default, and the publications are the only way in.**
  The rendered `OUTPUT` set is a default deny on `-o lo -d 127.0.0.0/8` for every service uid,
  with the per-publication accept rules above it. Pasta maps the gateway, so otherwise any
  container reaches any host loopback port, `sshd` on 22 included. The deny does not touch
  outbound traffic, and pasta's DNS forward is explicitly excluded from the loopback mapping, so
  the old justification — that a blanket drop "would break name resolution and package updates" —
  was false and is gone. There is no `[loopback] allow` table: a table whose whole content is a
  destination is a second way to grant one beside the publication set. What this does *not* stop
  is a service *binding* a port of its own choosing, and what it no longer forbids is an admin
  granting a rule that matches `-o lo` (ADR-0013, spec §7.7) — a granted rule renders above the
  deny, so it is reachable, and making that daemon a service stays the better answer.
- Ports are **requested** by a manifest and **granted** by the admin in a root-owned
  `overrides.toml`. Every grant is public ingress and every one is address translation to the
  service's loopback publication: no service ever binds a non-loopback address, and there is no
  private-versus-public bind. A poke never grants. The firewall is re-rendered whole, and the diff
  is printed.
- **A service may ask for a firewall rule of its own, and only an admin may install one.** Most
  traffic goes through the edge, so most manifests never mention a firewall; the ones that cannot
  be reached through it — a WireGuard endpoint, a full node's peer port — put the rules they want
  in a `firewall:` block, and it installs nothing until `weedr firewall open <service> <name>`.
  Same shape as a port grant for the same reason: repository input naming something the host
  owns. Four rules make it safe, and all four are load-bearing: the **grant** is a root verb on no
  sudoers rule, so no deploy path reaches it; a **request is additive only**, so it cannot flush a
  chain, set a policy, reorder guarden's rules or name a chain guarden does not render; the
  **position** is guarden's, so a grant always lands above the default deny and the deny stays
  last; and the rule is **deduplicated by content while the count is by name**, so two services
  asking for one line get one rule carrying both names and closing one leaves it while the other
  still asks. `weedr firewall list` is the deduplicated inventory with the services behind each
  rule, and it is the command for "which service opened this". A granted rule is root firewall
  authority and is priced like one: the admin agrees to a line, not to a service's intentions.
- **The kernel owns the public ports.** `soil sysctl` sets
  `net.ipv4.conf.<ingress-if>.route_localnet=1` on the ingress interface and nowhere else.
  `soil firewall`   writes `10-framework.conf` and `20-ingress-nat.conf` — the edge's three
  forwarding rules, from the enabled modules' declared ingress — and the mutator writes
  `50-services.conf`: the whole uid-matched filter set, any service's own granted forwarding and
  any service's own granted firewall rules.
  The two files are disjoint and each has exactly one writer. `443/udp` is a different protocol
  from `443/tcp`, so the edge's ingress is three rules, not two. No unprivileged process binds
  anything below 1024 and no program gains a capability. `REDIRECT` does not work here: it
  rewrites the destination to the incoming interface's own address, and the edge listens only on
  loopback. **ferm is the only firewall. ufw is not installed.** guarden runs **ferm** and nothing
  else. `ufw` is **uninstalled** by installation and is **not** in any package list, on any family,
  for any reason. If a change, a suite or a golden image appears to need `ufw` present, the change
  is wrong — fix the change. No `ufw` rule is ever written, read or reconciled on a guarden host,
  and the structural guarantee replaces the dead-man failsafe: SSH access is guaranteed by
  `00-ssh.conf` (root:root 0600, seed-once), its accept is the first rule of its own `guarden-ssh`
  chain, and `INPUT`'s first rule after conntrack and lo is `jump guarden-ssh;`. `soil firewall
  --apply` refuses (exit 1) unless all of these hold. Every service's rules come from the same
  ferm render, whether a module installed it, a poke deployed it or an operator typed the command.
- **A forwarded port is a `PREROUTING` DNAT and nothing else. There is no masquerade.** An
  earlier revision of these documents required a `nat POSTROUTING` masquerade per forwarded port
  and claimed that without it the forwarding set "delivers exactly nothing while everything on the
  box looks healthy". That was false and the requirement is gone. After the DNAT the destination is
  a local address, so the packet goes to `INPUT` and never reaches `POSTROUTING`; on the reply
  conntrack unwinds the translation and rewrites the source to the public address the client
  dialled. A rule `-o <if> -d 127.0.0.1 --dport <pub> -j MASQUERADE` matches no packet in either
  direction. The only requirement is `route_localnet` on the ingress interface. The golden-VM
  criterion "a forwarded port answers from off the box" is still right, for a different reason: a
  request the box makes to itself never traverses `PREROUTING`, so only a second machine can tell
  a working forward from none.
- Persistent data is declared in one of two lists: `state`, which is snapshotted, and `bulk`,
  which never is. A bulk volume **is** a btrfs subvolume with no snapper configuration, is never
  a fork or rollback source, is never cloned from a live volume, and is **an empty subvolume**
  after a fork. It is a subvolume on every path, the fork included; it is never a plain
  directory. It still gets a `.volume` unit so a container can mount it. A mounted named volume
  in neither list is refused. A service's **home** is not snapshotted and carries no snapper configuration: it holds the image
  store, the per-user podman secret database and build staging. Every declared `state` volume is
  a subvolume with a snapper configuration of its own, a service may declare as many as it needs,
  and one snapshot covers all of them. btrfs has no atomic multi-subvolume snapshot primitive,
  so the volumes in one snapshot are each consistent and may be microseconds apart. A fork or
  a rollback addresses the whole set, and changes nothing if one volume's number is missing.
  `soil storage` owns a fixed set of values on every configuration it finds — the state
  volumes' as much as the host's — and rewrites nothing else in them.
- Resource **weights** are a default baked into generated units from the root-owned environment
  table. Caps are the operator's, in a root-owned drop-in. Neither comes from a manifest.
- `overrides.toml`, root-owned, is the whole of the admin's grant surface: `[ports] open`,
  `[firewall] allow` — the names of requested firewall rules the admin agreed to install, never
  rule text — `[retention] keep_last` and `free_limit`, `[groups] add` — supplementary groups
  for the service user, which is how a hardware-transcoding service reaches `/dev/dri` — and
  `[mounts] allow`, the only host paths outside the service's own volumes and `/etc/guarden` its
  units may bind-mount. The renderer refuses every other one, and an entry there is a grant in
  the same sense a port is.
- `loom` refuses `PodmanArgs=`, `--privileged`, `cap_add`, `cap_drop`, `devices`,
  `network_mode: host`, `pid: host`, `userns_mode`, `network_mode: container:`, and any host-path
  bind outside the service's own volumes, `/etc/guarden` and `mounts.allow`. A repository cannot
  bind a host socket, another service's home, or anything else on the machine. These refusals are
  guardrails against accidents; the isolation boundary is the per-service uid and the `0700` on
  its tree.
- There is no name map and no `/etc/hosts`. For each edge the renderer writes
  `AddHost=<provider>:<ingress.alias>` into every unit of the consumer, and a route target is
  `<name>:<publication>`. The names are service names, with no suffix and no alias. The alias is
  a normative key in the `[ingress]` table of `guarden.toml`: empty until ticket 15 measures it,
  written by `soil install` from the probe it runs, and the edge does not start without it. There
  is therefore no `hosts` lock, because nothing writes a name map.
- **The alias is the container's default gateway, and every host-side rule matches `127.0.0.1`
  instead.** Pasta maps the gateway onto the host's loopback in userspace — "on the host such
  packets will appear to have both source and destination of `127.0.0.1`" — before the kernel's
  packet path, so a rule matching the alias matches nothing. The alias appears in `AddHost=` and
  nowhere else. It is derived from the host's default route, not chosen by guarden, so it drifts;
  `soil sysctl --check` reports when the recorded value no longer matches the route. The
  `[network] pasta_options` table is what the renderer writes as `Network=pasta:`, and an option
  that removes the host mapping is refused, because a container that cannot reach the host is a
  box where nothing reaches anything.
- The renderer converts Compose, unprivileged. The mutator never runs a converter, or any other
  program, over repository input.
- Every edge states its `auth`: `database`, `secret` or `none`. There is no default.
- Credentials are systemd-encrypted blobs, materialised into per-user podman secrets. The
  encryption key is stated once: `systemd-creds --with-key=host` for a host key at
  `/var/lib/systemd/credential.secret`, or `--with-key=tpm2` to bind it to the machine's TPM.
  `auto` is not used, because its meaning varies with the hardware — it prefers a TPM2 key when
  it finds one, so a box with a TPM would silently encrypt with a different key than the
  documents describe. Decryption happens once, root-side, in the credential materialiser unit.
  A key the manifest's schema marks `@required` or `@sensitive` gets a **credential request** from
  the renderer — `Secret=<KEY>,type=file` in the `[Container]` table and nothing else — and podman
  resolves it from that service's own secret store and presents it at `/run/secrets/<KEY>`;
  `type=env` is generated only when the application needs a variable. **The generated unit
  carries no `LoadCredentialEncrypted=`,** because it runs in the *service user's* user manager,
  which cannot read a `0600 root` system host key and has no business holding it. The renderer
  never emits a value, because it has none. The gate on a gated track runs before the old
  container stops, and so does the build. **A blocked gate is a state, not a failure**: the
  deploy exits `0`, the service is installed and waiting, `[gate] reason` in the registry says
  why, and `weedr service start` re-checks and starts once the operator has planted the
  credentials. Do not disable the unit instead — see the runbook.
- Every mutation that renders a shared file holds one lock across render, diff and install, or
  a stale render can install last and drop what the previous mutation granted. `guarden.toml` has
  three writers, not one — `weedr module add` appends to `[modules] enabled`, and `soil install`
  writes the measured `ingress.alias` and seeds `[modules] enabled` from cloud-init — and two of
  them share a key, so every one takes the `modules` lock, goes through the write protocol, and
  re-reads the file under the lock rather than trusting what it saw before it. Queue state is durable under `/var/lib/guarden/queue`;
  only the locks are tmpfs, in `/run/guarden/locks`, and the lock directory is recreated at boot
  by a `tmpfiles.d` entry `soil install` writes.
- **Lanes bound builds; `deploy-<service>` bounds deploys.** `build.lanes` is how many container
  builds may be in flight, and the `queue` lock covers enqueue and dequeue. One deploy of one
  service holds `deploy-<service>` end to end, so two deploys of the same service cannot overlap
  while different services proceed in parallel. That is what delivers "a deploy racing another
  deploy leaves half-written units": the queue serialises builds, not deploys, so raising
  `build.lanes` retires build serialisation and never had deploy serialisation to retire.
- **One canonical statement per rule.** The masquerade, the loopback deny and the sudoers
  argument rule each appear in several documents because each was needed in several places, and
  duplication is why a refuted claim survives in a stale copy. A rule is stated once — in the
  spec — and every other document points at it. When you change a rule, grep for it.
- **No verb on the privileged surface carries a flag that widens authority.** A sudoers rule
  naming a command without an argument specification matches any arguments, and sudoers has no
  negation, so `--grant-ports` on a service-creating verb could never have been withheld — the grant
  already permitted it. The capabilities are therefore verbs: a grant is `weedr port open`,
  destruction is `weedr service purge`, and `weedr service rollback` is not on the rule at all —
  rolling a production database back is an operator's deliberate act, made as root, with no
  program between the decision and the subvolume operations.
  Every verb that is granted is granted whole. Write the long form in every call site, every
  unit and every sudoers rule: a rule naming `weedr service rm` would not match it.
- Snapshots are atomic per volume, taken while the service runs. A fork is a copy-on-write
  subvolume clone. Pins are **derived** from the service registries plus manual pin files — no
  holders, no refcounts, no ledger.
- **Two kinds of snapshot, tagged differently because they are governed differently.** A
  **routine** snapshot — what the nightly `--all` makes — is `timeline`-tagged and lives by the
  volume's **ladder** (`TIMELINE_LIMIT_*`, with `keep_last` as the daily bucket's maximum): a
  production volume with `keep_last = 7` keeps seven daily snapshots aged up into the weekly,
  monthly and quarterly buckets. An **on-demand** snapshot — a fork source, or an operator's
  "before the risky change" — is `number`-tagged, and the marks protect those. `weedr service
  snapshot` makes a routine one and never marks it; a fork takes a `number`-tagged snapshot
  precisely so the mark can protect it. `keep_last` is a retention count, not a mark count, and
  it does not raise the floor of `NUMBER_LIMIT_IMPORTANT`.
- **Retention is snapper's.** guarden runs no delete loop. A root reconciler — `weedr pin sync`, a
  separate root action from `stakes` on purpose, because `stakes` runs unprivileged and writing
  snapper's metadata does not — reads the service registries and the pin files, recomputes the
  marks, and writes them as snapper `important` userdata with the `number` cleanup tag before
  snapper's own algorithms run. Both halves matter: `important` is read only by the `number`
  cleaner, and only a `number`-tagged snapshot is a candidate for it. It is idempotent, adds
  before it removes, and stops rather than clearing anything when its state is unreadable. A pin
  is a priority with a budget and not a promise: `NUMBER_LIMIT_IMPORTANT` is a range, the
  free-space pass uses the minimum, and under real disk pressure a marked snapshot can be reaped.
  The ladder's ranges are ranges for the same reason, so no retention promise here is absolute.
- **Two host invariants: one is detected, one is enforced.** `soil sysctl --check` and
  `weedr service list` report if IPv6 has been re-enabled, because guarden disables it and an
  operator can undo that, and all guarden can do is notice. For the port threshold they check
  against the **value `1024`**, not "the distribution's default" — an image that ships `0`
  satisfies the latter and breaks the former — and `soil sysctl` **sets** it. Lowering it grants
  every unprivileged uid a privileged port and is refused; raising it to the kernel default is
  a tightening and is what makes the claim a fact rather than a convention.
- **One lock, because snapper's own will not do.** `soil storage` disables the distribution's
  packaged snapper cleanup timer and installs its own oneshot, and both it and the reconciler take
  `/run/guarden/locks/snapshots.lock`. snapper takes no lock that `snapper modify` participates
  in, and its cleaner reuses one reference to the snapshot list across all three passes, so a mark
  written during a running cleanup is silently lost with no error anywhere. `snapper list` holds
  the configuration lock for its whole duration, so a reconciler that lists in a loop can stall
  cleanup.
- **Snapshot state is read with `snapper --machine-readable json --config <config> list`** — the
  option is a **global** one and goes before the command, the document is an object keyed by the
  configuration's name, and its `number 0` entry is the live subvolume and not a snapshot (spec
  §8.2 carries all three). JSON renders `userdata` as an object and `important` is therefore a
  key; CSV renders the whole map as one comma-joined quoted field. The effective configuration is
  read with `snapper get-config`, never by parsing `/etc/snapper/configs/<name>`. Writes never
  pass `--no-dbus`: with no daemon there is no inter-process coordination at all.
- **`chattr +i` on a snapshot's subvolume is an escalation, not a default.** It is a deny, not a
  keep-N, and it is one per-snapshot operator decision: the cleaner deletes candidates in a loop
  with no per-item error handling, so the first candidate it cannot delete aborts that
  configuration's entire cleanup for that run, and the configuration stops auto-pruning while that
  snapshot is a candidate. Recorded, opt-in, reversible with `chattr -i`.
- **No boot waves and no fixed delay, and the ordering lives in the system manager.** A unit in
  one service's user manager cannot require a unit in another's, so a consumer's container units
  carry only an `After=guarden-order.target` drop-in and the real edges live in a root-owned
  `<name>.target` per service, with `loom` emitting the edges and the mutator installing them.
  The edges are `Wants=`, not `Requires=`: a down provider must not stop its consumers (spec
  §6.10, ADR-0011).
- Modules are configuration, not plugins. They never write each other's files. `weedr module add
  gate` creates the `edge` group and adds the edge's user to it; `soil install` creates the
  `guarden` group and no other, and never an `edge`. The `guarden` group is load-bearing rather
  than tidiness: the registry, every `overrides.toml` and all of `/etc/guarden` are
  `root:guarden`, and the unprivileged programs read them through it.
- No secrets in git and none in CI. No drift correction; an empty commit is the nudge.
- The file and command-line surface is the API. The language is an implementation detail.

## Ingress

The edge does not bind 80 and 443, and neither does anything else. The kernel holds the public
ports and forwards them to the edge's published loopback ports. The edge is an ordinary
unprivileged service like any other, distinguished only by which ports are forwarded to it:
`soil sysctl` holds `net.ipv4.ip_unprivileged_port_start` at `1024`, and no capability is
granted anywhere. There is no exception left in the system to argue about.

The edge's own ingress is three ports and no more: 80 and 443 for a browser, plus `443/udp` for
HTTP/3, which the edge serves from the same TLS entrypoint. That is three forwarding rules, not
two — a forwarded udp port is a different protocol and a different nat rule — and `soil firewall`
writes them into `20-ingress-nat.conf` from the enabled modules' declared ingress. HTTP/3 is
additive: a client that cannot use it loses nothing and nothing else in the design depends on
it. The numbers behind ordinary services — 8096, 32400, 5001, 20000 and the rest — are
publications the edge dials on loopback, which is a different mechanism and needs no forwarding
rule. A service's own granted port is forwarded too, by the mutator into `50-services.conf`, and
never bound.

Two properties follow from the mechanism and are worth stating because they look like bugs:

- Locally generated traffic does not traverse PREROUTING, so a health check, a smoke test and
  the structural verification address `127.0.0.1:<publication>` and not the public host name. This is also
  why an on-box check cannot tell you that forwarding works: both a correct and a broken forward
  pass it.
- There is no hairpin NAT, so a machine on the same local network cannot reach the box by its
  public name.

And one that is not a bug at all: the service behind a forwarded port sees the **client's real
address**, not `127.0.0.1`, because `PREROUTING` DNAT rewrites the destination only.

## Test seam

**One harness, and it is a real machine: `just test` cuts a throwaway LXD VM from a golden
snapshot and runs every suite in it with the real tools.** There is no fast tier, no fake, and no
call log (ADR-0014). `tests/lxc.sh run <pattern>` is the same thing for one file, and that is how
you run the suite while you work on it.

**Each suite says in its own file whether it needs a machine of its own** — one line,
`# machine: shared` or `# machine: fresh`, and **an absent line means `fresh`**. The declaration
lives in the suite rather than in a list in `lxc.sh` so it travels with the suite, and the default
is the safe answer because a suite that says nothing must never silently inherit another suite's
system users, deleted snapshots or installed packages. `just test-fresh` cuts per file whatever
any suite says and `just test-shared` cuts one machine for the run, so either flag wins over a
declaration; `just test-reverse` runs the same suites in the opposite order, and both orders being
green is the only honest proof that a shared suite does not contaminate the next. **`GUARDEN_PREFIX`
is not what decides it** — it relocates guarden's own files and not `apt`, `systemctl`, `useradd`
or `btrfs`, so what decides it is which verbs a suite drives.

**A suite whose golden and tree are unchanged is inherited, and says so.** Its line is
`inherit <suite> (green from the cache; not observed this run)` — never something that could be
read as a pass — and the run's summary states how many ran and how many were inherited. **Only an
observed pass is recorded**, so a failing suite is re-run rather than inherited, and the three
non-determinisms this repository has paid for would otherwise be cached forever instead of fixed.
The key is the golden's identity (a rebuilt golden invalidates everything), the suite's read set,
and the machine it ran on: which shared group, and which order. **Nothing expires**, because an
expiry would make a run's meaning depend on a clock. `--no-cache` / `just test-gate` runs every
suite and inherits nothing, and is what a release gate uses; `just test-cache-clear` throws the
results away. The cache is outside the repository and disposable.

**`fixtures/` is retired. No fake is added, and `fixtures/bin` is never on `PATH`** — not in a
test, not in a VM run, not in a shell. It existed until 2026-10-01, and it was worse than a
second opinion: `tests/lib.sh` put it first on `PATH` unconditionally and the LXD runner never
removed it, so the "real machine" tier was executing against the fakes in 29 of 34 suites. A
fake that shadows a real tool is a tool that lies, and this repository has already paid for that
twice — once with `git` returning empty success, and once with a `runuser` fake one careless line
away from exec'ing the machine's real `podman`. If you find yourself wanting a fake, the answer
is to assert the **state** the call would have produced: the unit exists, the mark is on the
snapshot, the rule is in the file, the package was not installed. One command per shell
invocation. No `&&`, no `|`, no `;`.

Rules that hold for every test:

- **The VM is the only place anything is executed.** Never run a guarden program, a test script,
  or anything you have written on the machine you are sitting at. No `python3 -m guarden.*` off
  the VM, no `tests/*.sh` off the VM, no staged `/tmp` host, no `bash -n` on a suite to "check" it.
  Reading code, `git diff` and reasoning are how you work; running is how you verify, and
  verification happens in a throwaway machine. A development checkout is not a target: the
  programs are root-only, the host layout is the host's, and the one thing a local run proves is
  that something works somewhere nobody will deploy it.
- **Never download anything to the development machine.** No release archive, no binary, no
  `curl`/`wget` of anything outside a distribution repository, nothing in `/tmp` and nothing in
  your home. A fetch is a **phase**, phases run on a machine, and the machine is the VM. The
  golden VM has a network precisely so that the fetch can be exercised where it is supposed to
  run. This has already been got wrong on this branch: an agent downloaded the pinned podlet
  release, extracted it and executed it on the developer's machine, and left eleven megabytes of
  ELF and a dozen hand-built archives behind. All of it was unnecessary and all of it had to be
  deleted by hand.
- **Never add a fixture, and never add a stand-in for a system tool, unless a ticket or the
  operator asks for that specific file by name.** `fixtures/` holds `guarden*.toml`
  configuration inputs and `fixtures/projects/*` manifests, and that is the whole of it.
  `fixtures/bin/` and `fixtures/lib/` were deleted deliberately and stay deleted. A stand-in for
  `podman`, for `snapper`, for `btrfs`, for a converter, for a payload — one per system binary is
  madness, and it is the shape this repository has already paid for twice. If a test seems to
  need one, it needs to use the real tool in the VM; if it needs a payload, it builds one inside
  the VM from a file the machine already has. Helpers that *read or build machine state* are not
  fixtures and belong in `tests/` — `tests/pinarchive.py` is one, and is the right shape.
- **One VM at a time, and do not throw the golden away.** The runner uses a single fixed instance
  name, so two agents cannot share it — give the VM to one worker at a time. `just provision`,
  `just deprovision`, `just golden-vm` and `just destroy` rebuild or discard a machine that took
  an hour to build; do not run them to work around a problem. If a run wedges, report it with the
  guest's process state rather than hand-driving `lxc`.
- External behaviour only. No test imports a program's internals. The single exception is the
  manifest and registry parsers, tested directly, because their failures are invisible from
  outside.
- One command per shell invocation. No `&&`, `|`, or `;`.
- New tests are new files under `tests/`. Do not restructure `tests/lib.sh`; append to it only
  when a helper is genuinely shared. `tests/run.sh` is the retired fake tier and goes with
  ticket 35 — do not add to it and do not restore it.
- A failing test first, then the fix. Several red-green cycles, not one big bang.
- **A suite that passes in the VM is evidence about a machine.** Isolation, name resolution,
  clone recovery, an `iptables-save` that shows the rule you rendered — none of them is claimed
  on the strength of a stand-in, because there are no stand-ins left.

## Conventions

- Bash for invoking things and sequencing them. Anything with branches that matters is python,
  in its own file, never a heredoc inside a shell script.
- Runtime dependencies are **distribution packages** installed by `soil`: `python3-yaml`,
  `python3-jinja2`, and the ones `packages/packages.toml` lists per family — including `ferm`,
  which is the firewall guarden runs. **`ufw` is not among them and must never be added**: it is
  uninstalled, and the structural guarantee replaces the dead-man failsafe. No `pip install` at deploy
  time, no wheels
  checked in. A fetch from outside a distribution repository is deliberate and rare: each is a
  **pinned artefact** whose version and two SHA256s are recorded in this repository and verified
  on install — `podlet`, and (ADR-0015) the tunnel's `cloudflared`. No vendor repository, ever:
  a repository's contents move under the pin. This keeps the host installable on a distro we have
  not tried yet.
- `jinja2` renders units. YAML is parsed with `pyyaml` using `safe_load` only, because a
  developer-facing manifest should not have to be TOML, and every YAML file we read is one a human
  wrote in a repository. Guarden's own configuration is TOML, read with the standard library,
  because nothing depends on a parser to read it.
- **`loom` drives the pinned `podlet` for Compose translation, and treats its output as untrusted
  input.** podlet owns the fields guarden has no opinion about; `loom` overwrites or removes every
  field it does — the refusal list, the whole `PublishPort` set, `Network=pasta:`, `AddHost=`, the
  credential requests, the `.volume` units, the start-order edges. Running a converter is not
  trusting its output. It runs unprivileged, which is what satisfies ADR-0012: that rule is about
  who runs the converter, not about whether the renderer writes it itself.
- **The programs are Python console scripts, with no shell entry point.** Each is
  `soil = "guarden.soil:main"` and so on, so `just lint` runs `ruff` and not `shellcheck` —
  `shellcheck` on eight one-line wrappers would be checking the wrong language, and eight wrappers
  that must agree with the spec is exactly the drift this repository keeps fighting. Bash remains
  for scripts that only invoke and sequence.
- Every shared file is written with the protocol in spec §3.5: lock, temporary file in the same
  directory, fsync, rename. Readers take no lock. The pin store is deliberately lock-free by
  construction; do not give it a shared aggregate file.
- Diagnostics are one line, prefixed `warning:` or `error:`, and name the thing they are about.
  Exit `0` is done or already true, `1` is the host not being in the assumed state, and `2` is a
  rejected input. The dividing line is input against host: a manifest and a unit source are
  input, the filesystem and the installed services are the host.
- **There is exactly one verb alias in guarden, and it is `rm` for `remove`.** It is not derived
  from the long form, it is the only one there is, and no other verb will grow one. Every
  program's `--help` lists the alias beside the long form.
- No code comments unless a decision needs recording. If you need a comment, write the ADR.
- Logs go to the journal. The last external tool each program invoked is logged, so the exact
  commands that produced the current state can be read rather than reconstructed.

## Tickets

`docs/tickets/` is the work list, numbered in tens so a reorder can slot in without
renumbering. Each ticket names its blockers; a ticket with no blockers is on the frontier.

When implementing a ticket:

1. Read `CONTEXT.md`, the spec, and every ticket.
2. Implement only the assigned ticket. Do not fix adjacent bugs in the same change.
3. Finish with `just test` green, then commit the work and say what the commit is.

## What not to do

- Do not add a web UI. Do not add a shared podman network.
- **Do not add a fake.** Not a stand-in for a system tool, not a shim, not a fixture directory,
  and not a "harmless" call log. `fixtures/` is configuration inputs and manifests; the harness
  is a real machine; a suite that cannot say what it wants from a real tool has a design problem,
  not a missing fixture. This has already been got wrong three times on this branch.
- **Do not run guarden's programs or tests on the development machine, and do not download
  anything onto it.** Both belong in the throwaway VM, and both are in "Test seam" above for a
  reason that cost real cleanup time.
- **Do not add a second firewall manager, do not write a `ufw` rule — or read or reconcile
  one — anywhere, and do not put `ufw` back in any package list.** The host firewall is `ferm`
  and `ufw` is **uninstalled**. Do not
  give a service its own firewall tool, and do not put a grant's rule text in a root-owned file
  the repository can influence: `[firewall] allow` holds names, and the rule behind a name lives
  in the manifest that asked for it.
- Do not render a requested firewall rule after the default deny, and do not give a manifest a
  position field. The deny is last, always; a grant lands above it because position is guarden's.
- Do not let a manifest state a build priority, a snapshot priority, a data source, a resource
  cap or weight, a lineage, or a key that *records* a grant. A `ports:` or `firewall:` list is a
  request and is legitimate. Resource *weights* come from the root-owned environment table, never
  the manifest.
- Do not bind a non-loopback address in anything, and do not bring back a `private`/`public`
  grant distinction. Every grant is a translation to a publication.
- Do not render a forwarded port with a `nat POSTROUTING` masquerade. A DNAT to `127.0.0.1`
  alone delivers, and a masquerade rule that claims otherwise matches no packet in either
  direction. Do not render a firewall rule that matches `ingress.alias` either: pasta translates
  to loopback before the kernel sees the connection, so the destination is `127.0.0.1`.
- Do not put `LoadCredentialEncrypted=` in a service's generated unit. It runs in that service's
  user manager, which cannot read the system host key. Decrypt once, root-side, in the
  credential materialiser; the renderer names the secret.
- Do not let a manifest widen its own mounts: `[mounts] allow` is root-owned.
- Do not add a `.internal` suffix, a name map, or an `/etc/hosts` write. Names are service names.
- Do not write a root-owned file inside a service's home, and do not put a root-owned unit in a
  path systemd does not search. Admin units and drop-ins live in
  `/etc/containers/systemd/users/<uid>/`, which is podman's rootless search path and is
  uid-scoped; `/usr/lib/systemd/user/` is neither.
- Do not put a secret value in git, in a CI variable, or in a plaintext file on the box.
- Do not add a second database engine until there is a second database.
- Do not reintroduce a ledger where a projection will do.
- Do not rewrite the harness to make one test pass.
- Do not commit secrets, generated credential material, or VM evidence tarballs.
- **Commit freely, and merge into `develop` or a feature branch freely.** A commit is how a change
  reaches the golden VM — `tests/lxc.sh` pushes the checkout into a cut, so uncommitted work
  cannot be tested on a real machine. Merge a ticket branch into `develop` once its suite is
  green. **`main` is the operator's, and so is history**: never merge into `main`, never rebase,
  amend, force-push or otherwise rewrite what is already committed.
- Never merge a harness change whose claim needs the golden rebuilt, and never merge a suite
  asserting something the environment happens to satisfy — "green because the environment
  provides it" is the failure this repository keeps paying for.
