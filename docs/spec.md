# guarden v1 — normative spec

Status: ready-for-agent. Branch: `develop`.

Companion documents: [`CONTEXT.md`](../CONTEXT.md) is the vocabulary and is not negotiable.
Decisions that were hard to reverse are in [`docs/adr/`](./adr/). Why the system is shaped
this way is in [`docs/PRD.md`](./PRD.md). The security model and its limits are in
[`SECURITY.md`](../SECURITY.md). [`docs/sysadmin.md`](./sysadmin.md) is the 3am runbook.

This file is the contract: verbs, exit codes, file formats, and algorithms. Where this file
and a program disagree, the program is wrong. Where two documents disagree, the order of
authority is this file, then an ADR, then a ticket.

Conformance language: **must**, **must not**, **may**. Anything not required here is
implementation detail and may change without a decision.

---

## 1. Interface

### 1.1 How programs talk

Programs exchange files under `/etc/guarden` and `/var/lib/guarden` and are driven from a
command line. No program opens a socket or an HTTP endpoint to another program. A program's
contract is its verbs, flags, exit codes, diagnostic lines, and the files it writes.
Everything else about it is private (ADR-0012).

### 1.2 Diagnostics and exit codes

| stream | content |
|---|---|
| stdout | results. On a verb with `--json`, one JSON object on one line and nothing else on stdout, so a caller may parse it without stripping prose |
| stderr | diagnostics, each line prefixed `warning:` or `error:` |
| exit `0` | the requested work happened, or the requested state is already true |
| exit `1` | the host is not in the state the request assumed |
| exit `2` | the input was rejected |

**The dividing line is input against host.** A manifest and a unit source are input; the
filesystem, the installed services and the remote are the host. So:

| situation | code |
|---|---|
| an unknown or malformed key, a name that breaks a rule, a port out of range, an ambiguous unit source, a `service:` where a `container:` belongs | `2` |
| a container named in `routes:`, `ports:` or `widgets:` that the unit source does not define | `2` — both are input |
| a volume named in `state:` or `bulk:` that the unit source does not mount, or a name in both | `2` — both are input |
| a `needs:` entry whose provider does not exist, or exists and does not offer the `as:` kind | `1` — the answer came from the host, read from the provider's registry |
| a requested port already held by another service | `1` |
| `weedr firewall open` for a rule the manifest did not request, or a `firewall:` entry outside the closed rule shape of §7.7 | `2` |
| a snapshot that is gone, or absent from one of the volumes a fork needs | `1` |
| `weedr service gate` on a gated track whose gate is blocked | `1`, naming the key. It changed nothing, so the code is the answer rather than a failure |
| `weedr service gate` on a track with `gated = false` | `0`, and it records `not-required` |
| `weedr service start` on a gated track whose gate is blocked | `1` — you asked to start it and it cannot |
| a deploy whose gate is blocked, the deploy itself | `0` — the service exists and is waiting (§6.6) |

Nothing else writes `2`. A diagnostic names the thing it is about: the service, the key, the
port, the file, the line. A deploy that succeeds with warnings exits `0`.

**A drift line carries the requirement and the fact, in that order.** An item describes the
state that holds once the phase has converged — `the ferm package is installed`, and also
`the SSH accept is first in its chain`, whose converged state is itself a negative — so
`error: drift: <that sentence>` reads as a claim about the present, and an operator cannot
tell from it whether the thing is fine or missing. The line is one line, prefixed, carries the
word `drift`, quotes the requirement whole and says the host does not meet it. The requirement
is the informative half and the clause is what makes it actionable; there is one producer of
the line and both `--check` and `--apply` go through it, so the two modes cannot differ.

`--json` is available on exactly these verbs, and on no other: `weedr service list`, `weedr
service status`, `weedr secret list`, `weedr port list`, `weedr firewall list`, `weedr module
list`, `weedr project list`, `weedr project keys`, `weedr share list`, `stakes list`, `stakes query`, `furrow queue
list`, `furrow status`. `--json` on a write verb, and `--json` on a verb not in this list, is
exit `2`.

**Each `--json` output has a named field set, and an unknown field is never emitted and never
read.** The fields below are the whole of each object's shape, so adding one to a program is a
change to this table and not a compatible addition.

| verb | top-level fields |
|---|---|
| `weedr service list` | `services` — one object per service, each with `name`, `workload`, `project`, `environment`, `uid`, `source`, `deployed_sha`, `publication`, `edges`, `ports`, `volumes`, `instances`, `gate`, `warnings`. The nested objects are specified too, because a top-level name whose contents are open is not a field set: `publication` is `{ container, port }` pairs plus `api`; `edges` is `{ service, port, as, auth, publications }` per declared edge; `ports` is `{ requested, granted, pending }`; `volumes` is `{ name, kind, config, snapshots: { total, marked, oldest, newest, limits }, removed }` per declared volume; `instances` is `{ ref, created, seed }` per instance; `gate` is the `[gate]` table verbatim — `{ state, reason?, checked? }` — or `null` when the gate has never been evaluated, and `null` is **not** the same as `state: "ready"`. This is the field the runbook's "blocked, never started, crashed" triage reads, so it is in the table rather than folded into a status string. And `warnings` is a list of one-line strings, **including the two host invariants and the two host-lock state reports**, because those are what §6.2 says this verb reports |
| `weedr service status` | one object: `name`, `ref` (null on a slot track), `unit_state`, `active_state`, `sub_state`, `publications`, `edges`, `snapshots`, `instances`, `gate`, `warnings` |
| `weedr secret list` | `secrets` — one object per key, each with `name`, `set` (bool), `source` (`planted` \| `generated`), `example` (bool). **Never a value** |
| `weedr port list` | `services` — one object per service, each with `name`, `requested`, `granted`, `pending` |
| `weedr firewall list` | `rules` — one object per **rule text after deduplication**, each with `rule`, `chain`, `file`, `granted` (bool), `requested_by` (a list of `{ service, name }`). One object per rule rather than one per service is the whole shape: deduplication is a property of the set (§7.7), and a per-service list would report the same line twice and imply two rules |
| `weedr module list` | `enabled`, `available` — each a list of module names |
| `weedr project list` | `projects` — one object per project, each with `name`, `repository`, `environments` |
| `weedr project keys` | `project`, `keys` — one object per key with `type`, `fingerprint`, `added` |
| `weedr share list` | `issuances` — one object per issuance with `id`, `service`, `ref` (null on a slot track), `hosts`, `email`, `state` (`live` \| `expired` \| `revoked`), `issued`, `deadline`, `revoked` (null unless revoked). The deadlines are **absolute**, and a state is derived from them and the clock rather than stored |
| `stakes list` | `pins` — one object per pin with `id`, `service`, `volume`, `number`, `note`, `marked` |
| `stakes query` | one object: `id`, `service`, `volume`, `number`, `note`, `marked` — **and nothing snapper holds.** See below |
| `furrow queue list` | `requests` — one object per request with `service`, `ref`, `sha`, `state`, `lane`, `weight`, `queued_at` |
| `furrow status` | `lanes`, `in_flight`, `deployed`, `queued` |

**`stakes query` reads the pin file and the registry, and nothing else.** An earlier version of
this table listed `tag`, `description`, `important` and `userdata` for it, which is the same
contradiction §6.8 states a third time: those fields come from snapper, a service's
configurations are `0700` to that service, and `stakes` runs as `guarden` and cannot read them.
`stakes` cannot report the age of a snapshot, whether it exists, or whether the reconciler's mark
survived the number cleaner, and the field set says so rather than implying otherwise.

`marked` is a statement about **what `weedr pin sync` will write**, not about the filesystem: a
pin is a priority with a budget and not a promise (§8.5), and under real disk pressure a marked
snapshot can be reaped. A caller wanting the truth about the filesystem asks root, and the
read that gets it — `snapper --machine-readable json --config <config> list`, which is §8.2's
read in full, where `userdata` renders as an object and `important` is therefore a key rather
than part of a comma-joined CSV string — is `weedr service status --json`'s `snapshots` field
(§6.2), which runs as root. §8.2 is about that read, not about `stakes`.

### 1.3 Verb aliases

Every `remove` subcommand has exactly one alias, `rm`. No other verb has an alias and no
other alias will be added. `--help` lists the alias beside the long form. **The verb lists in
§6 print the long form, because that is what the sudoers grants name and what guarden's own
programs call** — a sudoers rule naming `weedr service rm` would not match it.

### 1.4 There are no privileged ports and no capabilities

No unprivileged process on the host may bind a port below 1024, and no process is granted a
capability. The kernel forwards 80/tcp, 443/tcp and 443/udp to the edge's published loopback
ports (§7.5). The edge is an ordinary service distinguished only by which ports are forwarded
to it.

---

## 2. Host layout

```
/usr/lib/guarden/                      guarden's own files, root-owned, never written by a
                                       deploy
  bin/                                 soil weedr loom roots twig furrow hose stakes
  lib/                                 python packages: the manifest parser, the shared
                                       "what does this service declare" projection, the
                                       firewall renderer
  modules/<name>/module.toml           module definitions (§3.6)
  templates/                           unit and configuration templates
/usr/bin/                              symlinks to bin/, one per program
/etc/guarden/                          configuration, root-owned
  guarden.toml                         host configuration, including the environment table
  projects.toml                        project -> repository, ref -> allowed environments
  projects.d/<project>.toml            a per-project copy, which wins over the file above
  services/<name>/overrides.toml       admin grants: ports, firewall rules, retention, groups, mounts
  edge/auth-provider                   the auth-authelia module's marker, read by roots
  firewall/00-ssh.conf                 SSH accept: root:root 0600, seed-once, its own chain,
                                       first rule in INPUT after conntrack and lo. Written by soil.
  firewall/10-framework.conf           ferm skeleton, the interface's route_localnet. Written by soil.
                                       The policy baseline: no grant reaches this file and nothing in
                                       it is ever a service's
  firewall/20-ingress-nat.conf         the edge's three forwarding rules. Written by soil,
                                       and by nothing else -- a module change converges it by
                                       calling `soil firewall --apply`, not by writing it
  firewall/30-admin.conf               admin/module drop-in (optional). Written by soil.
  firewall/50-services.conf            the whole uid-matched filter set, any service's own
                                       forwarding rules, and any service's own granted firewall
                                       rules (§7.7). Written by the mutator.
  creds/<name>/<KEY>.cred              systemd-credential blobs, mode 0600
  allow-gated-drop                     present only if a poke may drop a service in a
                                       gated track
/etc/containers/systemd/users/<uid>/   podman's uid-scoped rootless quadlet path: the admin
                                       injection point for a service's own units and drop-ins.
                                       The mutator copies from `services/<name>/units.d/`.
/etc/ssh/authorized_keys.d/hose        the poke keys, one forced command per project
/etc/systemd/system/                   soil's units and the units of the unprivileged programs
/usr/lib/systemd/user/                 not used; it is not uid-scoped and is not a search path
/var/lib/guarden/                      state. One btrfs subvolume. NOT snapshotted.
  soil/                                the btrfs convert state and the reboot marker
  render/<service>[/<escaped-ref>]/     a `guarden`-writable staging directory `loom` renders
                                       into; the mutator copies from it and removes it
  services/<name>/home/                the service user's home: units, the rootless container
                                       image store, the per-user podman secret database
  services/<name>/home/<escaped-ref>/  one instance's unit directory, on an instance track
  services/<name>/state/<vol>/         a volume: a btrfs subvolume. A `state` volume has a
                                       snapper configuration named <service>-<vol>; a `bulk`
                                       volume has none
  services/<name>/bulk/<vol>/          the same for a `bulk` volume, split out so the `state/`
                                       tree contains nothing but snapshotted subvolumes
  services/<name>/instances/<escaped-ref>/       an instance's OWN tree, on an instance track.
                                       A sibling of `state/`, never a child of it — see below.
                                       Its `state/<vol>` has a snapper configuration named
                                       <service>-<escaped-ref>-<vol>; its `bulk/<vol>` none
  shared/<name>/                       root-owned installed renderings: routes.toml, widgets/,
                                       schema.toml. Read by roots and twig
  shared/dashboard/                    the merged widget output, written by twig. This is the
                                       one place `twig` may write (§6.5)
  registry/<name>.toml                 the service record
  stakes/<service>:<vol>@<num>         one file per pinned snapshot
  queue/<request>.json                 deploy requests
  staging/<project>/<sha>/             a poke's unpacked source
/var/lib/guarden/removed/<service>/<time>/<vol>/   volumes moved aside by a removal
/run/guarden/locks/                    one flock file per resource. tmpfs, gone on reboot.
/etc/snapper/configs/<service>-<vol>   written by soil, converged to a fixed value set
```

**An instance's volumes are a sibling of the service's, never a child of them.** An earlier
version of this layout put them at `services/<name>/state/<vol>/<escaped-ref>/`, and that is
wrong in a way that fails silently: **btrfs does not recurse into nested subvolumes when it
snapshots.** A subvolume nested inside another is excluded from its parent's snapshot entirely,
so `state/data/` would have snapshotted cleanly, nightly, forever, while containing **no
instance data at all** — and the only symptom would be an empty restore. Every instance volume
therefore lives under `instances/<escaped-ref>/`, with its own snapper configuration, and
`state/` and `bulk/` contain nothing but the service's own subvolumes and no subvolume has
children.

The same reason splits `state/` from `bulk/`: they differ in whether a snapper configuration
exists, and keeping a snapshotted tree and an unsnapshotted one in one directory is how the
above happened in the first place.

Nothing root-owned lives inside a service's home, and **admin units are not copied into
one**: they live in `/etc/guarden/services/<name>/units.d/` until the mutator installs them
into `/etc/containers/systemd/users/<uid>/`. Generated units live in the home's quadlet
directory and are rewritten on regeneration.

A service's home is **not** snapshotted and carries no snapper configuration. It holds the container image
store, the per-user podman secret database, and build staging — none of it precious, and the
secret database large and cleartext. Only declared state volumes are snapshotted.

There is no `/home` for services. `weedr service remove` deletes one directory under
`/var/lib/guarden/services/` and calls `userdel`; nothing else on the box is touched.

### 2.1 Modes

Every row below is a row an implementer must be able to point at. **A mode that denies a
program the access it is documented to need is a defect, not a tight default**, and the two that
did are fixed here: `queue/` and `stakes/` were `0750 root:guarden`, whose group bits are `r-x`,
so `furrow` could not enqueue a request and `stakes` could not create a pin file. A directory a
program writes into is `0770`; a directory it only reads is `0750`.

| path | mode | owner | who creates it |
|---|---|---|---|
| `/var/lib/guarden/` | `0751` | `root:guarden` | `soil storage` |
| `/var/lib/guarden/services/` | `0711` | `root:root` | `soil storage` |
| `/var/lib/guarden/services/<name>` and everything under it | `0700` | the service user | `weedr service add`. **One owner for the whole tree, including every instance's volumes** — a `kind = "instance"` track's instances are one trust domain (§5.2) and are not `0700` individually |
| `/var/lib/guarden/registry/` | `0750` | `root:guarden` | `soil storage` |
| `/var/lib/guarden/registry/<name>.toml` | `0640` | `root:guarden` | `weedr`, by the write protocol |
| `/var/lib/guarden/render/` | `0770` | `guarden:guarden` | `soil install` |
| `/var/lib/guarden/render/<service>[/<ref>]/` | `0700` | `guarden` | `loom` |
| `/var/lib/guarden/shared/` | `0751` | `root:guarden` | `soil storage`. The dashboard reads `shared/dashboard` through a bind mount whose source resolves through this directory, and its user is in neither group — the same traverse grant as the row above, for the same measured reason |
| `/var/lib/guarden/shared/<name>/` | `0750` | `root:guarden` | the mutator, installing the render |
| `/var/lib/guarden/shared/dashboard/` | `0755` | `guarden:guarden` | `weedr module add homepage`. **World-readable, and that is the point** — the dashboard is an ordinary service in neither group, and the design keeps two groups, so `2750 guarden:<reader-group>` is not available. The content is merged widget output: UI configuration, no secret, and it is the public face of the box anyway |
| `/var/lib/guarden/edge/dynamic/` | `2750` | `guarden:edge` | `weedr module add gate-traefik` — **not** `roots`, which cannot set a group it is not in |
| `/var/lib/guarden/stakes/` | `0770` | `root:guarden` | `soil storage` |
| `/var/lib/guarden/share/` | `0750` | `root:guarden` | `soil storage`. The issuance record: one file per issuance, and the rendered projection the reconciler copies to the vendor |
| `/var/lib/guarden/queue/` | `0770` | `root:guarden` | `soil storage` |
| `/var/lib/guarden/soil/` | `0750` | `root:guarden` | `soil storage` |
| `/var/lib/guarden/staging/` | `0755` | `root:root` | `soil storage`. **Nobody creates a subdirectory here at run time** |
| `/var/lib/guarden/staging/<project>/` | `0755` | the `hose` user | `weedr project grant`, and `weedr project revoke` removes it. Pre-created because `hose` is unprivileged and cannot `mkdir` under a `0755 root:root` parent |
| `/var/lib/guarden/staging/<project>/<sha>/` | `0755`, files `0644` | the `hose` user | `hose`, and **`hose` removes it** once the deploy returns |
| `/run/guarden/` | `0755` | `root:root` | `soil install`, via `tmpfiles.d` — it is tmpfs and must be recreated every boot |
| `/run/guarden/locks/` | `2770` | `root:guarden` | `soil install`, via `tmpfiles.d`, mode and owner from the row above; setgid so a lock file created by either caller is group `guarden`, and `conf.lock` states `0664` on it |
| `/etc/guarden/` | `0751` | `root:guarden` | `soil install`. **Stated in code, not inherited from the write protocol's `mkdir`** — that is `0777 & ~umask`, so an umask of `027` would silently produce the `0750` that locks `hose` and the service users out of the tree, the same defect `/var/lib/guarden` had |
| `/etc/guarden/services/`, `/etc/guarden/projects.d/` | `0755` | `root:root` | `soil install`. A service user reads its own configuration through the first and `hose` globs the second, and both are in neither group; a listing here is names, not secrets |
| `/etc/guarden/edge/`, `/etc/guarden/firewall/` | `0750` | `root:guarden` | `soil install`, stated in code. The firewall's seed states it too, softly, because its phase runs before the `guarden` group exists; the edge's writer because the write protocol's `mkdir` is umask-dependent — the install rows converge the owner afterwards |
| `/etc/guarden/**` (files) | `0640` | `root:guarden` | the write protocol |
| `/etc/guarden/projects.toml`, the files under `/etc/guarden/projects.d/`, `/etc/guarden/allow-gated-drop` | `0444` | `root:root` | |
| `/etc/guarden/creds/` | `0700` | `root` | |
| `/etc/ssh/authorized_keys.d/hose` | `0644` | `root` | |

`/run/guarden/locks/` is `2770 root:guarden` because `guarden` and root both take these locks
— `queue` and `deploy-*` are taken by `furrow` as the `guarden` user, and the remaining names
(`registry`, `firewall`, `snapshots`, `projects`, `overrides`, `modules`, `preview-cap`) by
root-only callers. The setgid bit makes a newly created lock file group `guarden` whatever the
caller, and `conf.lock` states `0664` on creation because `open`'s mode is filtered by the
caller's umask: without both, a root-created `deploy-<service>.lock` under the usual `022` is
`0644 root:root` and the next `furrow deploy` of that service cannot open it for append. It is not
`0777`: a world-writable lock directory is a way for any process on the box to hold the
firewall render or a service's deploy open indefinitely, and `0777` buys nothing that `2770`
does not. The directory is tmpfs, so the row is incomplete without saying it is recreated at
boot — `soil install` writes a `tmpfiles.d` entry and nothing depends on the directory surviving.

**`/var/lib/guarden/services/` is `0711` rather than `0750` deliberately**: every service tree
under it is `0700`, so listing the directory would leak every workload name on the host and
which tracks exist, while `0711` still lets a program traverse to a service it legitimately
owns. **That grant only works because `/var/lib/guarden/` above it is `0751`** — the same
traverse-but-not-list mode, one level up, for the same users: a service user, `hose` and the
edge are in neither group and must pass through the parent to reach their own trees, and at
`0750` the child's `x` bit is unreachable. Measured, 2026-10-12, on the first golden whose
`soil storage` had actually converged: at `0750` every service user was locked out of its own
home and volumes — the defect this row corrects. `stakes` cannot use the traversal to read
anything — a `0700` tree stops it — which is
the same reason the pin store is separate from the state volumes in the first place.

