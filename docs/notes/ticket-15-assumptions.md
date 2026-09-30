# Ticket 15: the load-bearing assumptions, measured

Evidence for [`docs/tickets/15-prove-assumptions.md`](../tickets/15-prove-assumptions.md).
This is a spike's findings, not a decision: where a claim was refuted, the ADR is the human's
call and nothing here has been changed in `docs/adr/` or `docs/spec.md`.

**Result: 5 proven, 1 partly proven, 2 refuted, 11 not run, 1 not determinable, 1 out of scope.**

| # | claim | verdict |
|---|---|---|
| A | the alias is the container's default gateway and pasta maps it | **not run** — no pasta |
| B | the host firewall matches `127.0.0.1`, not the alias | **not run** — no pasta, no root |
| C | the connection arrives with the service uid as the socket owner | **not run** — no pasta, no root |
| D | a rule matching the alias matches nothing; an owner rule on `127.0.0.1` works | **proven** — both halves |
| E | `--no-map-gw`, `--map-host-loopback none`, a non-pasta backend and `network_mode: host` are refused | **not run** — `loom` does not exist |
| F | a container cannot reach a non-publication loopback port; an accepted uid can | **not run** — no pasta, no root |
| G | `--host-lo-to-ns-lo` is unset and a `127.0.0.1`-bound app is unreachable | **not run** — no pasta |
| H | a forwarded port answers from a second machine, no masquerade, peer is the client's address | **not run** — no root, no second machine |
| I | `soil install` writes the measured alias into `guarden.toml` itself | **not run** — `soil` does not exist |
| J | `soil install` refuses to start the edge without `ingress.alias` | **not run** — `soil` does not exist |
| K | `ingress.alias` is empty in a shipped `guarden.toml` | **proven** — no file is shipped |
| L | `soil sysctl --check` reports drift when the route changes | **partly proven** — the mechanism drifts, the check does not exist |
| M | a non-granted service uid fails, with and without the rule | **not run** — needs two uids, root, pasta |
| N | a snapshot of a live rootless PostgreSQL clones, starts, recovers, holds data, is writable | **proven** |
| O | `btrfs property set ro false` is available, and the version is recorded | **proven** — 5.16.2, with a deviation |
| P | the time a clone takes to start and recover | **proven** — 4.30 s cold, 0.41 s warm |
| Q | a publishing service is reachable by name from a second service and from the edge | **not run** — no pasta |
| R | a resource limit on a systemd scope is not silently dropped | **refuted** — `cpu` and `io` are dropped, silently |
| S | a container started from inside a limited scope inherits it | **refuted** — on podman 3.4.4 |
| T | the conclusions go into the ADRs and the spec | **out of scope** — an ADR is the human's call |
| U | if the alias does not work, the ADR is reopened | **not determinable** — A was not run |

The two refutations and the eleven not-runs share one cause, and it is worth stating before
the detail: **every check that needs pasta needs a podman that has pasta, and this host's
podman does not.** See §0.

---

## 0. The machine this ran on, and what it could not do

```
date:                2026-09-29T23:13:28Z
host kernel:         6.9.3-76060903-generic
btrfs-progs:         v5.16.2
podman:              3.4.4
podman cgroup:       cgroupManager=systemd, cgroupVersion=2
slirp4netns:         1.0.1
cgroup fs:           cgroup2fs
user:                rumlyne uid=1000
sudo:                a password is required          <- interactive, not available
root filesystem:     /dev/mapper/data-root[/@] btrfs
```

Three facts about this host decide what is measurable and what is not.

**No root, and no interactive sudo.** `sudo -n true` returns `a password is required` and the
fingerprint reader times out. Nothing that writes `/etc`, `/sys/fs/cgroup` outside a private
namespace, or a firewall table on the real host was run.

**podman 3.4.4 has no pasta.** The design requires pasta: spec §7.1 and §6.3 are built on it.

```
$ podman run --rm --network=pasta alpine:3.20 true
Error: unable to find network network configuration for pasta: network not found

$ podman info | grep -i networkBackend -A2
    slirp4netns:
      executable: /usr/bin/slirp4netns
```

pasta support arrived in podman 4.0. **Every document that says "pasta" is therefore untested
here**, and no substitute was used: a stand-in for pasta would answer a different question.
`https://passt.top/pasta` returned `404` and no upstream release was fetched, because a
different pasta build is not the build guarden would pin, and pasta's loopback mapping is
off unless asked for.

