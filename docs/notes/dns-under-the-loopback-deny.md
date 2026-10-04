# Does a service uid reach the stub resolver under the loopback deny?

**Status: open. Measured up to a point, not settled. Do not "fix" this by
loosening the deny without a decision.**

## What is measured

`podman run` as a service user exits 125. The podman message is a DNS failure:

    pinging container registry registry-1.docker.io: dial tcp:
    lookup registry-1.docker.io on 127.0.0.53:53: write udp
    127.0.0.1:38904->127.0.0.53:53: write: operation not permitted

`write: operation not permitted` on a UDP send is the kernel refusing it, and
127.0.0.53 is systemd-resolved's stub listener on loopback. spec 7.6 (lines
2078-2086) argues the loopback deny "does not touch name resolution" because
**pasta** excludes its DNS forward from the loopback mapping. That argument is
about traffic from inside a container. This is the HOST: podman's pull runs as
the service user, and the packet goes out through `OUTPUT`, which jumps to
`guarden-svc`, whose deny is `daddr 127.0.0.0/8 jump DROP;`.

**Not measured:** whether `guarden-svc` is what drops the packet. The probe that
tried to answer this created no service, so `30-services.conf` did not exist and
the deny never rendered. It needs a probe that renders the firewall first.

## Why this matters either way

- If the deny blocks it, then **no service can ever pull an image**, and every
  first deploy of a new workload fails. That is a much larger claim than the one
  the spec makes, and it is wrong as written.
- If it does not block it, this is a golden-VM artefact — the suite's resolver is
  the stub and the guest's network is incomplete — and the fix belongs in the
  harness, not in the firewall.

**What would settle it:** render the firewall with at least one service, then
`sudo iptables -S guarden-svc` and read its packet counters while a service uid
sends one UDP packet to 127.0.0.53. If the counter moves, the deny is the cause.

## The decision, when it is made

There is no `[loopback] allow` table, and there must not be one: a table whose
whole content is a destination is a second way to grant a destination beside the
publication set (spec 7.6). If DNS turns out to be blocked, the answer is not a
new table — it is either the stub resolver being moved off loopback, or pasta's
exclusion being extended to the host path the pull takes. Both are design
decisions and belong in an ADR.
