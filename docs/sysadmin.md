# guarden — sysadmin runbook

Every command here is for the operator at three in the morning. Nothing in this file is
required reading before the work; it is the opposite.

---

## The five questions

```sh
soil --check                    # has the host drifted?
weedr service list              # what does guarden think is running?
weedr port list                 # what is open, and what is still pending
furrow queue list               # what is waiting, and what failed
stakes list                     # which snapshots are protected, and by whom
```

If a service is not behaving, start with its units:

```sh
systemctl --user -M myapp-production@ list-units
systemctl --user -M myapp-production@ status web
journalctl --user -M myapp-production@ -u web -n 200
```

`-M <service>@` is the syntax that works for a service whose home is under
`/var/lib/guarden` and whose units are in a user manager that may not be running under your
login session. `runuser -l <service> -c 'systemctl --user status web'` works too.

---

## Installing and updating guarden

```sh
git -C /usr/lib/guarden pull          # the programs live root-owned under /usr/lib/guarden
soil install --apply                  # re-copy them, reinstall units
weedr service list                    # confirm nothing changed underneath you
```

`soil install` is the only phase that writes outside the host's own storage. It never stops a
running service.

---

## soil phases

```
soil <phase> --check      # report drift, change nothing, exit 1 with the word "drift"
soil <phase> --apply      # converge
soil --check              # every phase
soil list                 # what each phase owns
```

Phases in order: `packages`, `storage`, `sysctl`, `firewall`, `install`, `units`.

### btrfs conversion (once, on a fresh box)

```
soil storage --check     # ok when converged; reports the reboot marker and names it
soil storage --apply     # creates @ and @var, fixes fstab
soil storage --check     # ok when converged
reboot                    # only if --check asked for it
```

State lives in `/var/lib/guarden/soil/`. Exactly one reboot is required; a second run after
success reports no drift. `/boot` stays on ext4. The same phase installs
`/etc/apt/apt.conf.d/80guarden-snapper`, whose `DPkg::Pre-Invoke` snapshots `root` before every
package transaction, creates the `root` and `home` configurations, and installs the replacement
cleanup timer. It creates **no** service volume, and a snapper configuration belonging to a service is created by
the mutator and never recreated here. Never hand-edit a snapper configuration — change the
canonical values in the phase and re-apply.

### the values `soil storage` owns

The storage phase converges one fixed set of canonical values into every snapper configuration it
finds, a service's state volumes as much as the host's own, and rewrites nothing else in them.
`soil storage --check` reports drift when any of them differs, which is the only way the retention
policy is ever verified.

| value | why |
|---|---|
| `EMPTY_PRE_POST_CLEANUP=no` | guarden only ever creates `single` snapshots, never a pre/post pair, so switching the empty-pair cleaner off costs nothing. How the cleaner treats the cleanup tag and the `important` mark is not something these documents can confirm |
| `NUMBER_MIN_AGE=3600` | a brand-new snapshot must not be reaped before the reconciler has seen it |
| `NUMBER_CLEANUP=yes` | snapper prunes; guarden never deletes |
| `TIMELINE_CLEANUP=yes` | the nightly schedule is snapper's own |
| `TIMELINE_LIMIT_HOURLY=0` | guarden snapshots daily, so an hourly bucket is yours to fill by hand |
| `TIMELINE_LIMIT_DAILY=0-<keep_last>` | the daily bucket, from the track's `keep_last` or the service's `overrides.toml`. **This row is the volume's ladder**, and `keep_last` is its daily maximum — a retention count, not a mark count |
| `TIMELINE_LIMIT_WEEKLY=0-4` | snapper ages daily snapshots up into this bucket as they get older |
| `TIMELINE_LIMIT_MONTHLY=0-6` | |
| `TIMELINE_LIMIT_QUARTERLY=0-2` | |
| `TIMELINE_LIMIT_YEARLY=0` | |
| `NUMBER_LIMIT=2-10` | for the `number`-tagged snapshots — the fork sources and the operator's own — and a range, so the free-space pass has a floor |
| `NUMBER_LIMIT_IMPORTANT=8-12` | how many marked snapshots survive disk pressure; the low end, eight, is the floor, and it is one number `soil` owns. `keep_last` does not raise it |
| `FREE_LIMIT` | the disk pressure at which pruning starts early, from the track or the service's `overrides.toml` |
| the packaged snapper cleanup timer disabled, guarden's oneshot installed | the reason is a lost mark, not a preference — see **Pins** |

None of these is a manifest key and none is settable by a repository. Read the effective
configuration back from snapper rather than from the file:

```sh
snapper -c myapp-production-pgdata get-config
```

`stakes list --json` reports the pin files it owns and the services naming each as a seed.
It cannot report the per-volume figures: `stakes` runs as `guarden` and a service's tree is
`0700` to that service, so it cannot read a service's snapshots and does not pretend to. The
totals, the marked, the oldest, the newest, and the effective `NUMBER_LIMIT` and
`NUMBER_LIMIT_IMPORTANT` come from `weedr service list --json`, which is a root read. Poll that
one for disk and snapshot counts; poll `stakes` for what is pinned and why.

### the lockout drill

```
soil firewall --apply --deadman     # arm the timer before you touch a rule
```

If ferm cuts you off, wait for the timer, or use the provider's console. The timer's arm,
duration, effect and disarm are under **Ports and the firewall** below.

---

## Verb aliases

`remove` is typed often and is the one verb an operator never wants to type, so `remove` has
exactly one alias: `rm`. It is the only alias in guarden, no other verb has one, and none will be
added. It is not derived from the long form; it is simply the one.

| long form | alias |
|---|---|
| `weedr service remove` | `weedr service rm` |
| `weedr module remove` | `weedr module rm` |
| `weedr project remove` | `weedr project rm` |

Every program's `--help` lists the alias beside the long form. A verb with an abbreviation is a
second name to keep in step. `snapper` is not one of guarden's programs and none of its verbs
gains an alias.

**The alias is for a human at a terminal.** The sudoers grants name the long form, and guarden's
own programs call it, so `rm` is not something a script, a unit, or anything running under
`sudo` should reach for. See **gitops** below for the sudoers surface.

---

## Services

```sh
weedr service ingest <name[/ref]> --from poke <project>@<sha>
weedr service add <name[/ref]> --from <service>
weedr service remove <name[/ref]>      # alias: rm
weedr service purge <name>             # the only destructive verb
weedr service start|stop|restart <name[/ref]>
weedr service list [--json]
weedr service status <name[/ref]> [--json]
```

`--from` is **required** and names a service or a poke, never a folder. A service is created from
a manifest and guarden never infers where one is
where one is.