**This is a laptop, not the target.** The default route is `wlp170s0` (Wi-Fi, DHCP):

```
$ ip route show default
default via 10.188.205.118 dev wlp170s0 proto dhcp metric 600
```

so a forward is not the thing under test, and there is no second machine to forward from.

What *was* available and used: unprivileged btrfs subvolume creation on the host's own btrfs
(`/tmp` is btrfs), unprivileged rootless podman with working containers, a user systemd session
with cgroup v2, and `unshare -n` for a private network namespace where this user holds
`CAP_NET_ADMIN` and can install real iptables rules.

---

## 1. Proven

### D. A rule matching the alias matches nothing; a uid-matched rule on 127.0.0.1 works

**PROVEN, both halves.** Run in a private netns, which is enough to settle the *rule* half of
the claim; the pasta half of it is item A and was not run.

```sh
unshare -n --map-root-user owner-rule.sh
```

with the script binding a listener to `127.0.0.1:27821` and installing two rule sets in turn.
Actual output:

```
netns: lo               UNKNOWN        127.0.0.1/8 ::1/128

=== baseline: nothing configured ===
  127.0.0.1:27821 -> 200

=== a rule set built the wrong way: an owner accept on the ALIAS address ===
  OUTPUT chain:
    -P OUTPUT ACCEPT
    -A OUTPUT -d 192.0.2.1/32 -o lo -m owner --uid-owner 0 -j ACCEPT
    -A OUTPUT -d 127.0.0.0/8 -o lo -m owner --uid-owner 0 -j DROP
  127.0.0.1:27821 -> no-answer
  ABORT: the baseline itself does not work, so the rest of this run proves nothing
  the alias rule fired: 0 packets

=== the right way: an owner accept on 127.0.0.1, drop for every other uid ===
  OUTPUT chain:
    -P OUTPUT ACCEPT
    -A OUTPUT -d 127.0.0.1/32 -o lo -m owner --uid-owner 0 -j ACCEPT
    -A OUTPUT -d 127.0.0.0/8 -j DROP
  127.0.0.1:27821 -> 200
```

Reading it: the connection's destination is `127.0.0.1`, so the accept written for the alias
matched **0 packets** and the catch-all drop took the connection. A rule set built on the
conflation is not merely inert, it is the opposite of inert: it blackholes the hop it was
meant to permit. The correctly-written set, `-d 127.0.0.1 -m owner --uid-owner`, passes.

That is spec §7.1's first and second bullets, measured:

> At the point the host's `OUTPUT` chain sees the connection it is already
> `127.0.0.1:<publication>` … a rule that matches on it matches nothing.
> **The only host-side control that can see this hop is an `owner` match in `OUTPUT`.**

One caveat, and it is the reason this was not simply reported as settled: this run has a single
uid (0, inside a single-uid userns), so the accept arm of `-m owner --uid-owner` is not
distinguished from a rule that matched on the address alone. The drop arm and the
zero-packet count are what carry the finding. Item M, which needs two uids, was not run.

A discarded first attempt is worth recording, because it is the failure mode this ticket
warns about: with `lo` still `DOWN` in the fresh netns, the baseline returned `000` and both
rule sets appeared to "fail" identically. Nothing was proven. The script now brings `lo` up and
aborts the run if the baseline is not `200` before drawing any conclusion.

### K. `ingress.alias` is empty in a shipped `guarden.toml`

**PROVEN, and vacuously so — there is nothing to be wrong yet.**

```sh
$ find . -name guarden.toml -not -path './.git/*'          # no output
$ ls /etc/guarden
ls: cannot access '/etc/guarden': No such file or directory
```

No `guarden.toml` is committed and none is installed. The value the design starts from is
therefore empty, as spec §3.1 requires:

```toml
[ingress]
alias = ""                  # the address a rootless container can reach the host on. Empty until
                             # ticket 15 measures it; `soil install` writes the measured value here
```

This stays true after this spike, because item A was not run and nothing was measured. Ticket
20 is what makes it concrete.

### N. A btrfs snapshot of a live rootless PostgreSQL clones, starts, recovers, holds its data and is writable

**PROVEN.** This is the load-bearing storage claim, and it holds.

The state volume is a real btrfs subvolume owned by the service uid, with `PGDATA` on it and
the database running:

```sh
btrfs subvolume create /tmp/t15/pg/state
podman run -d --name pgprod --userns=keep-id --user 1000:1000 \
  -e POSTGRES_HOST_AUTH_METHOD=trust -e PGDATA=/var/lib/postgresql/data \
  -v /tmp/t15/pg/state:/var/lib/postgresql/data postgres:16-alpine
```

Data written, so that "the data is present" means something:

```sh
$ podman exec pgprod psql -U postgres -d postgres -c \
    "CREATE TABLE proof(id int primary key, note text); INSERT INTO proof VALUES (1,'written before the snapshot');"
CREATE TABLE
INSERT 0 1
```

The snapshot, taken **while the service was running** — `pgprod Up 55 seconds`, never stopped:

```sh
$ podman ps --format '{{.Names}} {{.Status}}'
pgprod Up 55 seconds ago
$ btrfs subvolume snapshot /tmp/t15/pg/state /tmp/t15/pg/snapshot-41
Create a snapshot of '/tmp/t15/pg/state' in '/tmp/t15/pg/snapshot-41'
```

The fork, exactly as spec §8.4 step 5 describes it — clone, clear the read-only flag, set the
owner:

```sh
$ btrfs subvolume snapshot /tmp/t15/pg/snapshot-41 /tmp/t15/pg/clone-staging
Create a snapshot of '/tmp/t15/pg/snapshot-41' in '/tmp/t15/pg/clone-staging'
$ btrfs property set /tmp/t15/pg/clone-staging ro false
$ chown -R 1000:1000 /tmp/t15/pg/clone-staging
```

The clone starts and recovers. The recovery is the proof that the snapshot was a consistent
instant of a *running* database, which is what spec §8.2 relies on:

```
LOG:  database system was not properly shut down; automatic recovery in progress
LOG:  redo starts at 0/14F7168
LOG:  redo done at 0/1558D08 system usage: CPU: user: 0.00 s, system: 0.00 s, elapsed: 0.00 s
LOG:  checkpoint starting: end-of-recovery immediate wait
LOG:  checkpoint complete: wrote 79 buffers (0.5%) ... total=0.173 s
LOG:  database system is ready to accept connections
```

The data is present, the clone is writable, and the source is untouched by the clone's write:

```
$ podman exec pgfork psql -U postgres -d postgres -Atc "SELECT id, note FROM proof;"
1|written before the snapshot
$ podman exec pgfork psql -U postgres -d postgres -c "INSERT INTO proof VALUES (2,'written into the clone');"
INSERT 0 1
$ podman exec pgfork psql -U postgres -d postgres -Atc "SELECT count(*) FROM proof;"
2
$ podman exec pgprod psql -U postgres -d postgres -Atc "SELECT count(*) FROM proof;"
1
$ podman ps --format '{{.Names}}  {{.Status}}'
pgprod  Up 2 minutes ago
pgfork  Up 13 seconds ago
```

Both services ran at once, on two subvolumes, each with its own engine — the production/staging
pair the lineage rules describe.

Copy-on-write was measured, not asserted. Cloning the 39 MiB database again consumed:

```
used before: 425540444 KiB
used after:  425541188 KiB
delta: 744 KiB for a 39 MiB database
```

744 KiB of new extent-tree and metadata for a 39 MiB clone, which is what "constant time" and
"the clone is the buffer" (§8.4) mean in practice.

### O. `btrfs property set <path> ro false` is available, and the version is recorded

**PROVEN.** btrfs-progs **v5.16.2**, above the 5.14 that spec §8.4 requires. It is available
and it works, as the unprivileged owner of the subvolume:

```sh
$ btrfs property set /tmp/t15/ro-test/snap ro true
$ btrfs property get /tmp/t15/ro-test/snap ro
ro=true
$ touch /tmp/t15/ro-test/snap/snap-canary2
touch: cannot touch '/tmp/t15/ro-test/snap/snap-canary2': Read-only file system
write exit=1
```

**One deviation, recorded because the documents assume the opposite.** A snapshot created by
this user arrived **writable** — the flag was never set on it:

```
=== a plain subvolume: ro, and a write attempt ===
ro=false
write exit=0

=== a snapshot of it, created unprivileged ===
Create a snapshot of '/tmp/t15/ro-test/src' in '/tmp/t15/ro-test/snap'
ro=false
write exit=0

=== can the ro flag be set, and does it then bite? ===
ro=true
touch: cannot touch '/tmp/t15/ro-test/snap/snap-canary2': Read-only file system
write exit=1

=== is the snapshot still a separate instant? ===
payload
```

