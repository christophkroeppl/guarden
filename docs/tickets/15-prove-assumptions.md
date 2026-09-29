# 15: prove the load-bearing assumptions

**What to build:** Several claims in the design are assertions today, and everything downstream
rests on them. Prove or refute them on a real machine before building on any. This is a spike:
it may conclude that an ADR is wrong, and that is a successful outcome.

**Blocked by:** 10 (harness and program skeletons)

**Status:** ready-for-agent

- [ ] **The alias is the container's default gateway, and pasta maps it.** Confirm on a real
      rootless container that the address in its own `ip route` is the one that reaches a socket
      bound to `127.0.0.1` on the host, with the container running with exactly
      `[network] pasta_options` and no other network configuration anywhere on the host. Record
      the literal address; do **not** record podman's `host-gateway` token, because a rendered
      `AddHost=` has to survive a resolver that is not ours
- [ ] **The host-side firewall matches `127.0.0.1`, not the alias.** With the connection above
      established, read the host's `iptables-save -t nat` and `iptables-save` and record what the
      connection actually looks like to the packet path. The claim under test is that pasta's
      translation is complete in userspace before any filter chain is consulted
- [ ] **The connection arrives with the consuming service uid as the socket owner**, so the
      `OUTPUT` accept rule matches. This is the only host-side control that can see this hop, and
      the whole isolation story depends on it
- [ ] **A rule matching `ingress.alias` in `OUTPUT` matches nothing**, and an
      `-m owner --uid-owner` rule on `127.0.0.1` works. Both halves, because the documents
      previously conflated the two addresses and a rule set built on the conflation enforces
      nothing
- [ ] **`--no-map-gw` and `--map-host-loopback none` are refused by the renderer**, and a unit
      source naming a non-pasta backend or `network_mode: host` is refused with the key named
- [ ] **A container can reach a host loopback port that is not a publication** — use `sshd` on
      22, or a throwaway listener. This is the known gap, and the ticket must demonstrate it
      rather than assume it, so that the default-deny question in `SECURITY.md` §2.6 is answered
      with a measurement
- [ ] **`--host-lo-to-ns-lo` is not set**, and an application inside a container that binds only
      `127.0.0.1` is confirmed unreachable — the gotcha that reads as a firewall fault and is not
      one
- [ ] **A forwarded port answers from a second machine, with the `nat POSTROUTING` chain
      containing no masquerade.** Two separate assertions, because only the first distinguishes
      working from broken and only the second keeps the design honest about why. Also record
      what the service sees as its peer address, which should be the client's real address and
      not `127.0.0.1`
- [ ] **`soil install` writes the measured alias into `guarden.toml` itself.** The probe is part
      of the phase, and the operator is not asked to edit the file. The write is `soil install`'s
      one exception, alongside `weedr module add`'s
- [ ] **`soil install` refuses to start the edge without `ingress.alias`**, and says which key it
      wants. A container that cannot reach the host loopback answers every route with a 502 that
      names no cause, so the missing measurement is refused rather than rendered around
- [ ] `ingress.alias` is empty in a shipped `guarden.toml`
- [ ] **`soil sysctl --check` reports drift when the recorded alias no longer matches the
      address the default route resolves to.** Change the host's route or simulate it, and confirm
      the check fires — the alias is derived from the network, not chosen by guarden, so this is
      the failure mode the design has to notice on its own
- [ ] The same connection attempt from a service user that was not granted the port fails, with
      the uid-matched `OUTPUT` rule in place and without it
- [ ] `btrfs subvolume snapshot` of a live rootless PostgreSQL data directory, cloned into a
      second data directory with the read-only flag cleared and the owner changed, starts and
      recovers; the data is present and the clone is writable
- [ ] `btrfs property set <path> ro false` is available (btrfs-progs 5.14 or later); the actual
      version is recorded
- [ ] The amount of time a clone of the live database takes to start and recover is measured
      and recorded, so the fork cost is a number rather than an assumption
- [ ] A service that publishes a port on host loopback is reachable by its service name from a
      **second** service's container through the same alias, and by the **edge** through the same
      `AddHost=` in the edge's own units. The edge is a consumer like any other and this is the
      case most likely to be missed, because it only fails at request time
- [ ] A resource limit set on a systemd scope is not silently dropped: read
      `memory.max` under `/sys/fs/cgroup/` and `cpu.weight` and `io.weight` directly, and do
      not treat silence as success. `podman-rootless(7)` records that systemd failures are
      silently ignored for some options when rootless podman runs inside a container, and
      there is a documented case of `cpu`, `cpuset` and `io` being dropped from the delegated
      controller set
- [ ] A container started from inside a limited scope actually **inherits** that scope, by
      reading `/proc/1/cgroup` inside the new container and comparing it with the scope's own
      path. This is the property the whole memory story for agent-spawned containers rests on
- [ ] Every conclusion is written into `docs/adr/0004` and `docs/adr/0007` and the spec, and
      the open questions in the PRD that this answers are struck
- [ ] If the host-loopback alias does not work, the ADR is reopened and a replacement is
      proposed — the spike does not proceed past a workaround