The `0700` on a service's tree is load-bearing. Without it any service user can read every
other service's state volumes directly from the host filesystem, which would make every
per-consumer credential and every uid-matched firewall rule decorative.

Three carve-outs from `0640 root:guarden`, each for a specific reader:

- `projects.toml` and the files under `projects.d/` are `0444` because `hose` — the
  network-facing program — must read the ref allowlist, and a project name, a repository URL
  and a ref pattern are not secret. `projects.d/` itself is the `0755` directory the table
  states, because a glob that cannot enter the directory silently skips every entry. Nothing
  else in `/etc/guarden` is readable by `hose`. In particular `hose` never
  reads `allow-gated-drop`: the refusal is enforced root-side, in `weedr service remove`.
- `stakes/` is `0770 root:guarden` because `stakes` runs as `guarden`, **creates and removes**
  the pin files itself, and reads them back. `weedr pin sync` is root and reads them.
- `queue/` is `0770 root:guarden` because `furrow` runs as `guarden` and enqueues, dequeues and
  updates an in-flight request by creating, renaming and removing files there.

### 2.2 Groups

There are two groups and no per-object groups.

| group | members | why |
|---|---|---|
| `guarden` | the `guarden` user, and `weedr`'s reading of the state it owns | the unprivileged programs share the state they may read |
| `edge` | the edge's service user | the edge reads the one directory `roots` writes |

`edge` is created by `weedr module add gate-traefik`, and the edge's user is added to it there, not by
`soil install` — a host with no edge module has no `edge` group.

---

## 3. Configuration

Two formats, one audience each, deliberately: **YAML for anything a human writes inside a
project repository**, **TOML for anything guarden owns**. The manifest is YAML because a
developer editing their own infrastructure is better served by the format they know and by one
that allows comments in the obvious place. Guarden's own configuration is TOML read with the
standard library, so nothing on the host's critical path depends on a parser.

### 3.1 `/etc/guarden/guarden.toml`

```toml
[host]
domain = "example.com"           # the only substitution available to a manifest
interface = ""                   # empty: resolve the ingress interface from the default route
admin_user = ""                  # empty: the invoking user at install time; the uid allowed to
                                 # reach the edge's API and the only uid with an interactive shell

[ingress]
alias = ""                  # the address a rootless container can reach the host on. Empty until
                             # ticket 15 measures it; `soil install` writes the measured value here
                             # from the probe it runs, and refuses to start the edge without it. Per
                             # §7.1 this is the gateway address pasta maps, and it is a NAME the
                             # consumer resolves -- never a firewall destination
publication_range = [20000, 32767]   # loopback ports guarden may allocate
forwarded = [ "80/tcp", "443/tcp", "443/udp" ]   # what soil forwards to the edge

[network]
backend = "pasta"           # the only value v1 supports; slirp4netns is refused, not degraded to
pasta_options = [ "--map-gw" ]   # the complete set guarden will run pasta with. `--map-gw` is what
                             # makes the host reachable at all and pasta's default, but it is
                             # written here because the whole connectivity model rests on it and a
                             # silent change must not be possible. `--no-map-gw` is refused

[build]
lanes = 1                        # concurrent builds; 1 is the default and the recommendation

[share]                          # the time-bounded grants that reach a tunnel route (ticket 220).
                                 # Root-owned, and no repository sets any of it.
max = "168h"                     # the longest a `weedr share issue --until` may be. Guarden's own
                                 # duration syntax: <number><unit> terms, units s m h d w. There
                                 # is no spelling of "never", and a grant above this is refused.
                                 # It is also the `session_duration` on every projected vendor
                                 # policy, converted to the vendor's Go syntax (7d -> 168h) — a
                                 # second, shorter bound under guarden's own deadline.
account = ""                     # the Cloudflare account id the reconciler projects onto
app = ""                         # the Access application id whose policies are the projection
token_name = "share"             # the API token's name, read from /etc/guarden/share.api-token,
                                 # 0600 root. The *value* is never in this file
scopes = [ "Access: Apps and Policies Write" ]   # what that token needs, recorded so an operator
                                 # can audit what a leaked one would reach

# [zram]                          # a compressed swap device. ABSENT by default, and
                                 # its absence is the default rather than a value:
                                 # with no [zram] table, `soil packages` installs no
                                 # generator, `soil install` writes no configuration
                                 # and creates no device, and `soil sysctl` says
                                 # nothing about swappiness. An operator may ask for
                                 # one on a box where swapping to disk thrashes, and
                                 # the right compression is a machine-to-machine
                                 # tradeoff guarden cannot make for them.
# [zram]
# algorithm = "zstd"               # zstd is the only algorithm offered; the level
#                                  # trades CPU for ratio and 22 on a busy host costs
#                                  # more than the memory it saves
# level = 6                        # zstd runs 1-22; guarden offers no named preset,
#                                  # because "high" is not a value
# size_percent = 50                # a percentage of this host's RAM, and never over
#                                  # 100: an absolute size is not portable and a
#                                  # percentage over 100 asks for a device larger than
#                                  # the memory backing it

[modules]
enabled = ["gate-traefik", "homepage"]

[[environments]]                # a track
name = "production"
host_prefix = ""                 # route host is myapp.$DOMAIN
gated = true                     # refuses to start on a missing or placeholder credential
weight = 1000                    # CPUWeight and IOWeight in generated units
free_limit = 0.10                # snapper FREE_LIMIT: the free-space floor (§8.1). Read as a
                             # number however it is written -- this row's TOML float or the
                             # quoted form the two rows below use; both spell ten-hundredths
                             # of a percent -- 0.1% -- and never the 10% a bare 10 invites
keep_last = 7                    # the daily bucket's maximum, NOT a total (§8.1)
kind = "slot"                    # one service per workload
fork_from = ""                   # the track this one forks from; empty starts empty (§8.3)

[[environments]]
name = "staging"
host_prefix = "staging."
gated = false
weight = 100
free_limit = "0.20"
keep_last = 0                     # daily bucket off; weekly/monthly/quarterly still apply
kind = "slot"
fork_from = "production"

[[environments]]
name = "preview"
host_prefix = "preview."
gated = false
weight = 10
free_limit = "0.20"
keep_last = 0
kind = "instance"                # one service per workload, one instance per ref, under cap
fork_from = "staging"
cap = 3                          # only meaningful on kind = "instance"
```

**The environment set is this table, not a code enum.** Adding `preprod` is appending a block;
it needs no code change, and nothing in guarden branches on a track's name. `weedr` reads this
file and **must not** rewrite it, with exactly one exception of its own: `weedr module add`
appends the module's
name to `[modules] enabled`, and rewrites nothing else in the file. That exception is why the
`modules` lock covers the write, and why the write protocol applies to this file like every
other.

A track's fields are `host_prefix` for route hosts, `gated` for the credential gate, `weight`
for resource priority, `free_limit` and `keep_last` as retention defaults, `fork_from` for
lineage (§8.3), `kind` to say
whether a track holds one service or one instance per ref, and `cap` for the instance cap.
A track with `kind = "slot"` **must not** carry `cap`, and a track with `kind = "instance"`
**must**; either mistake is exit `2` naming the track. `cap` appears nowhere else in this file
— there is no top-level `[preview]` table, because a second place to set it is a second place
for it to be wrong.

`fork_from` **must** name a track that exists in this same table, and must not name its own
track; either is exit `2` naming the track. An empty `fork_from` is a track that starts empty.
This is the one place a track refers to another track, and it is a field rather than a name guarden
recognises, so adding a track is appending a row and nothing else.

`admin_user` is a login name, resolved to a uid. It is the only uid besides the service uids
that the firewall names, and it is the uid allowed to reach the edge's API.

The `[network]` table is load-bearing rather than a preference, because it decides whether a
container can reach the host at all (§7.1). `loom` writes `Network=pasta:<pasta_options>` into
every generated unit, from this table and nowhere else, so a `pasta_options` entry in
`containers.conf` cannot reach a guarden container. An option that removes the host mapping —
`--no-map-gw`, or `--map-host-loopback none` — is exit `2` naming the key: a container with no
route to the host is not a degraded guarden, it is a box where nothing can reach anything.
`soil firewall --check` re-renders the option set and reports drift against the installed units
for the same reason `soil storage --check` reports retention drift.

### 3.2 `/etc/guarden/projects.toml` and `projects.d/<project>.toml`

```toml
[projects.myapp]
repository = "git@github.com:you/myapp.git"
environments = { "main" = ["production"], "develop" = ["staging"], "*" = ["preview"] }
```

`environments` is an **allowlist**: it says which environments a ref may deploy to, not which
one it gets. The first matching pattern wins and `*` matches any ref; a ref matching nothing
is refused with exit `1` and the reason named.

**A pattern with more than one track in its list is legal, so the poke names the one it wants.**
`environments = { "release/*" = ["staging", "production"] }` grants two environments to a
release branch, and `hose poke <ref> <sha> [<environment>]` carries the choice. The environment
is validated against that ref's allowed set and refused with exit `2` naming the set if it is not
in it; a ref whose matching pattern grants several and which names none is refused with the set
**`[zram]` is the one optional table, and it is absent on every host that has not been asked
for a compressed swap device.** Its absence is the default rather than a default value: `soil
packages` converges no zram package, `soil install` writes no configuration and creates no
device, and `soil sysctl` does not name `vm.swappiness`. The implementation is
`systemd-zram-generator`, the distribution's own, on the same argument as every other runtime
dependency — no pip, no wheels, no third-party fetch — and `zram-tools` is not used. `algorithm`
is `zstd` and only `zstd`; `level` is an integer in zstd's own range of 1–22 and guarden offers
no named preset, because "high" is not a value; `size_percent` is a percentage of this host's
RAM and never over 100, since an absolute size is not portable and a percentage over 100 asks
for a device larger than the memory backing it — a value the generator itself only warns about,
which is not good enough for something guarden is about to write.

**The device is read back from the kernel and never from the file guarden wrote**, on the same
rule as `ingress.alias` (§7.1): `/sys/block/zram0/comp_algorithm` brackets the algorithm in
force, `disksize` is the size, and `swapon` reports the priority. The **level is the exception
and the documents say so**: the driver declares `algorithm_params` write-only, so there is no
sysfs read-back for a level, and a check that claimed one would be checking the file. What
stands in for it is that the device exists at all, because a level the backend rejects fails
`disksize_store` and leaves nothing initialised. The expected size is computed the way
`systemd-zram-generator` computes it — `MemTotal` in MiB truncated, the percentage applied in
floating point, truncated again, then the driver page-aligns — because any other arithmetic is a
`--check` reporting drift forever against a device of exactly the right size.

**zram is swap, and that answers §8.** A zram device is RAM, so it does not move the free-space
floor `FREE_LIMIT` reads and the retention story is unaffected. It does change
`vm.swappiness`, which therefore joins §6.1's canonical sysctl set with the same "never from a
manifest" property — and only when the table is present, because absent means absent down to the
last sysctl.

**A converge that only ever creates cannot take down what it created**, so a marker under
`/var/lib/guarden/soil/` records that the device is guarden's. Removing the table and re-running
`--apply` swaps the device off, resets it, hot-removes it and deletes both files, which is the
converge-in-both-directions property `soil sysctl` has. **A `zram:` key in a manifest is refused
by name** in all three vocabularies a repository speaks — the manifest's own top level, a
Compose service's keys, and a hand-written quadlet file's `Sysctl=` line — because a repository
that could state a device would be a second place for it to be wrong.

printed. "First match wins" decides *which set applies*, and nothing inside the set is decided by
order — a rule that silently deployed the first track in a list would make a permission set
behave like an assignment, which is the confusion the allowlist exists to avoid.

This is a client-supplied argument and it is worth being explicit about why it is not the hole
`--project` was. The environment is a value from a closed set of track names the **operator**
wrote in a root-owned file, checked against the specific set that ref's pattern grants, before
it is used. It cannot name a project, a path, or anything outside that set, and the mutator
re-checks it — `furrow` proposing an environment the allowlist does not grant changes nothing.
A `--project` argument was a different animal entirely: it named a whole repository, and
`sshd` appends the client's own command, so it was never the operator's value to begin with. An entry in `projects.d/` overrides the same
project in the file above; `weedr project add` writes the `projects.d/` copy so a project can
be edited without touching the shared file.

### 3.3 `/etc/guarden/services/<name>/overrides.toml`

Created on first grant.

```toml
[ports]
open = [ "8080/tcp" ]            # public ports the admin grants this service. A grant
                                # is a translation to a publication (§7.5), so the
                                # registry must already name the container it goes to:
                                # a port the registry cannot resolve is refused, not
                                # half-rendered

[firewall]
allow = ["wireguard-peer"]       # requested `firewall:` rule names this service asked for and
                                # the admin agreed to install (§7.7). Names, never rule text:
                                # the rule lives in the manifest that asked for it, and the
                                # file an operator reviews stays readable. A name no manifest
                                # requested is refused, not installed

[retention]
keep_last = 7                    # the DAILY bucket's maximum; overrides the track's default
free_limit = 0.08                # a percentage of free space; overrides the track's default
weekly = 4                       # the ladder's other buckets, per-volume. `keep_last = 0` turns
monthly = 6                      # off the daily bucket only, and these still keep twelve
quarterly = 2                    # snapshots, so an operator who wants none sets them here

[groups]
add = ["video", "render"]        # supplementary groups for the service user

[mounts]
allow = ["/dev/dri"]             # host paths this service's units may bind-mount
```

`keep_last` and `free_limit` override the track's defaults. `groups.add` gives the service
user supplementary groups, which is how a hardware-transcoding service reaches `/dev/dri`
without the renderer having to know anything about video. `mounts.allow` is the only way a
host path outside the service's own volumes and `/etc/guarden` becomes bind-mountable: the
renderer refuses every other one, and an entry here is a grant in the same sense a port is.
`firewall.allow` is the same shape of grant in the same file and for the same reason: the
manifest asks, the admin decides, and the repository cannot widen it (§7.7).

Nothing else is overridable. Routes, edges, state volumes, the unit source and the credential
schema are the repository's, and this file does not touch them.

### 3.4 `/var/lib/guarden/registry/<name>.toml`

Written only by the mutator.

```toml
service      = "myapp-production"
workload     = "myapp"           # the part of the service name before the environment
project      = "myapp"           # the manifest's project, or the project its --from source
                                 # belongs to. Never a path basename: under the new layout the
                                 # staging directory's basename is a sha
environment  = "production"
uid          = 1004
created      = "2026-09-29T10:12:00Z"
source       = "manual"          # or "gitops"; recorded, and it changes nothing
installed_by = "gate-traefik"            # the module that created this service, or absent for a service
                                 # created by a poke or by hand. This is what makes step 1 of
                                 # `weedr module remove` answerable, and it is the reason modules
                                 # record provenance at all: without it "a service the module
                                 # installed is not the module's own" has nothing to consult
deployed_sha = "9f2c1ab"

[publication]
web = 20114                      # container name -> allocated loopback port
api = 20007                      # the edge's API publication, when it has one

[edges."postgres-production"]
port = 5432
as   = "db"
auth = "database"                # database | secret | none

[provides]
kinds = [ "db" ]                # what the manifest's provides: listed, and only that. Written by
                                # the mutator at creation from the manifest, and this is the ONLY
                                # copy a consumer can read: the provider's own tree is 0700 to
                                # the provider and loom runs as guarden. Absent for a service
                                # whose manifest declares none, which is not the same as empty

[route_hosts]
web = "web.myapp.com"            # manifest label -> the full name, prefix applied. A claim, like a
                                 # publication: allocated, refused when taken, released on remove

[ports]
requested = ["8080/tcp"]         # what the manifest asked for, in manifest order
granted   = ["8080/tcp"]         # what an admin has granted; a subset of requested

[firewall]                        # the manifest's `firewall:` entries (§7.7), written by the
                                  # mutator at creation exactly as [ports] is, and for the same
                                  # reason: the renderer has no business writing them and the
                                  # admin's decision needs somewhere to be read from
requested = [ { name = "wireguard-peer", chain = "guarden-svc",
                rule = "-p udp --dport 51820 -j ACCEPT" } ]
granted   = ["wireguard-peer"]    # a name an admin has agreed to install. overrides.toml is the
                                  # authority and this is its mirror, so a rule survives its
                                  # service's manifest until the admin closes it

[state.data]                     # one table per declared volume, state and bulk alike
config    = "myapp-production-data"   # absent for a bulk volume
snapshots = 42                       # newest snapshot number; absent for a bulk volume

[instances."feature\\x2dx"]      # instance tracks only: the escaped ref is the key
created = "2026-09-28T18:03:11Z"
publication = { web = 20120 }   # that instance's own publications, allocated per instance so two
                                # instances of one service can both be routed at once
seed    = { data = 38 }          # per state volume, by configuration name

[gate]                            # one per SERVICE, not per instance: every instance shares the
                                  # service's uid and therefore one secret store, so the
                                  # credential state is a property of the service. Omitted
                                  # entirely when the gate has never been evaluated, which is
                                  # NOT the same as state = "ready"
state   = "blocked"              # ready | blocked | not-required
reason  = "missing required key: DB_PASSWORD"   # present only when state = "blocked"
checked = "2026-09-29T10:12:03Z"  # when the verdict was last taken, by `weedr service gate`
                                     # or by `weedr service start` re-checking

[generated]
"API_KEY" = "2026-09-29T10:12:00Z"   # a value guarden minted, not one a human planted. Once
                                      # minted it is indistinguishable from a planted value, so
                                      # this is the only record that it was not one

[immutable]
"data" = "production rollback base, 2026-09-29"   # the chattr +i escalation, with its reason.
                                       # Written by `weedr service immutable`, which sets the
                                       # flag and this record together, and cleared by
                                       # `weedr service mutable`, which clears both. An earlier
                                       # revision had no writer for this table at all and the
                                       # runbook said to record the escalation with `stakes pin`,
                                       # which is a different thing: pinning also raises the
                                       # snapshot to important=yes under the number cleaner, so
                                       # it was a retention side effect presented as note-taking
```

`workload` and `project` are different things and may differ. `workload` is the service name
without its environment segment. `project` is the manifest's `project` field, defaulting to
the project its `--from` source belongs to — the `<project>` of `--from poke <project>@<sha>`,
or the source service's project for `--from <service>`. The instance cap
counts per **preview service**, which is per workload and environment — never per project,
because two repositories may declare the same project name.

The registry is the single record of a service's identity, its edges, its publications, its
lineage and its ports. It is a **projection**: anything derivable from the manifest and the
host is recomputed, and only what cannot be — the uid, the sha, the allocated ports, the
snapshot numbers, the seeds — is stored.

### 3.5 The write protocol

Every file more than one process may read while another writes is written like this, with no
exceptions: take `flock` on `/run/guarden/locks/<name>.lock`; write a temporary file **in the
same directory** as the target; `fsync`; `rename` over the target; release by exiting or
closing the descriptor.

A reader **must not** take a lock. Because writers rename, a reader sees the old file or the
new one, never a partial one, and a path that does not exist is absent rather than an error.

The lock names, and the composite operation each one covers:

| lock | held across |
|---|---|
| `registry` | a read of the registries, the change, and the write — for one service |
| `projects` | a project's allowlist edit. **Not** the dispatch decision: `projects.toml` is root-owned `0444` and only root writes it, so a reader of it has nothing to serialise — `hose` takes this lock never, and §3.5's rule that a reader takes no lock is what makes that true rather than accidental |
| `overrides` | a read of every service's overrides, the change, and the write |
| `firewall` | **the whole render, the diff, and the install of `50-services.conf`** — without it two concurrent grants each render and the stale one installs last, silently dropping the other's rule |
| `snapshots` | the mark reconciler **and** the cleanup unit (§8.5) |
| `queue` | enqueue, dequeue, and the state of an in-flight request |
| `deploy-<service>` | one deploy of one **slot** service, end to end, so two deploys of the same service cannot overlap while different services proceed in parallel |
| `deploy-<service>-<escaped-ref>` | the same, for one **instance**'s deploy. On a `kind = "instance"` track every instance of a service is deployed separately and is forked and rolled back separately, so one shared `deploy-<service>` lock would serialise an entire track's previews behind each other. The two names cannot collide: a `-` in a service name is a legal character, but the slot lock carries no ref and this one always does, and `<escaped-ref>` never contains a raw `/` |
| `preview-cap` | counting instances and evicting, so two creates cannot both pass the cap |
| `modules` | installing or removing a module's services, groups and grants |