The snapshot is a real point-in-time copy — the source was changed afterwards and the snapshot
kept `payload` — it simply is not read-only. The ro *mechanism* is fine; the flag is just not
there.

What this does and does not mean. Spec §8.4 step 5 says a fork clones the source "then clear
the read-only flag", which assumes the clone comes with the flag set. In this configuration it
does not, so that step is a no-op — harmless, and the fork works either way, as N shows. The
one thing this run cannot settle is whether a snapshot created by **root** — which is how
`weedr` creates one — arrives read-only. This user is not root, so that was not tested, and
the documents' assumption may well hold for the privileged case. Treat "clear the read-only
flag" as unverified rather than wrong until someone runs it as root.

### P. The time a clone takes to start and recover

**PROVEN, for a small database.** Two numbers, because the interesting one is the difference.

Clone of a **live** database, recovering from the crash the snapshot represents:

```
ready flag: 1
clone start-to-ready: 4.30 s
```

Clone that has already recovered once, started again clean:

```
clean-shutdown clone start-to-ready: 0.41 s
```

With the log's own breakdown, the 4.30 s is not database work: `redo … elapsed: 0.00 s` and
`checkpoint complete … total=0.173 s`. It is container start plus a single small replay. So for
a 39 MiB database the fork cost is **4.3 s cold, 0.4 s warm, and the redo itself is
immeasurable at this size**.

PRD §11's second open question asks about recovery for "a database larger than anything on the
current box". This does not answer it — 39 MiB is a small database, and redo time is the term
that will grow. What it does establish is that the recovery path is exercised and fast at the
small end, so the number to re-measure later is redo duration, not start-up.

---

## 2. Refuted

Both refutations are about resource limits, and neither is about guarden's code, which does not
exist yet. They are about a **host property the documents never state as a requirement and no
check ever verifies.**

### R. A resource limit set on a systemd scope is not silently dropped

**REFUTED on this host — two of the three are dropped, silently.** This is precisely the case
ticket item 18's own note describes, and it is found by reading the files rather than trusting
systemd.

Set all three and read all three back:

```sh
systemd-run --user --scope --quiet -p MemoryMax=256M -p CPUWeight=37 -p IOWeight=42 \
  bash -c 'm=$(awk -F: "/^0::/{print \$3}" /proc/self/cgroup)
           for f in memory.max cpu.weight io.weight; do
             if [ -e "/sys/fs/cgroup$m/$f" ]; then echo "$f = $(cat /sys/fs/cgroup$m/$f)";
             else echo "$f = ABSENT"; fi
           done'
```

```
scope cgroup: /user.slice/user-1000.slice/user@1000.service/app.slice/run-r9f9eb4d2….scope
memory.max = 268435456
cpu.weight = ABSENT
io.weight = ABSENT
```

`MemoryMax=256M` applied exactly. `CPUWeight=37` and `IOWeight=42` did nothing at all, and
systemd reported no error, because the interface files do not exist. The controllers are cut
between `user.slice` and the user's own slice:

```
/                                              subtree_control=cpuset cpu io memory hugetlb pids rdma misc   available=cpuset cpu io memory hugetlb pids rdma misc
/user.slice                                    subtree_control=memory pids                                    available=cpuset cpu io memory hugetlb pids rdma misc
/user.slice/user-1000.slice                    subtree_control=memory pids                                    available=memory pids
/user.slice/user-1000.slice/user@1000.service   subtree_control=memory pids                                    available=memory pids
```

`cpu` and `io` are available at `user.slice` and not enabled in its subtree; by
`user-1000.slice` the `cgroup.controllers` file no longer lists them. The kernel offers
everything; the delegation stops.

**Why this matters to guarden.** The track's `weight` is documented as reaching the box through
the generated units — spec §3.1:

```toml
weight = 1000                    # CPUWeight and IOWeight in generated units
```

That is the only sentence in the spec that ties `weight` to a resource limit, and on a host
delegated like this one the `CPUWeight=` and `IOWeight=` lines `loom` renders are **inert**.
A production container that misbehaves is not deprioritised; the box just does not see
production as more important than a preview. It fails silently, and nothing in the
specification looks for it. §6.1 gives `soil sysctl --check` exactly two jobs — the
`ingress.alias` drift and the `route_localnet` value — and the one place that does report host
state at all, §6.2's `weedr service list`, says:

```sh
# spec 6.2, weedr service list
It also reports the effective firewall state and one host invariant guarden cannot enforce and
one it can.
```

IPv6 and the port threshold. There is no check on delegated controllers anywhere in the
specification, and no requirement that says they must be delegated.

**Which sentence is wrong.** None of them is false; spec §3.1's comment states an intention
that is not guaranteed. The gap is that the mechanism is presented as unconditional
(`CPUWeight and IOWeight in generated units`) with no host precondition and no check. That
needs a decision, not a patch from a spike: either the host requirement becomes explicit and
`soil` verifies it, or the documents admit the weights are best-effort. The evidence is above.

### S. A container started from inside a limited scope inherits that scope

**REFUTED, on this podman version.** A container created inside a scope with
`MemoryMax=512M` allocated 2 GiB and lived:

```
launching scope:      /user.slice/user-1000.slice/user@1000.service/app.slice/run-r08d1377….scope
launching memory.max: 536870912
container id:         512a442f62e591c26a2fdf1bc78b1dbad31e6708fe003a76b8e344fae6cc5928
podman CgroupPath:    /user.slice/user-1000.slice/user@1000.service/user.slice/libpod-512a442f….scope
pid 3784737 (sleep) cgroup: /user.slice/user-1000.slice/user@1000.service/user.slice/libpod-512a442f….scope/container
    memory.max at that cgroup: max
pid 3784733 (conmon) cgroup: /user.slice/user-1000.slice/user@1000.service/app.slice/run-r08d1377….scope
    memory.max at that cgroup: 536870912
--- the limit must bite if the scope is inherited: allocate 2 GiB ---
2147483648 bytes (2.0GB) copied, 1.533438 seconds, 1.3GB/s
dd exit=0
--- what the container sees of its own limits ---
0::/
memory.max: max
```

podman asked the user systemd manager for a new scope and systemd placed it at
`user@1000.service/user.slice/libpod-….scope` — **not** beneath the caller's scope in
`app.slice/`. `conmon` stayed in the launching scope and inherited 512 MiB; the container's own
processes did not. The limit is inherited by the supervisor and not by the thing being
supervised.

The `/proc/1/cgroup` comparison the ticket asks for is not usable on its own, and it is worth
recording why: inside the container it reads `0::/`, because the container has a private cgroup
namespace. The honest read is the host-side one, which is `podman inspect
--format '{{.State.CgroupPath}}'` plus reading the limit at that path — and the allocation
test, which settles it without interpreting any path at all.

**Which sentence is wrong.** This refutes the property, not a sentence: nothing in the spec or
the ADRs currently asserts scope inheritance, but ticket item 18 calls it "the property the
whole memory story for agent-spawned containers rests on". It does not hold here, so a
container spawned by a guarden service is **not** bounded by a limit set on the scope that
spawned it. If that story is wanted, it has to be built rather than assumed — a quadlet unit's
own `MemoryMax=`, or an explicit cgroup path handed to the container.

**The version caveat is the whole caveat, and it is not small.** This is podman **3.4.4**, and
guarden needs podman **4.0 or later** for pasta. podman's cgroup handling changed across
4.x. Nothing here licenses a conclusion about podman 4.x, and the measurement has to be
repeated on the version guarden will actually install. What is established is that the property
cannot be assumed without measuring it, which is what this ticket is for.

---

## 3. Partly proven

### L. `soil sysctl --check` reports drift when the recorded alias no longer matches the route

**The mechanism is proven; the check was not run, because `soil` does not exist.**

The alias is a pure function of the routing table, it moves when the gateway moves, and it
goes empty when the default route is gone. Measured in a private netns, where this user holds
`CAP_NET_ADMIN`:

```sh
unshare -n --map-root-user alias-drift.sh
```

```
=== a first default route, as a host with one interface would have ===
default route: default via 192.0.2.1 dev dummy0
derived alias: 192.0.2.1

=== the interface's address changes, as a DHCP renewal would ===
default route: default via 198.51.100.1 dev dummy0 metric 600
derived alias: 198.51.100.1

DRIFTED: 192.0.2.1 -> 198.51.100.1

=== no default route at all: what does a derivation return? ===
derived alias: '' (empty)
```