Names carry the environment: `myapp-production`, `other-app-staging`, `postgres-production`,
`traefik-production`. The name is the service name everywhere — no suffix, no alias. A consumer
resolves it as it stands. `weedr service add myapp` with no environment defaults to **staging**,
never a gated track, and prints the resolved name. The environments that exist are the
`[[environments]]` entries in `/etc/guarden/guarden.toml`; a name whose last segment is not one
of them is refused. Operations on a track with `gated = true` are **refused outright, with no
flag that overrides them** — the only way to allow one is for you to remove the root-owned
`/etc/guarden/allow-gated-drop` marker yourself.

`weedr service add` is idempotent and it is the reconcile command. Running it against a converged
service prints `converged` and changes nothing; running it after editing a manifest re-renders
the units, the host entries and the routes, and installs the result. There is no documented path
that deletes the generated units to force a rebuild, and if you find yourself doing that you are
one step from deleting a home.

`weedr service purge <name>` is the only path in guarden that destroys data, and it is a verb of
its own rather than a flag on `remove`, so that no sudoers rule granting `remove` can also grant
destruction. It deletes the volumes instead of moving them, it asks at a terminal, it names
every volume it is about to destroy before it does, and it is refused for an instance. Everything
else moves data aside.

### where a service lives

```
/var/lib/guarden/services/<name>/home/          its home; units, image store, instances
/var/lib/guarden/services/<name>/state/<vol>/   a subvolume, with snapper config <name>-<vol>
/var/lib/guarden/registry/<name>.toml           the record
/etc/guarden/services/<name>/overrides.toml     admin grants
/etc/containers/systemd/users/<uid>/            admin units and drop-ins, uid-scoped
/var/lib/guarden/removed/<service>/<time>/<vol>/   moved, not deleted, by service remove
```

Nothing root-owned lives under `home`. If a file you expected to be protected is inside `home`,
it is not — that is the rule, and the fix is to move it.

### what an override can grant

`/etc/guarden/services/<name>/overrides.toml` is the whole of what an admin can decide, it is
`0640 root:guarden`, and it is created on first grant. A repository can widen none of it.

```toml
[ports]
open = ["8080/tcp"]              # public ports granted to this service

[retention]
keep_last = 7                    # the daily bucket's maximum; overrides the track's default
free_limit = "0.08"              # overrides the track's default

[groups]
add = ["video", "render"]        # supplementary groups for the service user

[mounts]
allow = ["/dev/dri"]             # host paths this service's units may bind-mount
```

`[groups] add` is how a hardware-transcoding service reaches `/dev/dri`: the group is added to
the service user and the renderer learns nothing about video. `[mounts] allow` is the only way a
host path outside the service's own volumes and `/etc/guarden` becomes bind-mountable at all —
the renderer refuses every other one, and an entry here is a grant in exactly the sense a port is.

Routes, edges, state volumes, the unit source and the credential schema are the repository's,
and this file does not touch them.

One thing it deliberately does not hold is the provenance of a secret value. `overrides.toml`
grants ports and sets retention; it says nothing about which keys are planted and which are
minted. The registry's `[generated]` table does, because once a value is minted into the podman
secret store it is indistinguishable from one a human planted:

```toml
# /var/lib/guarden/registry/myapp-staging.toml
[generated]
"API_KEY" = "2026-09-29T10:12:00Z"
```

A gated track gets no generated value at all. There a missing key is a gate failure, and
generating one would hide it.

### what the host should look like

Three in the morning is when somebody asks why a file is not readable, and the answer is almost
always one of these numbers.

| path | mode | owner |
|---|---|---|
| `/var/lib/guarden/services/<name>/` and everything under it | `0700` | the service user |
| `/var/lib/guarden/registry/<name>.toml` | `0640` | `root:guarden` |
| `/var/lib/guarden/shared/<name>/` | `0750` | `root:guarden` |
| `/var/lib/guarden/edge/dynamic/` | `2750` | `guarden:edge` |
| `/var/lib/guarden/stakes/` | `0770` | `root:guarden` |
| `/var/lib/guarden/queue/` | `0770` | `root:guarden` |
| `/var/lib/guarden/soil/` | `0750` | `root:guarden` |
| `/var/lib/guarden/staging/` | `0755` | `root:root`. Nobody creates a subdirectory here at run time |
| `/var/lib/guarden/staging/<project>/` | `0755` | the `hose` user. Created by `weedr project grant`, removed by `weedr project revoke` — `hose` is unprivileged and cannot `mkdir` here itself |
| `/var/lib/guarden/staging/<project>/<sha>/` | `0755`, files `0644` | the `hose` user, which also removes the tree after the deploy |
| `/etc/guarden/**` | `0640`, directories `0750` | `root:guarden` |
| `/etc/guarden/projects.toml`, `/etc/guarden/projects.d/`, `/etc/guarden/allow-gated-drop` | `0444` | `root:root` |
| `/etc/guarden/creds/` | `0700` | `root` |
| `/etc/guarden/edge/auth-provider` | `0640` | `root:guarden` |
| `/etc/ssh/authorized_keys.d/hose` | `0644` | `root` |
| `/run/guarden/locks/` | tmpfs, gone on reboot | `root:guarden` |

The `0700` on the service tree is the whole isolation scheme, and there is no carve-out for the
home. Without it every service user can read every other service's state volumes straight off the
host filesystem, and the uid-matched firewall rules and per-consumer credentials stop being
controls. The registry and the overrides are `0640 root:guarden` rather than world-readable,
because the registry describes the whole topology: every uid, every edge, every port, every
snapshot seed.

Four of those numbers are not the default; each is there for one reader:

- **`projects.toml` and `projects.d/` are `0444`** because `hose` — the only network-facing
  program — reads the ref allowlist, and a project name, a repository URL and a ref pattern are
  not secret. **Nothing else in `/etc/guarden` is readable by `hose`,** and in particular it never
  reads `allow-gated-drop`: the refusal is enforced root-side, inside `weedr service remove`.
- **`stakes/` and `queue/` are `0770 root:guarden`** because `stakes` and `furrow` run as `guarden`
  and *create and remove* the files in them. `0750` is a defect here, not a tightening: group bits
  of `r-x` would let `furrow` read the queue and not write to it.
  `weedr pin sync` is root and reads them.
- **`queue/` and `stakes/`** were both `0750`, which is why the rule above is worth stating: a
  directory a program writes into needs `w` on the directory, and `r-x` does not give it.
- **Everything else in `/etc/guarden`, and the registry, is `0640 root:guarden`** because the
  unprivileged programs are the readers, and the group is what they read it as. That is why
  `soil install` creates the `guarden` group: without it every one of those paths belongs to a
  group no program on the box is in.

The rest of the host, and where to look when a path is not what you expected:

| path | what it is |
|---|---|
| `/usr/lib/guarden/` | guarden's own files, root-owned, never written by a deploy |
| `/etc/guarden/guarden.toml` | the environment, network, ingress and module tables. Three writers, all under the `modules` lock and all through the spec §3.5 protocol: `weedr module add` appends to `[modules] enabled` and rewrites nothing else; `soil install` writes the measured `ingress.alias` and seeds `[modules] enabled` from cloud-init. Two share `[modules] enabled`, so a write re-reads the file under the lock rather than trusting what it saw before it |
| `/etc/guarden/services/<name>/overrides.toml` | admin grants: ports, retention, groups, mounts |
| `/etc/guarden/firewall/10-framework.conf` | ferm skeleton, dead-man timer, the interface's `route_localnet` — written by `soil firewall` |
| `/etc/guarden/firewall/20-ingress-nat.conf` | the edge's three forwarding rules, from the enabled modules' declared ingress — written by `soil firewall`. Each is a `PREROUTING` DNAT and nothing else |
| `/etc/guarden/firewall/30-services.conf` | the whole uid-matched filter set and any service's own forwarding, same shape — written by the mutator, under the `firewall` lock |
| `/etc/guarden/creds/<name>/<KEY>.cred` | one systemd-credential blob per key, `0600 root` |
| `/etc/apt/apt.conf.d/80guarden-snapper` | the `DPkg::Pre-Invoke` hook that snapshots `root` before every package transaction |
| `/etc/snapper/configs/<service>-<vol>` | written by soil and converged to the fixed value set |
| `/var/lib/guarden/soil/` | the btrfs convert state and the reboot marker |
| `/var/lib/systemd/credential.secret` | the encryption key, when the host is set up with `systemd-creds --with-key=host`. Absent on a `--with-key=tpm2` host, where the key is sealed to the TPM |
| `/etc/ssh/authorized_keys.d/hose` | the poke keys, one forced command per project |
| `guarden-firewall.service` | the unit `soil firewall` installs to load the set |
| `/etc/containers/systemd/users/<uid>/` | where admin units and drop-ins go, and the only place |
| `/var/lib/guarden/removed/<service>/<time>/<vol>/` | volumes a removal moved aside |

There are two groups and no per-object groups. **`soil install` creates the `guarden` group**, and
that group is load-bearing rather than tidiness: the registry, every `overrides.toml` and all of
`/etc/guarden` are `root:guarden`, and the unprivileged programs read them through it. A file
with no group to read it by is a file no unprivileged program can open. The other group, `edge`,
is only ever created by `weedr module add gate`, which also adds the edge's service user to it
— a host with no edge module has no `edge` group, and `soil install` never creates one.

The fact that surprises people, and is correct: **a service cannot read another service's
files, and cannot see its neighbours' secrets.** As root, `cat` a manifest, read the unit, and
the connection string is a variable name. That is the design working, not a permissions bug. If
a service genuinely needs something from another service, it declares an edge and gets a
credential scoped to that edge.

### previews

```sh
weedr service add myapp-preview/feature-login --from myapp-staging
furrow preview drop myapp-preview feature-login
weedr service remove myapp-preview/feature-login               # alias: rm
```

Every verb takes the ref **raw** — `feature-login`, `feature/x`, anything a poke names. The
escaping to a directory name, a unit name and a registry key is internal, which is why
`feature/x` and `feature-x` can never collide.

`weedr service remove <name>/<ref>` removes **one instance**: it stops that instance's units,
deletes its directory, releases its `seed`, and frees its publications. The service and every
sibling instance are left alone, and a ref that names no instance is refused. This is the verb
the cap's eviction and `furrow preview drop` both call, so there is one removal path rather than
two.

Removing the whole service — `weedr service remove myapp-preview` — is **refused while any
instance exists**, and the refusal names them. Remove those first. `weedr service purge` is
refused for an instance, and the reason is not politeness: an instance's volumes are the
service's data, so purging one would destroy the service's.

Instances live in the service's home, one directory each, named by the escaped ref. The cap is
the `cap` on the `preview` track in `/etc/guarden/guarden.toml`, and it is counted **per
service** — per workload and environment — never per project, because two repositories may
declare the same project name. When a create would exceed it, the oldest instance is removed
first, so the cap is never briefly exceeded.

`cap` lives only on an instance track's `[[environments]]` block. A `kind = "slot"` track must
not carry one and a `kind = "instance"` track must; either mistake is exit 2 naming the track,
and there is no top-level `[preview]` table to disagree with it.

A preview appears at a **path** on one host, not at a host of its own: `preview.$DOMAIN/<ref>`.
The `host_prefix` for the track is `preview.` and the ref is a path segment, which is why
previews need no wildcard certificate and no per-ref DNS. Production is the bare domain and
staging takes the `staging.` prefix.

Every instance of one preview service shares the service's uid, home, image store, podman secret
store and the other instances' directories. An allowlist of `*` will build an instance for any
ref a poke names, including a fork from outside your own repositories, and that instance can
read the others' credentials. If a repository has outside contributors, narrow the allowlist or
make the fork its own service.

---

## Deploying

```sh
furrow deploy <name[/ref]> --from poke <project>@<sha>
furrow deploy <name> --now               # skip queue position for this request
furrow queue list                        # what is waiting, in what order, and any failure
furrow status
```

The order is fixed, and the order is the point: ensure the service exists, render, build, gate,
stop, install and start. The build and the gate both land **before** the stop, so a broken
Dockerfile or a missing credential on a gated track fails without taking anything down. The
failure message names the reason and the key. On a track with `gated = false` a missing key is
one `warning:` line and the start proceeds.

The build step is a mutator verb:

```sh
weedr service build <name>
```

It runs `podman build` **as the service user**, tagged with the image reference the manifest
names. It is a `weedr` verb rather than something `furrow` does itself for two reasons: an
unprivileged `furrow` cannot become the service user, and the subuid range belongs to the service
user and only it may map container-root into it. `furrow` never touches podman.

The first step is how a poke creates a service: if there is no registry entry, `furrow` calls
`weedr service ingest <name> --from poke <project>@<sha>`, naming the project and sha it received
and never a path, since the mutator builds the staging location itself. `ingest` has no flag that
could grant a port, because the grant is
the separate verb `weedr port open`, which `furrow` may not run.

Only builds are queued, and lanes bound builds only. `build.lanes` in `guarden.toml` is how many
builds may be in flight; the `queue` lock covers enqueue and dequeue. Deploys are bounded
separately: one deploy of one service holds `deploy-<service>` from its first step to its last, so
two deploys of the same service cannot overlap and write its units over each other, while
different services proceed in parallel. That lock is what delivers "a deploy racing another
deploy leaves half-written units" — the queue serialises builds, not deploys, so raising
`build.lanes` retires build serialisation and never had deploy serialisation to retire. A deploy
that pulls a prebuilt image competes for no resource with anything and does not go behind a build
lane; it still takes `deploy-<service>`.

`furrow queue list` keeps the last failure's message. That is usually all you need.

