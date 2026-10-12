# guarden

One VPS. A handful of projects. No Kubernetes, no dashboard you have to learn.

`guarden` turns a fresh Ubuntu box into a small, honest deployment host. It puts each project
into a **service** — its own Linux user, its own containers, its own state — routes traffic to
it through one edge, shares Postgres when a project wants to, and snapshots everything that
matters so a bad deploy can be undone.

There is no web UI. Everything is a command you can read, and every piece talks to the next
one over files.

---

## What you get

| piece | what it does |
|---|---|
| **soil** | Prepares the host: btrfs, snapper, the firewall, ingress forwarding, IPv6 off. The only thing with a `--check`. |
| **weedr** | The one command that creates and removes services, grants ports and firewall rules, plants secrets, and snapshots. The only program that mutates anything as root. |
| **loom** | Turns a project's manifest into the units that run it. |
| **roots** | Writes the edge's routes. |
| **twig** | Writes the dashboard. |
| **furrow** | Builds and deploys, one build at a time, highest track weight first. |
| **stakes** | Remembers the snapshots you care about. |
| **hose** | Optional. Takes each project's CI pokes and redeploys the branch they name. |
| **gate** | A module: the edge service and its route renderer. On by default. |
| **homepage** | A module: the dashboard service and its renderer. On by default. |

You can install `soil`, `weedr`, `loom`, `roots`, `stakes` and `furrow` and stop there.
`twig` and `hose` come with modules you can leave off.

---

## What you need

- One VPS you do not mind reformatting.
- Ubuntu 26.04 (the layout is portable; the install path is not yet).
- A domain whose DNS you control.
- About thirty minutes the first time.

---

## Install

There are two paths to the same state, and they converge on the same host. The command line, the
exit codes and the word `drift` do not change with the path taken.

**From cloud-init** — for a machine that boots a user-data document. `tools/golden-vm` renders one
from [`packages/packages.toml`](packages/packages.toml) and hands it to the instance; the document
installs the substrate and then converges every phase and checks every phase.

**From the scripts** — for a host without cloud-init, which is most of them. Same phases, run by
hand — with `install` first, because it is what seeds the file `packages` resolves its fetch
against and puts the programs on `PATH`:

```sh
# 1. Install. `storage` reboots once or twice to convert the root filesystem to btrfs.
soil install  --apply   # the programs, the groups, the files every phase reads
soil packages --apply   # the distribution packages and the pinned podlet release
soil storage  --apply   # schedules the btrfs conversion; run it again after the reboot
soil sysctl   --apply
soil firewall --apply
soil units    --apply
# ... reboot when `storage` says to — it names the marker it wrote, under
# /var/lib/guarden/soil/ — then run `soil storage --apply` again; twice, if the
# second boot asks again (the conversion and the @/@var migration are two reboots) ...

# 2. Check nothing drifted.
soil --check

# 3. Say who you are.
weedr project add myapp --repository git@github.com:you/myapp.git
```

`soil install` reports one item it cannot converge until the host can measure it: `ingress.alias`
is recorded by running a `localhost/guarden-probe` container image, and this repository neither
builds nor ships that image. Until it exists, `soil install` and `soil --check` report that one
drift — and the edge will not start, which is by design: guarden records no address it did not
measure. Everything else converges on the first run.

`soil --check` is safe to run over ssh at any time: it reports and changes nothing.

The module selection is made once, at install, and recorded in `/etc/guarden/guarden.toml`:

```sh
soil install --apply --modules gate-traefik,homepage
```

After that it is `weedr module add` that changes it, and a later `soil install --apply` leaves
what it appended alone — three writers share that file and two of them share that key, so every one
of them takes the `modules` lock.

There is no PyPI and no wheel on either path. Every package is a distribution package, and the one
thing fetched from outside a distribution repository is a pinned `podlet` release whose SHA256 is
recorded in this repository.

### The firewall is `ferm`; `ufw` is uninstalled

guarden does not use `ufw`. It installs `ferm` and `ufw` is **not on the box** — it is removed
during installation. No `ufw` rule is ever written, read or reconciled on a guarden host: every
rule in `/etc/guarden/firewall/` is a ferm stanza, whatever installed the service it belongs to —
a module's service, a poke's service, or one you created by hand. There is exactly one firewall
on the box and it is ferm.