**Locks are taken in a fixed order, and the order is part of the contract.** Four of these
compose, and without an order two mutations can deadlock instead of serialising. The order is:

```
modules  >  projects  >  overrides  >  registry  >  preview-cap  >  queue  >  firewall  >  deploy-*
```

Each program takes what it needs and releases before taking the next, and **never two at once**
unless they are adjacent in that list and taken left to right. The compositions the order exists
for: `weedr module add` takes `modules`, releases it, then calls `soil firewall --apply` which
takes `firewall` — two locks, in sequence, never nested (§6.2). A preview create takes
`preview-cap`, releases, then `registry`, releases, then its `deploy-<service>-<escaped-ref>`.
`registry` is "for one service" and an add touches one service's registry plus possibly a
provider's, so it takes them **one at a time in lexical order of service name**, never two — that
is what "for one service" is for.

`hose` takes none of these. It is not a member of the `guarden` group, so it could not open them
even if it wanted to, and it needs none: it reads a root-owned `0444` allowlist to make a
dispatch decision and writes nothing that a lock protects.

`<escaped-ref>` in a lock name is the **same escaped form** as the registry's instance key
(`feature\x2dx`, §3.4) and the instance directory's, so one escaping rule governs every place a
ref becomes part of a path, a key or a filename. A raw ref is never used in any of the three,
because a ref taken raw may contain `/` and turn one lock file into a path that does not exist.

`guarden.toml` has **three** writers, not one, and two of them share a key: `weedr module add`
appends to `[modules] enabled`; `soil install` writes the measured `ingress.alias` **and** seeds
`[modules] enabled` from cloud-init or from the install script; and `soil install` is also the
phase that owns the rest of the file. The statement that this file has a single writer was wrong
twice over.

The rule for every one of them is the same, and it is the rule for adding a fourth: **a write
takes the `modules` lock, goes through this protocol, and rewrites only the keys it owns.** A
read-modify-write of `[modules] enabled` re-reads the file under the lock rather than trusting
what it saw before it, so `soil install` seeding the list and `weedr module add` appending to it
cannot lose one another. Two writers of one key is legal here because both take the lock; two
writers of one key with neither taking it would not be. There is no `hosts` lock, because nothing
writes a name map: names go into the consumer's own unit (§7.3). The pin
store is deliberately exempt from the protocol's locking: one file per snapshot, created and
removed by name, never aggregated, so there is no read-modify-write to lose.

### 3.6 `/usr/lib/guarden/modules/<name>/module.toml`

The module registry is this directory. There is no separate registry file, and
`weedr module list` reads the directory plus `guarden.toml`.

```toml
name = "gate-traefik"
requires = []                    # modules that must be installed first

[[services]]
service = "traefik-production"    # created by weedr service add, from the shipped manifest
ingress = [ "80/tcp", "443/tcp", "443/udp" ]   # forwarded by soil firewall, not by a grant
api = true                        # the service publishes an API/dashboard, restricted to admin_user

[[switches]]
program = "roots"                 # the shared programs this module switches on
```

A module declares the services it installs, the shared programs it switches on, the ingress it
declares for forwarding, whether the service has an API, and the modules it requires. It never
declares a path, a mode, or a program that does not exist. A module contributes no code: the
programs are shared and ship with guarden.

---

## 4. The project manifest

`.guarden/service.yml` at the repository root.

```yaml
project: myapp                    # optional; defaults to the project the --from source
                                 # belongs to, never to a path basename

units: compose.yaml               # or: units: .guarden/quadlet/ — exactly one

state:                            # snapshotted: a btrfs subvolume with a snapper configuration
  - data
bulk:                             # not snapshotted, and empty after a fork
  - chainstate

needs:                            # declared edges to other services
  - service: postgres-production  # a guarden service
    as: db                        # the prefix for this edge's generated variables
    port: 5432
    auth: database                # database | secret | none

provides:                         # what this service can offer a consumer, as KINDS
  - db                             # consumed as `as: db`, which also gives DB_HOST/DB_PORT
  - secret                         # consumed as `as: secret`, verified with a shared credential

ports:                            # public ports requested from outside the host
  - container: web                # a container in THIS service, exactly as under routes:
    port: 8080                    # the container's own port; the loopback publication is guarden's

routes:                           # published to the edge
  - container: web                # a container in THIS service
    port: 3000                    # the container's own port; the loopback publication is guarden's
    host: "web"                   # a LABEL, not a domain. The full name is the track's
                                 # root-owned host_prefix + this, so a manifest cannot claim a
                                 # name outside host.domain
    auth: true

firewall:                         # firewall rules this service ASKS for (§7.7). A request and
  - name: wireguard-peer          # nothing else: none is installed until an admin grants it
    chain: guarden-svc            # one of guarden's own chains; today the only value
    rule: "-p udp --dport 51820 -j ACCEPT"

widgets:
  - container: web
    file: .guarden/widgets/web.yml

schema: .guarden/.env.schema      # names, types, examples; never values
```

`service:` names a guarden service; `container:` names a container inside this service. A
`service:` key inside a `routes:` or `widgets:` block is a validation error, because the
manifest's whole point is that a developer can tell which is which. `port:` under `routes:` is
the **container's** port and is required: guarden allocates the loopback publication that
Traefik dials, and the manifest never names it.

`needs` and `provides` must agree, and they are compared **kind to kind**: a consumer's
`as: db` requires a provider whose `provides:` lists `db`, and its `as: secret` requires one
that lists `secret`. An edge's `auth:` is a second, separate matter — it says how the consumer
authenticates, not what the provider is — and it does not have to match anything in
`provides:`. The comparison is against the provider's **registry**, not its manifest, so there is
one input and one exit code: a disagreement is exit `1` with both kinds and both service names
named. The earlier `2`-and-`1` pair described a check that no program could have performed,
because it required reading two manifests the renderer cannot reach.

Validation rules:

- Unknown top-level keys are refused, and so are unknown keys **inside** a known one. Each
  block has a closed key set: a `needs` entry takes `service`, `as`, `port` and `auth` and
  nothing else; a `routes` or `ports` entry takes `container` and `port`; a `firewall` entry
  takes `name`, `chain` and `rule` and nothing else; a
  `widgets` entry
  takes `container` and `file`; a `provides` entry is a **single string naming a kind** — `db`,
  `secret` — and nothing else, because a `provides` entry carries no value and no structure; a
  `state`/`bulk` entry is a string. An unknown key inside one
  of them is refused **by name**, the same as an unknown top-level key. This was a gap: the
  rule covered only the top level, so a typo in a nested key was silently dropped and a
  manifest asking for `authentification: true` got a route with no auth on it and no diagnostic
  saying so.
- An `environment` key is refused **specifically**, with a message saying the host decides the
  environment and where the decision is recorded.
- `project` must match `^[a-z0-9][a-z0-9._-]*$`. It has no length limit of its own; the
  **resulting service name** must not exceed 31 characters, and that is what is checked.
- `state` and `bulk` entries must match `^[a-z0-9][a-z0-9._-]*$`, must name a volume the unit
  source mounts, and a name may not appear in both.
- `needs` entries must name a service that exists **or will exist**, carry an `as:` kind, and a
  port in range. A service that does not exist *yet* is not an error: a poke creates services in
  dependency order and a manifest may name a service a later deploy brings into being.
- **The provider's `provides:` is read from the provider's registry, never from its manifest.** A
  manifest that declared both sides of every edge would be one document the renderer cannot
  reach: the consumer's tree is `0700` to the consumer and `loom` runs as `guarden`, so the
  provider's `provides:` lives in a file the mutator wrote and the renderer can read. The
  consequence is that **every** disagreement has a single input, which is why there is one exit
  code for it rather than two: a provider with no registry entry, or one whose `[provides]
  kinds` does not include the consumer's `as:`, is **exit `1`** with the kind and both service
  names in the diagnostic. There is no case where the disagreement is visible from two manifests
  alone, so §1.2 has no `2` row for it — that row was in an earlier revision and described a
  check no program could have performed.
- **`as:` is the variable name, uppercased.** `as: db` gives the consumer `DB_HOST` and
  `DB_PORT`; `as: cache` gives `CACHE_HOST` and `CACHE_PORT`. There is no mapping table to keep in
  step, and no per-edge exception: the manifest names the prefix, so a service that wants
  `SEARCH_URL` writes `as: search`. For a `database` auth edge the credential additionally arrives
  as `/run/secrets/DB_PASSWORD` — the same uppercased prefix plus `_PASSWORD` — and for a `secret`
  edge as `/run/secrets/<KEY>` named in the manifest's schema.
- `ports` entries carry `container:` and `port:`, exactly as `routes` entries do, and `port:`
  is the **container's** port. A bare `"8080/tcp"` string is not a valid entry. This is a
  correction rather than a new requirement: a grant is a translation to a publication (§7.5),
  a publication is allocated per container, and an entry that named only a public port named no
  container, so there was nothing for the grant to translate to and `weedr port open` could not
  render a rule at all. A public port alone is not a destination. The manifest's whole position
  is that a developer can tell which is which, and `ports:` is the only place a public port
  appears — a `route` is reached from the edge over loopback and needs no public port at all.
- The protocol comes from the container port's declared protocol in the unit source, and a
  `ports:` entry **may not** disagree with it. `"8080/tcp"`-style protocol suffixes are
  therefore not used anywhere in a manifest entry; the old string form carried the protocol, and
  carrying it in two places is two places for it to be wrong.
- `routes` must name a container the unit source defines, and carry a container port.
- **A route's `host:` is a label, not a domain, and the host owns the domain.** The full name is
  `<track host_prefix><host:>`, and `host_prefix` is root-owned. So with `host_prefix = "myapp."`
  a manifest writing `web` claims `web.myapp.com` and a manifest writing
  `www.elsewhere.com` claims `www.elsewhere.com.myapp.com` — inside the domain, unreachable,
  and visibly wrong to the developer rather than silently successful. **A repository therefore
  cannot claim a name outside `host.domain`, and the only way to serve another domain is for the
  operator to set `host.domain` or the track's `host_prefix`.** The earlier revision combined
  these two with a `${domain}` substitution and validated nothing, which meant any repository
  could claim any name in the operator's domain and two services claiming one was undefined.
- `host:` must match `^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$` after
  prefixing, and must be at least one label. An uppercase character, an underscore, a leading or
  trailing dot, a wildcard or a port is exit `2` naming the value. A wildcard was the shape that
  would have been dangerous and the reason the pattern is closed rather than a list of
  prohibitions.
- **A host is allocated, like a publication, and the allocator refuses the second claimant.** A
  second `weedr service ingest` whose route host is already taken is exit `1` with the holder
  named, exactly as for a duplicate port (§1.2). The allocation lives in the host's
  `[route_hosts]` table, so it survives regeneration and two instances of one preview service
- **A `zram:` key is refused specifically, in all three vocabularies a repository speaks.** It
  is host configuration, it is in the root-owned `/etc/guarden/guarden.toml` (§3.1), and the
  answer is never in a repository — the same shape and the same reason as `environment:` and
  `weight:`. The refusal covers the manifest's own top level (and any block nested inside it),
  a `zram:` or `swap:` key on a Compose service, and a `Sysctl=` line in a hand-written quadlet
  file, because those are three parsers on three inputs and a refusal in one of them would leave
  the door open in the vocabulary most developers write. `sysctls:` and `swappiness:` are refused
  with them: `vm.swappiness` is the one real sysctl this design adds to the set `soil sysctl`
  owns, and neither is a grant nor a request, so neither is anything a repository may state.
  cannot collide. Nothing about this is cooperative: a repository cannot take a name that is
  already serving, and a service that loses its host on removal has it released, so the name
  becomes available again.
- A `ports:` entry names a container the unit source defines, exactly as `routes:` does. The
  container's port is also how its publication is found, so a container named only in `ports:`
  gets a publication like any other (§7.4). This is the case the whole grant model rests on: a
  peer-to-peer service with no route and no dependency exposes a public port and nothing else.
- A **`firewall:` entry is a request and installs nothing** (§7.7). `name` must match
  `^[a-z0-9][a-z0-9._-]*$` and be unique within the manifest, because it is what a grant names
  and two entries sharing a name would make that grant ambiguous. `chain` may be omitted and
  defaults to `guarden-svc`; naming a chain guarden does not render is exit `2` naming the chain
  and the rule. `rule` is one iptables-shaped line matching `^-` followed by option tokens and
  exactly one `-j` or `-g` target, and it may **not** open, close, rename, flush or set a policy
  on a chain or a table, nor jump to a chain guarden does not render — each is exit `2` naming
  the rule and the key. There is no position, priority or comment field, so nothing in a
  manifest says where in the chain a rule goes: that is guarden's, and it is why a grant cannot
  be rendered somewhere the default deny has already matched.
- `widgets` must name a container the unit source defines, and the file must exist.
- `as` must be unique within the manifest, because it is the prefix of generated variables.
- A self-edge is refused.
- Exactly one of `compose.yaml` at the root and `.guarden/quadlet/` must exist. Both present
  is ambiguous; neither present names both accepted locations.
- The manifest may not contain a key that **records** a grant, nor one expressing a build
  priority, a snapshot priority, a resource cap or weight, or a data source. Each is refused by
  name. `ports:` is a request and is legitimate; a key that records an open host port is not.
  `firewall:` is the same shape of thing and for the same reason: it records nothing that is in
  force, and the only file that does is the root-owned `overrides.toml` (§7.7).
- **There is no range form** for a port, in a manifest or in a grant: a service that wants a
  block of ports lists them. A range would make the manifest harder to read than the firewall it
  produces, and a service needing a hundred ports is a signal that it should be reached over an
  overlay rather than by publishing a hundred.

`${domain}` is the only substitution, from `host.domain`. No host environment variable and no
service name is substituted, because both would make a rendered unit depend on when it was
rendered.

`compose.yaml` must stay valid Compose and is converted by the renderer, never by the mutator.
A repository that ships quadlet units has them used as they are, after the checks in §6.3.

**The division of labour in that conversion is stated here because it was not.** The pinned
`podlet` does the mechanical Compose-to-quadlet translation, and `loom` drives it,
post-processes its output, and owns every field the design has an opinion about:

- **podlet owns**: container, image, command, entrypoint, environment, user, working
  directory, ports before stripping, volumes before rewriting, and the labels quadlet needs.
  Compose is a large and still-moving specification and reimplementing the translation is a
  project of its own with a long tail of edge cases; the renderer exists to make the
  *security* decisions unprivileged, not to re-derive a converter.
- **`loom` owns, on the output**: the refusal list (§6.3), the whole `PublishPort` set, the
  `Network=pasta:` line from `[network] pasta_options`, `AddHost=` per edge, the credential
  requests, the `.volume` units, the `After=guarden-order.target` drop-in, and the
  `<name>.target` start-order edges. **Every one of those overwrites or removes something
  podlet emitted**, which is why running podlet is not the same as trusting it: it is a
  translator for the fields guarden has no opinion about, and not a security boundary for
  the fields it does.

So `loom` invoking `podlet` does not weaken ADR-0012. That rule is about **who runs the
converter** — the mutator runs no program at all over repository input — and podlet runs as
the unprivileged renderer, which is exactly where ADR-0012 puts the conversion.

The secret schema is a **varlock schema**, `.guarden/.env.schema`, and there is no
`.env.example` — the schema is the single source of truth and the two are never kept in step
because there is only one. guarden does **not** run varlock, does not depend on it, and is not
installed by `soil`; the annotations are read as text, which is why the four below are the only
ones that carry meaning and an unknown annotation is ignored rather than refused:

- `@required` — the key must be set, and a gated track refuses to start without it
- `@sensitive` — the key's value is a credential and is never printed, never listed by name
  with its value, and never rendered
- `@type` — informational for guarden, which stores every value as text
- `@example` — the example the gate rejects while it is still present

**The varlock defaults are part of the contract, because a project will not spell them out.**
`@defaultSensitive` is `true` unless the file says otherwise, so a bare `DB_PASSWORD=` is
already a credential and needs no decorator; `@defaultRequired` is `true` unless the file says
`infer`. guarden therefore treats **every key in the schema as a credential and every key as
required** unless the file's own root decorators say otherwise, and reads those two decorators
to find out. A project that writes `@defaultRequired=infer` gets "a key with a value in the
schema is required, a key without one is not", and a project that writes
`@defaultSensitive=false` gets "only keys marked `@sensitive` are credentials". Getting this
wrong fails closed: a key guarden believes is optional is not required, and a key guarden
believes is a credential when it is not is stored encrypted and injected as a file, which is
harmless.

Nothing is generated from the schema into the repository: a service's credentials exist only in
its own store.

---

## 5. Services, tracks, instances

### 5.1 Names

A service name is `<workload>-<environment>`, where the environment is the last
`-`-separated segment and must name a track in the environment table. The workload may
contain dashes, dots and digits. The whole name must match `^[a-z0-9][a-z0-9._-]*$`, must not
exceed 31 characters — the Linux user-name limit — and must not contain `..`.

`other-app-production` parses as workload `other-app` in `production`. There is no `--env`
flag: the name carries the environment, so a name and an environment cannot disagree. A name
with no recognised environment segment is exit `2` — **except** that `weedr service add` with
no environment in the name resolves a default and prints the resolved name. The default is
**the first track in table order with `gated = false` and `kind = "slot"`**, which is `staging`
in the shipped table. It is resolved that way rather than hardcoded as the word `staging`
because the shipped table is a default and not a list in the code, and an operator who has
marked `staging` gated would otherwise have a documented default that creates a gated service —
exactly what this rule exists to prevent. **If no such track exists, the name is exit `1` naming
that fact**, not a silent choice of a gated track. An omitted environment segment can never
create a gated service.

**No verb on the privileged surface carries a flag that widens authority, and this is structural
rather than conventional.** A sudoers rule that names a command without an argument
specification matches *any* arguments, and sudoers has no negation, so a rule granting
`weedr service remove` also grants `weedr service remove --purge-state`: the prohibition could
never be expressed in the file, only described in prose. The three verbs that would need such a
flag therefore do not have one, and each capability is a separate verb instead:

| capability | verb | on the `guarden` sudoers rule? |
|---|---|---|
| create a service from a poke | `weedr service ingest` | **yes** |
| create a service from another service's tree | `weedr service add` | **no** |
| fork, with a chosen source | `weedr service fork` | **no** |
| grant a public port | `weedr port open` | **no** |
| install a requested firewall rule | `weedr firewall open` | **no** |
| destroy a service's volumes | `weedr service purge` | **no** |
| roll a service back to a snapshot | `weedr service rollback` | **no** |

Every verb that *is* granted is granted whole. A caller that can run `weedr service ingest`
creates a service and nothing else: it cannot grant a port, cannot destroy data, cannot roll
anything back, and cannot choose where a service's tree or data comes from, because none of those
is a flag on something it can run.

Names are service names everywhere. There is no separate host-name convention, no suffix, and
no alias: the name a consumer resolves is the service's own name, and the route target Traefik
receives is `<name>:<publication>`.

### 5.2 Instances

An instance is a preview of one service, named by the ref it tracks. **Every verb takes the
ref raw**, and escaping is internal: `weedr service ingest myapp-preview/feature-login --from poke <project>@<sha>`
and `furrow preview drop myapp-preview feature-login` both take `feature-login`, and the directory,
the unit name and the registry key are all `systemd-escape` of it, so `feature/x` and
`feature-x` can never collide.

Instances exist only for a track whose `kind` is `instance`; asking for one otherwise is exit
`2`. They live under the service's home and share its user, its image store, its publication
namespace and each other's directories.

**Instances of one service are one trust domain, and that is a decision rather than an omission.**
They share one uid, so a compromised instance can read every sibling instance's state volumes and
the service's secret database — all of it sits inside the service's single `0700` tree (§5.3),
owned by one user. **There is no per-instance user, no per-instance `0700` and no per-instance
subuid range, and an implementer shall not add one.** The alternative was considered and costs
a subuid range, a home and an image store per instance, which on a small host is more disk than
the isolation is worth.