So spec §6.1's drift check has something real to detect, and a DHCP renewal on a Wi-Fi
interface is enough to trigger it — which on this host is the normal case, not an edge case.

**One edge case the documents do not name.** With no default route the derivation returns the
**empty string**, which is the same value spec §3.1 uses for "not measured yet" and the same
value §6.1 refuses to start the edge on. The outcome is safe — the edge refuses either way — but
the diagnostic would say "not measured" when the truth is "this host has no default route",
and those want different fixes. Worth a sentence in §6.1 when the probe is written.

`soil sysctl --check` itself is ticket 20 and was not run.

---

## 4. Not run

None of these is reported as passing. Each needs root, a podman with pasta, or a second
machine, and this host has none of the three. The commands are what a human would execute.

### A. The alias is the container's default gateway, and pasta maps it

Not run: no pasta. The contrast that *was* measured is why pasta is load-bearing. A rootless
container on this host uses slirp4netns, and its gateway is a slirp-internal address that
reaches nothing on the host:

```
default via 10.0.2.2 dev tap0
10.0.2.0/24 dev tap0 scope link  src 10.0.2.100
```

A host listener on `127.0.0.1:27813` was reachable from the host and from no address inside the
container:

```
--- container -> 127.0.0.1:27813 ---        nc exit=1
--- container -> 10.0.2.2:27813 ---         nc exit=1
--- container -> 10.188.205.118:27813 ---   nc exit=1
```

That is a necessary condition, not the claim: it shows the alias would be useless without
pasta, and says nothing about whether pasta makes it work.

```sh
# unexecuted — needs podman >= 4.0 with pasta, on a throwaway machine
podman run --rm --network=pasta:<opts from guarden.toml [network] pasta_options> \
  alpine sh -c 'ip route; nc -w3 $(ip route show default | awk "{print \$3}") <probe-port>'
# record the literal address, never podman's host.containers.internal token
```

### B. The host-side firewall matches `127.0.0.1`, not the alias

Not run: needs pasta for the connection and root for the host's chains. Item D proves what the
rules match; this item is about what pasta has already rewritten by the time they see it.

```sh
# unexecuted — with a pasta container's connection open, on the host
iptables-save -t nat
iptables-save
# the OUTPUT chain's destination must read 127.0.0.1, not the alias
```

### C. The connection arrives with the consuming service uid as the socket owner

Not run: needs a real service uid, a real container and root to watch the socket. Item D
covers the rule arm of this; the owner of the *pasta* socket is the part untested, and it is
the part §7.1 calls "the only host-side control that can see this hop".

```sh
# unexecuted
ss -tnp | grep <probe-port>          # in the host namespace, during the connection
```

### E. `--no-map-gw` and `--map-host-loopback none` are refused; a non-pasta backend and `network_mode: host` are refused with the key named

Not run: `loom` does not exist (ticket 40), and pasta is not installed, so its option set could
not even be enumerated to check that those two spellings are the ones to refuse. What *is*
established is the host floor: podman must be 4.0 or later for the `Network=pasta:` the
renderer emits to mean anything, and **no document in this repository states a podman version**.
That is a gap worth closing independently of the renderer.

### F. A container cannot reach a host loopback port that is not a publication; an accepted uid can

Not run: this is the default-deny claim, and it needs pasta plus a real `OUTPUT` rule set plus
two uids.

```sh
# unexecuted — needs pasta, root, and a listener on a non-publication loopback port
podman run --rm --network=pasta … nc -w3 127.0.0.1 22        # must fail
podman run --rm --network=pasta … nc -w3 <alias> <publication>  # must succeed
```

### G. `--host-lo-to-ns-lo` is not set, and an app bound to `127.0.0.1` inside a container is unreachable

Not run: pasta. Spec §7.1 states the option is undesirable by default and that the gotcha is
therefore expected; the measurement would confirm the default, which is pasta's own default and
not guarden's doing.

### H. A forwarded port answers from a second machine, with no masquerade; the service sees the client's real address

Not run, and not runnable here at all: it needs root (`route_localnet`, the DNAT) and a second
machine. **This is the single most important unrun check in the ticket**, because a forward
cannot be distinguished from no forward by any request the box makes to itself.

