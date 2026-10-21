# guarden — sysadmin runbook

Every command here is for the operator at three in the morning. Nothing in this file is
required reading before the work; it is the opposite.

---

## The five questions

```sh
soil --check                    # has the host drifted?
weedr service list              # what does guarden think is running?
weedr port list                 # what is open, and what is still pending
weedr firewall list             # every firewall rule, and which service asked for it
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

## Installing a fresh host

The canonical way to install a host is one command, and it is the one the
installer prints for itself when it needs a second run:

```sh
curl -fsSL https://raw.githubusercontent.com/christophkroeppl/guarden/develop/tools/install.sh | sudo bash
```

It clones the repository to `/usr/local/src/guarden` and converges every phase.
You need nothing on the box but a network and a root shell: the installer
installs the Python dependencies, the packages and the pinned `podlet` release
itself.

**The run order is 75, 75, 0, and the two 75s are the design.** The btrfs
root conversion is a staged offline operation that crosses two reboots — the
first converts the root filesystem, the second boots into the migrated
`@`/`@var` layout — and the installer stops at each of them with **exit 75**,
which means *a reboot is required, then run me again*. The command to re-run
is printed in the banner before the script exits, so you never have to
remember it:

```
[install]  btrfs root conversion staged.
[install]  REBOOT now, then re-run:
[install]    curl -fsSL https://raw.githubusercontent.com/christophkroeppl/guarden/develop/tools/install.sh | sudo bash
```

So the whole thing is three runs:

| run | what it does | what you do |
|---|---|---|
| 1 | converges `install` and `packages`, stages the conversion | reboot |
| 2 | runs the conversion in the initramfs, stages the `@`/`@var` migration | reboot |
| 3 | finishes the migration and converges the rest | nothing — it prints `guarden host converged` |

Re-running is safe and is the expected recovery, not a workaround: every phase
is check-then-apply, so a phase that already converged is skipped and only the
ones that have not are applied. **A run that ends in 75 has not failed** — it
has staged a reboot and told you so.

### the same thing through cloud-init

If the host boots from a cloud-init document — the `vps` profile, which
`tools/render-user-data --profile vps` renders — then cloud-init runs the
installer **once**, and the host's first boot ends in the same staged reboot
the scripts path stages. So:

**Expect `cloud-init status: error` on the first boot, and re-run the installer
by hand after each reboot.**

```sh
cloud-init status                       # status: error  <- expected, boot 1
reboot
curl -fsSL https://raw.githubusercontent.com/christophkroeppl/guarden/develop/tools/install.sh | sudo bash
reboot
curl -fsSL https://raw.githubusercontent.com/christophkroeppl/guarden/develop/tools/install.sh | sudo bash
```

The red is not a defect and it is not the document's fault: the installer's
exit 75 is a *reboot required*, and cloud-init reads any non-zero exit as a
failed module. The banner the installer prints before it exits names the
command to re-run.

**The re-run is yours to make — cloud-init will not make it, and `cloud-init
status` will not tell you that it is missing.** The document's `runcmd` runs
`once-per-instance`, and cloud-init writes that marker *before* the module
runs, so the failed boot still counts as the instance's one. The next boot
therefore reports the step as *previously ran* and does not run it again —
which is why **`cloud-init status` reads `done` on the second boot while the
host is still unconverged**. A green cloud-init status is not a converged host.

The host is converged when the installer says so, and the way to ask is the
host's own check:

```sh
soil --check                            # silent, exit 0 -> converged
```

That is the answer to the question `cloud-init status` cannot answer. The
installer is what resumes, and it resumes because every phase asks whether it
has converged before it applies.

If you would rather drive the phases by hand, the order and the reason for it
are in [README.md](../README.md) under **Install**. The two paths converge on
the same host and the same exit codes.

### what the installer put where

| path | what it is |
|---|---|
| `/usr/local/src/guarden` | the checkout — a git repository, and the only one on the host |
| `/usr/lib/guarden` | guarden's own files, installed root-owned by `soil install`; **not** a checkout |
| `/etc/guarden` | the configuration, root-owned |

The two are different places and the distinction is the one the next section
depends on: the checkout is where the code comes from, and the installed tree
is where the programs live once they are on the host.

---

## Updating an installed host

```sh
git -C /usr/local/src/guarden pull     # the checkout the installer cloned
soil install --apply                   # re-copy the programs, reinstall the units
weedr service list                     # confirm nothing changed underneath you
```

`soil install` is the only phase that writes outside the host's own storage. It never stops a
running service.

**The checkout is `/usr/local/src/guarden`, and `/usr/lib/guarden` is not one.**
`/usr/lib/guarden` holds guarden's own files — the programs, the templates, the
modules, the package list — installed there root-owned by `soil install` and
never written by a deploy. There is no `.git` in it, so `git -C
/usr/lib/guarden pull` answers `fatal: not a git repository`. The clone the
installer made is the git repository, and it is the one to pull.

---

## soil phases

```
soil <phase> --check      # report drift, change nothing, exit 1 with the word "drift"
soil <phase> --apply      # converge
soil --check              # every phase
soil list                 # what each phase owns
```

Phases in order: `packages`, `storage`, `sysctl`, `firewall`, `install`, `units`.

**`soil list` prints that order, and it is the order the phases are
described in — not the order a fresh host runs them.** On a host that is
already installed the order does not matter: every phase is check-then-apply,
so each one is skipped when it has already converged. On a **fresh** host the
bootstrap order is different, and it is `install` first:

```sh
soil install  --apply   # the programs, the groups, the files every phase reads
soil packages --apply   # the distribution packages and the pinned podlet release
soil storage  --apply
soil sysctl   --apply
soil firewall --apply
soil units    --apply
```

`install` goes first because `packages` needs what it seeds: `soil packages`
resolves the pinned `podlet` release against a record that `soil install`
writes, and `soil install` is what puts the programs on `PATH` at all. Run
`packages` first on a bare host and it refuses with *the pinned podlet record
is absent* — by design, and the fix is to run `install` first. The installer
runs the phases in exactly this order, and
[README.md](../README.md) under **Install** has the same list with each
command's effect annotated.

### btrfs conversion (once, on a fresh box)

```
soil storage --check     # ok when converged; reports the reboot marker and names it
soil storage --apply     # schedules the offline conversion -- or migrates, after the first reboot
soil storage --check     # ok when converged
reboot                   # only if --check asked for it
```

State lives in `/var/lib/guarden/soil/`. **Two reboots**: the first converts the root offline in
the initramfs, the second boots into the migrated `@`/`@var` layout; `--check` names the marker
while either is outstanding, and a run after the second reports no drift. `/boot` stays on ext4. The same phase installs
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

### structural SSH guarantee

SSH access is guaranteed structurally: `00-ssh.conf` in `/etc/guarden/firewall/` is root-owned
and seed-once (written only if absent, so an operator's port edit survives reinstall). Its
accept is the first rule of its own `guarden-ssh` chain, and `INPUT`'s first rule after
conntrack and lo is `jump guarden-ssh;`. `soil firewall --apply` **refuses** (exit 1, installs
nothing) unless all of: the file exists, is 0600 root:root, its accept is first in
`guarden-ssh`, and the INPUT jump is first.

If you are editing a rule and want to verify the guarantee holds, run `soil firewall --check`.
It reports drift against the requirement and changes nothing.

The firewall file layout is now:

```
00-ssh.conf         root:root 0600, seed-once, the SSH accept
10-framework.conf   soil's skeleton
20-ingress-nat.conf soil's PREROUTING DNAT per forwarded port
30-admin.conf       admin/module drop-in (new, optional)
50-services.conf    the mutator's uid-matched set (renamed from 30-services.conf)
```

Every root-owned `.conf` is loaded in lexical order. Non-root files are skipped with a warning.
`0640` is the default mode for config files under `/etc/guarden`; `00-ssh.conf` stays `0600`.

### compressed swap, if you asked for it

**There is none unless your `guarden.toml` says so.** No `[zram]` table means no generator
package, no `/etc/systemd/zram-generator.conf`, no `/dev/zram0`, and `soil sysctl` does not
touch `vm.swappiness`. That is the default on every host.

To ask for one, add the table to `/etc/guarden/guarden.toml` and run `soil packages --apply`
(it installs `systemd-zram-generator`, which is why it is not on a host that did not ask) and
then `soil install --apply` and `soil sysctl --apply`.

```toml
[zram]
algorithm = "zstd"
level = 6
size_percent = 50
```

| field | what it means |
|---|---|
| `algorithm` | `zstd`, and only `zstd`. Which compressor suits a given box's memory is a measurement guarden cannot make for you, so the set is short and closed rather than the kernel's |
| `level` | zstd runs 1–22, and this is an integer rather than a preset because "high" is not a value. Level 22 on a busy host costs more CPU than the memory it saves |
| `size_percent` | a percentage of this host's RAM, never over 100. An absolute size is not portable, and over 100 asks for a device larger than the memory behind it |

Ask the machine what it actually ended up with, rather than reading the file `soil` wrote:

```sh
cat /sys/block/zram0/comp_algorithm     # the algorithm in force, in brackets
cat /sys/block/zram0/disksize           # the size in bytes
swapon --show                            # the device and its priority
zramctl                                 # disksize, data, compratio
```

**The level cannot be read back.** The kernel exposes `algorithm_params` as write-only, so
there is no way to ask the device what level it is compressing at. What a bad level does is
leave no device at all — the backend rejects it and the device never initialises — and
`soil install --check` reports that.

Removing the table and running `soil install --apply` again **takes the device down** rather
than leaving it enabled: swapped off, reset, hot-removed, and both files deleted. To do that by
hand:

```sh
systemctl stop dev-zram0.swap
systemctl stop systemd-zram-setup@zram0.service
swapoff /dev/zram0
zramctl --reset /dev/zram0
printf '0\n' >/sys/class/zram-control/hot_remove
rm -f /etc/systemd/zram-generator.conf /var/lib/guarden/soil/zram
systemctl daemon-reload
sysctl -q -w vm.swappiness=60
```

`vm.swappiness` goes back out of `/etc/sysctl.d/90-guarden.conf` with it, and the next
`soil sysctl --apply` stops converging the knob — a device-less host has no business having a
swappiness value that soil put there.

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
weedr service create <name> [--env <environments>] [--template <template>]
weedr service remove <name[/ref]>      # alias: rm
weedr service purge <name>             # the only destructive verb
weedr service start|stop|restart <name[/ref]>
weedr service list [--json]
weedr service status <name[/ref]> [--json]
```