The reasoning is that a preview is the operator's own fork of a project the operator already has
publish access to. An untrusted fork is a different problem, and the answer is not a per-instance
user: it is that the untrusted repository is its own **service** in its own track, and the
`projects.toml` ref allowlist is narrowed (§3.2) so only its own refs may deploy. A per-instance
user would give isolation between an operator's own branches and nothing against a contributor
who can push to the repository, which is the case that actually matters.

### 5.3 What a service owns

**A service's tree comes from exactly one of two places, and never from a path an argument names.**

```
  weedr service ingest <name[/ref]> --from poke <project>@<sha>    on the guarden rule
      └ CI's tree, already on the box. The system builds the path.

  weedr service add <name[/ref]> --from <service>                   root only
      └ copy that service's manifest and unit source
```

There is **no `--from <path>`**, and that is the whole security argument rather than a
convention. An earlier revision took a directory, and the entire problem it created was that a
caller could then *choose a location*: a path is the one argument in this interface that can
mean something other than what it says, and every mitigation for it was a check — staging
confinement, a `realpath` resolution, a symlink refusal, a uid-conditional allowance. A service
name and a `<project>@<sha>` pair are not paths. The system resolves them to locations it already
owns, and there is nothing left to confine.

**The rule is about the verb surface, not about every read.** A root-owned program reading a
root-owned path it shipped is not a caller naming a location, and one case depends on the
distinction: `weedr module add` creates the module's declared services from the unit source in
`/usr/lib/guarden/modules/<name>/`, which guarden shipped and root owns. It reads that path
itself, takes no `--from` form for it, and offers no way for anyone to name a different one. So
the two-place rule holds for every caller — operator, `furrow` and `hose` alike — without
implying that `weedr` may not read its own installation.

Two consequences, and they are the reason this is the shape rather than a preference:

- **The box never authenticates to a forge.** There is no git clone form, so a private repository
  is not a special case — CI holds the credential, pushes a tarball, and `hose` receives it. That
  removed the need for a deploy key, a token or an `.netrc` on the host, which was the reason
  `--from git` was awkward in the first place.
- **A poke cannot promote anything but itself.** `--from <service>` is root-only and `ingest` has
  no such form, so a branch can never create a service out of another service's tree. It ships
  its own tree, into a track the allowlist approves. A compromised `guarden` program cannot
  promote a staging manifest into production either, which was possible while `weedr service
  fork --from` was on the same rule as the verbs a deploy needs.

`ingest` requires its two arguments. `add` requires `--from`, and is also the reconcile command:
run either again to apply an edited manifest.

**A poke may create a service in a gated track, including `production`, and that is forced rather
than chosen.** With no `--from git` and no `add --from <service>` for CI, the staged tree a poke
carries is the only path in the system that brings code to a workload that does not exist yet. A
rule that only root could create a production service would make the first production deploy of
every new project impossible, not safer. So CI creates, and what stands between a push and a
running production container is not the creation but the gate: the service exists, builds and
installs, and **does not start** until an operator has planted its credentials and run
`weedr service start`, which needs root (§6.6). The gate is a mutator verdict precisely so that
the thing that starts a production service is never reachable from a workflow key.

In order:

1. The registry entry, if absent.
2. A system user of the same name, home `/var/lib/guarden/services/<name>/home`, no login
   shell, linger enabled, and a subuid/subgid range allocated by the system with
   `useradd --system --add-subuids-for-system`, falling back to `usermod --add-subuids`. The
   mutator reads `/etc/subuid` and `/etc/subgid` back and **fails loudly** if the range it
   asked for is absent. Every service user gets a distinct range; a shared range would map
   every container's root to the same host uid. The home is `0700`; the service tree is `0700`.
3. Supplementary groups named in `groups.add`.
4. The home's quadlet directory.
5. For each `state` and `bulk` entry, a btrfs subvolume owned by the service user, and for each
   `state` entry a snapper configuration named `<service>-<volume>` with soil's canonical value
   set (§8.1). A `bulk` volume gets a subvolume and no configuration.
6. An allocated publication for every container named in a `routes:` entry, a `ports:` entry or a
   `needs:` entry, and for the edge's API when the module declares one (§7.4). A `ports:` entry is
   here because a grant is a translation to a publication: without this a peer-to-peer service
   with no route and no dependency would be grantable in the manifest and unrenderable in the
   firewall.
7. A firewall accept rule per edge, and the drop rules for every publication (§7.6). Any
   `firewall:` entry the manifest declared is **recorded in the registry and left pending**
   (§7.7): creation records the request and installs none of it, which is the same answer a
   requested port gets.
8. A forwarded public port for every granted entry in `overrides.toml` (§7.5).
9. For a track with `gated = false`, a generated value for every `@sensitive` key the schema
   declares and no value has been planted for — minted once, stable until the service is
   removed, and visible in `weedr service list` as generated. A gated track gets no generated
   value: there, a missing key is a gate failure, and generating one would hide it.
10. For a `database` edge, a role and a database in the provider, a minted password planted as
   a podman secret in the **consumer's** store, and nothing in the provider's. For a `secret`
   edge, a minted secret planted in both, because the provider has to be able to verify it.
11. Units, rendered by `loom` and installed by the mutator.
12. **A fork, when the track forks — as an internal step of this command, from the track's
    `fork_from` field and nothing else.** §8.3 has the rules; the two that matter here are that
    **`production` has `fork_from = ""` and therefore starts empty, and a production service
    never forks from staging**, and that the source is read from the field rather than from any
    argument. The fork is a step of creation rather than a verb a deployer invokes, precisely so
    that the override and the automatic path cannot be the same call: `weedr service fork` with
    its `--from` override is root-only and is *not* on the `guarden` rule (§5.1), so a poke
    cannot ask for a fork at all, let alone one out of staging into production. An operator
    wanting that does it deliberately, by hand, and it is the `weedr service fork` verb.
13. A re-render of the edge's routes and the dashboard, at the end of the command (§6.9).

Every step is idempotent. A second `ingest` or `add` of a converged service exits `0`, says it
converged, and changes nothing.

`weedr service remove <name>` removes a whole service: it reverses all of it, moves each state
and bulk subvolume to `/var/lib/guarden/removed/<service>/<time>/<vol>/` rather than deleting
it, and leaves the repository and the operator's offline copy of credentials alone. Its
`overrides.toml` goes with it, so every port grant and every firewall rule grant it held is
released and the firewall is re-rendered (§7.7). It is
**refused outright on a track with `gated = true`**, and refused while any instance of an
instance track still exists, with the instance names named — remove those first.

There is no flag that overrides the gated refusal. The only way to make it possible is for an
operator to remove the root-owned `/etc/guarden/allow-gated-drop` marker, which is the point: a
refusal that a caller can switch off with an argument is not a refusal, and a sudoers rule
granting this verb cannot tell that argument from any other.

`weedr service remove <name>/<ref>` removes **one instance** of an instance track, and is the
verb the preview cap's eviction and `furrow preview drop` both call. It stops that instance's
units, deletes its directory, releases its `seed`, and releases its publication, and leaves the
service and its siblings alone. Refused if the ref names an instance that does not exist.

**`weedr service purge <name>` is the only path in guarden that destroys data, and it is a
verb of its own rather than a flag.** It deletes the volumes instead of moving them, names every
volume it destroys before it does, requires a terminal to confirm at, and is refused for an
instance: an instance's volumes belong to the service, so purging one would destroy the
service's data. It is refused for a service on a gated track for the same reason `remove` is.
It is not on any sudoers rule, so no unprivileged program can reach it at all, and it exists so
that destruction is a word someone types at a terminal, not a consequence of a cleanup routine
and not something a compromised workflow key can ask for.

---

## 6. Programs

### 6.1 `soil` — the host converger

```
soil <phase> --check      # report drift, change nothing, exit 1 with the word "drift"
soil <phase> --apply      # converge
soil --check              # every phase
soil list                 # the phases and what each owns
```

Phases in order: `packages`, `storage`, `sysctl`, `firewall`, `install`, `units`. `soil` is
the only program with two modes and the only other one with a `--check`. It **must not**
create a service user, a service directory, or any identity belonging to a service. There is
no `soil users` phase: the two program users are created by `install`.

**The index refresh is not an item, and it is not a step before the phase either.** The
`packages` phase runs the family's index refresh **once per run, inside the first install that
needs it** — immediately before that install resolves a version against the index — and never
per install, because one refresh serves every install in the run. It is not an item because the
index is not a declared piece of state — no file of guarden's says how fresh it is — so there is
nothing for `--check` to ask it and nothing for it to converge against. **`--check` does not
refresh the index and does not report it as drift**, and `--apply` refreshes it only when an
item it is about to converge actually installs. (An earlier revision had it as a step that ran
before the phase's items; that paid a refresh for applies that converged nothing about any
package.) Its failures surface from the install that triggered the refresh, classified as the
paragraph below says.

The refresh **exits `1`** when it runs and fails, because a host that cannot reach its own
mirror is the host and not the request (§1.2), and **`2`** when `packages.toml` carries no
`update` argv for the family, because a list nobody filled in is input. A failed refresh stops
that phase's installs and the run reports the packages it could not install; the other phases
still converge and the run still exits `1`.

- `packages` **disables the distribution's own apt timers — `apt-daily`,
  `apt-daily-upgrade` and `dpkg-db-backup` — then** installs the distribution packages, refreshing
  the package index from the family's own `update` argv in
  `packages/packages.toml` once per run, **immediately before the first install that needs it**:
  btrfs-progs, snapper,
  ferm, fail2ban, podman, `dracut` (the conversion machinery's initramfs hook runs under it —
  `dracut-core` on Debian — and a host without it refuses the conversion explicitly), and
  `python3-yaml` and `python3-jinja2`. `ufw` is **uninstalled** by
  installation and is **not** in any package list, on any family, for any reason. The host firewall
  is `ferm` and nothing else. It also fetches **pinned artefacts**
  from outside a distribution repository, and each one is an exception to "distribution packages
  only" that is deliberate: a **url** and **two SHA256s** — the artefact's, verified before
  anything is unpacked out of it, and the program's, re-read on every `--check` because the
  artefact is not kept. Today that is `podlet` and, with ADR-0015, the tunnel's `cloudflared`.
  **A vendor repository is never one of these**: its contents move under the pin, so the version
  in force would be the vendor's to decide rather than recorded here. `soil packages --check`
  asserts the version in force.

  **The timers are disabled for the same reason `storage` disables the packaged
  snapper cleanup timer, and it is the same overlap by another name**: a packaging
  timer running on its own schedule is another writer of the state this phase converges.
  Waiting for the lock instead is not available, because `apt-get` does not do it — two
  concurrent `apt-get update` runs give one exit `0` and one exit `100` with
  `E: Could not get lock`, both inside five seconds — so a refresh that met a timer
  would fail the run rather than queue behind it. `storage` installs a replacement oneshot
  because it has daily work of its own to schedule; `packages` installs nothing, because
  nothing in guarden installs packages on a schedule. "Disabled" means *not enabled*, for the
  reason and with the same answer `storage` uses: the `.service` names are `static`.
  **`unattended-upgrades.service` is deliberately not disabled** — it installs security
  updates unattended and switching it off is an operator's decision, not this phase's; the
  timer this removes is what triggers it on a schedule. Anything that starts that service
  deliberately can still meet a `packages` run, and the run reports it rather than retrying.
  The disable is this phase's **first item**, and the refresh runs inside the first install
  that needs it — after the disable — so the *first* `packages` run on a host whose timers are
  still armed meets them only in the window before its own first item: the disable is what
  closes that window.
- `storage` verifies btrfs with `@` and `@var` subvolumes, installs
  `/etc/apt/apt.conf.d/80guarden-snapper` with a `DPkg::Pre-Invoke` that snapshots `root`
  before every package transaction, converges the canonical value set into every snapper
  configuration it can see — a service's configurations, and the host's own `root` and `home`,
  and nothing else (§8.1) — creates `root` and `home` where they are absent, and installs
  `/var/lib/guarden/soil/`. It creates **no** service volume. **A root that is not yet btrfs,
  or that is btrfs without the subvolumes, is converted**: the phase drives a staged offline
  conversion — `--apply` schedules it, a reboot runs it in the initramfs, and the phase is run
  again after each reboot (twice in all: the conversion, then the `@`/`@var` migration) — and
  while a reboot is outstanding it reports the marker it wrote at
  `/var/lib/guarden/soil/reboot-required` and stays unmet, which is the one drift a `storage`
  run is expected to carry between reboots. It also **disables the
  distribution's packaged snapper cleanup timer** and installs the replacement that takes the
  `snapshots` lock (§8.5). A snapper configuration belonging to a service is created by the mutator and is
  never recreated here.
- `sysctl` sets `net.ipv4.conf.<ingress-if>.route_localnet=1` on the ingress interface only,
  and `net.ipv6.conf.all.disable_ipv6=1` and `net.ipv6.conf.default.disable_ipv6=1`. It
  sets `net.ipv4.ip_unprivileged_port_start=1024` and owns that key — raising it to the kernel
  default establishes the invariant, and lowering it is the thing that is refused. It also
  checks, in `--check`, that
  `ingress.alias` still matches the address the default route resolves to (§6.1).
- `firewall` installs ferm and fail2ban and
  `guarden-firewall.service`, writes `00-ssh.conf` — the SSH accept rule, root:root 0600, seed-once,
  its own `guarden-ssh` chain with the accept as the first rule, and the INPUT jump as the first
  rule after conntrack and lo — writes `10-framework.conf`, writes `30-admin.conf` (optional),
  and writes `20-ingress-nat.conf` from the enabled modules' declared ingress. It owns the
  framework, the SSH accept, the admin drop-in and the edge's forwarding; the mutator owns
  `50-services.conf`, any service's own forwarding and any service's own granted firewall rules
  (§7.7). The files are disjoint and each is written by exactly one program.

  **`soil firewall --apply` refuses (exit 1, installs nothing) unless all of:** `00-ssh.conf` exists,
  is 0600 root:root, its accept is the first rule in `guarden-ssh`, and the INPUT jump to
  `guarden-ssh` is the first rule after conntrack and lo. This is the structural guarantee that
  replaces the dead-man timer: SSH access is guaranteed by the filesystem and rule order, not by a
  timer that opens the firewall.
- `install` copies guarden's programs, templates and units into `/usr/lib/guarden` root-owned,
  creates the `guarden` and `hose` users **and the `guarden` group** — which is load-bearing,
  because the registry, every `overrides.toml` and all of `/etc/guarden` are `root:guarden` and
  the unprivileged programs must read them — records `host.admin_user` from the invoking user if
  it is empty, runs the alias probe below and writes its result into `ingress.alias`, and
  installs the credential materialiser. It creates no group beyond
  `guarden`: the `edge` group belongs to `weedr module add gate-traefik`. It installs no service, so a
  fresh host has no ingress and no dashboard until a module is added, and it refuses to start the
  edge if `ingress.alias` is still empty. It is the only phase that writes outside the host's own
  storage.

  The **alias probe** runs a throwaway rootless container with the `[network]` table's options
  and records four things, none of which may be assumed:

  1. the gateway address the container sees in its own route table — this is what
  **A `conditional` role in `packages/packages.toml` is converged by this phase and by nothing
  else, and only when the operator's own configuration asks for the thing it provides.** The one
  role today is `zram`, which carries `systemd-zram-generator`, and it is conditional because
  §3.1's promise is "absent means absent — no package": a generator in the substrate list would
  make that false on every host the list was copied onto. The drift line names the package *and*
  the reason it is wanted, because on a host without the knob the same package is one nobody
  needs. `tools/render-user-data` renders the substrate and the harness roles only and **not**
  the conditional ones, because a machine being provisioned is not yet a configured host —
  baking the generator into every golden-VM image would make the absence untestable on the one
  machine whose job is to test it. The phase installs one the moment the knob is there, which is
  the same path a real host takes.
     `ingress.alias` is set to, and it is a literal address, never podman's
     `host.containers.internal` token, because a rendered `AddHost=` has to survive a resolver
     that is not ours;
  2. that a socket bound to `127.0.0.1:<probe-port>` **on the host** is reachable from the
     container at that address;
  3. that the connection arrives on the host with the probing **service uid** as the socket
     owner, so the `OUTPUT` accept rules can match it (§7.1);
  4. that the source address on the host side is `127.0.0.1`, not the alias.

  Any of the four failing is exit `1` naming which one, and `ingress.alias` is left empty.
  Because the alias is derived from the host's current default route and pasta recomputes it
  per container, the probe **must be re-run** when the host's default route changes: `soil
  sysctl --check` compares the recorded `alias` against the address the default route currently
  resolves to and reports drift, and a drift there means every `AddHost=` already rendered is
  pointing at an address that no longer means this host.
- `units` converges the system units of the unprivileged programs.

### 6.2 `weedr` — the privileged mutator

```
weedr service ingest <name[/ref]> --from poke <project>@<sha>
weedr service add <name[/ref]> --from <service>
weedr service remove <name[/ref]>
weedr service purge <name>                 # the only destructive verb; not on any sudoers rule
weedr service gate <name>                  # evaluate the credential gate; change nothing else.
  `ingress.alias` still matches the address the default route resolves to (§6.1). **It also
  owns `vm.swappiness`, and only on a host whose `guarden.toml` carries a `[zram]` table
  (§3.1).** A zram device is faster than a disk swap, so the kernel's default of 60 would keep
  preferring the disk and leave the device idle — the one thing an operator who asked for it did
  not ask for. The key is in the canonical set rather than beside it and, like every other key
  here, is never from a manifest. It is **absent from the set on a host with no device**, because
  absent means absent down to the last sysctl and a knob nothing on the box needs is a value
  guarden should not be writing.
                                           # No [/ref]: the verdict is per SERVICE, because
                                           # every instance shares the service's secret store
weedr service start|stop|restart <name[/ref]>   # start re-evaluates the gate
weedr service list [--json]
weedr service status <name[/ref]> [--json]
weedr service snapshot <name> [--all]
weedr service immutable <snapshot-id> <reason>   # the chattr +i escalation; sets the
                                        # flag AND records it, so the two cannot disagree
weedr service mutable <snapshot-id>                # clears the flag; the record goes with it
weedr service fork <target[/ref]> [--from <service[@<timestamp>]]   # the override; root only
weedr service rollback <name[/ref]> --to <timestamp>   # not on any sudoers rule
weedr service build <name>                    # podman build, as the service user, from its own
                                              # home. It takes no --from: a build has exactly one
                                              # tree it is ever allowed to build, and it is the
                                              # service's

weedr secret set <name> <KEY>
weedr secret list <name> [--json]

weedr port list [--json]
weedr port open <name> <public-port>     # must match a ports: entry in the manifest
weedr port close <name> <public-port>

weedr firewall list [--json]             # every rule, installed or pending, and which services
                                       # asked for it; deduplicated, so a rule two services
                                       # asked for appears once with both names
weedr firewall open <name> <rule-name>   # install one requested firewall rule; must match a
                                         # firewall: entry in the manifest
weedr firewall close <name> <rule-name>  # withdraw it; another service still asking for the same
                                         # rule keeps it in force

A `ports:` entry carries `container:` and `port:`, and **that `port:` is both the container's own
port and the public port requested for it** — one number, two meanings, because a grant is a
translation from the public port to the container's port and a peer-to-peer service exposes them
the same. So `ports: [{ container: web, port: 8080 }]` asks for public port 8080 to reach
container `web`, and `weedr port open <name> 8080` matches that entry by the number. The rule was
undefined and could not be: the manifest stopped naming a public port when `ports:` gained a
container key, and the verb's argument was left matching nothing. The registry's
`[ports] requested` carries the same numbers, not `"8080/tcp"` strings, so the grant resolves
against one shape.

weedr pin sync                 # the privileged bridge into snapper (ADR-0007)

weedr share issue <name[/ref]> <email> --until <duration>   # record a time-bounded grant to a
                                         # tunnel route. --until is required and there is no
                                         # spelling of "never"; a value above [share] max is
                                         # refused. A route whose destination is `edge` is exit 2
                                         # naming the route and its destination. Not on any
                                         # sudoers rule.
