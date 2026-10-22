# Ticket 307c: the pod the renderer writes, measured

Evidence for `t307c` (the kanban card under ticket
[`307-monorepo-multi-app-deploys.md`](../tickets/307-monorepo-multi-app-deploys.md)),
which builds on `t307b`'s measurement
([`ticket-307b-pod-keepid.md`](ticket-307b-pod-keepid.md)). The suite that produces
all of it is [`tests/t307c-pods.sh`](../../tests/t307c-pods.sh), and it is green.

## The machine

```
golden:            Ubuntu 26.04, cut per suite (`tests/lxc.sh`), 2026-10-22
podman:            5.7.0 (rootless, as the service user)
podman pod:        systemd-podprobe — quadlet names a `.pod` file `$name.pod` the
                   `$name-pod.service` unit and the `systemd-$name` podman pod
service user:      created by `weedr service ingest`, not by a `useradd` in the suite
publication:       20000 (allocated from the host's own range, read out of the record)
```

## What was measured

| # | claim | verdict |
|---|---|---|
| 1 | one app with two containers renders ONE `.pod`, and both container units carry `Pod=<pod>.pod` | **proved** — one `.pod` in the unit directory, both units carry it, neither carries `Network=` or `PublishPort=` |
| 2 | the pod unit carries the host's pasta backend and the whole published set | **proved** — `Network=pasta:<the installed option set>` and one `PublishPort=127.0.0.1:<pub>:<port>` per member |
| 3 | two REAL containers of the pod reach each other over `127.0.0.1` | **proved** — a payload served by one container's own init process is fetched by the other, and the request is read back out of the server |
| 4 | the host reaches a member through the POD's publication | **proved** — `curl 127.0.0.1:<publication>/proof.txt` returns the payload the container serves |
| 5 | the pod starts before its containers and stops after them | **proved, with one correction** — quadlet emits **`BindsTo=<pod>-pod.service`** and `After=<pod>-pod.service` in each member (not `Requires=`), and after `weedr service stop` the pod's own unit is `inactive` |
| 6 | a service whose containers' images run as different uids is REFUSED | **proved** — `loom render` exits 2 naming `33:33 for api (…nginx…)` and `999:999 for worker (…postgres…)` |
| 7 | `[pod] name` renames the one pod, two apps of one repository are two pods, omitting `[pod]` names it after the workload | **proved** — `pods-web.pod` / `pods-api.pod` from the fixture, `podprobe.pod` from the default |
| 8 | `loom check` renders all four shapes with no host context | **proved** — four trees, exit 0 each, nothing written |

## What this means for the next card

- **`StopWhenUnneeded` is not what stops the pod.** The member's `BindsTo=` is
  what starts it, and `weedr service stop` names the pod unit after the
  containers — the stop ordering is guarden's, not the generator's.
- **The publication moved to the pod and nothing on the host's side moved.** The
  registry still allocates per container, `firewall.accept_lines` still grants per
  publication, and a member container carries no `PublishPort=` of its own. A pod
  does not make a publication reachable — the accept set does (§7.6).
- **A container in a pod cannot carry `UserNS=`.** The pin is the pod's, one per
  pod, and a service whose images disagree is refused rather than split.