`--from` is **required** on `ingest` and `add`, and each verb accepts exactly one form.
`ingest` accepts only `poke <project>@<sha>`; `add` accepts only `<service>`. `create` takes no
`--from` at all — it builds a service from a template installed root-owned in
`/usr/lib/guarden/templates/services/`. A service is created from a manifest — under `create`,
from a template's quadlet files and no manifest at all — and guarden never infers where one is.

### Deploying a service by hand

`weedr service create <name>` is the path a third-party image takes: the images you do not
build, and the ones no repository pokes. It takes no `--from` — it builds a service from a
template named by `--template`, or picked at a terminal when the flag is omitted, in the
installed set at `/usr/lib/guarden/templates/services/`. The template provides the quadlet
files; guarden provides the identity, the tree and the registry record.

#### templates

A template is one directory in that set, holding quadlet files and nothing else: `create`
walks it and writes **every file in it** into the service's own unit directory
(`home/.config/containers/systemd/`), `0640` under the service uid, which is where a rendered
unit lands. A `.guarden/` or a `compose.yaml` put in here would land beside the units rather
than where the renderer reads, and nothing would look at it. The file name is the unit's name,
and the user manager is per service uid, so two services created from one template do not
share a unit.

**No set ships.** `soil install` builds `/usr/lib/guarden/templates/` from
`src/guarden/templates/`, and that tree has no `services/` subdirectory, so on a host that has
just been installed `create` is refused before anything else is asked of it:

```
weedr service create myapp --env staging --template postgres
error: the template 'postgres' does not exist at /usr/lib/guarden/templates/services/postgres; /usr/lib/guarden/templates/services holds none

weedr service create myapp --env staging
error: no template was chosen; /usr/lib/guarden/templates/services holds none
```

Both are exit `1`: neither name breaks a rule, so the input is fine and what is missing is on
the host — spec 1.2 draws one line, "The dividing line is input against host", and the
filesystem is the host's half of it. The argument is what fails when the value breaks the name
rule, and then it is exit `2` whatever the host holds:

```
weedr service create myapp --env staging --template ../x
error: the template '../x' is not a template name; /usr/lib/guarden/templates/services holds none
```

The same line with templates installed: a name that breaks no rule and a set that does not hold
it is still `1`, while an empty answer at a prompt that had a set to offer — or an explicitly
empty `--template`, an answer that reaches the same refusal without asking — is `2`, because
there the input itself named nothing. With templates installed and `--template` omitted, the
verb takes the set's only entry without asking, asks at a terminal when there is more than one,
and when stdin is not a terminal says so rather than reading an answer from it:

```
error: create needs a terminal to answer its prompts; run it interactively
```



A template declares nothing guarden reads: no `state:` and no `bulk:`, no `ports:`, no
`schema:`. The consequences are the bullets below — no volume, no publication, no firewall
rule, and a credential the gate has nothing to check against.

It makes a name that does not exist yet. A name the registry already holds is refused with
exit `1` naming the entry, **before** anything is created and for every environment in an
`--env` list at once, so a second `create` can never overwrite the record, the volumes, the
`provides` or the instances that name carries. Replacing a service is `weedr service remove
<name>` first, and bringing it a manifest is `weedr service add <name> --from <service>` —
which copies **that service's whole staged tree** out of its home and reconciles from it — the
`.guarden/`, the compose file, the Containerfile and the application's own files, minus the
podman store and the rendered units (which are that service's own, not its source's). The
whole tree is copied because the home is `podman build`'s context and a `COPY` resolves against
it (ticket 317). That is the whole of what `add`
copies, and no verb reads a directory you wrote: `ingest` takes a poke, `add` takes a service,
`create` takes a template name resolved inside the template set — the three forms and nothing
else. **A manifest you wrote for a third-party image therefore has nowhere to land.** Until one
arrives from another service, the template's quadlet files are what runs, and the service has
no `state:` and no `bulk:` volumes at all.

* **A declared volume is mounted by name, never by path.** `state:` and `bulk:` declare volumes
  by name, and the unit source has to mount that name:
  `Volume=data:/var/lib/postgresql/data`, not
  `Volume=/var/lib/guarden/services/<svc>/state/data:...`. A host path is a *path* mount and
  satisfies nothing, so the **render** refuses
  `the manifest <path> declares the volume 'data', and the unit source <path> does not mount
  it` — the renderer raises it, over a manifest, and guarden resolves the name to the real path
  when it renders. `weedr service create` never meets that refusal: it reads no manifest, and a
  template ships no `state:` and no `bulk:`. The volumes arrive with the first `ingest` or `add`
  that brings a manifest in, and the unit source has to mount them by then.

The credential keys a manifest needs are declared in `.guarden/.env.schema` with the varlock
syntax (`@required`, `@sensitive`, `@type env`) — see §6.5. A key with `@type env` reaches the
container as a variable, which is what an image like postgres reads; a key without it arrives as
a file the image will not look at.

Three things that bite on a first hand deployment, none of them a bug in the manifest:

* **Plant a credential before you start.** `weedr secret set` encrypts into
  `/etc/guarden/creds/<svc>/<KEY>.cred` and asks the credential materialiser to run, which is
  only possible while the service user's manager is alive. If the service has never started, or
  its user manager died, `systemctl start guarden-creds-boot.service` fills podman's store from
  what is planted. This is the one that bites hardest on a template-created service, which has
  no `.guarden/.env.schema` for the gate to read: `weedr service start` evaluates an empty
  schema and answers `not-required` on an ungated track and `ready` on a gated one, so a
  `Secret=` naming a key nobody planted is refused by podman when the container starts and not
  by `[gate] reason`. There is no blocked state to look at — plant first, then start.
* **Give the volume an owner the image accepts.** A volume is created `0700` under the service
  uid, and an image that runs as its own uid cannot write it:
  `mkdir: can't create directory '/var/lib/postgresql/data/pgdata': Permission denied`. The
  step is `podman unshare chown -R <image uid>:<image uid> <volume>`, run as the service user
  (tickets 273 and 277). Point the image's data directory at a *subdirectory* of the mount, or
  it collides with snapper's root-owned `.snapshots`.
* **A re-ingest after an edit redeploys** (ticket 275). `source_hash` covers the whole staged
  tree — the unit source, the compose file, the Containerfile and the application's own files
  — because the whole tree is the build's context and every file in it is a build input (spec
  6.6). So an
  edited manifest, compose file, Containerfile or source file hashes differently and re-ingests
  as **not** `converged`: the units are re-rendered and installed, and there is nothing to
  delete first —
  no `rm /var/lib/guarden/registry/<svc>.toml`, and no second ingest after it. The note below
  about `weedr service add` being the reconcile command holds for this case exactly as it
  holds for a poke.

### verifying a service answers

`weedr service start` returning `started <name>` is the mutator's word for it: the
units are installed and the start was requested. It is **not** the service
answering, and nothing on the host prints the difference. A container that
crashed on its first instruction, or an image that refused to start for want of
a credential, leaves a started service and no container. So ask the service.

Two things first, and both are about the box rather than about guarden:

```sh
systemctl --user -M postgres-staging@ is-active postgres.service   # active
weedr service list                                                  # the service is there
```

`active` means the unit is up; it does not mean the application inside it is
serving. For that, ask the application.