weedr share revoke <id>                  # end one issuance immediately
weedr share list [--json]                # live, expired and revoked, with their deadlines
weedr share reconcile                    # recompute the vendor's Access policies from the record

weedr module list [--json]
weedr module add <name>
weedr module remove <name>

weedr project list [--json]
weedr project add <name> --repository <url> [--environments <mapping>]
weedr project remove <name>
weedr project keys <name> [--json]
weedr project grant <name> <pubkey>
  **It also converges the zram device, when the operator's `guarden.toml` carries a `[zram]`
  table, and builds no zram item at all when it does not** (§3.1). "No item" is the mechanism,
  not a conditional scattered through the phase: the device's configuration, its marker, and the
  predicate that asks the kernel whether it holds are three items appended by one call, so a host
  with no knob gets none of them and `--check` has nothing to say about zram. When the knob is
  present, `--apply` swaps any existing device off, reloads the manager so the generator runs and
  turns the configuration into `dev-zram0.swap`, and starts it — and it does so **without
  depending on what the device was**, because neither `disksize` nor `comp_algorithm` can be
  written to an initialised device, so a changed percentage converges only if the old one is torn
  down first. When the knob has been *removed* and the marker is present, one item converges the
  other direction: the device is swapped off, reset, hot-removed and both files deleted, which
  is the property `sysctl` has and a create-only converge never can. The marker is what makes
  that possible — nothing else on the box says which of two zram devices guarden made.

weedr project revoke <name> <pubkey>
```

There is no `weedr redeploy`: deploying is `furrow deploy`, and a mutator that also deploys is
two programs wearing one name. `remove` has the alias `rm`; nothing else does.

`weedr service list` is the status command: name, track, uid, publications with their
allocated ports, granted public ports with anything pending marked `pending`, volumes with
their snapshot counts and effective retention, the deployed sha, the snapper configuration
names, and the instances for an instance track. It also reports the effective firewall state and
one host invariant guarden cannot enforce and one it can. Either puts the box outside this
design, and both are checked by `soil sysctl --check` and reported here:

- **IPv6 has been re-enabled.** Every rendered rule is IPv4 and the design has no IPv6 story.
  guarden disables it and an operator can undo that; all guarden can do is notice.
- **`net.ipv4.ip_unprivileged_port_start` is not `1024`.** The check is against the **value
  `1024`**, not against "the distribution's default", and that is a correction: a distribution
  or a base image that ships `0` — a common setting in container images and in anything
  tuned for convenience — would satisfy "the distribution's default" while every unprivileged
  process on the box could bind a privileged port. The predicate has to be the invariant, not
  the baseline.

  `soil sysctl` therefore **sets it to `1024`** and owns that key. An earlier revision said
  guarden "must not set" it, on the reasoning that the setting is an operator's. That
  reasoning conflated two different acts: *lowering* the threshold grants every unprivileged
  uid the right to bind any privileged port, and is refused; *raising* it to the kernel default
  is a tightening that establishes §1.4 as a fact rather than a convention, and is exactly what
  guarden should do. The result is that "nothing unprivileged on the host binds below 1024" is
  a value guarden converges, like the snapshot retention values in §8.1, and `--check` reports
  drift against it.

`weedr secret set` writes nothing readable: it prompts with the terminal echo off and encrypts
into `/etc/guarden/creds/<name>/<KEY>.cred` mode `0600`, then asks the credential materialiser
to run. Which key that encryption uses is stated once, here, and nowhere else may imply
otherwise: `systemd-creds --with-key=host` for a host key at
`/var/lib/systemd/credential.secret`, or `--with-key=tpm2` to bind it to the machine's TPM. The
`auto` setting is **not** used precisely because its meaning varies with the hardware — it
prefers a TPM2 key when it finds one, so a box with a TPM would silently encrypt with a
different key than the runbook describes. `weedr secret list` prints key names and whether each
is set, never a value.

`weedr port open` takes a public port that the manifest must already have requested, and
refuses anything else with exit `2` naming the request it would have to be — an admin cannot
open a port the repository never asked for, because a grant with no manifest request has no
container to translate to (§4) and rendering it would be inventing a destination. It creates
the service's `overrides.toml` if absent, adds the public port,
renders `50-services.conf` whole, prints the diff against what is installed, and installs it —
all under the `firewall` lock. A public port another service already forwards is refused with
exit `1` and the holder named.

**A public port no manifest requested may not be granted at all**, and this reverses the older
rule. A grant is a translation to a publication, a publication is allocated per container, and
a request naming only a public port names no container — so the grant had no destination and
the renderer had nothing to render. An operator who wants a port open is editing the
repository's `ports:` list, which is the request, and then running this. That is the same
direction of travel as every other grant in the system: the manifest asks, the admin decides,
and neither can do the other's job.

`weedr firewall open` is the same shape of act for the same reason, and §7.7 is its contract: it
installs a rule the manifest asked for by name, renders `50-services.conf` whole, prints the
diff and installs, all under the `firewall` lock, and refuses with exit `2` anything the
manifest did not ask for. Two services asking for one rule is not a conflict — deduplication is
a property of the set (§7.7) — so there is no holder to name and no exit `1` case here. What
`weedr firewall list` reports, and its field set, is in §1.2 and §7.7.

There is no prune verb, by decision. Container and image reclamation is podman's own storage
management, run as the service user (`podman system prune`), and putting a destructive verb
behind the mutator would be a second way to delete something without the confirmation the
mutator asks for everywhere else.

`weedr pin sync` is the mark reconciler: root, under the `snapshots` lock, computing the
desired snapper marks from the pin files and the registries (§8.5). `stakes` owns the files and
the queries and runs unprivileged; the noun appears in both because it is one concept with two
sides, and these are the only two verbs on it.

`weedr project grant` appends to `/etc/ssh/authorized_keys.d/hose` a line of the form
`command="/usr/lib/guarden/bin/hose --project <name>",no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty <type> <key>`, refusing a key that is not ed25519 and refusing a project that does not exist. `revoke` removes that project's lines and nothing else.

The forced command carries the project and the verb's own argument list does not, so a client
cannot name a different project even by asking (§6.7). `hose` **refuses an invocation carrying
`--project` at all** with exit `2`, because sshd appends the client's own command and a
client-supplied `--project` would be the last occurrence and therefore the one that won. The
forced command is the only source of the project name at runtime.

`weedr module add <name>` appends the module's name to `[modules] enabled` in `guarden.toml`
and rewrites nothing else in the file, under the `modules` lock and through the §3.5 protocol.
It then, for the module's declared services, does everything a service needs: creates the
service from the module's own unit source, installs the units, creates any group the module owns
(`gate-traefik` owns `edge` and adds the edge's service user to it), and converges the edge's forwarding
by invoking `soil firewall --apply`.

**The mutator does not write `20-ingress-nat.conf`; it calls the program that does.** An earlier
revision of this step had the mutator re-render the file itself, which put a second writer on a
file the layout table says has exactly one, and did it with no `firewall` lock — the precise
stale-render failure the lock exists to prevent. Calling `soil` is not a violation of the
renderer's separation either: ADR-0012's rule is that the mutator never runs a program **over
repository input**, and `soil firewall` reads `guarden.toml` and the module directory, both
root-owned. The two steps that touch the module list and the ingress therefore do not nest: the
`modules` lock is released before the `firewall` lock is taken, and `soil firewall` re-reads
`guarden.toml` under that lock rather than trusting what `weedr module add` saw.

**A module grants no port, no firewall rule and no mount.** `module.toml` (§3.6) declares
`name`, `requires`,
`[[services]]` with `service`/`ingress`/`api`, and `[[switches]]` with `program` — there is no
port key, no rule key and no mount key, and an earlier revision of this paragraph said a module
"grants the ports and mounts the module declares", which named two things the schema does not
have. A module ships services, and a service's ports and firewall rules come from its manifest
and an admin's `overrides.toml` like any other service's (§7.7). The
`ingress` a module declares is the module's **own** contribution
to the forwarded set, which is configuration rather than a grant, and it is the one ingress list
the design has: `[ingress] forwarded` in `guarden.toml` is not read by anything and is not in the
shipped table.

`weedr module remove <name>` is the inverse, and its steps are stated because a half-removed
module is the failure this verb exists to prevent. In order, under the `modules` lock and the
`firewall` lock:

1. Refuse if any service the module installed is not the module's own — refused with exit `1`
   naming it. A module never removes a service it did not create.

   **This is the one caller exempt from the gated-drop refusal.** `weedr module add gate-traefik` installs
   `traefik-production` on a `gated = true` track, and `weedr service remove` is refused outright
   there, so removing the module that installed it would otherwise be impossible. The exemption is
   narrow and is not a flag: the module removes exactly the services in its own `[[services]]`
   list, it is a root action, and removal moves volumes aside rather than deleting them
   (§5.3). `weedr service purge` — the destructive verb — is not reachable from it, and the
   operator is told on stdout which gated services were removed, because a module removal is not
   something they did.
2. For each of the module's services, `weedr service remove` them. Volumes are **moved aside**,
   never deleted, so a module removal is reversible with `weedr service add`; nothing here
   destroys data, and `weedr service purge` is not reachable from a module removal.
3. Remove the module's name from `[modules] enabled` in `guarden.toml`, through the protocol.
4. Call `soil firewall --apply`, which re-renders `20-ingress-nat.conf` from the **remaining**
   enabled modules' declared ingress and installs it, so the ports this module declared stop
   being forwarded. The mutator does not write that file, because `soil` is its only writer.
   Without this step a removed module's ingress rules would outlive it, since the module removal
   is what changed the input and nothing else would notice.
5. Re-render the edge's routes and the dashboard from the remaining services (§6.9).
6. Remove the group the module owns **only** if no remaining service is in it, and report the
   group removal on stdout. A group in use is a `warning:` line and exit `0`, not a failure.
7. **`[[switches]]` is reference-counted by module name, and that is why `installed_by` exists.**
   Two modules switch the same program on — `gate-traefik` and `auth-authelia` both switch on `roots` — so
   removing `gate-traefik` must not switch `roots` off out from under `auth-authelia`. The rule: after step 6, for
   each program this module switched on, remove it only if **no other enabled module's
   `[[switches]]` names it**, and report what stayed with a `warning:` naming the module that
   still wants it. Without the count the two cases are indistinguishable, and switching `roots`
   off would silently stop the edge's route renderer for a service that still needs it.

A module that declares no services still converges the ingress and the route set, so removing
it is never a no-op.

### 6.3 `loom` — the renderer

```
loom render <source-dir> --service <name> --out <unit-dir> [--instance <escaped-ref>]
loom check <source-dir>
```

Unprivileged and pure: the same manifest, the same registry, the same overrides and the same
configuration always produce the same bytes. It reads the manifest, the registry, the
referenced overrides and the environment table, and writes quadlet units, a `.volume` unit for
every declared volume — `state` and `bulk` alike, since a container must be able to mount
either — an environment file, the host entries, the credential requests, and the rendered
slices that the mutator installs into `/var/lib/guarden/shared/<name>/` for `roots` and `twig`.

`loom` **must** refuse rather than guess, with the code §1.2 gives each case.

**The renderer owns the container's network backend.** Every generated unit carries
`Network=pasta:` followed by the `[network] pasta_options` from `guarden.toml`, verbatim and in
order, and the renderer **replaces** any `Network=`, `PodmanArgs=`-adjacent network option or
`network_mode` the unit source asked for rather than passing it through — the same treatment
`PublishPort` gets, and for the same reason: a Compose `network_mode: host` that survived
rendering would give a repository the host's whole network namespace, and a pasta option list
that survived would let a repository remove the host mapping the connectivity model rests on.
A unit source naming a backend other than `pasta` is refused with the key named.

**The renderer owns the published-port set completely.** It strips every `PublishPort` line
found in the unit source, from Compose or from hand-written quadlet, and regenerates the
whole set from the grants and the allocations. Without this the grant model is advisory,
because a Compose `ports:` entry becomes a `PublishPort=` line verbatim.

The renderer refuses, with the directive named: `PodmanArgs=`, `--privileged`, `cap_add`,
`cap_drop`, `devices`, `network_mode: host`, `pid: host`, `userns_mode`,
`network_mode: container:`, and any host-path bind outside the service's own volumes,
`/etc/guarden`, and the paths the admin listed in `mounts.allow`.

**A `firewall:` entry is validated here and installed nowhere.** The renderer checks the closed
shape of §4 and refuses the same malformed input it refuses everywhere else, and it writes the
entry into the registry as a *request* for the mutator to read — it renders no firewall rule,
because a renderer that emitted rules would be a second writer on `50-services.conf` with no
`firewall` lock, which is the precise failure §3.5's lock exists to prevent.

**These refusals are guardrails against accidents, not a security boundary.** A unit source is
arbitrary configuration and a text check cannot be a boundary. The isolation boundary is the
per-service uid and the `0700` on its tree.

Repository YAML is parsed with `safe_load` only. The default loader constructs arbitrary
Python objects, and the mutator must never run anything over repository input.

For a `@sensitive` or `@required` key, `loom` emits a **credential request** and never a value:
`Secret=<KEY>,type=file` in the `[Container]` table, and nothing else. Podman resolves `<KEY>`
from that service's own secret store and presents it inside the container at
`/run/secrets/<KEY>`. A key the manifest's schema marks as needing an environment variable gets
`type=env` instead, and the application reads the variable. No value ever passes through the
renderer, because the renderer has none.

**The generated unit carries no `LoadCredentialEncrypted=`,** and must not. These units run in
the *service user's* user manager, which cannot read the system host key: it is `0600 root`, and
a user manager has no business holding it. The decryption happens once, root-side, in the
credential materialiser, which is why that unit exists; by the time the renderer runs, the value
is already a podman secret and the renderer only names it.

Units are rendered from `templates/` with jinja2, not from heredocs, and a changed template
changes the output on the next run.

### 6.4 `roots` — the edge's routes

```
roots sync
```

Reads the rendered route slice of every service from `/var/lib/guarden/shared/<name>/` and
renders the edge's file-provider configuration into `/var/lib/guarden/edge/dynamic/`, which is
`guarden:edge 2750`. The edge's user is in `edge` and is not in `guarden`. `roots` **must not**
write outside that directory.

With the auth-authelia module installed, a route declaring `auth: true` gets the forward-auth rule aimed
at the service named in `/etc/guarden/edge/auth-provider`, which must be the name of an
existing service in a gated track; anything else is exit `1` and no configuration is written.
The auth service's own routes never carry the rule. With the module **not** installed, `roots`
emits the route without a middleware and writes a single `warning:` line naming the service and
the route, once, on every sync — so `auth: true` in a manifest is never silently ignored.

`roots` has no intermediate route format. If the edge is ever replaced, `roots` is replaced.

### 6.5 `twig` — the dashboard

```
twig sync
```

Merges every service's widget files, copied through from the shared directory **unparsed**,
into `/var/lib/guarden/shared/dashboard/`, which `weedr module add homepage` creates
`guarden:guarden 0755` and the dashboard service reads. `twig` runs as `guarden` and the
shared directory is root-owned and read-only to it, so a *new* path was needed: there was
previously no directory `twig` could write to at all, and `twig sync` — a verb the `homepage`
module ships enabled by default — could not run. `twig` **must not** write outside that
directory. It parses no widget content: it validates the `widgets:` entries in the manifest
against the container set the shared parser produces, and copies the files the manifest names.
It generates only the grouping and the per-project links, from `projects.toml`.

This is a third `shared/` shape and it is stated rather than left implicit: `shared/<name>/` is
root-owned and read by the renderers, `shared/dashboard/` is `guarden`-owned and written by
`twig`, and the split is exactly the writer/reader line the edge's directory already draws.
Adding a second writer to `roots` would need a new group, and the design keeps two groups on
purpose.

### 6.6 `furrow` — the deploy queue

```
furrow deploy <name[/ref]> [--from poke <project>@<sha>] [--sha <sha>] [--now]
furrow preview drop <name> <ref>
furrow queue list [--json]
furrow queue show <service>
furrow status [--json]
```

One request at a time per build lane. Priority comes from the track's `weight`, and a manifest
**must not** be able to state a priority. Requests for the same service and sha collapse into
one. `--now` skips queue position for this request only. Queue state is a directory of files
under `/var/lib/guarden/queue`, so `ls` answers what is waiting and a reboot does not lose an
accepted request.

**`--from` is required when the service does not exist, and it never takes a path.** The only
form is `poke <project>@<sha>`, and the mutator builds
`/var/lib/guarden/staging/<project>/<sha>` itself. `<project>` is checked against the project's
`projects.toml` entry and `<sha>` must be hex, so **the path is assembled by the system from two
validated components and there is nothing for a caller to traverse out of.** This replaces a
staging-confinement design that was correct and needless: `--from <dir>` made the caller choose a
location, and the only question was how much checking to wrap around it.

Two rules follow from the type rather than from a check. **A `furrow deploy` with no `--from` and
no registry entry is exit `1` naming the service** — not a silent redeploy of whatever exists,
and not a path taken from the current directory. And **a hand-run `furrow deploy` names a
project and a sha, never a folder**, so an operator at a terminal uses the same two-argument form
CI does and there is no second, looser path for a human to take.

`--from` **may** be omitted when the registry already has an entry, in which case the render
uses the manifest and unit source already in the service's home and `--sha` records what is
being deployed. That is the re-deploy case.

The steps, in this order, and the order is the point (ADR-0011):

0. **Ensure the service exists.** If the registry has no entry, call
   `weedr service ingest <name> --from poke <project>@<sha>` with the sha the poke carried.
   The mutator resolves that pair to `/var/lib/guarden/staging/<project>/<sha>` itself; `furrow`
   never names a path, and neither does any other caller. This is where a poke creates a service,
   which is why `hose` needs no `weedr` verb at all.
1. Render with `loom`.
2. Build, if the unit source has a build instruction: `weedr service build <name>`, which runs
   `podman build` **as the service user** on the service's own tree, tagged with the image
   reference the manifest names.

   **`weedr service build` takes no `--from`, and that is the fix rather than a restriction.** It
   used to take one, and the staging confinement written for `weedr service add --from` was never
   copied to it — a separate verb on the same sudoers rule, simply not mentioned, and
   `podman build` executes arbitrary `RUN` steps, so an unconfined `build --from <dir>` let a
   `guarden` program, or a poke key through the `(guarden)` hop, run code as any service uid from
   a tree it chose. A build has exactly one tree it is ever allowed to build and it is the
   service's own, so the argument is gone rather than confined. The build is a mutator verb
   because an unprivileged `furrow` cannot become the service user, and because the subuid range
   belongs to the service user and only it may map container-root into it. A failure exits `1`
   and the running container is still running.
3. **Gate, before the stop.** `weedr service gate <name>` evaluates the credential gate and
   changes nothing else: for a gated track, every key the schema requires exists in the service's
   own podman secret store with a value that is neither empty, nor prefixed `EXAMPLE-`, nor
   equal to `changeme`. It records the verdict in the registry and returns. It is a mutator verb
   because the store is inside the service's `0700` home and only root can read it — an earlier
   revision had `furrow` evaluate the gate, which no permitted verb could support, since the only
   secret-reading verb on its rule returns booleans and never a value.

   **A blocked gate does not fail the deploy.** The deploy has done what it was asked: the
   service exists, the image is built, the units are installed, and the container is not started.
   So `furrow` reports `warning: deployed, waiting for the credential gate — reason: …` and
   **exits `0`**. A red X on every push until the operator plants credentials is noise, and noise
   teaches people to want the gate gone. The operator then plants the credentials and runs
   `weedr service start <name>`, which re-evaluates the gate and starts if it now passes. **No
   second push is needed**, and the gate's verdict — which until now existed only in the journal
   — is a field in the registry.

   For a track with `gated = false`, a missing or example value produces a `warning:` line naming
   the key, the gate records `not-required`, and the start proceeds. That is the whole difference
   between the two tracks, and it is the only difference.
4. Stop the units.
5. Install the rendered units, record the sha, reload the user manager, and then **start only if
   step 3 recorded `ready` or `not-required`.** A blocked gate stops the sequence here: the units
   are installed, the user manager is reloaded, the container is not started, and `furrow`
   reports the `[gate] reason` and exits `0`. `furrow` does **not** call `weedr service start` on a
   blocked service and then convert its exit `1` into a `0` — it reads the verdict step 3 recorded
   and branches, so the verb that says `1` and the deploy that says `0` are never both spoken
   about the same attempt.

   The consequence for an existing service is the property ADR-0011 orders for: a blocked gate
   never reaches step 4, so the running container is untouched. For a service that is being
   created for the first time there is nothing to stop, and the same sequence leaves it installed
   and waiting.

Only builds are queued. A deploy that pulls a prebuilt image competes for no resource with
anything and does not go behind a build lane.

`furrow` is unprivileged and calls the mutator through a sudoers rule. The rule is written out
in full, because "unprivileged" is a property of the file and not of the reader's assumption:

```
guarden ALL=(root) NOPASSWD: /usr/lib/guarden/bin/weedr service ingest, \
    /usr/lib/guarden/bin/weedr service remove, /usr/lib/guarden/bin/weedr service gate, \
    /usr/lib/guarden/bin/weedr service start, \
    /usr/lib/guarden/bin/weedr service stop, /usr/lib/guarden/bin/weedr service restart, \
    /usr/lib/guarden/bin/weedr service snapshot, \
    /usr/lib/guarden/bin/weedr service build, \
    /usr/lib/guarden/bin/weedr secret list, /usr/lib/guarden/bin/weedr port list, \
    /usr/lib/guarden/bin/weedr firewall list, \
    /usr/lib/guarden/bin/weedr service list, /usr/lib/guarden/bin/weedr service status, \
    /usr/lib/guarden/bin/weedr module list