Queue state lives in `/var/lib/guarden/queue`, on disk. The locks that protect it are tmpfs under
`/run/guarden/locks`, which is the right split: a request that was acknowledged must not be
lost because the box rebooted, and a lock that outlives a reboot would only be a stale lock.

Every read verb takes `--json`: `weedr service list`, `weedr service status`, `weedr port list`,
`weedr module list`, `weedr project list`, `stakes list`, `stakes query`, `furrow queue list`
and `furrow status`. When you are writing a check, use the JSON.

---

## Ports and the firewall

```sh
weedr port list
weedr port open <name> 8080/tcp
weedr port close <name> 8080/tcp
```

Everything `weedr` renders is derived from the union of the grants in every
`/etc/guarden/services/*/overrides.toml`, and every change prints the diff before installing it.
Render, diff and install happen under one `firewall` lock, so two grants in a row cannot install
out of order. If a port is open and should not be, find the grant:

```sh
grep -A3 '\[ports\]' /etc/guarden/services/*/overrides.toml
```

To see what guarden *intends*, read the three files the two programs write:

```sh
cat /etc/guarden/firewall/30-services.conf
```

`soil firewall` writes `10-framework.conf` and `20-ingress-nat.conf`; the mutator writes
`30-services.conf` and nothing else. The two are disjoint and each has exactly one writer, so a
rule that appears in both is a defect.

To see what the host is *actually running*, read the ruleset. These are ferm files, and ferm
compiles them to iptables, so the live rules are directly visible — an earlier version of this
runbook said otherwise and that error is what let a wrong claim about the masquerade survive:

```sh
iptables-save                 # filter: the uid-matched accept/drop set
iptables-save -t nat          # nat: the DNAT rules, and nothing that should masquerade
```

The two can legitimately differ — an edit to a `.conf` that has not been converged yet, or a
rule another tool added — and that difference is the thing worth finding. If the live set does
not match the file, the fix is `soil firewall --apply` or a `weedr port` mutation, not editing
either by hand.

`weedr port list` is the human-readable inventory: every service, its requested ports, its
granted ports, and what is pending.

**A grant is never a bind.** No service ever binds a non-loopback address, and there is no such
thing as a private grant versus a public one. A granted public port becomes a `DNAT` from that
port on the ingress interface to the service's own loopback publication. **A port the manifest
did not request cannot be granted** — the command refuses with exit `2` and names the `ports:`
entry it would have to be, because a grant is a translation to a publication and an entry
naming only a public port names no container. The manifest asks, the admin decides.

**A granted port is not proof that anything can reach it.** The grant is a rule; reachability is
a property of the whole path, and only a request from a second machine demonstrates it (see
"there is no masquerade, and there never was" below).

The firewall's job inside the host is to stop a service *connecting* to a publication it did not
declare an edge for, not to stop a service *listening* on a port of its own choosing — nothing
polices that at runtime. Public access for HTTP is the edge's job, and it is a grant like any
other. `soil firewall` owns the rest: ssh, the dead-man timer, fail2ban.

Every rule guarden writes is IPv4 only, because `soil` disables IPv6. There is no ip6tables set
to go looking for, and if you re-enable IPv6 you are outside what this was designed or tested
for.

**Two host invariants guarden depends on and cannot enforce are detected, not merely refused.**
`soil sysctl --check` and `weedr service list` both report:

- IPv6 has been re-enabled. Every rule in `30-services.conf` is IPv4.
- `net.ipv4.ip_unprivileged_port_start` is not `1024`. `soil sysctl` **sets** it and owns the
  key, so this is drift against a value guarden converges rather than against a convention
  somebody has to honour. If it has been lowered — and a base image that ships `0` is the
  ordinary way that happens — unprivileged processes can bind ports below 1024 and the edge's
  public ports are no longer exclusively the kernel's. The check is against `1024`, not against
  "the distribution's default", precisely so that such a host is reported.

Either one puts the box outside this design. Both are reported, not corrected — guarden will not
change a sysctl an operator set on purpose.

### how 80 and 443 get here

The kernel holds the public ports and forwards them. `soil sysctl` sets
`net.ipv4.conf.<ingress-if>.route_localnet=1` on the ingress interface and nowhere else — without
it the kernel drops packets DNATed to `127.0.0.1` that arrived on a non-loopback interface as
martians — and `soil firewall` writes the three edge forwarding rules into
`20-ingress-nat.conf` from the enabled modules' declared ingress:

| arriving on | protocol | forwarded to | serves |
|---|---|---|---|
| the ingress interface | `tcp/80` | the edge's publication | the HTTP-to-HTTPS redirect |
| the ingress interface | `tcp/443` | the edge's TLS publication | TLS termination |
| the ingress interface | `udp/443` | the edge's TLS publication | HTTP/3, additive |

The edge's publications are allocated from `ingress.publication_range`, so read them rather than
assuming a number:

```sh
weedr service list
```

There is a second address in this design and it is easy to confuse with the publications, so it
is worth naming here. A rootless **container** cannot dial `127.0.0.1` on the host; it can dial
the address pasta maps, which is the container's **default gateway** and is recorded in
`guarden.toml` as `ingress.alias`:

```sh
grep -A3 '^\[ingress\]' /etc/guarden/guarden.toml
ip -4 route show default          # the alias is derived from this
```

`ingress.alias` appears in exactly one place — the `AddHost=` line `loom` writes into a
consumer's units, so `<provider>` resolves — and in **no firewall rule**, because pasta has
already translated the address to `127.0.0.1` by the time the kernel's packet path sees the
connection. If the two disagree, every service can reach every other one and nothing looks
wrong.

Because the alias comes from the host's default route rather than from guarden, it drifts when
the route changes — a new gateway, a VPS migration, a VPN. `soil sysctl --check` reports the
mismatch, and the fix is to re-run `soil install --apply` so the probe re-measures it, not to
edit the file by hand.

Those are the edge's three ingress ports and there are no others. Every other number in
`weedr port list` — 8096, 32400, 5001, 20000 and the rest — is a publication a service exposes
on loopback for the edge to dial. Those get no forwarding rule and need none.

That is **three forwarding rules, not two**: a forwarded udp port is a different protocol and a
different nat rule, and anything that counts the edge's rules counts three. `443/udp` is HTTP/3,
which the edge serves from the same TLS publication as `443/tcp`. It is an additive optimisation
and nothing else depends on it: a browser, a proxy or a network that cannot use HTTP/3 loses
nothing, and removing the rule breaks nothing. A service's own granted port adds one more rule,
in the other file, on the same shape.

### there is no masquerade, and there never was