**postgres.** The publication is on loopback — a template declares no `ports:`,
so no publication is allocated and no firewall rule is written, and the
`PublishPort=` in the template binds `127.0.0.1` — so you ask it on
`127.0.0.1`, not on the public name. The client is **not** on the host by
default; it is a distribution package:

```sh
apt-get install -y postgresql-client      # pg_isready and psql
pg_isready -h 127.0.0.1 -p 5432            # 127.0.0.1:5432 - accepting connections
```

`pg_isready` needs no password and no database: it says whether the server is
answering, and it exits `0` when it is. **A healthy answer is
`accepting connections`** and exit `0`; `no response` means the container is
not serving and the journal is where the reason is.

To ask the server a question as well, you need the password you planted:

```sh
PGPASSWORD='<the value you planted>' psql -h 127.0.0.1 -U postgres -d postgres -tAc 'select version()'
# PostgreSQL 17.11 on x86_64-pc-linux-musl, compiled by gcc (Alpine 15.2.0) 15.2.0, 64-bit
```

`psql` without the password answers `fe_sendauth: no password supplied` and
exits `2` — that is the **client** refusing, not the server, and it is what a
planted-but-unmaterialised credential looks like from the host. The `select
version()` line is the proof that the database itself answers.

The same two answers are available from inside the container, which needs no
client package on the host at all:

```sh
cd /tmp                                  # a service user's podman cannot chdir into /root
runuser -u postgres-staging -- podman exec systemd-postgres pg_isready -U postgres
# /var/run/postgresql:5432 - accepting connections
```

The container's name is the unit's name, so it is `systemd-postgres` for the
`postgres` example — not `postgres`.

**vaultwarden.** The web port is `127.0.0.1:8082` (the template's
`PublishPort=127.0.0.1:8082:80`), and `curl` is on every host:

```sh
curl -fsS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8082/alive
# 200
```

**`200` is the healthy answer.** `/alive` is the vendor's own health endpoint
and it answers `200` as soon as the server is serving. The root path answers
`200` too, and is the weaker check: it tells you the server is up, not that
it is well.

The one thing that bites here is the volume. vaultwarden refuses to start
without one and says so in its log:

```
[ERROR] No persistent volume!
```

The template mounts a named podman volume (`Volume=vaultwarden-data:/data`),
which is what the example expects, so this is what you see when the volume is
missing or was removed underneath the service.

**What a healthy answer is not.** A `200` or an `accepting connections` from
the box proves the service is serving **on the box**. It does not prove that
anything outside the box can reach it: locally generated traffic never
traverses `PREROUTING`, so a loopback check passes on a host whose forwarding
is broken. See **there is no masquerade, and there never was** below for the
one check that tells the two apart.

Names carry the environment: `myapp-production`, `other-app-staging`, `postgres-production`,
`traefik-production`. The name is the service name everywhere — no suffix, no alias. A consumer
resolves it as it stands. `weedr service add myapp` with no environment defaults to **the first
track in table order with `gated = false` and `kind = "slot"`** — `staging` in the shipped
table, and never a gated one — and prints the resolved name; if no such track exists the name
is exit `1` naming that fact rather than a silent choice of a gated track. The environments
that exist are the `[[environments]]` entries in `/etc/guarden/guarden.toml`; a name whose last
segment is not one of them is refused. **Two** operations on a track with `gated = true` are
refused outright with no flag that overrides them — `weedr service remove` and `weedr service
purge` — and the only way to allow either is for you to remove the root-owned
`/etc/guarden/allow-gated-drop` marker yourself. Nothing else about a gated track is refused:
creating one, deploying to it, building it and snapshotting it are ordinary work, and the
credential gate is what stands between a push and a running container.

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
/var/lib/guarden/services/<name>/state/<vol>/data/
                                             the volume's data, one level down inside
                                             the subvolume, and what the container
                                             mounts: snapper's .snapshots/ is the
                                             payload's sibling, so a container never
                                             sees it (ADR-0020)
/var/lib/guarden/registry/<name>.toml           the record
/etc/guarden/services/<name>/overrides.toml     admin grants
/etc/containers/systemd/users/<uid>/            admin units and drop-ins, uid-scoped
/var/lib/guarden/removed/<service>/<time>/<vol>/   moved, not deleted, by service remove
```

**A `state` volume's data is one level down, and an existing volume whose data is at the
root is refused rather than moved.** A `state` volume is a btrfs subvolume and snapper puts
its own root-owned `0750` `.snapshots/` inside it; the container is rootless, so its `uid 0`
is the service uid and it cannot chown a directory owned by the real host root. Every image
whose entrypoint chowns its data directory — `postgres`, `mariadb`, `mysql`,
`elasticsearch` — therefore fails against a `state` volume whose data is at the root, with

    chown: changing ownership of '/var/lib/postgresql/data/.snapshots': Operation not permitted

**The payload directory is the fix**: the container mounts `state/<vol>/data/`, the payload's
sibling is `.snapshots/`, and the image's chown walks the payload only.

**Guarden does not migrate a volume that already has its data at the root.** The mutator and
`weedr service start` both refuse with one line naming the service, the volume, the payload
directory and the work, and they change nothing. To move the data across:

    weedr service stop <service>
    mkdir -p /var/lib/guarden/services/<svc>/state/<vol>/data
    find /var/lib/guarden/services/<svc>/state/<vol> -mindepth 1 -maxdepth 1 \
        ! -name .snapshots -exec mv -t /var/lib/guarden/services/<svc>/state/<vol>/data {} +
    chown -R <svc>:<svc> /var/lib/guarden/services/<svc>/state/<vol>/data
    weedr service start <service>

**The start asks the same question again**, so a move that missed something is refused rather
than started against a half-moved volume.

**The move is the operator's, deliberately**, and it is the same rule guarden already states
for a newly declared volume: the volume starts EMPTY and the data does not follow the change.

Nothing root-owned lives under `home`. If a file you expected to be protected is inside `home`,
it is not — that is the rule, and the fix is to move it.

### what an override can grant

`/etc/guarden/services/<name>/overrides.toml` is the whole of what an admin can decide, it is
`0640 root:guarden`, and it is created on first grant. A repository can widen none of it.

```toml
[ports]
open = ["8080/tcp"]              # public ports granted to this service

