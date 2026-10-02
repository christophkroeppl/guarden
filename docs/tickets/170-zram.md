# 170: zram

**What to build:** An operator may ask guarden to set up a zram device on the host — a
compressed block device backed by RAM, which on a small VPS buys memory at the cost of CPU.
Default is **none**: with nothing configured, guarden creates no zram device, installs nothing
zram-related, and writes no configuration. The option exists because a one- or two-gigabyte
box swapping to disk thrashes, and because the right compression algorithm is a machine-to-machine
tradeoff that guarden cannot make for someone.

This is host configuration, so it obeys the same rule as every other host value: it is the
operator's, it is root-owned, and **a manifest cannot ask for it.** `zram:` in a `compose.yaml`
is refused by name, exactly as `weight:` and `environment:` are.

**Blocked by:** 20 (`soil install` and `soil storage` are where this lands), and 130 for the
cloud-init half

**Status:** draft — the decisions below are not made, and each one is a real tradeoff rather
than a detail

## Decide first

- **Which implementation.** `systemd-zram-generator` is the distribution's own and is what
  `soil` should use, on the same argument as every other runtime dependency: no pip, no wheels,
  no third-party fetch. `zram-tools` is the older alternative and ships a hand-written unit
  instead of a generator. One of them, not both.
- **Algorithm and level.** zstd is the only one worth offering on a small box, and its level
  trades CPU for ratio. "High" is not a value: `zstd` runs 1–22, and level 22 on a busy host
  costs more than the memory it saves. Either the operator states a level, or there is a named
  preset with a **stated level and a stated ratio** — not a word like "high".
- **Device size.** A percentage of RAM is the portable form; an absolute size is not. What
  happens when it is set on a box that already has zram, or when it exceeds RAM, needs an answer.
- **Swap.** `systemd-zram-generator` makes the device swap by default. guarden's own retention
  story (§8) assumes it can read free space, and zram changes what free space means. Decide
  whether zram is swap or is not, and write that down before the code.
- **Interaction with `soil sysctl`.** `vm.swappiness` is a real knob here and guarden already
  owns a fixed set of sysctls. If zram changes the right answer for one of them, that belongs
  in the same canonical set with the same "never from a manifest" property.

## Shape

- [ ] The knob lives in root-owned `guarden.toml`, host-level, **default absent**
- [ ] Absent means absent: no package, no unit, no config, no sysctl write, and `soil sysctl
      --check` reports nothing about zram
- [ ] Present means converged: `soil install --apply` installs and enables; `--check` reports
      drift and names it
- [ ] `zram:` in a manifest is **refused by name**, in both vocabularies, in `loom`
- [ ] `soil install --apply` twice is a no-op the second time
- [ ] The chosen algorithm and level are **read back** from the running device, not from the
      file guarden wrote — the same rule as `ingress.alias`
- [ ] The cloud-init path carries it: `soil install --render-user-data` emits it, and the
      rendered document and `tools/golden-vm --print` agree (spec §6.10, ticket 130)
- [ ] Removing the knob and re-running `--apply` tears the device down rather than leaving it
      enabled — the same converge-in-both-directions property `soil sysctl` has

## Evidence

- [ ] On the golden VM: with the knob absent, nothing zram exists — `zramctl`, `systemctl` and
      `zramctl --list` all agree
- [ ] With it set, `/dev/zram0` exists, the configured algorithm and level are the ones asked
      for, and a kernel log line records the chosen algorithm
- [ ] With the knob removed, `/dev/zram0` is gone
- [ ] A load test is **not** in this ticket: measuring that compression helps is an
      `assumptions` exercise for ticket 15, and the answer depends on the box
