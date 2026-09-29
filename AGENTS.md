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
modules/  shipped module definitions: gate, homepage, auth (unimplemented)
tests/    the one test seam                               created by ticket 10
fixtures/ fake binaries, PATH-first                       created by ticket 10
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

`docs/adr/0001`–`0012` are binding. `docs/spec.md` is the contract, and where the code and the
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
- Lineage is derived from the track and cannot be set by a repository or by `overrides.toml`:
  production starts empty, staging forks from production, a preview forks from staging. Only
  `weedr service fork --from` overrides it.
- Connectivity is one loopback namespace. A declared edge produces an `AddHost=` entry in the
  consumer's own units, a uid-matched firewall rule and a per-consumer credential. There is no
  shared podman network, no name map, and no per-group address space.
- **The loopback is closed to service uids by default, and the publications are the only way in.**
  The rendered `OUTPUT` set is a default deny on `-o lo -d 127.0.0.0/8` for every service uid,
  with the per-publication accept rules above it. Pasta maps the gateway, so otherwise any
  container reaches any host loopback port, `sshd` on 22 included. The deny does not touch
  outbound traffic, and pasta's DNS forward is explicitly excluded from the loopback mapping, so
  the old justification — that a blanket drop "would break name resolution and package updates" —
  was false and is gone. There is no fifth grant table: a service that needs a host loopback
  port which is not a publication needs that daemon to be a service. What this does *not* stop
  is a service *binding* a port of its own choosing.
- Ports are **requested** by a manifest and **granted** by the admin in a root-owned
  `overrides.toml`. Every grant is public ingress and every one is address translation to the
  service's loopback publication: no service ever binds a non-loopback address, and there is no
  private-versus-public bind. A poke never grants. The firewall is re-rendered whole, and the diff
  is printed.
- **The kernel owns the public ports.** `soil sysctl` sets
  `net.ipv4.conf.<ingress-if>.route_localnet=1` on the ingress interface and nowhere else.
  `soil firewall` writes `10-framework.conf` and `20-ingress-nat.conf` — the edge's three
  forwarding rules, from the enabled modules' declared ingress — and the mutator writes
  `30-services.conf`: the whole uid-matched filter set plus any service's own granted forwarding.
  The two files are disjoint and each has exactly one writer. `443/udp` is a different protocol
  from `443/tcp`, so the edge's ingress is three rules, not two. No unprivileged process binds
  anything below 1024 and no program gains a capability. `REDIRECT` does not work here: it
  rewrites the destination to the incoming interface's own address, and the edge listens only on
  loopback.
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
  `[retention] keep_last` and `free_limit`, `[groups] add` — supplementary groups for the
  service user, which is how a hardware-transcoding service reaches `/dev/dri` — and
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
  destruction is `weedr service purge`, and `weedr service rollback` is not on the rule at all.
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
- **Snapshot state is read with `snapper list --machine-readable json`**, because JSON renders
  `userdata` as an object and `important` is therefore a key; CSV renders the whole map as one
  comma-joined quoted field. The effective configuration is read with `snapper get-config`, never
  by parsing `/etc/snapper/configs/<name>`. Writes never pass `--no-dbus`: with no daemon there is
  no inter-process coordination at all.
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
rule. A service's own granted port is forwarded too, by the mutator into `30-services.conf`, and
never bound.

Two properties follow from the mechanism and are worth stating because they look like bugs:

- Locally generated traffic does not traverse PREROUTING, so a health check, a smoke test and
  the lockout drill address `127.0.0.1:<publication>` and not the public host name. This is also
  why an on-box check cannot tell you that forwarding works: both a correct and a broken forward
  pass it.
- There is no hairpin NAT, so a machine on the same local network cannot reach the box by its
  public name.

And one that is not a bug at all: the service behind a forwarded port sees the **client's real
address**, not `127.0.0.1`, because `PREROUTING` DNAT rewrites the destination only.

## Test seam

One seam: the command line of every program. Two harnesses:

- **Fast (`just test`, seconds):** `fixtures/bin` is first on `PATH`. Fakes for `useradd`,
  `usermod`, `userdel`, `loginctl`, `podman`, `podlet`, `runuser`, `systemctl`, `snapper`,
  `btrfs`, `chattr`, `systemd-creds`, `ferm`, `iptables`, `ip`, `tar`, `sudo`, `git` and the
  distribution's package tools append to a shared call log. The `snapper` fake answers
  `list --machine-readable json` and `get-config`, and its `modify` records the userdata it was
  given. Tests assert exit code, diagnostic lines, files that appeared or vanished, and the call
  log.
- **Golden VM (minutes, manual):** a throwaway machine with real tools, proving what fakes
  cannot — that a rootless container reaches a dependency by the measured alias, that a
  non-member cannot open the port, that a forwarded port answers from off the box, that nothing
  unprivileged can bind below 1024, and that a clone of a live snapshot starts and recovers.

Rules that hold for every test:

- External behaviour only. No test imports a program's internals. The single exception is the
  manifest and registry parsers, tested directly, because their failures are invisible from
  outside.
- One command per shell invocation. No `&&`, `|`, or `;`.
- New tests are new files under `tests/`. Do not restructure `tests/run.sh` or `tests/lib.sh`;
  append to `lib.sh` only when a helper is genuinely shared.
- A failing test first, then the fix. Several red-green cycles, not one big bang.
- A green fast harness is evidence about the fast harness. The claims that matter — isolation,
  name resolution, clone recovery — are proven on the VM or they are not claimed.

## Conventions

- Bash for invoking things and sequencing them. Anything with branches that matters is python,
  in its own file, never a heredoc inside a shell script.
- Runtime dependencies are **distribution packages** installed by `soil`: `python3-yaml`,
  `python3-jinja2`. No `pip install` at deploy time, no wheels checked in. There is exactly one
  fetch from outside a distribution repository, and it is deliberate: the pinned `podlet`
  release, whose version and SHA256 are recorded in this repository and verified on install. It
  is the only third-party binary. This keeps the host installable on a distro we have not tried
  yet.
- `jinja2` renders units. YAML is parsed with `pyyaml` using `safe_load` only, because a
  developer-facing manifest should not have to be TOML, and every YAML file we read is one a human
  wrote in a repository. Guarden's own configuration is TOML, read with the standard library,
  because nothing depends on a parser to read it.
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
3. Finish with `just test` green. The reply is two lines: `DONE` and one paragraph.

## What not to do

- Do not add a web UI. Do not add a shared podman network.
- Do not let a manifest state a build priority, a snapshot priority, a data source, a resource
  cap or weight, a lineage, or a key that *records* a grant. A `ports:` list is a request and is
  legitimate. Resource *weights* come from the root-owned environment table, never the manifest.
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
- Do not commit unless the human asks. Leave the tree dirty and say what is done.