[firewall]
allow = ["wireguard-peer"]       # requested firewall rules granted to this service, by name

[retention]
keep_last = 7                    # the daily bucket's maximum; overrides the track's default
free_limit = 0.08                # overrides the track's default

[groups]
add = ["video", "render"]        # supplementary groups for the service user

[mounts]
allow = ["/dev/dri"]             # host paths this service's units may bind-mount
```

`[groups] add` is how a hardware-transcoding service reaches `/dev/dri`: the group is added to
the service user and the renderer learns nothing about video. `[mounts] allow` is the only way a
host path outside the service's own volumes and `/etc/guarden` becomes bind-mountable at all —
the renderer refuses every other one, and an entry here is a grant in exactly the sense a port is.
`[firewall] allow` holds **names**, never rule text: the rule lives in the manifest that asked
for it, so the file an operator reviews stays short, and an entry naming a rule no manifest
requested is refused rather than installed.

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

| path | mode | owner | who creates it |
|---|---|---|---|
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
| `/etc/guarden/` | `0751` | `root:guarden` | `soil install`, stated in code |
| `/etc/guarden/` (below), files | `0640` | `root:guarden` | the write protocol |
| `/etc/guarden/services/`, `/etc/guarden/projects.d/` | `0755` | `root:root` | `soil install` |
| `/etc/guarden/edge/`, `/etc/guarden/firewall/` | `0750` | `root:guarden` | `soil install`, stated in code; each seeding writer states its own softly — the firewall's because its phase runs before the `guarden` group exists, the edge's because the write protocol's `mkdir` is umask-dependent |
| `/etc/guarden/projects.toml`, the files under `/etc/guarden/projects.d/`, `/etc/guarden/allow-gated-drop` | `0444` | `root:root` | |
| `/etc/guarden/creds/` | `0700` | `root` |
| `/etc/guarden/edge/auth-provider` | `0640` | `root:guarden` |
| `/etc/ssh/authorized_keys.d/hose` | `0644` | `root` |
| `/run/guarden/locks/` | `2770`, gone on reboot | `root:guarden` — recreated by `/etc/tmpfiles.d/guarden-tmpfiles.conf` |

The `0700` on the service tree is the whole isolation scheme, and there is no carve-out for the
home. Without it every service user can read every other service's state volumes straight off the
host filesystem, and the uid-matched firewall rules and per-consumer credentials stop being
controls. The registry and the overrides are `0640 root:guarden` rather than world-readable,
because the registry describes the whole topology: every uid, every edge, every port, every
snapshot seed.

Four of those numbers are not the default; each is there for one reader:

- **`projects.toml` and the files under `projects.d/` are `0444`** because `hose` — the only network-facing
  program — reads the ref allowlist, and a project name, a repository URL and a ref pattern are
  not secret. `projects.d/` itself is the `0755` directory the table states, because a glob that
  cannot enter the directory silently skips every entry. **Nothing else in `/etc/guarden` is
  readable by `hose`,** and in particular it never
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
| `/etc/guarden/guarden.toml` | the environment, network, ingress and module tables. Four writers, all under the `modules` lock and all through the spec §3.5 protocol: `weedr module add` appends to `[modules] enabled` and rewrites nothing else; `soil install` writes the derived `ingress.alias` (from the pinned `-g`), seeds `[modules] enabled` from cloud-init, and writes `host.admin_user`. Two share `[modules] enabled`, so a write re-reads the file under the lock rather than trusting what it saw before it |
| `/etc/guarden/services/<name>/overrides.toml` | admin grants: ports, firewall rules, retention, groups, mounts |
| `/etc/guarden/firewall/00-ssh.conf` | SSH accept: root:root 0600, seed-once, its own `guarden-ssh` chain, first rule in INPUT after conntrack and lo — written by `soil firewall` |
| `/etc/guarden/firewall/10-framework.conf` | ferm skeleton, the interface's `route_localnet` — written by `soil firewall`. No grant reaches this file |
| `/etc/guarden/firewall/20-ingress-nat.conf` | the edge's three forwarding rules, from the enabled modules' declared ingress — written by `soil firewall`. Each is a `PREROUTING` DNAT and nothing else |
| `/etc/guarden/firewall/30-admin.conf` | admin/module drop-in (optional) — written by `soil firewall` |
| `/etc/guarden/firewall/50-services.conf` | the whole uid-matched filter set, any service's own forwarding and any service's own granted firewall rules, same shape — written by the mutator, under the `firewall` lock |
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
is only ever created by `weedr module add gate-traefik`, which also adds the edge's service user to it
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
`weedr firewall list`, `weedr module list`, `weedr project list`, `stakes list`, `stakes query`,
`furrow queue list` and `furrow status`. When you are writing a check, use the JSON.

---

## Ports and the firewall

**The firewall on this box is `ferm`.** guarden does not use `ufw` and `ufw` is not installed on
a guarden host. `soil packages` installs `ferm`; `ufw` is uninstalled. No `ufw` rule is ever
written or reconciled. If you find a `ufw` rule, something outside guarden put it there.

```sh
ferm --version
```

SSH access is guaranteed structurally: `00-ssh.conf` in `/etc/guarden/firewall/` is root-owned
and seed-once (written only if absent, so an operator's port edit survives reinstall). Its
accept is the first rule of its own `guarden-ssh` chain, and `INPUT`'s first rule after
conntrack and lo is `jump guarden-ssh;`. `soil firewall --apply` **refuses** (exit 1, installs
nothing) unless all of: the file exists, is 0600 root:root, its accept is first in
`guarden-ssh`, and the INPUT jump is first.

```sh
weedr port list
weedr port open <name> 8080/tcp
weedr port close <name> 8080/tcp

