# Ticket 307b: what a pod actually gives us, measured

Evidence for `t307b` (the kanban card under ticket
[`307-monorepo-multi-app-deploys.md`](../tickets/307-monorepo-multi-app-deploys.md)),
which t307c depends on. This is a measurement, not a decision: where a claim was
refuted, what to do about it is the operator's call and nothing in `docs/adr/` or
`docs/spec.md` was changed.

The suite that produces all of it is [`tests/t307-pod-keepid.sh`](../../tests/t307-pod-keepid.sh),
and it is green.

**Result: 1 refuted, 1 refuted with a workable substitute, 2 proved.**

| # | claim | verdict |
|---|---|---|
| 1a | a container in a pod keeps its own `UserNS=keep-id:uid=<image uid>` pin | **REFUTED** — podman refuses it, three spellings |
| 1b | a pod shares net/ipc/uts and **not** the user namespace | **REFUTED** — the user namespace is in the pod's `SharedNamespaces` |
| 1c | one pod can put several different image uids onto the service user | **REFUTED**, with a substitute: one uid, plus container root |
| 2 | `[network] pasta_options` apply to a POD, and the host answers at `10.0.2.2:<publication>` from inside a pod container | **PROVEN** |
| 3 | two containers of one pod round-trip a payload over `127.0.0.1` | **PROVEN** |

## 0. The machine

```
golden:            Ubuntu 26.04, cut per suite (`tests/lxc.sh`), 2026-10-22
podman:            5.7.0 (rootless, as the service user)
network backend:   pasta, from `passt` in packages/packages.toml
pasta options:     --map-gw,--ipv4-only,-a,10.0.2.100,-n,24,-g,10.0.2.2
                   (read out of the host's own /etc/guarden/guarden.toml)
service user:      uid 994, gid 981 — created by `weedr service ingest`,
                   not by a `useradd` in the suite
volume:            a directory in the service's own tree, 0700, owned 994:981
```

Everything below was measured as the service user through `setpriv`, which is the
identity a rendered unit runs under.

## 1. The per-container pin does not exist in a pod

**REFUTED.** t307b's premise was "a pod shares net/ipc/uts but NOT the user
namespace, so each container should keep its own `UserNS=keep-id:uid=<image
uid>` pin". Podman 5.7.0 refuses a container that carries both:

```sh
$ podman run --userns keep-id --pod podplain alpine true
Error: --userns and --pod cannot be set together            (exit 125)

$ podman run --pod podplain --userns keep-id:uid=33,gid=33 alpine true
Error: --userns and --pod cannot be set together            (exit 125)

$ podman run --pod podplain --uidmap 0:100000:65536 alpine true
Error: cannot specify a new uid/gid map when entering a pod with an infra
container: invalid argument                                 (exit 125)
```

Both flag orders, the bare `keep-id` and the uid-bearing spelling the renderer
would write, and the only other way to express a mapping (`--uidmap`). There is
no spelling left: **a container that carries `Pod=` cannot carry `UserNS=`.**

The reason is 1b. `--userns` is not per-container in a pod because the pod
already has one:

```sh
$ podman pod create --name podplain --network pasta:…
$ podman pod inspect podplain --format '{{.SharedNamespaces}}'
[uts ipc net]

$ podman pod create --name podpin --network pasta:… --userns keep-id:uid=33,gid=33
$ podman pod inspect podpin --format '{{.SharedNamespaces}}'
[ipc net user uts]
```

`user` appears exactly when the pod was given a `--userns`. The user namespace
is a **pod** property, and the card's premise is inverted.

## 2. What a pod-level pin does — one uid, plus root

A pod-level pin is accepted, and it works. Three containers in the pinned pod,
each writing into the service user's 0700 directory:

```
pod  --userns keep-id:uid=33,gid=33
  --user 33:33    → /data/pinned-33.txt   994:981  (the service user)
  (no --user)     → /data/root.txt        994:981  (the service user)
  --user 999:999  → sh: can't create /data/other.txt: Permission denied
```

The root case is rootless podman's default mapping — container root is the
calling user, which is ADR-0019's "no `USER` line, no pin needed" row, unchanged
by the pod. The 999 case is the constraint: a uid that is neither the pinned one
nor root lands in the service's subuid band, which is not the service user, and
the 0700 directory refuses it.

**The control, and it is the point of the whole measurement:** the same uid-33
container, the same command, in a pod with no `--userns`:

```
pod (no --userns)
  --user 33:33    → sh: can't create /data/plain-33.txt: Permission denied
```

So the pod's pin, and not `--user`, is what puts a non-root uid onto the service
user — and the refusals are the reason the two greens above mean anything.

**One pod can therefore host: containers running as the pinned uid, and
containers running as root. Nothing else.**

## 3. Pasta applies to the pod

**PROVEN.** `podman pod create --network pasta:<the pinned option set>` is
accepted, and a container of that pod carries the addressing:

```
$ podman exec net-srv ip addr show
2: enp5s0: <BROADCAST,MULTICAST,UP,LOWER_UP> …
    inet 10.0.2.100/24 scope global enp5s0
$ podman exec net-srv ip route
default via 10.0.2.2 dev enp5s0
10.0.2.0/24 dev enp5s0 scope link  src 10.0.2.100
```

pasta's device inside the namespace is named by the runtime — `enp5s0` here, not
`eth0` — so a suite must not assert an interface name.

The host, from inside a pod container. A publication is a listener on the host's
loopback bound by the service user (`python3 -m http.server … --bind 127.0.0.1`
as uid 994, port 24123, inside guarden's publication range):

```
host:                          GET /hostproof.txt → 200, body host-publication-307
pod container → 10.0.2.2:24123  → host-publication-307     (exit 0)
pod container → 10.0.2.100:24123 → Connection refused      (exit 1)
```

The second line is the discriminator: the pod's **own** address is not where the
host is, so the first line is pasta's gateway mapping and nothing else. The host
side's log of the request prints the source as `127.0.0.1`, which is spec §7.1's
translation seen from the receiving end.

## 4. Two containers of one pod round-trip a payload

**PROVEN**, and not by a connect. One container's own process serves, a second
container's own process fetches, and both halves are read:

```
client (container 2):  wget -qO- http://127.0.0.1:8080/proof.txt
                       → pod-roundtrip-307
server (container 1):  cat /tmp/request.txt
                       → GET /proof.txt HTTP/1.1
                         Host: 127.0.0.1:8080
                         User-Agent: Wget
                         Accept: */*
                         Connection: close
```

The response is 17 bytes with a `Content-Length: 17` and a `Connection: close`,
so the client's success is the payload arriving; the server's captured input is
the request arriving. Neither half alone would have been enough.

**busybox cannot serve HTTP out of the box on this image.** alpine:3.20's busybox
carries **no `httpd` applet** (`command -v httpd` → nothing; `httpd: not found`,
exit 127) and `nc` has no `-z`, which is why the fixture is a `while` loop around
a one-shot `nc -l -p 8080` fed a canned response. A suite that reached for
`busybox httpd` would have been red for a reason that has nothing to do with
pods.

## 5. Two harness facts, measured, that cost this run two reds

Neither is about pods, and both will bite the next suite that runs containers:

- **`podman logs` answers nothing on this host.** The log driver is `journald`,
  a rootless user's journal is not readable here, and `podman logs` returns exit
  0 with empty output. `--log-driver k8s-file` fixed the stdout half and **still
  lost the container's stderr**: a container that printed its uid and then failed
  a write came back with the uid and nothing else, twenty seconds apart, twice.
  A refusal is therefore read from a **foreground** run, where podman passes the
  container's stderr to the caller.
- **`--publish`-free pod containers still get a device named by the runtime.**
  See §3: `enp5s0`. Assertions about addressing must name the address, not the
  interface.

## 6. What this means for t307c, and what is left to decide

t307c's design line "each container should keep its own `UserNS=keep-id:uid=<image
uid>` pin" cannot be rendered. Quadlet writes `UserNS=` as `--userns`, so a
`.container` carrying both `Pod=` and `UserNS=` produces a unit that fails at
start with the message in §1 — the failure would arrive at the first start rather
than at render time, which is the worst place for it.

What is available instead:

- **A pod-level pin: `UserNS=` in the `.pod` unit**, from the same probe
  ADR-0019 already runs. It must be in `render.py`'s owned-fields list for the
  `.pod` key set, for the reason t307c's trap note gives about `Pod=`: a
  repository must not be able to choose the pod's user namespace.
- **The constraint it buys:** every container in the pod must run as the pinned
  uid or as root. Apps whose images settle on different non-root uids cannot
  share a pod — `postgres:17` (999) and an app at 33 is exactly such a pair. The
  four shapes of t307c stay expressible, but "one pod per source" can only hold
  when the source's apps agree on a uid; where they do not, the pod has to be
  split by uid.
- **For the split case, the machinery already exists** and the ticket itself
  points at it: siblings and edges over the host's loopback publications
  (spec §7.1, `t400-sibling`, `t316-sibling`), which is what guarden already
  ships for two services that must talk, rather than a second mechanism.

The decision this measurement asks for is therefore not "pods or not" but **which
of those two shapes t307c implements for a source whose apps disagree on a uid**,
and the card cannot answer that on its own.

## 7. Not measured, and deliberately so

- **Whether quadlet's `.pod` file accepts `UserNS=` and reaches podman as
  `--userns`.** That is a renderer claim and belongs to t307c's own suite; this
  measurement stops at the runtime.
- **A pod-level pin at a uid whose image resolves it by name** (the probe reads
  the image's own `/etc/passwd`); only 33 (numeric `--user`) and 999
  (`postgres:17`, handoff) were measured.
- **A pod whose containers run as a uid that is mapped elsewhere in the pod's
  userns** beyond 33/999/root.
- **`[groups] add` or `mounts.allow` inside a pod.** Both are root-owned grants
  and neither interacts with the namespace question measured here.