```
net.ipv4.conf.<ingress-if>.route_localnet = 1        # soil sysctl, per interface
nat PREROUTING  -i <ingress-if> -p tcp --dport 80  -j DNAT --to-destination 127.0.0.1:<pub>
nat PREROUTING  -i <ingress-if> -p tcp --dport 443 -j DNAT --to-destination 127.0.0.1:<pub>
nat PREROUTING  -i <ingress-if> -p udp --dport 443 -j DNAT --to-destination 127.0.0.1:<pub>
```

That is the complete forwarding set. **There is no fourth line.** An earlier version of this
runbook claimed a `nat POSTROUTING … -d 127.0.0.1 --dport <pub> -j MASQUERADE` was mandatory
and that omitting it produced a box that looked healthy from the inside and was unreachable from
outside. That was wrong, and it survived a long time because this document told you the
firewall files were ferm source and that `iptables -S` "shows you nothing" — which is not true,
ferm compiles to iptables, and that command is the one that would have shown the rule was
absent. **The live ruleset is always inspectable:**

```sh
iptables-save -t nat          # the running DNAT set, not the rendered source
```

If you see a `MASQUERADE` in there, it is not part of this design. It cannot be doing anything:
after the DNAT the packet is local and never reaches `POSTROUTING`, and on the reply the
destination is the client, so a rule matching `-d 127.0.0.1` in `POSTROUTING` matches no packet
in either direction.

What *is* load-bearing is `route_localnet`. Without it the kernel treats a packet addressed to
`127.0.0.1` arriving on a non-loopback interface as a martian and drops it silently:

```sh
sysctl net.ipv4.conf.<ingress-if>.route_localnet      # must read 1
```

**A forwarded port still cannot be tested from the box.** A health check, a smoke test and a
`curl` to the public name all pass on a box where nothing outside can connect, because locally
generated traffic never traverses `PREROUTING`. The only diagnostic that distinguishes working
forwarding from none is a request from a second machine, and that is what the golden-VM check is
for.

A service's own granted port gets the same single DNAT in `30-services.conf`.

`REDIRECT` is not used anywhere, deliberately: it rewrites the destination to the incoming
interface's own address, and the edge listens on loopback only, so nothing would be listening
there.

Two consequences that look like faults:

- **Check the edge on its publication, not on the public host name.** Locally generated traffic
  does not traverse PREROUTING, so a request the box makes to its own public address never
  reaches the forwarding rules. A health check, a smoke test and the lockout drill all need the
  loopback address, and the only hairpin there is not.
- **There is no hairpin NAT.** A laptop on the same local network cannot reach the box by its
  public name. That is expected, and reaching the box from there is an ssh port, not 443.

### the edge's API and dashboard

Traefik's own API and dashboard are a control surface, not ingress, and they are not forwarded.
On this box the API is published on a loopback high port with its grant restricted to the
operator's uid, so it is reachable from an ssh session and from nowhere else:

```sh
weedr port list | grep -i traefik
```

Disabling it instead — removing `api.dashboard` and `api.insecure` from the edge's static
configuration — is the other acceptable answer, and the module owns the choice: no manifest can
turn it on and no grant can forward it.

### the dead-man timer

The timer is not always running, and it is the thing that saves you from a bad firewall apply.

```sh
soil firewall --apply --deadman    # arm: 15 minutes, then it lets you back in
soil firewall --apply             # disarm: converge without arming
```

- **Armed** only by the explicit `--deadman` flag, which is part of `soil firewall`'s interface
  in the spec. A plain `soil firewall --apply` never arms it. If your `soil` rejects the flag
  with a usage error, it is not the spec's `soil` and the timer is not installed — re-run
  `soil install --apply` before touching a rule, because the lockout drill is the one control
  that gets you back in
- **Lasts** fifteen minutes. `systemctl list-timers | grep -i deadman` shows what is left.
- **Does**, when it fires: stops `ferm` and re-enables the distribution firewall, so ssh answers
  again. Nothing is rolled back; the point is to get a shell back, not to undo the rules.
- **Disarms** by firing (it is one-shot) or by a plain `soil firewall --apply`. Neither leaves it
  armed past the drill, so you cannot forget about it and find it live in three weeks.

If it has already fired and you still cannot get in, use the provider's console and
`systemctl stop ferm`.

---

## Credentials

```sh
weedr secret set <name> <KEY>      # prompted, with echo off
weedr secret list <name>           # names and whether they are set; never values
```

A value is encrypted with `systemd-creds` into `/etc/guarden/creds/<name>/<KEY>.cred`, and
materialised into a podman secret of the same name in that service's store. Inside the container
it arrives **as a file** under that name; an environment variable is available for a manifest
that genuinely needs one, but it is not the default because `/proc/<pid>/environ` and stack
traces leak it and every child process inherits it.

The trust boundary is worth stating because the mechanism is easy to overclaim, and an earlier
version of this runbook overclaimed it. **A credential is protected from every other service,
and it is not protected from the host's storage or from a backup of it.** The encrypted blob in
`/etc/guarden/creds/` is unreadable at rest by anything but the one service that owns it — it is
in no snapshot of a service's state and in nothing a filesystem backup of `/var/lib` carries.
But the materialised podman secret store is **cleartext inside the service's own `0700` home**
(`podman secrets` keeps them in the clear; the file mode is the protection), so a stolen disk,
a stolen `/var/lib` backup or a snapshot of anything containing that home yields every
credential in the clear. The correct statement is the narrow one: `systemd-creds` protects the
value on the host filesystem, and it deliberately does not protect it from the service that
owns it, because a rootless container shares that service's uid and the secret database lives
in that service's own home. If you are deciding what may leave this host, a backup carries the
credentials and the blobs. Scoping and rotation are the real
controls: one credential per declared edge, and rotation is `weedr secret set` followed by a
restart.

To materialise everything by hand after touching the blobs:

```sh
systemctl start guarden-creds.path      # watch /etc/guarden/creds/ and materialise what changed
systemctl start guarden-creds-boot.service   # or materialise everything, once
```

Those two units are the only place a blob is decrypted, and they are root because the key is.
There is no `guarden-creds.service`; a runbook that named one would send an operator to start a
unit that does not exist and conclude the blobs had been re-materialised. The renderer
emits a *credential request* and never a value, because it has none. For a key the
manifest's schema marks `@required` or `@sensitive`, the generated unit carries
`Secret=<KEY>,type=file` in the `[Container]` table **and nothing else**, and podman resolves
`<KEY>` from that service's own secret store and presents it at `/run/secrets/<KEY>`. A key
whose application needs a variable gets `type=env` instead, and it is the application that
decides, not the repository.

### if the encryption key is lost

**The key is stated once and nowhere else may imply otherwise.** `weedr secret set` encrypts with
either `systemd-creds --with-key=host`, against a host key at
`/var/lib/systemd/credential.secret`, or `systemd-creds --with-key=tpm2`, binding it to the
machine's TPM. There is one key, and it is whichever of those the host was set up with.