weedr firewall list                                  # every rule, installed or pending, and who asked
weedr firewall open <name> <rule-name>               # install one a manifest asked for
weedr firewall close <name> <rule-name>              # withdraw it
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
cat /etc/guarden/firewall/50-services.conf
```

`soil firewall` writes `10-framework.conf` and `20-ingress-nat.conf`; the mutator writes
`50-services.conf` and nothing else. The two are disjoint and each has exactly one writer, so a
rule that appears in both is a defect. `50-services.conf` is the only file a firewall grant can
reach: `10-framework.conf` is the policy baseline and no grant touches it.

To see what the host is *actually running*, read the ruleset. These are ferm files, and ferm
compiles them to iptables, so the live rules are directly visible — an earlier version of this
runbook said otherwise and that error is what let a wrong claim about the masquerade survive:

```sh
iptables-save                 # filter: the uid-matched accept/drop set, and any granted rules
iptables-save -t nat          # nat: the DNAT rules, and nothing that should masquerade
```

The two can legitimately differ — an edit to a `.conf` that has not been converged yet, or a
rule another tool added — and that difference is the thing worth finding. If the live set does
not match the file, the fix is `soil firewall --apply` or a `weedr port`/`weedr firewall`
mutation, not editing either by hand.

`weedr port list` is the human-readable inventory of ports: every service, its requested ports,
its granted ports, and what is pending. `weedr firewall list` is the same idea for rules, and
neither one of them replaces the other.

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
other. `soil firewall` owns the rest: ssh, fail2ban.

### a service asking for a rule of its own

Most traffic goes through the edge, so most manifests never mention a firewall. Some services
cannot be reached through it — a WireGuard endpoint, a full node's peer port — and those
services **ask**:

```yaml
# .guarden/service.yml
firewall:
  - name: wireguard-peer        # a stable name; the grant names this
    rule: "-p udp --dport 51820 -j ACCEPT"