```

Note the `(root)`: `furrow` runs as `guarden` and the mutator runs as root. `weedr firewall
list` is here rather than absent because it reads the registries and the overrides, both
`root:guarden`, and needs nothing a `guarden` program cannot read — so a deploy can report a
pending rule request in the push's log the way it reports a pending port. The **writes** are
not here and never will be: `weedr firewall open` installs root firewall text, which is the same
authority class as `weedr port open` (§7.7), and neither is named.

**Every verb on that rule is granted whole, with no exceptions for particular arguments, and
that is the property the whole grants design rests on.** A sudoers command with no argument
specification matches any arguments, and sudoers has no negation, so `--grant-ports` and
`--purge-state` could not have been withheld on a verb that carried them: a rule permitting
`weedr service remove` would have permitted `weedr service remove --purge-state` and a rule
permitting `weedr service add` would have permitted `weedr service add --grant-ports`. The
resolution was to remove the flags rather than to try to constrain the arguments, and to make
each capability its own verb:

- **No flag on a granted verb widens authority.** `weedr service ingest` takes `--from poke
  <project>@<sha>` and nothing else; the grant is `weedr port open`, a different verb that is not
  on the rule. So a poke can create a service and leave its ports pending, which is ADR-0006's
  rule arriving through the mechanism that enforces it.
- **Nothing on the rule destroys data.** `weedr service remove` moves volumes aside; the verb
  that deletes them is `weedr service purge`, and it is not on the rule. No program that answers
  a poke can destroy data, and the sudoers file is where that is true rather than a sentence
  beside it.
- **`weedr service fork` and `weedr service add` are both off the rule, and that is what makes
  production's empty lineage structural.** Both carry a source, and the source is the only thing
  that can change where a service's tree or data comes from. The automatic fork on a
  `fork_from` track is a *step inside `weedr service ingest`*, not a verb the deployer calls, so
  there is no `fork --from` for a poke to reach — and `production` has `fork_from = ""`, so an
  ingest of a production service starts it empty and a poke cannot ask for anything else. An
  operator who wants to fork a staging database into production does it by hand with the root
  `weedr service fork <target> --from myapp-staging`, which is deliberate, recorded in the
  call log, and not something a workflow key can do.
- **`weedr service gate` is on the rule and that is safe**, because it *evaluates and changes
  nothing*: it reads the schema and the service's own secret store, records a verdict, and
  returns. The gate it records is re-evaluated by `weedr service start` every time, so a wrong
  verdict — the only thing a compromised `guarden` program could produce here — cannot start
  anything, and the worst case is a stale line in the registry.
- **`weedr service rollback` was removed from the rule**, and the operator keeps it as a root
  verb. It replaces a service's current volumes with a clone of an old snapshot, so it is
  destructive in the way `purge` is, and it used to be gated only by a `--yes` the rule could not
  distinguish from any other argument. `furrow` never rolls anything back — the deploy sequence in
  ADR-0011 has no such step — so nothing needed it, and **rolling a production database back is
  an operator's deliberate act, made as root, with no program between the decision and the
  subvolume operations.** An indirection there would be a liability, not a convenience.

The verbs it may name are exactly the ones in the block. Never `weedr port open`, `weedr port
close`, `weedr firewall open`, `weedr firewall close`, `weedr service purge`, `weedr service
rollback`, `weedr module add`, `weedr project add`, `weedr project grant`, `weedr project
revoke`. The rules name the long form of each verb, because a rule naming `weedr service rm`
would not match it.

### 6.7 `hose` — the gitops receiver

```
hose poke <ref> <sha> [<environment>]   # source tar archive on stdin. <environment>
                                       # only when the ref's allowlist grants more than one track
hose drop  <ref>
hose check                 # verify this project's ability to deploy. Exits 0 or 1.
```

**There is no `<project>` argument, and its absence is the whole of the per-project binding.**
The project is a property of the key, not of the request: it arrives in the forced command
`weedr project grant` writes, and there is no way for a client to supply or override it. This
was not the previous design. `hose --project <name> <verb> <project> <ref> <sha>` looked
equivalent, and was not: sshd *appends* the client's command to the forced command, so a key
holder for project A could send `--project B …`, and every conventional argument parser takes
the **last** occurrence of a repeated option — the client would have won, and one repository's
CI key would have deployed another repository's project. Deleting the client-supplied project
removes the class of bug rather than one instance of it, and it is the reason the forced command
in `/etc/ssh/authorized_keys.d/hose` is the only place a project name appears at runtime.

The same reasoning fixes the second hole. `hose drop <ref>` **derives** the service name from
the project and the ref through the allowlist and never accepts one; it calls `furrow preview
drop <name> <ref>` with a name it computed. The previous signature took a free-form `<name>`,
which let a key for one project drop any preview instance on the box.

The only network-facing program, holding no privilege beyond a sudoers rule naming exactly:
`furrow deploy`, `furrow preview drop`, `furrow queue list`, `furrow status`, `weedr project
list`.

**It cannot drop a service, cannot grant or revoke a port or a firewall rule, and cannot read a
service's status at all.** `weedr port open`, `weedr port close`, `weedr firewall open`,
`weedr firewall close` and `weedr service remove` are the verbs that could change something and
none is named.

`weedr service list` **was** on this rule, and it had to come off: this rule's runas target is
`(guarden)`, not root, so `weedr service list` invoked here ran with no read on a service's
`0700` tree and could not return the per-volume snapshot figures its contract promises. The same
verb is on the `guarden` rule with runas `(root)`, so it had two behaviours depending on which
rule reached it — a class of bug worth naming generally, because **a verb's output depends on
its runas target, and a verb that appears on two rules with different runas targets has two
contracts.** `weedr service list` is a root read, so it is root-only. `weedr project list` needs
nothing private and stays. A poke can therefore see which projects are registered and nothing
else about the box, which is less than it could and more than it needs. Its rule is

```
hose ALL=(guarden) NOPASSWD: /usr/lib/guarden/bin/furrow deploy, \
    /usr/lib/guarden/bin/furrow preview drop, /usr/lib/guarden/bin/furrow queue list, \
    /usr/lib/guarden/bin/furrow status, /usr/lib/guarden/bin/weedr project list
```

so a poke reaches a root program only by way of one that is itself unprivileged, and the
`(guarden)` is what makes that a property of the file rather than of a reader's assumption.
Installing a poke key is privileged — writing an `authorized_keys` line is a root action — so it
belongs to `weedr project grant`.

The ref maps to a track through the project's allowlist, read from `projects.toml`. A poke
unpacks the archive into `/var/lib/guarden/staging/<project>/<sha>/` and calls `furrow deploy
--from` that directory; `furrow` creates the service. Requested public ports stay pending and
are reported as a `warning:` line naming them and the exact command to run, which reaches the
workflow log.

**The per-project directory is created when the key is installed, not when the poke arrives.**
`hose` is unprivileged and `staging/` is `0755 root:root`, so it cannot create a subdirectory
there at all; `weedr project grant` creates `/var/lib/guarden/staging/<project>/` owned by the
`hose` user, and `weedr project revoke` removes it. The staged tree is then `0755` with `0644`
files so that `guarden` can render it and root can read it, because `hose` is deliberately not a
member of the `guarden` group — it may read `projects.toml` and nothing else under
`/etc/guarden`, and the world bits on a transient source tree are the price of that. **A service
can read another project's staged source while a deploy is in flight**, which is stated rather
than hidden: the tree contains no secret, because a repository contains none.

**Whoever created the tree removes it, which for a poke means `hose` and not `furrow`.** The tree
is owned by the `hose` user, `furrow` runs as `guarden` and has no write on it, and a design in
which `furrow` deleted a tree it cannot write to was wrong in the same way the creation was.
`hose` removes `/var/lib/guarden/staging/<project>/<sha>/` after `furrow deploy` returns,
whatever that deploy exited with, so a failed deploy does not leave a tree behind either. The
per-project parent directory survives for the next poke and is removed by `weedr project revoke`.
A `furrow deploy --from` invoked by hand at a terminal leaves the tree, because the caller is a
human who chose the path, and `furrow` prints a `warning:` naming the path it did not remove.

Unpacking is hardened: extracted as the `hose` user under `umask 022`, with no absolute member
names, no `..` component, no preserved ownership, and no symlink followed. A member that
escapes the target directory is refused and the poke fails without touching a service. The
staged tree contains no secret, because a repository contains none, and it is removed after
the deploy.

`hose drop` removes an instance through `furrow preview drop`, and the refusal for a gated
track is enforced root-side in `weedr service remove` against
`/etc/guarden/allow-gated-drop` — `hose` never reads that file.

**`hose check` verifies rather than announces.** It was a verb that printed "not implemented"
and exited `0`, which is a stub, and a stub in a document set whose standard is that there are
none is worse than no verb. It now answers one question a workflow can use before it pushes:
**could a poke for this project deploy right now?** In order — the project is in
`projects.toml`; the key's forced command names this project and only this project; the
per-project staging directory exists and is writable by the `hose` user; the ref asked for maps
to a track through the allowlist; and the `guarden` group can read the files `furrow` needs. Each
check is a `warning:` line naming what failed, and the exit is `1` if any failed, `0` if all
passed. It reads nothing it is not already allowed to read and changes nothing, so it is safe for
CI to call on every push.

**`--project` must appear exactly once in `argv`, and that occurrence is the forced command's.**
This is the whole rule and it is the second time a client-controlled argument has been
load-bearing in this program. sshd builds the command line by concatenating the forced command
with whatever the client sent, so a legitimate invocation is exactly
`hose --project <name> poke <ref> <sha>` and a client that sends nothing adds nothing. A client
that sends `--project other` produces two occurrences, and **two is exit `2` naming the key** —
which is the answer, and it is not "refuse any `--project`", because the forced command supplies
one and refusing those would refuse every poke. Counting occurrences is what makes the forced
command's value unforgeable: whichever of the two a parser reads, both are the same string in the
legitimate case and the invocation is rejected in the illegitimate one. A parser that took the
last occurrence would be wrong here, which is why the count is checked before the value is used
and not instead of it.

### 6.8 `stakes` — pins

```
stakes pin <snapshot-id> [note]
stakes unpin <snapshot-id>
stakes list [--json]
stakes query <snapshot-id> [--json]
```

A snapshot id is `<service>:<volume>@<number>`, and nothing else. A colon cannot appear in a
service name or a volume name, so the id is unambiguous in a way a dash is not:
`other-app-production-pgdata-41` could be a service called `other-app` with a volume called
`production-pgdata`. `stakes pin` creates one file and is idempotent.

`stakes` runs as `guarden`, and a service's tree is `0700` to that service, so **`stakes` cannot
read a service's snapshots and does not pretend to.** It reports the pin files it owns and,
for each, which services name it as a seed — its own files and the registries, both readable.
Everything that requires reading a state volume comes from a root read instead: `weedr service
list --json` reports, per state volume, the total, the marked, the oldest, the newest, and the
effective `NUMBER_LIMIT` and `NUMBER_LIMIT_IMPORTANT` read back with `snapper get-config`. That
is the shape disk and snapshot-count monitoring consumes, and the division is stated here so it
is not a surprise in a monitoring script.

### 6.9 What triggers what

| trigger | runs |
|---|---|
| end of `weedr service ingest` / `add` / `remove` / `fork` / `rollback` | `roots sync` and `twig sync`, as the `guarden` user |
| `guarden-sync.path` on `/var/lib/guarden/shared/` | the same, so an edit made outside the mutator still converges |
| `guarden-queue.path` on `/var/lib/guarden/queue/` | `furrow`, which drains the queue; no daemon. A `.path` on a directory the triggered program also writes to can re-trigger itself as it dequeues, so the unit carries `TriggerLimitIntervalSec` and the drainer removes a request file only after it has finished with it |
| `guarden-pins.path` on `/var/lib/guarden/stakes/` and `/var/lib/guarden/registry/` | `weedr pin sync`, under the `snapshots` lock |
| `guarden-snapshots.timer`, daily | `weedr service snapshot --all`, then `weedr pin sync` |
| `guarden-snapshots-cleanup.timer`, every 15 minutes | snapper's cleanup, under the `snapshots` lock, replacing the packaged unit |
| `guarden-creds.path` on `/etc/guarden/creds/`, and `guarden-creds-boot.service`, a boot-time oneshot | the credential materialiser. Both are named here because a runbook that told an operator to `systemctl start guarden-creds.service` would name a unit that does not exist, and this pair is the only place a blob is decrypted |
| a poke | `furrow deploy` |

There is no long-running daemon. Every recurring job is a `.path` or a `.timer` unit running a
oneshot.

### 6.10 Start order

A service's start order is expressed in the **system** manager, not in the user managers, and the
mechanism is one target per service. A unit in one service's user manager cannot require a unit
in another's — the two are different dependency graphs and systemd does not cross them — so a
consumer's container units carry only an `After=guarden-order.target` drop-in, and the real edges
live in a root-owned `<name>.target` per service:

- **`guarden-order.target`**, `Wants=` every enabled service's target, installed in the root path.
- **`<name>.target`**, `Wants=` and `After=` the targets of the services the manifest declared
  under `needs:`. `loom` emits the edges; the mutator installs the file and converges
  `/etc/systemd/system/<name>.target.wants/`.
- The service's quadlet drop-in gains `After=guarden-order.target`, which is the only way a
  user-manager unit can depend on something in the system manager.

The edges are `Wants=`, not `Requires=`. A provider that is down does not prevent its consumers
from starting; the consumer's first dial fails and it retries. A hard requirement would let one
dead database take down everything that declares it. **No boot wave and no fixed delay**: a
service with no edges starts in parallel with everything else, and the graph is a dependency
graph, not a sequence. ADR-0011 is the binding decision.


---

## 7. Connectivity, ports and ingress

**The host firewall is `ferm`, and the whole of it is `ferm`** (§6.1): no `ufw` rule, no firewalld
zone, no nftables table written by hand and kept in step, and nothing anywhere in this system
that writes, reads or reconciles a `ufw` rule. That has one consequence for this whole section,
which is worth stating once: **every service's rules come from the same render**, whether a module
installed it, a poke deployed it or an operator typed the command, so there is no per-service
firewall to keep in step with the host's. The rules are ferm stanzas in
`/etc/guarden/firewall/`, and ferm compiles them to iptables, so `iptables-save` reads the
running set and always has.

### 7.1 What pasta actually gives a container, and what the host firewall actually sees

A rootless container runs in its own network namespace, so the host's `127.0.0.1` is not an
address it can dial and a per-service `127.x` scheme is unreachable from inside it by
construction. What a container can dial is the **default gateway address**, because pasta maps
it. From `pasta(1)`:

> `--map-host-loopback addr` — Translate `addr` to refer to the host. Packets from the guest to
> `addr` will be redirected to the host. **On the host such packets will appear to have both
> source and destination of `127.0.0.1` or `::1`.** … *Default is to translate the guest's
> default gateway address, unless `--no-map-gw` is given.*

So there is exactly one address a consumer can reach the host on, it is the gateway address the
container already has a route for, and **pasta performs the translation itself, in userspace,
at layer 4** — before the kernel's packet path and therefore before any firewall rule is
consulted. guarden installs no rule of any kind for this hop. The three consequences that shape
the rest of this section:

- **The alias belongs in `AddHost=` and nowhere else.** At the point the host's `OUTPUT` chain
  sees the connection it is already `127.0.0.1:<publication>`, so every rendered rule's
  destination is `127.0.0.1`. `ingress.alias` is a *name the consumer resolves*; it is never a
  firewall destination, and a rule that matches on it matches nothing.
- **The only host-side control that can see this hop is an `owner` match in `OUTPUT`.** Pasta
  makes its sockets as the service user, so `-m owner --uid-owner` matches. Nothing in the
  `nat` table participates and nothing could.
- **The alias is derived, not chosen.** Pasta takes it from the host's current default route and
  recomputes it whenever a container starts. `guarden` therefore owns the pasta option set
  (§3.1) and re-measures on a trigger (§6.1); a host whose gateway changes invalidates every
  `AddHost=` already rendered.

**An application inside a container must listen on `0.0.0.0`, not on `127.0.0.1`.** Pasta
rewrites a loopback destination to the guest's observed address before delivery, and
`--host-lo-to-ns-lo` — the option that would preserve it — is documented as usually undesirable
because it exposes namespace-local services to the host. An application bound only to its own
loopback inside a container is therefore reachable from nowhere, which reads as a firewall
problem and is not one.

Ticket 15 measures this on a real machine before anything is built on it, and ADR-0004 is
reopened if the measurement fails. Nothing here is assumed; §6.1 states what the probe records.

### 7.2 One namespace

All services share one loopback port namespace, and every publication is on `127.0.0.1`. Two
services **must not** be given the same publication, and the allocator refuses the second.

### 7.3 Names

There is no name map and no `/etc/hosts`. For each edge, the renderer writes into every unit of
the consumer:

```
AddHost=<provider-service>:<ingress.alias>
```

so the consumer resolves the provider's **service name** — the same string, with no suffix and
no alias — to the host's loopback alias. The edge's route target is
`<provider-service>:<publication>`, resolved the same way inside the edge's own units. A
generated environment variable per edge carries `DB_HOST` and `DB_PORT`, and for a database
edge the credential arrives as `/run/secrets/DB_PASSWORD`.

### 7.4 Publications

A **publication** is a loopback port allocated from `ingress.publication_range`. Publications
are the only ports anything in guarden binds. One is created for every container named in a
`routes:`, `ports:` or `needs:` entry, and for the edge's API when its module declares one. A
`ports:` entry is included because a grant is a translation to a publication: without it a
peer-to-peer service that exposes a public port and declares no route and no dependency would
have a requestable port and no destination to translate to.
The allocation is persisted in the registry, so it is stable across regenerations and unique
per service and instance — which is what lets several instances of one preview service be
routed at the same time.

The manifest never names a publication. It names a container and the container's port, and
guarden picks the loopback port.

### 7.5 Public ports are forwarded, never bound

A public port is a port the outside world uses. It becomes reachable only through a grant, and
a grant produces an address translation rule from the public port to the service's
publication:

```
net.ipv4.conf.<ingress-if>.route_localnet = 1        # set by soil sysctl, per interface
nat PREROUTING  -i <ingress-if> -p tcp --dport 80  -j DNAT --to-destination 127.0.0.1:<pub>
nat PREROUTING  -i <ingress-if> -p tcp --dport 443 -j DNAT --to-destination 127.0.0.1:<pub>
nat PREROUTING  -i <ingress-if> -p udp --dport 443 -j DNAT --to-destination 127.0.0.1:<pub>
```

**There is no `POSTROUTING` masquerade, and adding one does nothing.** After the `PREROUTING`
translation the packet's destination is a local address, so it is delivered to `INPUT` and never
reaches `POSTROUTING`. On the way back, connection tracking unwinds the destination translation
and rewrites the reply's source to the public address the client dialled, so the reply leaves
with the source the client expects and is accepted. A rule of the form
`-o <ingress-if> -d 127.0.0.1 --dport <pub> -j MASQUERADE` matches **no packet in either
direction**: the forwarded packet is local, and the reply's destination is the client. An earlier
revision of this document required that rule on the grounds that a loopback source is
unacceptable to an external client; that reasoning was wrong, and the requirement has been
removed rather than kept as a harmless superstition, because a rule that claims to be
load-bearing and is not is worse than no rule at all.

Two things about a loopback destination are worth stating because they surprise operators:

- **The service sees the client's real address, not `127.0.0.1`.** `PREROUTING` DNAT rewrites the
  destination only, so the socket's peer is the original client. The edge therefore logs real
  client addresses, and any application that requires a loopback peer — a socket that refuses a
  non-loopback remote — needs a per-application `nat INPUT -d 127.0.0.1 -m conntrack --ctstate
  DNAT -j SNAT --to-source 127.0.0.1`. That is an operator workaround for one application, not
  part of the design, and it collapses every client onto one source address, so the edge's logs
  stop identifying who called.
- **`route_localnet` is the whole requirement.** Without it the kernel treats a packet addressed
  to `127.0.0.1` arriving on a non-loopback interface as a martian and drops it. With it, the
  routing decision succeeds and the packet is delivered locally.

**No service ever binds a non-loopback address**, and there is no such thing as a "private"
versus "public" bind. A granted port that is not one of the edge's is forwarded by the mutator
in `50-services.conf`, under the `firewall` lock. A port the manifest requested and the admin
has not granted is simply not forwarded, which is what "pending" means.

`route_localnet` is scoped to the ingress interface, which resolves from
the default route and is overridable as `host.interface`.

**`REDIRECT` does not work here.** `redirect` rewrites the destination to the incoming
interface's own address, and the edge only listens on loopback, so nothing would be there.
Only `DNAT` with an explicit loopback destination is correct.

Those three are the **edge's** forwarded ports, and they are the only ports the edge's
entrypoint answers on: 80/tcp for the redirect and the ACME HTTP-01 challenge, 443/tcp for TLS,
and 443/udp for HTTP/3 from the same entrypoint, whose absence costs nothing. A granted port
belonging to another service is a fourth kind of rule, in a different file, and the long list of
"common ports" is almost entirely services reached from the inside, which is a publication and
needs no forwarding rule at all.

Two consequences an operator must know. Locally generated traffic does not traverse
`PREROUTING`, so a health check, a smoke test or the structural verification **must** target
`127.0.0.1:<publication>` and not the public name. And there is no hairpin translation, so
another machine on a local network cannot reach the box by its public name.

The edge's API and dashboard are a control surface, not ingress: published on loopback,
restricted in `OUTPUT` to `host.admin_user`, and never forwarded.

### 7.6 Isolation between services

Two layers, and both are real, with their exact limits stated.

**The loopback is closed by default, and the publications are the only way in.** Because pasta
maps the gateway (§7.1), **any** container can otherwise reach **any** host loopback port
through the alias — `sshd` on 22, a database the operator runs by hand, anything. So the
rendered set in `OUTPUT` is a **default deny on the whole of loopback for every service uid**,
with the accept rules above it. Order is the whole of it: accepts first, then one drop.

```
filter OUTPUT
  -A guarden-svc -d 127.0.0.1 --dport <pub> -m owner --uid-owner <allowed-uid> -j ACCEPT
  ... one per (publication, allowed uid) ...
  -A guarden-svc -d 127.0.0.53 -p udp --dport 53 -m owner --uid-owner <service-uid> -j ACCEPT
  -A guarden-svc -d 127.0.0.53 -p tcp --dport 53 -m owner --uid-owner <service-uid> -j ACCEPT
  ... one per service uid, the host's stub resolver and nothing else ...
  -A guarden-svc -d 127.0.0.0/8 -j DROP