SSH access is guaranteed structurally: `00-ssh.conf` in `/etc/guarden/firewall/` is root-owned
and seed-once (written only if absent, so an operator's port edit survives reinstall). Its
accept is the first rule of its own `guarden-ssh` chain, and `INPUT`'s first rule after
conntrack and lo is `jump guarden-ssh;`. `soil firewall --apply` refuses (exit 1, installs
nothing) unless all of these hold.

```sh
ferm --version                # the firewall engine on this host
ls /etc/guarden/firewall/     # what guarden intends: 00-ssh.conf, 10-framework.conf, 20-ingress-nat.conf, 30-admin.conf, 50-services.conf
iptables-save                 # what the host is actually running
```

Ferm compiles to iptables, so the running rules are always inspectable — the rendered files are
not a private format you need a tool to read.

---

## Put a project on the box

A project repository carries a manifest, a Compose file, and a shape for its secrets.

```
myapp/
├── compose.yaml                  # the app, as plain Compose ...
└── .guarden/
    ├── quadlet/                  # ... or your own quadlet units instead
    ├── service.yml               # what guarden needs to know
    ├── .env.schema               # the shape of every key. never values
    └── widgets/
        └── web.yml               # one file per container
```

`compose.yaml` and `.guarden/quadlet/` are an either-or, and a pre-commit hook stops you when
neither is there.

```yaml
# .guarden/service.yml
state:
  - pgdata

needs:
  - service: postgres-production    # needs names another service
    as: db
    port: 5432
    auth: database

routes:
  - container: web                  # routes and widgets name a container in this service
    host: "web.${domain}"
    port: 3000

widgets:
  - container: web
    file: .guarden/widgets/web.yml

firewall:                       # a firewall rule this service ASKS for; it installs nothing
  - name: wireguard-peer        # the admin grants it with `weedr firewall open <service> <name>`
    rule: "-p udp --dport 51820 -j ACCEPT"

schema: .guarden/.env.schema
```

Then, on the box:

```sh
weedr service add myapp-production --from myapp-staging   # copy that service's setup
```

One command creates the Linux user, the home, a subvolume for `pgdata` with its own snapshots,
a role and a database in `postgres-production` with a freshly minted password, a firewall rule
that lets this service reach 5432 and nothing else, and the quadlet units. The routes are not a
step: guarden re-renders them at the end of the command, so a service that declared a route
has one as soon as the command returns. The service starts on the next `furrow deploy` or
immediately with `weedr service start`.

Notice what is *not* in that manifest: which environment this runs in, whether the port is
open, and where the data comes from. Those are the host's decisions, and a repository cannot
make them.

### Tracks, environments and host names

The environment set is a root-owned table in `/etc/guarden/guarden.toml`, not a list in the
code. Each row is a **track**: it carries its own host prefix, gate, weight, retention defaults
and instance-or-slot kind. Three ship; appending a fourth — `preprod` — is a configuration change
and needs no code change.

| track | route host | gated | weight | kind |
|---|---|---|---|---|
| `production` | `myapp.$DOMAIN`, the bare domain | yes | 1000 | one service per workload |
| `staging` | `staging.myapp.$DOMAIN` | no | 100 | one service per workload |
| `preview` | `preview.$DOMAIN/<ref>` | no | 10 | up to `cap = 3` per service |

`host_prefix` is where a host name comes from: empty for production, `staging.` for staging,
and for a preview a **path prefix on one host** rather than a host per ref — which is why
previews need no wildcard certificate and no per-ref DNS. `gated` is what makes a service in that
track refuse to start on a missing or placeholder credential. A project that needs a different
host name says so in its own manifest, and that is the only place it can. `cap` belongs to an
instance track and to nothing else: a `kind = "slot"` track must not carry one.

```toml
# /etc/guarden/guarden.toml
[[environments]]
name = "preprod"                  # any further track: append and use
host_prefix = "preprod."
gated = false
weight = 500
free_limit = "0.10"
keep_last = 0
kind = "slot"
```

### A gated track says yes first

```sh
weedr service add myapp-production --from myapp-staging     # copy staging's setup
weedr service remove myapp-production                       # refused: gated track; alias: rm
```

`--from` names a **service**, never a folder. There is no path in this interface, and no
`--from git <url>` either — CI holds the credential and pushes a tarball, so the box never
authenticates to a forge. A brand-new project is created by a push to `main`; `weedr service
add` is how you copy one service's setup onto another track.

Staging and preview do not ask. `weedr service add myapp` with no environment defaults to
**staging**, never to a gated track, so a forgotten argument cannot create one.

### The edge

The `gate-traefik` module installs `traefik-production`, which reads the routes `roots` writes. It is an
ordinary service with its own user and no capability of any kind. Its two container ports — one
issues the HTTP-to-HTTPS redirect, the other terminates TLS — are published on loopback
publications guarden allocates; `weedr service list` prints the numbers.

It does not bind 80 and 443, because the kernel owns those. `soil` sets
`net.ipv4.conf.<ingress>.route_localnet=1` on the ingress interface, and `soil firewall` writes
nat PREROUTING rules that forward `80/tcp` to the edge's redirect publication and `443/tcp` and
`443/udp` to its TLS one. That is three rules, not two, because a forwarded udp port is a
different protocol and a different rule. `443/udp` is HTTP/3, served by the edge from the same TLS
entrypoint; it is additive, and a browser or a network that cannot use it loses nothing.
`soil sysctl` holds `net.ipv4.ip_unprivileged_port_start` at `1024`, so nothing unprivileged on
the host can bind below 1024 — the edge is not an exception, it is a service like the others. The mutator owns a
separate file, `50-services.conf`, for the uid-matched filter set and any service's own granted
forwarding; `soil` owns the other two, and neither file is written by both.

**There is no masquerade, and the `DNAT` plus `route_localnet` is the whole mechanism.** An
earlier draft of this document said otherwise and was wrong:

```
net.ipv4.conf.<ingress-if>.route_localnet = 1        # soil sysctl, per interface
nat PREROUTING  -i <ingress-if> -p tcp --dport 80  -j DNAT --to-destination 127.0.0.1:<pub>
nat PREROUTING  -i <ingress-if> -p tcp --dport 443 -j DNAT --to-destination 127.0.0.1:<pub>
nat PREROUTING  -i <ingress-if> -p udp --dport 443 -j DNAT --to-destination 127.0.0.1:<pub>
```

After the translation the destination is a local address, so the packet is delivered to `INPUT`
and never reaches `POSTROUTING`; on the way back connection tracking unwinds the translation and
rewrites the reply's source to the public address the client dialled. A rule written as
`-o <ingress-if> -d 127.0.0.1 --dport <pub> -j MASQUERADE` matches no packet in either direction.
The one thing that genuinely bites is subtler and is kept: a request the box makes to itself
never traverses `PREROUTING`, so a loopback health check passes whether or not forwarding works
at all, and only a request from a second machine can tell the two apart. That is what the
golden-VM criterion is for.

The flip side is that the edge sees each visitor's **real address** rather than `127.0.0.1`,
because `DNAT` rewrites the destination only — so its access logs and any rate limiting work
without a trusted-proxy workaround.

Traefik's own API and dashboard are a control surface rather than ingress. On this box it is
published on a loopback port with its access restricted to the operator's uid, and it is
deliberately not forwarded from outside. Disabling it entirely is the other acceptable answer,
and the module owns the choice either way.

---

## Everyday commands

```sh
weedr service list                       # what is running, and what is waiting
weedr service add myapp-staging --from myapp-production
weedr service start|stop|restart myapp-staging
weedr service remove myapp-staging       # alias: weedr service rm
weedr service purge myapp-staging                     # the only way data dies

weedr service snapshot myapp-production  # take a snapshot, without stopping anything
weedr service rollback myapp-production --to 2026-09-27T03:00:00Z
weedr service fork myapp-staging --from myapp-production
weedr service build myapp-staging            # podman build, as the service user, from its own home

weedr secret set myapp-production STRIPE_KEY
weedr secret list myapp-production

weedr port list                          # requested, granted, pending
weedr port open myapp-production 8080/tcp

weedr firewall list                      # every rule, installed or pending, and who asked for it
weedr firewall open myapp-production wireguard-peer

stakes pin myapp-production:pgdata@41 "before the risky change"
stakes list                              # pin files it owns, and which services name each as a seed
weedr service list --json                # per state volume: totals, marked, oldest, newest, limits

furrow deploy myapp-production --from poke myapp@"$(git rev-parse --short HEAD)"
furrow queue list

hose poke main 9f2c1ab < site.tar.gz   # what a project's CI sends; the project comes
                                  # from the key's forced command, not from here
```

`stakes` and `weedr service list --json` answer different questions on purpose. `stakes` runs
unprivileged and a service's tree is `0700` to that service, so it cannot read a service's
snapshots: it reports its own pin files and the registries, both readable. Every figure that needs
a state volume — the totals, the marked, the oldest, the newest, the effective `NUMBER_LIMIT` and
`NUMBER_LIMIT_IMPORTANT` — is a root read, so it comes from `weedr service list --json`. A
monitoring job polls the second for disk and snapshot counts and the first for what is pinned.

`weedr service build` is a mutator verb because an unprivileged `furrow` cannot become the
service user, and because the subuid range belongs to the service user and only it may map
container-root into it. `furrow` never touches podman; it calls this.

One container build runs at a time. The queue is FIFO within a priority, and priority comes
from the track's `weight` in `/etc/guarden/guarden.toml`, so the shipped tracks put production
first and previews last. `build.lanes` in the same file can raise the lane count if the box has
headroom — and it bounds **builds only**. Deploys are bounded separately: one deploy of one
service holds `deploy-<service>` end to end, so two deploys of the same service cannot overlap
while different services proceed in parallel. Raising `build.lanes` retires build serialisation
and has never had serialised deploys to retire, so it is not the knob for a deploy that races
another deploy.

---

## Secrets

There is no secrets service and no encrypted blob in a repository.

- **Production:** you type the value once with `weedr secret set`. It is encrypted on the box with
  `systemd-creds --with-key=host`, against a host key at `/var/lib/systemd/credential.secret`, or
  with `--with-key=tpm2` to bind the key to the machine's TPM. The key is chosen once; `auto` is
  not used, because its meaning varies with the hardware and a box that finds a TPM2 key would
  silently encrypt with a different key than the one described here. Decryption happens once,
  root-side, in a credential materialiser unit, and the result is materialised into the service's
  own podman secret store — from where it reaches the container under that name, as a file by
  default at `/run/secrets/<KEY>`. The generated unit carries no `LoadCredentialEncrypted=` and
  cannot: it runs in the service user's user manager, which cannot read a `0600 root` system host
  key and has no business holding it. It names the secret and podman resolves it.

  The value is protected from every other service, and from a backup of `/etc`. It is **not**
  protected from a backup of `/var/lib`: the credential materialiser writes the cleartext value
  into the owning service's podman secret store, and podman keeps secrets in the clear, so the
  `0700` on that home is the protection. A stolen disk, a provider volume snapshot or a `tar` of
  `/var/lib` yields every credential in the clear. It is deliberately available to the service
  that owns it, because a rootless container shares that service's uid — but the distinction to
  carry away is *encrypted blob* versus *materialised copy*, and only the first survives an
  encrypted-key theft. If you lose the VPS **and** the encryption key, every credential is
  unrecoverable and each has to be re-planted from your own offline copy — there is no second copy
  of a host key anywhere. That is the deal for one person and one box.
- **Staging and previews:** generated once, stable until the service is removed.
- **The gate:** a service in a gated track will not start if a required key is missing, empty, or
  still an example. It is checked **before** the old container stops, so a blocked gate never takes
  the running service down. The deploy itself still succeeds — the service is created, built,
  installed and **waiting**, with the reason in the registry — so a push with no credentials planted
  yet is a green build rather than a red one. Plant them, then `weedr service start`; no second
  push is needed. So is the image build. The error names the key. On a track
  that is not gated the same condition is one warning line and the start proceeds.

The shape of every key lives in a tracked varlock schema, `.guarden/.env.schema`, and there is
no `.env.example` — the schema is the single source of truth. Values never do. A snapshot
of a service's state does not contain its credentials, which is what makes it safe to clone and
roll back automatically. Scoping is the real control, not secrecy: one credential and one
least-privilege role per declared edge, and rotation is `weedr secret set` followed by a
restart.

---

## Staging and previews

Every service says which environment it is in its name, and the environment it says must be one
the host's table defines. Data flows one way: **production starts empty, staging forks from
production, a preview forks from staging.** A repository cannot change that, and neither can
`overrides.toml`; `weedr service fork --from` is the only override.

A preview is a directory inside one preview service, not a service of its own:

```sh
weedr service add myapp-preview/feature-login --from myapp-staging
weedr service remove myapp-preview/feature-login      # one instance; alias: rm
```

It appears at `preview.$DOMAIN/feature-login`, it is capped at three concurrent instances per
service with the oldest evicted first, and when it is evicted its directory and its claim on
the snapshot it was forked from go away — while any other branch forked from the same snapshot
keeps it. `weedr service remove <name>/<ref>` is the verb that does it: it stops that instance's
units, deletes its directory, releases its `seed`, frees its publications, and leaves the service
and every sibling instance alone. The cap's eviction and `furrow preview drop` both call it.

Removing the whole service instead — `weedr service remove myapp-preview` — is refused while any
instance exists, and the refusal names them. Remove those first. `weedr service purge` is refused for
an instance outright, because an instance's volumes are the service's data.

All instances of one preview service are one trust domain: they share a uid, a home, an image
store, a podman secret store, and each other's directories, and an allowlist of `*` creates an
instance for any ref a poke names. A fork from outside your own repositories is therefore
inside the boundary of the ones it shares with. Narrow the allowlist for a repository that has
outside contributors, or make the fork its own service.

---

## Snapshots and clones

`soil` puts snapper on the host's own volumes. Every state volume a manifest declares gets its
own subvolume and its own snapper configuration. A service's home does not: it holds generated
units, the image store and the podman secret database, none of it worth keeping a moment of. A
snapshot list for a service therefore only ever shows its state volumes.

Snapshots come in two kinds, and the difference decides who may delete one. A **routine**
snapshot is what the nightly timer makes; it is tagged `timeline` and lives by the volume's
**ladder** — how many to keep per time bucket, aged upward as they get older, so a nightly
snapshotter keeps a bounded history across weeks and months rather than a flat window of the
newest few. An **on-demand** snapshot is a fork source or your own "before the risky change"; it
is tagged `number`, and the pins below protect it. `weedr service snapshot` makes a routine one.

A service may declare as many `state` volumes as it needs, and one snapshot covers all of them.
`weedr service snapshot` takes one **while the service keeps running**: each volume's snapshot
is atomic, and it costs almost no space because the blocks are shared. btrfs has no atomic
multi-subvolume snapshot primitive, so each volume in the set is consistent and the set may be
microseconds apart from itself. Configuration and a media library tolerate that without noticing;
two volumes that had to agree byte-for-byte would not, and such a service has to say so in its
own documentation.

A second list, `bulk`, is a btrfs subvolume with no snapper configuration at all: never snapshotted, never a
fork or rollback source, and **an empty subvolume after a fork** — it is never cloned from a live
volume, because a copy as of an instant is not reproducible afterwards. It still gets a volume
unit so a container can mount it. A bulk volume is a subvolume on every path, the fork included;
it is never a plain directory, because a container mounts a `.volume` unit and that has to be the
same kind of thing either way.

`weedr service fork` clones a snapshot into every state volume of another service in constant
time: the clone is copy-on-write, the source is never written to, and the target's own engine
recovers it on start. Forks and rollbacks are the same operation, and both address the snapshot as
a complete set of per-volume numbers — if one volume is missing its number, nothing is changed.
A fork holds the source snapshot pinned for the duration and releases it whether it succeeded or
not.

A snapshot is identified by `<service>:<volume>@<number>` and by nothing else, and it is marked
as protected while any service was forked from it. That is derived from the service registries,
not recorded, so evicting one branch cannot take a snapshot away from another. The mark is not
itself a guarantee — read the next paragraph before relying on it. Pins are for
you: `stakes pin <id>` when you are about to do something you would want to undo.

Retention is snapper's. guarden runs no delete loop: a root reconciler reads the registries and
the pin files and marks the snapshots that must survive with snapper's own `important`
userdata, and snapper's cleanup algorithms do the deleting. A pin is a priority with a budget
rather than a promise — when the disk is nearly full, snapper's free-space pass uses the
bottom of the `NUMBER_LIMIT_IMPORTANT` range and a marked snapshot can be reaped, oldest first.
That only happens under real disk pressure, which is the signal worth having. The floor under
pressure is one number, the low end of that range, `soil` owns it in the state volume's snapper
configuration, and the shipped default keeps eight; the runbook says how to change it.

`soil storage` also owns `EMPTY_PRE_POST_CLEANUP=no` and a `NUMBER_MIN_AGE` on every state
volume's configuration, and reads back the effective limits with `snapper get-config` rather
than trusting what it believes it wrote. Reading snapper output means
`snapper --machine-readable json --config <config> list`, where `userdata` is an object and
`important` is a key; the option goes before the command, and the document is keyed by the
configuration's name.
One snapshot can be made unreapable with `chattr +i`, at the cost that it is a deny rather than a
keep-N: while it stands, that configuration's cleanups abort. The runbook has it.

`keep_last` is the **daily bucket's maximum**, and it is the track's default unless a service
overrides it. It is not a number of marked snapshots and it does not raise the floor under disk
pressure:

```toml
# /etc/guarden/services/myapp-production/overrides.toml
[retention]
keep_last = 7     # overrides the track's keep_last
```

`7` means seven daily snapshots, which snapper ages up into the weekly, monthly and quarterly
buckets as they get older — a bounded, spread-out history rather than a flat window of the newest
few. The ladder's own values are ranges, so the free-space pass keeps only their minimum and no
retention promise here is absolute. The marks are a separate mechanism on top of the ladder, and
they govern the `number`-tagged snapshots: the fork sources and your own deliberate ones.

---

## Ports and resources

A manifest may ask for a host port. The request does nothing on its own.

```sh
weedr port list                              # requested vs granted vs pending
weedr port open myapp-production 8080/tcp    # the admin grants it
```

Every mutation re-renders the whole firewall rule set and prints the diff, so "what is open" is
answerable by reading a file and duplicate rules are impossible. Render, diff and install
happen under one lock, so two mutations in a row cannot install out of order. Every rule is
IPv4: `soil` disables IPv6, so there is no second address family to keep in step. A poke from
CI never grants a port; it creates the service, leaves the port pending, and says so in the
pull request's log until you grant it. The knobs live in `/etc/guarden/guarden.toml`; a path
unit that promotes pending requests automatically is documented in
[`docs/notes/repo-ports.md`](docs/notes/repo-ports.md) and deliberately not installed.

There are exactly three ingress ports for the edge on a guarden host: `80/tcp` and `443/tcp` for
a browser, plus `443/udp` for HTTP/3. The kernel holds them and forwards them to the edge's own
loopback publications, one nat rule each, so anything counting the edge's forwarding rules counts
three. HTTP/3 is served by the edge from the same TLS entrypoint and is additive: a client that
cannot use it, or a rule you delete, breaks nothing. Every publication you will see in
`weedr service list` is a loopback port guarden allocated from `ingress.publication_range`
(`20000`–`32767` by default) for the edge to dial; it needs no forwarding rule at all. The
numbers `weedr port list` shows are a different thing entirely — the *requested* and *granted*
public ports from `overrides.toml`, which is why a peer-to-peer port like `8333` appears there
and never as a publication.

No service ever binds a non-loopback address, and there is no such thing as a "private" versus
"public" grant: a grant is a translation from a public port to that service's publication, and
that is the only thing it is. A granted port gets the same shape as the edge's — a `PREROUTING`
DNAT to `127.0.0.1:<publication>` in `50-services.conf`, and nothing else.

### When a service needs a rule of its own

Most traffic goes through the edge, and a service that publishes HTTP declares a `routes:` entry
and never touches the firewall again. Some cannot: a WireGuard endpoint, a full node's peer port,
a source range you want to name rather than imply. Those services put the rules they want in
their manifest, and you decide what happens.

```yaml
# .guarden/service.yml
firewall:
  - name: wireguard-peer         # a stable name; the grant names this
    rule: "-p udp --dport 51820 -j ACCEPT"
```

```sh
weedr firewall list              # every rule, installed or pending, and which services asked
weedr firewall open wg-production wireguard-peer     # you agree to one
weedr firewall close wg-production wireguard-peer
```

The rule installs **nothing** until you run `weedr firewall open`, and that verb is root, made by
hand, and on no sudoers rule — a poke creates the request and leaves it pending, exactly as it
leaves a port pending. Requests are additive only: a service can add a rule to the chain guarden
owns and cannot flush a chain, set a policy, reorder guarden's own rules or reach anything after
the default deny. `weedr firewall list` is the inventory you actually want at three in the
morning — every rule on the host, deduplicated, with the services behind each one, so "which
service opened this" is a command rather than a grep through `overrides.toml` files.

Two services asking for the same rule get **one** rule with both names on it; closing one leaves
it in force while the other still asks. A granted rule is root firewall authority and it is
priced like one: you are agreeing to that line, not to what the author intended by it, and a
rule that matches loopback does reopen loopback for exactly the match it names.

Two consequences worth knowing before a smoke test surprises you: locally generated traffic does
not traverse PREROUTING, so a request this box makes to its own public host name never reaches
the forwarding rules. Health checks and smoke tests address the publication directly — read the
numbers out of `weedr service list`. And there is no hairpin NAT, so a laptop on the same local
network cannot reach the box by its public name.

Resource priorities are a default, not a cap. The generated units carry `CPUWeight=` and
`IOWeight=` from the environment's `weight` — 1000 for production, 100 for staging, 10 for a
preview — so when the box is busy the box still serves production first. There are no memory
or task caps, because a wrong cap is worse than none on a box this size. Caps are yours:

```sh
# /etc/containers/systemd/users/<uid>/web.container.d/10-caps.conf   root-owned
[Service]
MemoryMax=2G
TasksMax=512
```

That directory is podman's rootless quadlet search path and is scoped by uid, so only that
service's units pick the drop-in up. It is root-owned and nothing in guarden reads or rewrites
it, which is what makes a cap survive a regeneration. A manifest cannot state a weight or a
cap; both come from the host.

---

## gitops, if you want it

Each project's GitHub Action pokes the box over ssh with the project, the ref, the sha and the
source. `hose` maps the ref to a track using a root-owned allowlist, unpacks the source, and
asks `furrow` to deploy. The box keeps no git state. CI holds one ssh key per project and
nothing else — no registry token, no GitHub credential. `weedr project grant` installs one key
bound to its project by a forced command, and `weedr project revoke` takes it away again.

A push to `main` can create and deploy a service in a gated track, production included. That is
forced, not chosen: with no clone on the box, a poke carrying a tree is the only way code reaches
a workload that does not exist yet. What holds the start is the gate. The first deploy starts with
an empty database and waits for you to plant its credentials. A poke can never remove a service
in a gated track — the refusal is enforced root-side, and the only way to allow it is for you to
create `/etc/guarden/allow-gated-drop` yourself. If you would rather not have gitops, do not
install `hose`.

---

## If something goes wrong

```sh
soil --check                    # did the host drift?
weedr service list              # what does guarden think is running?
weedr port list                 # what is open, and what is still pending
weedr firewall list             # every firewall rule, and which service asked for it
systemctl --user -M myapp-production@ status
journalctl --user -M myapp-production@ -u web
snapper --machine-readable json -c myapp-production-pgdata list
stakes list
furrow queue list
```

The runbook is [`docs/sysadmin.md`](docs/sysadmin.md). It also says how to re-converge after
editing a manifest — `weedr service ingest <name> --from poke <project>@<sha>`, which is idempotent and is the
reconcile command — and how SSH access is guaranteed structurally. The structural guarantee
means SSH is never locked out: `00-ssh.conf` is root-owned and seed-once, its accept is the
first rule of its own chain, and `soil firewall --apply` refuses to load a ruleset where that
is not true.

---

## Where to look next

| file | what is in it |
|---|---|
| [`CONTEXT.md`](CONTEXT.md) | The vocabulary. Read it before changing anything. |
| [`docs/spec.md`](docs/spec.md) | The contract: verbs, exit codes, file formats, algorithms. |
| [`docs/adr/`](docs/adr/) | The decisions that are hard to reverse. |
| [`docs/PRD.md`](docs/PRD.md) | Why it is shaped this way: the four constraints that removed the obvious options. |
| [`docs/sysadmin.md`](docs/sysadmin.md) | The 3am commands. |
| [`AGENTS.md`](AGENTS.md) | How to work on the code. |