```sh
# unexecuted — on the guarden host, as root, with a service granted 8080/tcp
sysctl -w net.ipv4.conf.$(ip route show default | awk '{print $5}').route_localnet=1
iptables-save -t nat | grep -A5 POSTROUTING          # must contain no MASQUERADE for the grant
# from the SECOND machine:
curl -v http://<host-public-ip>:8080/                # must answer
# and on the host, during that request:
ss -tnp | grep 8080                                  # the peer must be the client's address
```

### I. `soil install` writes the measured alias into `guarden.toml` itself

Not run: `soil` does not exist (ticket 20). §6.1 already specifies the probe's four recordings
and that it writes the result itself, so this is a check against a future implementation.

### J. `soil install` refuses to start the edge without `ingress.alias`, naming the key

Not run: ticket 20. §6.1 specifies the refusal; item K confirms the value it refuses on is
indeed empty today.

### M. A connection attempt from a non-granted service uid fails, with and without the rule

Not run: needs two real uids, root, and pasta. A single-uid userns cannot express the
difference, and the netns run in item D could only show the drop arm.

```sh
# unexecuted — as root, with two service uids and pasta
runuser -u <accepted-uid> -- nc -w3 <alias> <publication>   # succeeds
runuser -u <other-uid>    -- nc -w3 <alias> <publication>   # fails, rule in place
iptables -F OUTPUT                                          # and fails without it too
```

### Q. A service publishing a loopback port is reachable by service name from a second service, and by the edge

Not run: pasta. This is the case the ticket calls most likely to be missed, because it only
fails at request time, and nothing here can stand in for it.

```sh
# unexecuted — needs two services, the edge, and pasta
podman exec <consumer> getent hosts <provider-service>     # must resolve to the alias
podman exec <consumer> nc -w3 <provider-service> <publication>
podman exec <edge>      getent hosts <provider-service>
```

### U. If the alias does not work, the ADR is reopened and a replacement proposed

**Not determinable.** Item A was not run, so the alias is neither proven nor refuted, and the
condition this item is written for has not occurred. Nothing is proposed here. §7.1 says ADR-0004
is reopened if the measurement fails; the measurement has not been made. PRD §11's first open
question is likewise still open.

---

## 5. Out of scope by instruction

### T. Write the conclusions into ADR-0004 and ADR-0007 and the spec, and strike the PRD's open questions

Deliberately not done. The instruction for this spike was that the evidence is committed under
`docs/notes/` and that **an ADR is the human's call**. Nothing in `docs/adr/`, `docs/spec.md` or
`docs/PRD.md` was modified.

For whoever does that, here is the ledger. Two conclusions would change a document:

1. **The resource weights need a host precondition or an admission of best-effort** (item R).
   `CPUWeight=` and `IOWeight=` are silently inert wherever `cpu` and `io` are not delegated to
   the user slice, and no check exists. §3.1's comment and §6.1's check list are the places.
2. **A container does not inherit the launching scope's limits** (item S), on podman 3.4.4 at
   least. If a memory story for agent-spawned containers is wanted, it must be built into the
   unit rather than inherited.

Two findings are documentation-level, not architectural: an unprivileged btrfs snapshot is
writable, so §8.4 step 5's "clear the read-only flag" is a no-op in at least one configuration
(item O, untested as root); and the alias derivation returns the empty string when there is no
default route, which is indistinguishable from "not measured" (item L).

One PRD question is partly answered and should be annotated rather than struck: §11's second
question is about recovery time for a large database, and item P gives 4.3 s cold / 0.4 s warm
with `redo elapsed: 0.00 s` for a 39 MiB database — the small end only, and the term that
grows is redo, not start-up.

PRD §11's first question — the pasta alias — is untouched. It is the question the whole
connectivity design rests on, and it is the one this host could not answer.

---

## 6. What to run next, in priority order

1. **A, B, C, F, G, Q on a throwaway machine with podman 4.x and pasta.** These are one
   experiment: boot, run the probe §6.1 describes, and the connectivity model is either
   confirmed or ADR-0004 is reopened. Nothing else in guarden can be built on until it is done.
2. **R and S again on podman 4.x.** Both refutations are version-bound, and the versions matter
   more than the results: the question is whether `loom` may render `CPUWeight=` at all, and
   whether a spawned container is bounded.
3. **H, from a second machine.** Needs a granted port and root, and is the only check that
   distinguishes a working forward from none.
4. **E, I, J** with the renderers, as they are written.
5. **O as root**, to settle whether a root-created snapshot is read-only.