**There is no interface match, and `-o lo` was removed from this example as
redundant rather than as a decision.** The kernel routes the whole of
`127.0.0.0/8` locally — `ip route get 127.0.0.1` answers `local 127.0.0.1 dev lo` —
so a destination in that network is only ever reachable over loopback, and
naming the interface says the same thing twice. It was never emitted: `git log -S
'o lo' -- src/guarden/firewall.py` returns nothing, and an assertion that `50-
services.conf` carries `-o lo` was checking a property the code has never had.

**The final rule matches no uid at all.** An earlier version put
`-m owner --uid-owner <every-service-uid>` on it, which meant a uid that is not a service user —
`guarden` itself, `hose`, an operator's own shell, a package's system user, anything on the box —
matched nothing and, under a default `ACCEPT` policy, reached every publication and `sshd`. A
default deny that enumerates who it applies to is not a default deny. The accepts carry the owner
match because they are the only place a uid is named; the deny carries none because it is the
rule that needs no exceptions.
```

The accept set is the same one each publication already had, unchanged: the edge's uid for every
route publication, a consumer's uid for each edge it declared, `host.admin_user` for the edge's
API, and for a granted public port the service itself, its declared consumers and the admin
(§7.4). The service's **own** publication is in the set, or a service could not be reached by
the edge that is supposed to reach it.

**The host's own stub resolver is the one destination that is not a publication, and it is
rendered as an accept like every other.** systemd-resolved's stub listens on `127.0.0.53`
port 53, over **both** protocols, so a service uid carries two accepts for it — `udp` and
`tcp` — exactly as it carries an accept per publication, with the same owner match and above
the same deny. **The address is `127.0.0.53` and never `127.0.0.0/8`**, and the port is 53 and
nothing else, so every other loopback destination and every other port on that one are still
refused. The uid set is the service uids and no other: the rule cannot be widened by a
manifest, an `overrides.toml`, a module or a poke, and there is no key that adds one. It is
drawn from guarden's knowledge of what the host runs rather than from configuration, so it is
not the `[loopback] allow` table ADR-0013 removed — see ADR-0015 for that distinction, which
is the whole of what makes this rule safe to render unconditionally.

**This is what the deny must not be confused with.** The drop is on `-d 127.0.0.0/8`, and
it does not touch outbound traffic: a package update, a git fetch and a call to the outside
world leave on the real interface and are unaffected. **It did touch name resolution, and an
earlier revision of this document claimed it did not.** The claim rested on pasta's exclusion
of its DNS forward from the loopback mapping ("traffic identified as DNS, originally directed
to the `--map-host-loopback` address … is not translated to loopback, but rather handled in the
same way as if specified as `--dns-forward`"), and that is true — **of traffic from inside a
container.** `podman pull` is not inside a container: it runs on the host as the service user,
the packet leaves through `OUTPUT`, `OUTPUT` jumps to `guarden-svc`, and the deny is on
`127.0.0.0/8`, which contains the resolver. Measured on a real machine by reading the deny's
own packet counter across one UDP send from a service uid to `127.0.0.53:53`:

```
DENY_COUNTER_BEFORE=0
DENY_COUNTER_AFTER=1
```

So the resolver was unreachable from every service uid and **no first deploy of a new
workload could complete**, which is a much larger claim than the sentence it replaced was.
An even earlier revision of this document justified leaving loopback open on the grounds that
a blanket drop "would break name resolution and package updates". The package-update half was
wrong and the name-resolution half turned out to be right for the wrong reason and the wrong
layer; both claims are gone, and the resolver accept above is the measured answer. The claim
survived as long as it did because nobody ran `iptables -S`; `docs/sysadmin.md` used to say
the firewall files were ferm source and that `iptables -S` "shows you nothing", which is not
true.

**There is no `[loopback] allow` table, and the reason is the rule, not the name.** A key whose
whole content is "this destination" is a second way to grant a destination beside the publication
set, and two ways to grant one thing are two ways for it to be wrong. §7.7's `[firewall] allow`
is not that: it names rules a repository asked for by name and carries no destination of its own,
so it cannot become a way to reach a loopback port without somebody typing that rule in full.
**Nor is the stub resolver's accept above:** it is one destination guarden derives from the host
it is running on, and adding a second one is a change to the code and to this spec rather than a
key an admin fills in (ADR-0015).

**A service that needs a host loopback port which is not a publication should make that daemon a
service**, and that stays the default answer. It is a default rather than a prohibition now,
because §7.7 exists: an admin may grant a service the rule text that opens one, and the rule it
grants is a grant of the same authority class as `weedr port open` — root, made by hand, on no
sudoers rule. The honest cost is one line, and it belongs here rather than in a footnote: a
granted rule is rendered above the default deny, so a rule that matches `-o lo` and accepts
**does** reopen loopback for exactly the match it names, and the default deny stays last rather
than stopping it. Nothing else about the loopback posture changes — the deny is still the last
line of the chain, the accepts are still the ones guarden renders from the registries, and the
renderer still owns all of them.

The owner match is **not** used in `INPUT`. A forwarded packet has no socket, so an owner
match there is unreliable and the edge's traffic would be dropped. `INPUT` accepts the
published ports plainly; the uid restriction happens in `OUTPUT`, where it works.

The rules are rendered in full from the union of all grants, all allocations and every granted
firewall rule (§7.7) — one set, so deduplication is a property of it and needs no mechanism —
written atomically, and the diff against the installed set is printed before installation, all
under the `firewall` lock.

Every rule is IPv4, because `soil` disables IPv6. An operator who re-enables it is outside the
design, and `weedr service list` says so.

### 7.7 A service may ask for a firewall rule, and only an admin may install one

Almost everything a service needs is the edge: `routes:` publish it over HTTPS and the kernel
forwards 80/tcp, 443/tcp and 443/udp to the edge, and a service whose whole outside life is HTTP
never touches this section. What is left is the service the edge cannot speak for — a WireGuard
endpoint, a full node's peer port, a protocol from a source range the operator wants to name
rather than imply. A manifest may **ask** for those rules and an admin may **install** them, and
that is the whole of the model: the request is repository input and has no effect at all, and the
grant is a root-owned verb on no sudoers rule.

**A request.** A `firewall:` block in the manifest (§4), one entry per rule, each with a `name`
that is unique within the manifest, a `chain`, and the `rule` line itself:

```yaml
firewall:                            # firewall rules this service asks for; none is installed
  - name: wireguard-peer             # the grant names this, and it must be stable in the repo
    chain: guarden-svc               # one of guarden's own chains; the default, and today the only
    rule: "-p udp --dport 51820 -j ACCEPT"