```

The ask installs nothing. It is recorded and stays pending until you grant it:

```sh
weedr firewall list
weedr firewall open wg-production wireguard-peer
weedr firewall close wg-production wireguard-peer
```

`weedr firewall list` is the command you want when something is open and you do not know why:

```
RULE                                  CHAIN         STATE      SERVICES
-p udp --dport 51820 -j ACCEPT       guarden-svc   installed  wg-production wireguard-peer, wg-staging wireguard-peer
-p tcp --dport 22 -j ACCEPT          guarden-svc   pending    myapp-staging admin-ssh
```

Every rule is listed **once**, with every service that asked for it behind it — each entry
written `<service> <the name the manifest gave the rule>` — because two
services asking for the same line get one rule. `weedr firewall close` on one of them leaves
the rule in force while the other still asks; the rule goes when the last one closes. The grant
lives in `[firewall] allow` in that service's `overrides.toml`, and it is removed with the
service.

Three things to know before you grant one:

- **You are agreeing to a line of firewall text, not to a service's intentions.** A rule whose
  match is broader than its author expected reaches everything the match covers. Read the
  `rule:` in the manifest; that is the whole of what is being installed.
- **A granted rule is rendered above the default deny.** That is deliberate — a grant that could
  never match would be useless — and it means a rule matching `-o lo` and accepting really does
  reopen loopback for exactly that match. Nothing else about the deny changes, and the deny is
  still the last line of the chain.
- **A request can only add.** It may not flush a chain, set a policy, reorder guarden's own
  rules or name a chain guarden does not render, so a manifest cannot undo the baseline and
  cannot install its own policy.

A poke leaves these pending exactly as it leaves a port pending, and says so in the push's log
with the command to run. `weedr firewall open` is root and on no sudoers rule, so no deploy path
can reach it.

Every rule guarden writes is IPv4 only, because `soil` disables IPv6. There is no ip6tables set
to go looking for, and if you re-enable IPv6 you are outside what this was designed or tested
for.

**Two host invariants guarden depends on and cannot enforce are detected, not merely refused.**
`soil sysctl --check` and `weedr service list` both report:

- IPv6 has been re-enabled. Every rule in `50-services.conf` is IPv4.
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
the address pasta maps, which is the container's **default gateway** — pinned to `10.0.2.2` by
the `[network] pasta_options` set and recorded in `guarden.toml` as `ingress.alias`:

```sh
grep -A3 '^\[ingress\]' /etc/guarden/guarden.toml   # alias = "10.0.2.2"
grep -A4 '^\[network\]' /etc/guarden/guarden.toml   # the pinned set the alias is derived from
```

`ingress.alias` appears in exactly one place — the `AddHost=` line `loom` writes into a
consumer's units, so `<provider>` resolves — and in **no firewall rule**, because pasta has
already translated the address to `127.0.0.1` by the time the kernel's packet path sees the
connection. It is a constant and it cannot drift: it does not come from the host's route, and a
new gateway, a VPS migration or a VPN changes nothing about it. The one host state that can
collide with it is a route of your own inside the reserved `10.0.2.0/24`; `soil sysctl --check`
warns when one exists, and the remedy is the range change below — not an edit to the alias.

**A mapping that stops working has no host-side check.** The trade is stated plainly: with
the alias derived from configuration, nothing on the host can tell a working mapping from a broken
one — the first symptom is a 502 at the edge, or a refused connection inside a container, and
nothing in guarden's reporting says why. What catches a podman or pasta change before your users
do is the golden VM's hop suite (`tests/t130-alias.sh`), which runs the real container against the
real listener.

Those are the edge's three ingress ports and there are no others. Every other number in
`weedr port list` — 8096, 32400, 5001, 20000 and the rest — is a publication a service exposes
on loopback for the edge to dial. Those get no forwarding rule and need none.

That is **three forwarding rules, not two**: a forwarded udp port is a different protocol and a
different nat rule, and anything that counts the edge's rules counts three. `443/udp` is HTTP/3,
which the edge serves from the same TLS publication as `443/tcp`. It is an additive optimisation
and nothing else depends on it: a browser, a proxy or a network that cannot use HTTP/3 loses
nothing, and removing the rule breaks nothing. A service's own granted port adds one more rule,
in the other file, on the same shape.

### moving an existing host onto the pinned alias

A host installed before the pin keeps the `pasta_options` it was installed with, and the new
validation **refuses it** — exit `2` naming `[network] pasta_options` — until you replace the
set with the pinned one:

```toml
[network]
pasta_options = [ "--map-gw", "--ipv4-only", "-a", "10.0.2.100", "-n", "24", "-g", "10.0.2.2" ]
```

Then `soil install --apply` derives `ingress.alias` from the `-g` value and writes it, and the
alias is a constant from then on. But the units already on the box were rendered with the
**old** alias, and nothing re-renders them on its own: **every service must be re-deployed
once** (or its consumers re-rendered), or its containers resolve their dependencies to the old
gateway and fail. One service at a time, through whatever re-renders it — `weedr service add`'s
reconcile or the next `furrow deploy` — and every preview instance with it.

The check that says it is done — no rendered consumer unit names anything but the alias your
config pins. It reads the alias out of `guarden.toml` rather than hardcoding the default, so it
stays true on the range-change path below:

```sh
alias=$(sed -n 's/^alias = "\(.*\)"$/\1/p' /etc/guarden/guarden.toml | head -1)
grep -rI 'AddHost=' /var/lib/guarden/services/*/home/ | grep -v ":$alias$"
# nothing printed: every consumer unit resolves its providers through the pinned alias
```

Any line it prints is a service that has not been re-deployed yet. And if your own LAN uses
`10.0.2.0/24`, do not live with the overlap: change the range in the one place it is written —
the three values `-a`, `-n` and `-g` in `[network] pasta_options` — re-run `soil install
--apply`, which derives the new alias, and re-deploy as above.

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

A service's own granted port gets the same single DNAT in `50-services.conf`.

`REDIRECT` is not used anywhere, deliberately: it rewrites the destination to the incoming
interface's own address, and the edge listens on loopback only, so nothing would be listening
there.

Two consequences that look like faults:

- **Check the edge on its publication, not on the public host name.** Locally generated traffic
  does not traverse PREROUTING, so a request the box makes to its own public address never
  reaches the forwarding rules. A health check, a smoke test and the structural verification all need the
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
systemctl enable guarden-creds.path      # watch /etc/guarden/creds/ and materialise what changed
systemctl start guarden-creds-boot.service   # or materialise everything, once
```

Those two units are the only place a blob is decrypted, and they are root because the key is.
There is no `guarden-creds.service`; a runbook that named one would send an operator to start a
unit that does not exist and conclude the blobs had been re-materialised. The renderer
emits a *credential request* and never a value, because it has none. For a key the
manifest's schema marks `@required` or `@sensitive`, the generated unit carries
`Secret=<KEY>,type=mount` in the `[Container]` table **and nothing else**, and podman resolves
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
weedr service fork <target[/ref]> --from <service>[@<timestamp>]
weedr service rollback <name[/ref]> --to <timestamp>   # refused outright on a gated track
```

The `@` suffix on `--from` is a **time**, not a snapshot number: `2026-09-29T18:03:11Z`. A bare
number is refused with exit `2`, because one service with several state volumes has a different
number in each configuration and no single number names the set (spec §8.6).

There are two kinds of snapshot and they are governed differently, so read which one you have
before you trust it. A **routine** snapshot, made by the nightly `--all`, is tagged `timeline`
and lives by the volume's ladder. An **on-demand** snapshot — a fork source, or your own "before
the risky change" — is tagged `number`, and is what the pins below protect. `weedr service
snapshot` makes a routine one; a fork makes an on-demand one. There is no flag to choose.

A state volume's snapshots are listed by snapper, which owns them:

```sh
snapper --machine-readable json -c myapp-production-pgdata list
snapper -c myapp-production-pgdata diff 40..41
```

Read them as JSON. It renders a snapshot's `userdata` as a real object, so `important` is a key to
look up; the CSV output renders the whole map as one comma-joined quoted field, so a CSV consumer
ends up string-matching a blob. The fields that matter are `number`, `cleanup`, `date`, `userdata`
and `description`. Anything that parses snapper output — a check, a script, a program's own
`--json` — uses `--machine-readable json` and does not fall back to CSV.

**`--machine-readable` is a global option, so it goes before the command**, as above. Written after
`list` it is refused with `Unknown option '--machine-readable' for command 'list'`, and if you are
looking for a snapshot that is very much there, that error is the whole of what you will see. Two
other things about the document: it is an **object keyed by the configuration's name**, not a list,
so `jq '.[].number'` reads nothing and `jq '.["myapp-production-pgdata"][].number'` reads the
snapshots; and its first entry is **`number 0`**, which is the live subvolume rather than a
snapshot — it is described `current`, has no date and no cleanup tag, and the count you want is
one less than the length of that array.

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
weedr service rollback myapp-production --to 2026-09-27T03:00:00Z
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
`snapper --machine-readable json --config <config> list`, which makes them the input monitoring
will consume. That is the read **Pins** above spells out, including the `0` entry that is not a
snapshot. The counts come from the root read, not from `stakes`, for the reason given under **Pins**
above. Alerting on disk usage and snapshot counts is backlog, not v1, so on this box nothing will
tell you the disk is filling until you look.

### one snapshot that cannot be reaped

`chattr +i` on a snapshot's subvolume is the escalation. The btrfs delete ioctl checks the victim
inode for immutability and returns `EPERM`, which no `NUMBER_LIMIT`, `FREE_LIMIT` or
`SPACE_LIMIT` can override; btrfs does not inherit immutability into a new subvolume, so a fork
from it still works; and it survives `snapper cleanup all`.

The cost is stated here because it is the reason this is not the default. snapper's cleaner
deletes candidates one at a time with no per-item error handling, so the first candidate it
cannot delete aborts the whole cleanup for that configuration for that run. It is a deny, not a
keep-N, and there is no dial that makes it one.

So it is a per-snapshot decision an operator makes, records and can undo, and **one verb does
both halves** — the flag and the record — so they cannot disagree:

```sh
weedr service immutable myapp-production:data@41 "production rollback base"
lsattr /var/lib/guarden/services/<name>/state/<vol>/.snapshots/<n>/snapshot
weedr service mutable myapp-production:data@41          # back to normal, record and all
```

**This is not a pin, and the runbook used to say it was.** `stakes pin` is a *retention* act: it
raises the snapshot to `important=yes` under the number cleaner, which respects it up to a
budget. `chattr +i` is a *deny*: no limit overrides it and the whole cleanup for that
configuration aborts. Pinning when you meant immutability gives you the weaker of the two plus a
side effect you did not ask for. They compose — pin it *and* make it immutable — but each has its
own verb.

Production rollback bases are what it is worth spending on. If you need the flag without the verb,
snapper's own layout puts the snapshot subvolume at `.snapshots/<number>/snapshot`:

```sh
chattr +i /var/lib/guarden/services/<name>/state/<vol>/.snapshots/<n>/snapshot
chattr -i /var/lib/guarden/services/<name>/state/<vol>/.snapshots/<n>/snapshot   # back to normal
```

Doing it by hand is possible and leaves no record, which is why the verb exists.

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
snapper --machine-readable json -c myapp-production-pgdata list
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
hose check                          # could a poke deploy? verifies and exits 0 or 1
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

Both rules are written out in full, once, in `docs/spec.md` §6.6 and §6.7 with their runas
targets. They are not repeated here, because a rule duplicated across documents is a rule that
drifts and this one has changed four times. What an operator needs from them:

- **`guarden ALL=(root)`** — the mutator verbs, run as root. `furrow` runs as `guarden` and
  reaches root through exactly that list. It does **not** name `weedr port open`,
  `weedr port close`, `weedr service purge`, `weedr service rollback`, `weedr service fork`,
  `weedr service add`, `weedr module add`, or any `weedr project` verb, so a workflow can create
  a service and nothing else.
- **`hose ALL=(guarden)`** — the deploy queue, run as `guarden`. A poke reaches the mutator only
  through `furrow deploy` and `furrow preview drop`, and its only `weedr` verb is
  `weedr project list`.

Read them before you change either program. A verb added to a program that is on a rule is a
grant, and a grant added to reach one new capability is a grant to everything that verb can do.
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

`gate-traefik` and `homepage` are on by default in `/etc/guarden/guarden.toml`. Adding a module creates
its services and grants what it declares; it does not re-run soil and does not touch other
modules. `weedr module add` appends the module's name to `[modules] enabled` and rewrites
nothing else in the file, under the `modules` lock and by the same write protocol as every
other shared file. It is one of four writers — `soil install` seeds the table, writes
the derived `ingress.alias`, and writes `host.admin_user` — and the only one that changes which modules are on.

**`weedr module add gate-traefik` is also what creates the `edge` group** and adds the edge's user to it.
`soil install` creates the `guarden` group and no other, and never an `edge` — the `guarden`
group is what makes every `root:guarden` path readable to the unprivileged programs, and `edge`
is only ever created here. A host with no edge module has no `edge` group, and
`/var/lib/guarden/edge/dynamic/` does not exist.

---

## Reaching a tunnel route: `weedr share`

A route on a track whose `expose` is `tunnel` is reached through the tunnel and
is not public on the edge. Getting somebody to it is a **grant**, and a grant is
an issuance that always expires.

```sh
weedr share issue routed-staging alice@example.com --until 7d
weedr share list [--json]
weedr share revoke <id>
weedr share reconcile
```

`--until` is required and there is no spelling of "never": a grant that cannot be
time-bounded is a grant whose expiry is somebody's memory. The value is
`<number><unit>` terms — `12h30m`, `7d` — and a value above the root-owned
`[share] max` in `guarden.toml` is refused. `weedr share issue` against a route
whose destination is `edge` is exit 2 naming the route: the edge is public
already, and there is deliberately no `--via` flag, because which terminator
carries a route is configuration.

**The record is guarden's, and the vendor's Access policy is a projection of it.**
One file per issuance lives in `/var/lib/guarden/share/`, holding an **absolute**
deadline computed at issue time. `weedr share reconcile` recomputes the union of
the live issuances per hostname into one `Allow` policy, writes it to
`/var/lib/guarden/share/projection.json`, and copies it to Cloudflare. It runs on
`guarden-share-reconcile.timer`, every ten minutes, and it is enabled only on a
host that has the `cloudflared` module.

**If that timer stops, a grant outlives its deadline.** The vendor has no expiry
field, so removing the address from the policy is the act that ends a grant and it
is this reconciler that removes it. A live session still ends when
`session_duration` expires — guarden sets it to `[share] max` — but the customer
can sign in again while the email is still in the policy. Check the timer first
when a revoked grant still works:

```sh
systemctl is-enabled guarden-share-reconcile.timer
systemctl is-active guarden-share-reconcile.timer
weedr share list                 # is the record what you expect?
```

**What a leaked API token would allow.** The reconciler holds one token, read
from `/etc/guarden/share.api-token` (`0600 root`), and it is the only thing that
calls the vendor. `guarden.toml`'s `[share] scopes` records what that token
needs — `Access: Apps and Policies Write` — so an operator can see what a leaked
one would reach. It can rewrite the Access policies of the one application named
by `[share] app`, and nothing else. It cannot mint, extend or revoke a grant on
its own: those are `weedr share` verbs, on no sudoers rule, and `hose` cannot
reach them.

**A failed vendor call changes nothing locally.** The record and the projection
stay where they are and one `warning:` names the endpoint and the vendor's error;
the reconciler exits `1` and the next tick retries. A host with no `[share]
account`/`app` or no token is a **state**, not a failure: it warns and exits `0`.

The live path — a browser on a phone with no client reaching the route, a second
browser without the grant refused, and the grant still refused after `weedr share
revoke` — needs a real Cloudflare account and a delegated zone, and is an
operator acceptance step. `just test` does not depend on it.

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