**`auto` is not used**, deliberately. Its meaning varies with the hardware: it prefers a TPM2 key
when it finds one. A host set up with `--with-key=auto` on a box that happened to have a TPM
would encrypt with a different key from the one this runbook describes, and nothing would say so
at the time. If you find `--with-key=auto` in a wrapper, that is the wrapper to fix, and the
blobs it wrote are encrypted with a key this runbook cannot tell you about.

**Lose the key and every credential on the host is unrecoverable.** Not weakened — unreadable.
Re-plant each one from the operator's own copy:

```sh
weedr secret set myapp-production STRIPE_KEY
```

There is no other consequence. Services, volumes, snapshots, publications and the firewall are
untouched; the materialiser will run again on the next `weedr secret set` and the next reboot. It
is the same single point as losing the values themselves, which is the deal for one operator and
one box.

The two key choices differ in what losing the box costs, and the difference is the whole trade:

| key | where it lives | losing the VPS | losing the box itself |
|---|---|---|---|
| `--with-key=host` | `/var/lib/systemd/credential.secret`, single, no second copy anywhere | every credential is unreadable | same, if the disk came with it |
| `--with-key=tpm2` | sealed to the machine's TPM, never in a file | every credential is unreadable | unreadable, and the key did not leave the hardware |

Binding to the TPM strengthens the at-rest claim against a stolen disk or a provider volume
snapshot, and it costs the operator a recovery path on a machine failure. Re-encrypting an
existing blob is a `systemd-creds` operation on the `.cred` file; re-planting with
`weedr secret set` is simpler and is what the rest of this section describes.

A service in a gated track that is missing a required key will not start. The message names it:

```sh
furrow deploy myapp-production --from poke myapp@9f2c1ab   # warning: waiting for the gate
```

The same condition on a track with `gated = false` is a single `warning:` line and the start
proceeds.

---

## State, snapshots, forks, rollbacks

```sh
weedr service snapshot <name>                       # does not stop anything
weedr service fork <target[/ref]> --from <service>[@<number>]
weedr service rollback <name[/ref]> --to <number>   # refused outright on a gated track
```

There are two kinds of snapshot and they are governed differently, so read which one you have
before you trust it. A **routine** snapshot, made by the nightly `--all`, is tagged `timeline`
and lives by the volume's ladder. An **on-demand** snapshot — a fork source, or your own "before
the risky change" — is tagged `number`, and is what the pins below protect. `weedr service
snapshot` makes a routine one; a fork makes an on-demand one. There is no flag to choose.

A state volume's snapshots are listed by snapper, which owns them:

```sh
snapper -c myapp-production-pgdata list --machine-readable json
snapper -c myapp-production-pgdata diff 40..41
```

Read them as JSON. It renders a snapshot's `userdata` as a real object, so `important` is a key to
look up; the CSV output renders the whole map as one comma-joined quoted field, so a CSV consumer
ends up string-matching a blob. The fields that matter are `number`, `cleanup`, `date`, `userdata`
and `description`. Anything that parses snapper output — a check, a script, a program's own
`--json` — uses `--machine-readable json` and does not fall back to CSV.

A service's home is **not** snapshotted and carries no snapper configuration of its own: it
holds generated units, the image store, the podman secret database and build staging, none of it
worth keeping a moment of. A snapshot list for a service therefore only ever shows its `state`
volumes, and a `bulk` volume never appears at all — that is what "bulk" means, not a setting
somebody forgot.

A service may declare as many `state` volumes as it needs, and one snapshot covers all of them.
Each is a subvolume with its own snapper configuration named `<service>-<volume>`.

A `bulk` volume is a btrfs subvolume like any other and gets a `.volume` unit so a container can
mount it, but it has no snapper configuration, is never a fork or rollback source, and **is an
empty subvolume after a fork**. It is a subvolume on every path, the fork included — never a plain
directory, because the `.volume` unit has to resolve to the same kind of thing either way. It is
never cloned from a live volume: a copy as of an instant is not reproducible
afterwards, and a fork that quietly produced different data on two targets would be worse than an
empty one. Rebuild it instead, which is what the declaration promises.

btrfs has no atomic multi-subvolume snapshot primitive, so the volumes in one snapshot are each
internally consistent and may be microseconds apart from each other. A fork or a rollback
addresses the snapshot as a complete set of per-volume numbers and validates the whole set
before it moves anything; if one volume does not have that number, the command exits 1 having
changed nothing and names the volume. What the skew costs depends on the pair: a configuration
volume beside a media library does not notice it, and two volumes that had to agree
byte-for-byte would — which is a property the service records in its own documentation, not
something guarden can tell from a volume name.

Cloning a snapshot is a copy-on-write subvolume, so a fork costs no space and no time, and the
target's engine recovers it on start. The source snapshot is pinned for the duration of the
clone, by creating its pin file, and the pin is released when the clone is done — a failure
releases it too, so nothing is pinned forever. After a failed fork the target's previous
subvolumes are put back and it is started again; nothing is left half-swapped.

Rollback is a stop, a swap, and a start. It restores data only. Units, credentials and
configuration come from the manifest, so after rolling back a database, redeploy the service
too if the application schema also moved.

```sh
weedr service rollback myapp-production --to 41
weedr service start myapp-production
```

---

## Pins

```sh
stakes pin myapp-production:pgdata@41 "before the risky change"
stakes unpin myapp-production:pgdata@41
stakes list                              # the pin files it owns, and which services name each as a seed
stakes query myapp-production:pgdata@41