```

The `rule` is **one iptables-shaped rule line**, which is the dialect ferm emits and the dialect
`iptables-save` prints back, so a request can be read against the running ruleset without knowing
ferm's stanza syntax. It matches `^-` followed by option tokens and exactly one `-j` or `-g`
target; the pattern is **closed** rather than a list of prohibitions, for the same reason
`host:` is (§4): an open rule shape is an open grant shape.

A request is **purely additive, and that is enforced by the shape and not by a rule that checks
for badness.** A request may add a rule to a chain guarden owns. It may not open, close, rename
or flush a chain or a table, may not set a policy on one, and may not jump to a chain guarden does
not render. Anything of that shape is exit `2` naming the rule and the key. The chains that may
be named are a **closed set** — `guarden-svc` today, the chain guarden owns and jumps to from
`filter OUTPUT` — and growing that set is a change to this spec rather than a configuration
change. So a repository can widen the rule set by one line and only by one line, and it can never
remove a rule guarden rendered, reorder one, or take the policy of a chain away from guarden.

**A grant.** `weedr firewall open <name> <rule-name>` adds the rule's name to
`/etc/guarden/services/<name>/overrides.toml`:

```toml
[firewall]
allow = ["wireguard-peer"]           # requested rule names the admin has agreed to install
```

and renders `50-services.conf` whole, prints the diff, and installs it, all under the `firewall`
lock, exactly as `weedr port open` does. `weedr firewall close <name> <rule-name>` removes it and
re-renders the same way. A rule no manifest requested **may not be granted at all** — exit `2`
naming the `firewall:` entry it would have to be — because the manifest asks and the admin
decides, and a grant with no request behind it is an admin typing firewall text into a file
nobody will later find the counterpart of.

**A granted rule is a grant of root firewall authority, and it is priced like one.** It is not on
any sudoers rule, it is not a flag on a verb that is, and `weedr service ingest` cannot reach it,
so a poke leaves every requested rule pending and says so in the push's log the way it says so for
a pending port. What an admin is agreeing to is one rule line, not a service's intentions: the
grant is the rule, and a rule that matches more than its author expected matches more than they
expected. That is the honest limit and it is stated in `SECURITY.md` §2.5 and ADR-0013 rather
than discovered.

**Where it lands.** guarden's own accepts first — the per-publication accepts and the stub
resolver's (§7.6) — then the granted rules, then the single default deny — **last**, always.
Position is guarden's and not the request's: a request carries no
position field, so a grant can never be rendered into a part of the chain where the default deny
has already matched, and the invariant that every accept precedes the single deny survives a
grant. **A grant may not replace the resolver's accept either**, because the resolver's accepts
are rendered from the host rather than asked for and are in the set whatever any manifest says.

**Deduplication is by content, and the count is by name.** Two services whose manifests ask for
the same rule line produce **one** rule in `50-services.conf`, carrying the names of both, because
the render is a pure function of a set (§7.6) and a set has no duplicates. The two grants are
independent: `weedr firewall close` on one service leaves the rule while the other service still
asks for it, and the rule disappears when the last one closes. That is the same reference count
`[[switches]]` gets by module name (§6.2), and it is why `weedr firewall list` reports a rule
once with every service behind it rather than once per service.

**`weedr firewall list` is the inventory, and it answers two questions at once.**

```sh
weedr firewall list                 # every rule, installed or pending, and who asked for it
weedr firewall list --json
```

```
RULE                                  CHAIN         STATE      SERVICES
-p udp --dport 51820 -j ACCEPT       guarden-svc   installed  wireguard-staging, wireguard-production
-p tcp --dport 22 -j ACCEPT          guarden-svc   pending    myapp-staging
```

`--json` reports `rules` — one object per **rule text after deduplication**, each with `rule`,
`chain`, `file` (the ferm file it is installed in), `granted` (bool), and `requested_by`, a list
of `{ service, name }`. It is a read of the registries and the overrides, both `root:guarden`, so
it needs no privilege a `guarden` program lacks and it **is** on the `guarden` sudoers rule
(§6.6) beside `weedr port list`; a deploy can therefore report a pending rule request the same way
it reports a pending port. It is not on `hose`'s rule, for the reason `weedr service list` is not:
a poke learns which projects exist and nothing about the host's rule set.

**Removal.** `weedr service remove <name>` drops that service's grants with its
`overrides.toml` and re-renders, so a rule it alone was holding leaves the ruleset. A removed
service's rule is neither orphaned nor silently kept: the grant file goes with the service
(§5.3), and the mutator is the only writer of the `[firewall]` table in it.

**A module grants nothing here either.** `module.toml` (§3.6) declares no rule, and `weedr
module add` installs a module's services with their requests **pending**, exactly as a poke's
services are. A module's service may ask for a rule in its shipped manifest; an admin installs it
with `weedr firewall open` like any other, and removing the module leaves nothing granted to
remove.

---

## 8. State, snapshots, lineage

### 8.1 Volumes and soil's canonical values

Every declared volume, `state` or `bulk`, is a btrfs subvolume owned by the service user. A
`state` volume also has a snapper configuration named `<service>-<volume>`; on an instance
track, `<service>-<escaped-ref>-<volume>`. A `bulk` volume
has none, is never snapshotted, is never a fork or rollback source, and is created empty by a
fork.

**A configuration's name is opaque, and nothing parses it.** Workload names and volume names may
both contain `-`, so `<service>-<volume>` cannot be decomposed back into its parts, and code
that tried would be wrong for any service named `my-app`. `soil storage` therefore never reads
the track out of the name: it reads `registry/<name>.toml`, which records the service's
`environment` as a field, and takes `free_limit` and `keep_last` from the environment table row
for that field.

**The skip rule is narrower than "a name I do not recognise".** It has exactly three cases and no
others, because a rule that skips whatever it does not recognise silently drops configurations the
operator owns:

- **A service's configuration** — the name matches a registry entry, so the track is read from the
  registry and the retention values come from that track.
- **`root` and `home`**, the host's own. These are converged with the **fixed set only** —
  `EMPTY_PRE_POST_CLEANUP`, `NUMBER_MIN_AGE`, `NUMBER_CLEANUP`, `TIMELINE_CLEANUP` — and **no
  ladder value and no `FREE_LIMIT` is written for them**, because no track owns them and there is
  no track to read a default from. Their ladder is left as the distribution shipped it. Nothing
  snapshots them on a schedule, so their limits govern only what a human gets who runs `snapper`
  by hand there, and that is a human's own housekeeping rather than a policy guarden owns. An
  earlier revision applied the skip rule to these two as well, which meant every
  `soil storage --apply` emitted two warnings and never converged the host at all.
- **Anything else** is a configuration guarden did not create, so it is **skipped with a
  `warning:` line naming it** and left byte-for-byte alone. This is the "every configuration it
  can see" in the phase description, and "can see" is doing the work: seeing means a name that
  either matches a registry entry or is one of the host's two.

A configuration for a **removed** service is the case that matters most, and it is the second
branch: `weedr service remove` deletes the service's `state` subvolumes, and `soil storage` is
what removes their snapper configurations. They are gone before the next `soil storage --apply`
runs, so there is no stale configuration to skip.

`soil storage` converges this fixed set of values into **every** configuration it can see and
rewrites nothing else in them — **and a configuration is created with the same set**:
`weedr service ingest` writes each state volume's configuration from the identical list
(`volumes.canonical_values`), so a service is never live with a value `soil storage` would have
to come along later and change. The two lists are held to each other by `t30-create`'s pins on
the create-time values and `t20-storage`'s on the converged ones:

| key | value | why |
|---|---|---|
| `EMPTY_PRE_POST_CLEANUP` | `no` | guarden only creates `single` snapshots, so the empty-pre/post cleaner has no pre/post pair to act on and disabling it costs nothing — which is the reason, and it holds whatever that cleaner does with marked snapshots |
| `NUMBER_MIN_AGE` | `3600` | in **seconds**, snapper's unit for this key, and the reason is so that a brand-new snapshot cannot be reaped before the reconciler has seen it |
| `NUMBER_CLEANUP` | `yes` | snapper prunes; guarden never deletes |
| `TIMELINE_CLEANUP` | `yes` | so the nightly schedule is snapper's own |
| `TIMELINE_CREATE` | `no` | snapper's default is `yes`, which lets the distribution's `snapper-timeline.timer` take snapshots **guarden never made** — hourly, on every configuration it can see. guarden's own snapshots are the only ones the design has, and one such uninvited snapshot is what turned a service-tree chown's walk into an EROFS (measured 2026-10-12); the cleanup half of the timeline mechanism is wanted, the creation half is not |
| `TIMELINE_LIMIT_HOURLY` | `0` | guarden snapshots on a daily schedule, so an hourly bucket is the operator's to fill by hand |
| `TIMELINE_LIMIT_DAILY` | `0-<keep_last>` | from the track's `keep_last` |
| `TIMELINE_LIMIT_WEEKLY` | `0-4` | |
| `TIMELINE_LIMIT_MONTHLY` | `0-6` | |
| `TIMELINE_LIMIT_QUARTERLY` | `0-2` | |
| `TIMELINE_LIMIT_YEARLY` | `0` | |
| `NUMBER_LIMIT` | `2-10` | for the `number`-tagged snapshots only; a range, so the free-space pass has a floor |
| `NUMBER_LIMIT_IMPORTANT` | `8-12` | the **minimum** is what survives disk pressure; see §8.5 |
| `FREE_LIMIT` | from the volume's track `free_limit`, or its `overrides.toml` | snapper reads it as a **percentage of the filesystem's free space**: the number-cleaner starts deleting marked and unmarked snapshots when free space falls below it. So `0.10` means "prune only when the filesystem is within 0.1% of full", which is the conservative end, and the shipped tracks put production tighter than staging |

The `TIMELINE_LIMIT_*` values are the volume's **ladder**: how many snapshots to keep per time
bucket, aged between buckets by snapper as they get older. A daily cadence fills the daily
bucket, and snapper moves those snapshots up into the weekly, monthly and quarterly buckets as
they age, so one nightly timer produces a full ladder rather than a flat window. A bare
`NUMBER_LIMIT` of ten, by contrast, keeps the newest ten whatever their age — about ten days
for a daily snapshotter, and no history at all beyond that.

`keep_last` and `free_limit` in a service's `overrides.toml` override the track's defaults.
Nothing in a manifest may set any of this. `soil storage --check` reports drift when any of
these values differs, which is the only way the retention policy is ever verified.

**`keep_last` is the daily bucket's maximum, and nothing else.** It is not a total, and setting
it to `0` does not mean "keep nothing": it makes `TIMELINE_LIMIT_DAILY` `0-0`, while the weekly,
monthly and quarterly buckets keep their shipped `0-4`, `0-6` and `0-2`. A staging or preview
volume with the shipped `keep_last = 0` therefore still retains up to **twelve** snapshots —
four weekly, six monthly, two quarterly — because those are the ones that have aged out of the
daily window. That is a defensible default for a low-priority track and a surprising one, so it
is stated here rather than left to be discovered: **an operator who wants a track to keep
nothing must set the weekly, monthly and quarterly limits as well, through `overrides.toml`, and
`soil storage --check` will then hold them there.** The alternative — making `keep_last = 0` a
shortcut for "no ladder" — would put a second way to express the same policy in the file, and
this document's whole position is that a second place to set a thing is a second place for it to
be wrong.

### 8.2 Snapshots

`weedr service snapshot <name>` creates, for each **state** volume, one snapper snapshot with
a timestamped description, and records the newest number per volume in the registry. `--all`
snapshots every service with a state volume, which is what the nightly timer uses. Bulk volumes
are skipped and the command says which ones.

There are two kinds of snapshot and they are tagged differently, because they are governed by
different mechanisms:

- **A routine snapshot** — what the nightly `--all` makes — is tagged `timeline`, and the
  volume's **ladder** decides how long it lives. These are the volume's history.
- **An on-demand snapshot** — a fork source, or an operator's "before the risky change" — is
  tagged `number`, and `NUMBER_LIMIT`, `NUMBER_LIMIT_IMPORTANT` and the marks decide. These are
  the ones a fork can be taken from, so they are the ones worth protecting.

**Snapper's subtree is snapper's, and every walk owes it an exception.** A snapshot is a
read-only btrfs subvolume, so any recursive operation over a path that can contain one —
`service._make_tree`'s chown walk over the service tree above all, and the removal paths that
follow it — skips any path with `.snapshots` among its parts (`paths.SNAPSHOTS`); a chown on a
snapshot is an EROFS and a `rmtree` cannot delete it, which is why the destructive paths delete
the snapper configuration first (`snapper delete-config` takes the subtree with it). Measured
2026-10-12, once in sixty runs, when the distribution's timeline timer had written a snapshot
no guarden path knew about.

`--tag` is not a flag. The kind follows from why the snapshot was taken, because that is what
determines who is allowed to delete it later.

It does **not** stop the service, does not lock, and does not wait. A btrfs subvolume snapshot
is atomic, so a clone is consistent as of that instant and the service's engine recovers from
it; nothing in guarden depends on which engine it is.

**`weedr service immutable <snapshot-id> <reason>` is the only way to escalate one snapshot, and
it does both halves in one call.** It sets `chattr +i` on the snapshot subvolume and writes
`[immutable]` in the provider's registry with the operator's reason. They have to be the same
verb: a flag set without a record is an escalation nobody can find later, and a record without a
flag is a lie. `weedr service mutable` clears the flag and the record together. The verb is
**root** and is not on any sudoers rule, because `chattr +i` needs `CAP_LINUX_IMMUTABLE` and
because this is an operator's decision about a production artifact.

**A pin is not the same thing, and conflating them was a defect.** `stakes pin` raises the
snapshot to `important=yes` under the number cleaner (§8.5), which is a *retention* effect the
cleaner respects up to a budget; `chattr +i` is a *deny* that no limit overrides and that aborts
the whole cleanup for its configuration. A runbook that told the operator to "record it as a pin"
was pointing at the weaker of the two and adding a side effect they had not asked for. The two
compose — pin a snapshot and make it immutable — but they are separate acts and each has its own
verb.

A service with several state volumes gets several snapshots in one operation. btrfs has no
atomic multi-subvolume primitive — one destination name and one source per ioctl — so the
volumes are individually consistent and may be microseconds apart. That is a cost the
particular service must judge: a configuration volume beside a bulk media library does not
care, two volumes that must agree byte for byte should not be snapshotted together.

Snapshot state is read with `snapper --machine-readable json --config <config> list`, because
JSON renders a snapshot's `userdata` as an object while CSV renders the whole map as one quoted
blob. The effective configuration is read back with `snapper get-config`, never by parsing the
file in `/etc/snapper/configs/`. Writes never use `--no-dbus`, because without the daemon there is
no inter-process coordination at all.

**Three facts about that read are normative, and all three are measured on snapper 0.10.6, the
version `soil packages` installs.** They are here because an earlier revision of this section
wrote the option after the command and expected a list, and every reader written from it read
nothing:

- **`--machine-readable` is a global option and precedes the command.** Written after `list` it
  is not an option of `list` at all, and the tool answers `Unknown option '--machine-readable'
  for command 'list'` and exits `1`. That is the shape behind a snapshot that was taken and
  cannot be read back, and nothing in the answer says which option was wrong.
- **The document is an object keyed by the configuration's name** — `{ "<config>": [ … ] }` — and
  not a list. A reader that expects a list has to treat the mismatch as a **failed** read rather
  than as an empty configuration, because §8.5 makes the two mean opposite things.
- **The first entry is `number 0`, and it is not a snapshot.** It is the live subvolume, described
  `current`, with an empty `date` and no `cleanup` tag; snapper issues snapshot numbers from `1`
  and its cleaners never consider `0`. Every figure computed from this read — total, marked,
  oldest, newest, the newest number, and every number a fork or a rollback addresses — is a figure
  about snapshots, so entry `0` is excluded. Counting it would report a configuration that has
  never been snapshotted as holding one, and one that holds one as holding two.

### 8.3 Lineage

Seeding is decided by the track and never by the manifest. Each track's environment table row
carries a `fork_from` field naming the track it forks from, and the shipped rows are:

| track | `fork_from` | meaning |
|---|---|---|
| `production` | `""` | starts empty |
| `staging` | `"production"` | the same workload's service in that track |
| `preview` | `"staging"` | the same workload's service in that track |

**A track is never recognised by its name.** `fork_from` is a field, so `preprod` forking from
`staging` is a row in `guarden.toml` and not a code change, and a track with a `fork_from` naming
a track that does not exist is exit `2` naming both. The previous form of this table keyed on
the literal words `production`, `staging` and `preview`, which contradicted §3.1's rule that
nothing in guarden branches on a track's name and meant the fourth track in the environment
table could not fork at all. A `fork_from` naming the track's own name is refused as a cycle.

`fork_from` may name a `kind = "slot"` or `kind = "instance"` track; the fork itself refuses an
instance source for a `state` volume, because an instance's volumes are not the service's (§8.4).

`--from` overrides, and names `<service>[@<number>]`. There is no manifest key for this, and a
manifest containing one is refused by name.

Adding a service on a track that forks takes a snapshot of the source if it has none newer than
the target's recorded seed, then forks. The whole thing is one command, so a first `staging`
service does a fork and the call log shows it; a first `production` service does not, and the
call log shows no fork. A `preview` service forks from staging; the preview service itself is
created empty and its first instance does the fork, so the log shows the service created and
then the instance seeded.

### 8.4 Forks

`weedr service fork <target> [--from <source>[@<number>]]`:

1. Validate the complete set: for every **state** volume of the target, resolve the source
   snapshot — the target's recorded `seed` for that volume, or the one at or before the
   `--from <service>@<timestamp>` time if one was given. **A number is never used to name a set,
   because a service with several state volumes has a different number in each configuration and
   no single number can mean the whole set.** If any volume resolves to nothing, exit `1` having
   changed nothing, naming that volume.
2. Pin the source snapshot for the duration, by creating its pin file.
3. Stop the target's units.
4. Move each target state subvolume aside to `<vol>.replaced.<timestamp>`.
5. For each state volume, create the clone: `btrfs subvolume snapshot <source-snapshot> <target>`,
   then clear the read-only flag, then set ownership to the target's user.
6. For each bulk volume, create an empty **subvolume** owned by the target's user, with no snapper
   configuration — a bulk volume is always a subvolume, in every path. A bulk volume is
   never cloned from a live volume: a copy as of an instant is not reproducible afterwards, and
   a fork that quietly produced different data on two targets would be worse than an empty one.
7. Record `seed` per state volume in the target's registry.
8. Start the target, and release the pin.
9. On any failure, move the replaced subvolumes back, start the target, release the pin, exit
   `1`. Nothing is left half-swapped.

The clone is copy-on-write, so the source is never written to and needs no writable buffer of
its own — the clone is the buffer. `btrfs property set <path> ro false` requires btrfs-progs
5.14 or later; the version is checked and reported, not worked around.

### 8.5 Retention

Pruning is snapper's. guarden never runs a delete loop and never calls `snapper delete`.

A snapshot that is still wanted is marked: `snapper -c <config> modify --cleanup-algorithm
number --userdata "important=yes, guarden=<referencing-service>" <number>`. Both halves matter
— the `number` cleaner reads only the `important` mark, and only snapshots tagged `number` are
its candidates.

`weedr pin sync` computes the desired mark for every snapshot from three sources and calls
`modify` only where reality differs:

1. every file in the pin directory is marked;
2. every snapshot named as a `seed` by any service's registry is marked;
3. nothing. The ladder governs routine snapshots and `keep_last` is its daily bucket, so the
   reconciler never marks one; a mark is only ever about an on-demand snapshot.

It adds before it removes, it is idempotent, and if its state cannot be read it stops rather
than clearing anything. A snapshot's `guarden=` key names the service that wants it, so a human
reading `snapper list` can see why, and a mark written by something else is distinguishable.

**A mark is a priority with a budget, not a promise.** `NUMBER_LIMIT_IMPORTANT` is a min-max
range, and the free-space pressure pass keeps up to the *minimum*. Under genuine disk pressure
marked snapshots are reaped, oldest first. This is accepted: it only happens when the disk is
nearly full, which is the signal worth having, and the floor is a number the operator chooses.

The mark governs the **number**-tagged snapshots. The routine history is governed by the
**ladder**, which is the right home for a retention count: `keep_last` is the daily bucket's
maximum, so `keep_last = 7` on a production volume means seven daily snapshots aged up into the
weekly, monthly and quarterly buckets — a bounded, spread-out history rather than a flat window
of the newest few. The ladder's ranges are likewise bounded by the same pressure pass, so no
retention promise here is absolute, and the runbook says so.

`weedr service snapshot` never marks a snapshot, because a routine snapshot is not a fork
source. A fork takes a snapshot if the source has none newer than the target's recorded seed,
and that snapshot is `number`-tagged precisely so the mark can protect it.

The lock exists because snapper takes none that `modify` participates in. Its per-config lock
lives in the daemon, is advisory, is released when a client disconnects, and is not checked by
the method behind `modify`; the cleaner takes one reference to the snapshot list and reuses it
across all three passes, so a mark written during a running cleanup is lost silently. And
`snapper list` holds the config lock for its whole duration, so a reconciler that lists in a
loop can stall cleanup. So `soil` disables the packaged cleanup timer and installs one that,
together with the reconciler, takes `/run/guarden/locks/snapshots.lock`.

The escalation, per snapshot, by operator decision, recorded with its reason in the registry:
`chattr +i` on the snapshot's subvolume. The btrfs delete ioctl checks the victim inode for
immutability and returns `EPERM`, which no snapper limit overrides, and btrfs does not inherit
immutability so a fork still works. It is an escalation rather than the default because
snapper's cleaner has no per-item error handling: the first candidate it cannot delete aborts
that configuration's whole cleanup for that run. It is a deny, not a keep-N. `chattr -i`
restores normal pruning.

Read-only is **not** a pin. The cleaners never consult it, and every snapper btrfs snapshot is
read-only by default. It is used after a fork to confirm the clone's flag was cleared.

### 8.6 Rollback

**`--to` takes a timestamp, not a snapshot number, and that is the fix rather than a
restriction.** A service with several `state` volumes has a *different* snapper number in each
of their configurations, so there is no single number that names a set — `--to 41` is 41 in
`data` and something else entirely in `cache`, and choosing which reading was intended was
guesswork. The volumes are snapshotted together, microseconds apart (§8.2), so **a time selects
a consistent set**: the mutator takes, for each `state` volume, the newest snapshot at or before
that time, and refuses the whole operation with exit `1` naming any volume that has none. That is
also the operator's actual mental model — "back to yesterday" — and it cannot be half-resolved.

A single snapshot is still individually addressable, and nothing is lost: the pin syntax
`myapp-production:data@41` names one snapshot of one volume exactly (§6.8), and an operator who
means a specific number reads it with `weedr service list --json` and rolls back to the
timestamp that snapshot carries.

`weedr service rollback <name[/ref]> --to <timestamp>` validates the complete set as in §8.4,
stops the service, replaces each state volume with a clone of that snapshot, and starts it.
Refused outright on a track with `gated = true`, with no flag that overrides it — the verb is not
on the `guarden` sudoers rule at all, so this is a refusal an operator can only lift by
conceding, in their own judgement, that rolling back production is the wrong next action.
Rollback restores data only: units, credentials and
configuration come from the manifest, so after rolling back a database, redeploy the service
too if the application schema also moved.

---

## 9. Previews

A track with `kind = "instance"` holds one service per workload and one instance per ref. Its
`cap` bounds concurrent instances **per service**, which is per workload and environment. When
a create would exceed it, the oldest instance is removed **before** the new one is created, so
the cap is never briefly exceeded and a failure during creation cannot leave the count above
it. The `preview-cap` lock is held across counting, the eviction **and the new instance's
registry entry**, so the count can never be observed mid-flight.

A manual redeploy does not make an instance newer; the ordering is a property of creation and
cannot be gamed by redeploying.

Route hosts for an instance are a **path prefix** on one host: `preview.$DOMAIN/<ref>`. All
previews of all projects therefore share one host, which means no wildcard certificate, no
per-ref DNS and no per-ref public port.

---

## 10. Precedence

Exactly one rule, applied in this order, and nothing else overrides anything:

1. The manifest declares what a service is made of: its containers, its volumes, its edges, the
   public ports it *asks* for, the firewall rules it *asks* for, its routes, its widgets, the
   shape of its secrets.
2. `overrides.toml`, root-owned, grants public ports, installs requested firewall rules, sets
   retention, adds supplementary groups, and lists the host paths its units may mount.
3. `guarden.toml`, root-owned, decides the environment set and the host's policy: route host
   prefixes, the credential gate, resource weights, retention defaults, ingress, the module
   set, the admin user.
4. `projects.toml`, root-owned, decides which tracks a ref may deploy to.

A repository cannot widen any of 2, 3 or 4. Routes, host entries, edge definitions, volumes and
the unit source are the repository's and no root-owned file overrides them.

---

## 11. Test seam

**Each program is a Python module with a `main`, exposed as a console script** — `soil =
"guarden.soil:main"`, `weedr = "guarden.weedr:main"`, and so on. There is no shell entry point
and no wrapper to keep in step: eight one-line shims are eight more files that must agree with
the spec, which is the drift this repository keeps fighting, and `shellcheck` on a shim that
contains no logic is checking the wrong language. `just lint` therefore runs `ruff` and nothing
else. Bash remains for scripts that only invoke and sequence.



Every test drives a command line and asserts on the exit code, the diagnostic lines, the files
that appeared or vanished, and the state the program left behind. No test imports a program's
internals. The one exception is the manifest and registry parsers, which are tested directly,
because their failure is invisible from outside until it silently drops a service's
configuration.

**One harness, and it is a real machine** (ADR-0014). `just test` cuts a throwaway LXD VM from a
golden snapshot and runs every suite in it with the real tools; `tests/lxc.sh run <pattern>` is
the same for one file. There is no second tier.

**Each suite declares whether it needs a machine of its own, in the suite itself.** One line —
`# machine: shared` or `# machine: fresh` — read by the runner, and **an absent declaration is
`fresh`**. The default is the safe answer: a suite that says nothing must never silently inherit
another suite's system users, deleted snapshots or installed packages. The declaration travels with
the suite, so a suite that forgets it gets isolation rather than a neighbour's machine. `just
test-fresh` cuts per file whatever any suite says, `just test-shared` cuts one machine for the
whole run, and either flag wins over a declaration because a declaration is a claim about a suite
and a flag is a decision about a run. Sharing is a claim and `just test-reverse` asks about it:
the same suites, the opposite order, and both runs green is the only evidence a shared suite does
not contaminate the next.

**A suite's result is cached, and an inherited result is never an observed one.** A suite passes or
fails as a function of two things — the golden it was cut from and the tree it read — so the key is
a hash of both, plus the machine it ran on: which shared group, and whether the run shared at all
and in which order. `just test` inherits every suite whose key is unchanged and prints
`inherit <suite> (green from the cache; not observed this run)`, which is not a line anyone can
read as a pass, and a summary that states how many suites ran and how many were inherited. **A
failure is never recorded**, so a suite that did not pass runs again rather than being inherited —
the property that makes a cached green worth having at all, and the reason this cache may only be
built on a suite that passes when run twice. **Nothing expires**: a result stays valid while the
golden and the tree do, so a run's meaning never depends on a clock, and a rebuilt golden — a
different `lxc info` creation time — invalidates every recorded result. `--no-cache` runs every
suite and inherits nothing; that is what a release gate uses, and its run still records, so the
next ordinary run can inherit what the gate observed. The cache lives outside the repository, under
`$XDG_CACHE_HOME/guarden/suite-results`, and `just test-cache-clear` removes it.

- **No fake exists, and `fixtures/bin` is never on `PATH`** — not in a test, not in a VM run, not
  in a developer's shell. The directory is retired. It was not a second opinion: `tests/lib.sh`
  put it first on `PATH` unconditionally and the VM runner never removed it, so the "real
  machine" tier executed against the fakes in 29 of 34 suites, and the failures that run produced
  were facts about the fake — an invented `loginctl show-user`, a group ownership no run had ever
  produced, a drift line the fake never emitted.
- **No test asserts on a call log.** A test asserts the state a call would have produced: the
  unit exists, the snapshot carries the mark, the rule is in the file, the package was not
  installed. An assertion about an argv that left no state is dropped rather than ported.
- **What the VM proves that nothing else could:** that a rootless container reaches a dependency
  **by the alias the probe measured**, and that the connection arrives on the host with the
  consumer's uid as the socket owner; that a non-member cannot connect to a declared port; that a
  clone of a live data volume starts and recovers; that **a forwarded port answers from a second
  machine**; that nothing unprivileged can bind below 1024; and that a lock is a file and a rename
  is a rename.

  The forwarded-port criterion is a test and not a proof. "A forwarded port answers from off the
  box" distinguishes one working forwarding path from none; it cannot distinguish a
  configuration that works because it is correct from one that works for a reason nobody
  intended, and the runbook says so where an operator will read it. What is asserted about the
  rule set is the thing that is actually checkable: the installed `nat PREROUTING` chain
  contains exactly one `DNAT` per forwarded port and **no** `POSTROUTING` masquerade, because
  such a rule matches no packet in either direction (§7.5) and its presence would mean the
  render carries a claim it cannot keep.

  **`GUARDEN_PREFIX` relocates guarden's own files and nothing else.** It is not a sandbox: a
  suite that runs `soil packages --apply` or `soil install --apply` under a prefix still reaches
  the machine's `apt`, its apt timers and its identity databases, because `apt-get`,
  `dpkg-query`, `systemctl`, `groupadd` and `useradd` take no prefix. Whether a suite needs a
  machine of its own is therefore a fact about which verbs it drives and not about whether it
  called `guarden_prefix`.

`just test` runs the whole suite in a throwaway VM and exits `0`; `just test-one <file>` runs one
suite in one VM, and that is the command for work in progress. There is no suite that runs
outside a machine (ADR-0014).