weedr service list --json                # per state volume: totals, marked, oldest, newest, limits
```

A snapshot id is `<service>:<volume>@<number>`, and nothing else. A colon cannot appear in a
service name or a volume name, so the id is unambiguous: `other-app-production-pgdata-41` could
be a service called `other-app` with a volume called `production-pgdata`, and that is why the
dash form is not used.

**`stakes list` cannot report the per-volume figures, and does not pretend to.** `stakes` runs as
`guarden`; a service's tree is `0700` to that service. It reads the pin files it owns and the
registries, both `root:guarden` and both readable, and that is exactly what it reports. Anything
that requires reading a state volume is a root read, so it comes from `weedr service list
--json`: per state volume the total, the marked, the oldest, the newest, and the effective
`NUMBER_LIMIT` and `NUMBER_LIMIT_IMPORTANT` read back with `snapper get-config`. A monitoring job
polls the second for disk and snapshot counts and the first for what is pinned and who wants it.

A snapshot is marked as protected while any service was forked from it, or while you have pinned
it. The first is derived from the registries, so it needs no maintenance: evicting one preview
does not release a snapshot another preview is still using. Marking is a priority with a budget
rather than a promise — see below. To clear a pin you forgot about, unpin it.

### how a pin actually protects a snapshot

Retention belongs to snapper, not to guarden. There is no delete loop to find and no ledger to
reconcile: snapper's own cleanup algorithms do the deleting, on the `number`, `timeline` and
`space` algorithms the distribution ships. Nothing in guarden blocks snapper — a pin that
outlives its reason keeps one snapshot inside the archive window and nothing else.

What guarden does is mark. A root oneshot, `weedr pin sync`, reads the service registries and the
pin files, recomputes which snapshots must survive, and writes each one with `snapper modify` as
`userdata important=yes` with the `number` cleanup tag. It is a separate root action from
`stakes` because `stakes` runs unprivileged and writing snapper's metadata does not. Both halves
matter: `important` is read only by the `number` cleaner, and a snapshot is a candidate for that
cleaner only when its cleanup tag is `number`. It is idempotent, it adds before it removes, and if
its own state is unreadable it stops rather than clearing marks it cannot justify — a missing
registry directory means every existing mark stays.

**Writes never use `--no-dbus`.** Without the snapperd daemon there is no inter-process
coordination at all, so a write made that way can be lost with nothing reporting an error
anywhere. **If a mark or a snapshot does not appear to have landed, look for `--no-dbus` in a
wrapper before anything else** — the write did not fail, it was never coordinated.

**A pin is a priority with a budget, not a promise.** `NUMBER_LIMIT_IMPORTANT` is a min-max
range, and snapper's free-space pass uses the minimum. When the disk is genuinely filling,
snapper will reap a marked snapshot, oldest first. That is accepted: it only happens when the disk
is nearly full, which is itself the signal worth having.

**The reading that matters at three in the morning: a preview that cannot be re-forked from an
old snapshot means the disk is filling, not that something is broken.** Check `df` before you
check anything else.

The dial for that is one number: the low end of `NUMBER_LIMIT_IMPORTANT`, which is how many marked
snapshots the free-space pass keeps. The shipped default keeps eight. It is one of the values
`soil storage` owns in the state volume's snapper configuration, so raise it in the phase's
canonical values and re-apply — it is not a manifest key, and no repository can set it. Read the
effective value back with:

```sh
snapper -c myapp-production-pgdata get-config
```

### why the packaged cleanup timer is off

The reconciler and the cleanup must never run at the same time, and snapper will not enforce that
for us. Its per-configuration lock lives in the daemon, is advisory, and is released when a client
disconnects; the method behind `snapper modify` does not check it at all. The cleaner takes one
reference to the snapshot list and reuses it across all three of its passes, so a mark written
while a cleanup is running is silently lost, with no error anywhere.

So `soil storage` disables the distribution's packaged snapper cleanup timer and installs
guarden's own oneshot, and both it and the reconciler take one lock at
`/run/guarden/locks/snapshots.lock`. `snapper list` holds that configuration lock for its whole
duration, so a loop that lists repeatedly can stall cleanup; do not leave one running.

The second consequence of the same race is a value rather than a lock: `NUMBER_MIN_AGE` is set on
every configuration, so a brand-new snapshot is not a cleanup candidate until the reconciler has
had a chance to see it.

If you re-enable the packaged timer, you have put a second cleaner back on the box, outside
guarden's lock. Two cleaners can then run at once, and any mark written in that window is lost
without an error. If a marked snapshot is unexpectedly unmarked, check that the timer is still
disabled:

```sh
systemctl status snapper-cleanup.timer        # must be inactive
```

Every state volume's snapper configuration also sets `EMPTY_PRE_POST_CLEANUP=no`, and the
distribution's own default template enables it. guarden only ever creates `single` snapshots and
never a pre/post pair, so switching the empty-pair cleaner off costs nothing. How that cleaner
treats the cleanup tag and the `important` mark is not something these documents can confirm, and
the value stands on the `single`-only fact alone. It is one of the values `soil storage` owns,
listed under **the values `soil storage` owns** above.

```sh
weedr service list --json     # per volume: totals, marked, oldest, newest, effective limits
stakes list --json            # the pin files, and which services name each as a seed
```

Those limits are read back with `snapper get-config` rather than from the configuration guarden
believes it wrote, and the snapshot lists behind the counts are read with
`--machine-readable json`, which makes them the input monitoring will consume. The counts come
from the root read, not from `stakes`, for the reason given under **Pins** above. Alerting on
disk usage and snapshot counts is backlog, not v1, so on this box nothing will tell you the disk
is filling until you look.

### one snapshot that cannot be reaped

`chattr +i` on a snapshot's subvolume is the escalation. The btrfs delete ioctl checks the victim
inode for immutability and returns `EPERM`, which no `NUMBER_LIMIT`, `FREE_LIMIT` or
`SPACE_LIMIT` can override; btrfs does not inherit immutability into a new subvolume, so a fork
from it still works; and it survives `snapper cleanup all`.

The cost is stated here because it is the reason this is not the default. snapper's cleaner
deletes candidates one at a time with no per-item error handling, so the first candidate it
cannot delete aborts the whole cleanup for that configuration for that run. It is a deny, not a
keep-N, and there is no dial that makes it one.

So it is a per-snapshot decision an operator makes, records and can undo. Record it as a pin, so
the intent is written down rather than remembered:

```sh
stakes pin myapp-production:pgdata@41 "immutable: production rollback base"
```

Production rollback bases are what it is worth spending on. Snapper's own layout puts the snapshot
subvolume at `.snapshots/<number>/snapshot` under the state volume:

```sh
chattr +i /var/lib/guarden/services/<name>/state/<vol>/.snapshots/<n>/snapshot
lsattr /var/lib/guarden/services/<name>/state/<vol>/.snapshots/<n>/snapshot
chattr -i /var/lib/guarden/services/<name>/state/<vol>/.snapshots/<n>/snapshot   # back to normal
```

While it is set, and while that snapshot is among the candidates, every cleanup for that configuration
aborts — so the configuration accumulates snapshots rather than pruning them. That is usually the intent, and it is not
the same thing as a keep-N. If it is not the trade you meant to make, unset it and let the marks
and the limits do their work.

### a pin that points at nothing

`stakes list` prints what you asked it to protect; it does not check that the snapshot still
exists. A pin whose id no longer names a real snapshot — the volume was purged, the service was
purged, the service was dropped, the number was never real — protects nothing, and the file just
sits there being a lie you read at three in the morning.

Check it against snapper, which is the thing that knows:

```sh
snapper -c myapp-production-pgdata list --machine-readable json
```

No entry whose `number` is 41 means the id is stale. The fix is to unpin it:

```sh
stakes unpin myapp-production:pgdata@41
```

`stakes` deliberately does not decide this for you and does not clean up after you. A pin is a
statement the operator made; the operator removes it, because the whole design refuses to keep
a ledger that has to be reconciled.

`overrides.toml` also has `retention.keep_last`, which is **the daily bucket's maximum** — a
retention count, not a mark count. `7` means seven daily snapshots, and snapper ages them up into
the weekly, monthly and quarterly buckets as they get older, so a production volume keeps a
spread-out history rather than a flat window of the newest few. It does **not** mark seven
snapshots, and it does **not** raise the floor of `NUMBER_LIMIT_IMPORTANT`; those are the
`number`-tagged snapshots' business and one number soil owns. The ladder's own values are ranges,
so the free-space pass keeps only their minimum and no retention promise here is absolute.
`retention.free_limit` is the disk pressure at which pruning starts early.

---

## gitops

```sh
hose poke <ref> <sha>               # what a project's CI sends; tar archive on stdin
hose drop <ref>                      # remove a preview instance
hose check                          # prints "not implemented: events only"
```

There is no drift correction. If a deploy was missed, push an empty commit.

A poke unpacks into `/var/lib/guarden/staging/<project>/<sha>/` — the path is keyed by project,
so it exists before any service does — and the tree is removed after the deploy.

**A poke may never remove a service in a gated track.** The refusal is enforced root-side, in
`weedr service remove`, and the only override is a root-owned file:

```sh
touch /etc/guarden/allow-gated-drop
```

`hose` never reads that file and is never permitted the verb that enforces it. The file is
present, or it is not; a poke can neither create it nor be affected by it directly.

Creating a poke key, when you add a project:

```sh
weedr project add myapp --repository git@github.com:you/myapp.git
weedr project grant myapp "$(cat ci-poke.pub)"   # weedr, not hose: writing authorized_keys is root
weedr project keys myapp                         # what is installed, per project
weedr project revoke myapp "$(cat ci-poke.pub)"  # removes that project's lines and nothing else
cat /etc/guarden/projects.d/myapp.toml           # the ref -> track allowlist
```

The keys live in `/etc/ssh/authorized_keys.d/hose`, one forced command per project:

```
command="/usr/lib/guarden/bin/hose --project myapp",no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty ssh-ed25519 AAAA...
```

`weedr project grant` refuses anything that is not ed25519 and refuses a project that does not
exist. A forced command naming a different project is refused, so one repository's workflow can
only ever reach its own services.

The allowlist is the reason a feature branch cannot create a production service: it names which
tracks a ref *may* deploy to, not the one it gets, the first matching pattern wins, and a ref
matching nothing is refused with exit 1 and the reason named. To change where a branch deploys,
edit that file. To take a project's key away, `weedr project revoke <name> <pubkey>` — it
removes that project's lines from the file and touches nothing else, and a poke cannot name the
verb.

### the sudoers surface

The two rules are written out in full, with their runas target, because "unprivileged" is a
property of the file and not of a reader's assumption — and because the default reading of "a
sudoers rule naming X" is that X runs as root, which would make `furrow`, the program that
handles repository-supplied paths, a root program:

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

`guarden`'s rule is the mutator, and `weedr service build` is on it: the build has to happen as
the service user, and an unprivileged `furrow` cannot become the service user. It is never
`weedr port open`, `weedr port close`, `weedr service purge`, `weedr service rollback`,
`weedr module add`, `weedr project add`, `weedr project grant`, `weedr project revoke` — and
that list is exhaustive because **no verb it may run carries a flag that widens authority**. A
sudoers rule naming a command without an argument specification matches any arguments and
sudoers has no negation, so a flag could never have been withheld here; each of those
capabilities had to become a verb it does not name.

`hose`'s rule is the deploy queue, **not** `weedr` — and its removal verb is `furrow preview
drop`, not a direct `weedr service remove`, so a workflow cannot name the removal path at all. It
holds no `weedr` verb that creates, grants or removes anything, and a poke reaches a root program
only by way of a program that is itself unprivileged. That is what makes "cannot reach a shell" a
property of this file rather than of an assumption.

**Those grants name the canonical long form, and every program inside guarden calls it that way.
`rm` is a human abbreviation and nothing else may use it.** A program that invoked the alias
would not match its own sudoers rule, and sudo would deny it — a confusing failure that looks like
a permissions problem. If you are editing a call site, a unit, or a sudoers file, use the long
form.

---

## Modules

```sh
weedr module list
weedr module add homepage
weedr module remove homepage                  # alias: rm
```

`gate` and `homepage` are on by default in `/etc/guarden/guarden.toml`. Adding a module creates
its services and grants what it declares; it does not re-run soil and does not touch other
modules. It is also the one verb that writes `guarden.toml`: `weedr module add` appends the
module's name to `[modules] enabled` and rewrites nothing else in the file, under the `modules`
lock and by the same write protocol as every other shared file.

**`weedr module add gate` is also what creates the `edge` group** and adds the edge's user to it.
`soil install` creates the `guarden` group and no other, and never an `edge` — the `guarden`
group is what makes every `root:guarden` path readable to the unprivileged programs, and `edge`
is only ever created here. A host with no edge module has no `edge` group, and
`/var/lib/guarden/edge/dynamic/` does not exist.

---

## When nothing makes sense

1. `weedr service status <name>` — the registry record, its edges, its ports, its snapshots.
2. `journalctl --user -M <name>@ -u <unit> -n 200` for the failing unit.
3. `loom check <source-dir>` — validate a manifest without writing anything. Most "it worked
   yesterday" reports are a manifest that no longer renders.
4. `soil --check` — if the host drifted, nothing above it means much.
5. The call log. Every program logs each external tool it invokes, so the exact commands that
   produced the current state are in the journal, not reconstructed.

### a service that deployed but did not start

A push to a gated track with an unplanted credential **succeeds**: the service exists, the image
is built, the units are installed, and the container is not started. The workflow is green. This
is deliberate — a red build on every push until you plant credentials is noise, and noise makes
people want the gate gone.

So a service can sit waiting, and that is a state you can see:

```sh
weedr service list                 # blocked services say so, and give the reason
weedr service status myapp-production
```

Three different things look alike from a distance, and the listing tells them apart:

- **blocked** — `[gate] reason` names the missing or still-example key
- **never started** — no `[gate]` table at all, because the gate has never been evaluated
- **crashed** — the gate passed and the unit went down on its own

The way out of blocked is not a re-push. Plant the credential, then start the service:

```sh
weedr secret set myapp-production DB_PASSWORD   # prompts, echo off
weedr service start myapp-production           # re-evaluates the gate, then starts
```

**Do not reach for `systemctl --user disable` or `mask` instead.** Those are not the control, and
they hide the reason: the gate is credential-shaped, a service has N units rather than one, and
`disable` does not stop an explicit start anyway. A masked unit looks disabled whether it is
waiting for a password or broken, which is exactly the confusion the registry field exists to
remove.

A raw `systemctl --user start` bypasses the gate entirely. That is true of every guarden rule on
the box and it is a deliberate act by someone who already has those powers — but nothing CI can
reach can do it.
