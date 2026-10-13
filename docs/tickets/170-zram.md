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

**Status:** implemented on `ticket-170-zram`. The decisions are recorded below and
carried into `docs/spec.md` §3.1, §4, §6.1 and `docs/sysadmin.md`, which is where a
reader of the code is sent.

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
      file guarden wrote
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

## What was decided, and where it is recorded

- **Which implementation.** `systemd-zram-generator`. It is the distribution's own, it is a
  distribution package and therefore installable on a family nobody has tried, and it produces
  its units through a systemd generator rather than shipping a hand-written one. `zram-tools` is
  not used and the package list has no row for it.
- **Algorithm and level.** `algorithm = "zstd"` is a closed set of one, and `level` is an
  integer in zstd's own range of 1–22. **There is no named preset**, because the ticket is right
  that "high" is not a value: a preset would have to state a level *and* a ratio, and the ratio
  is a measurement of somebody else's memory. Which algorithm suits a box is the operator's.
- **Device size.** `size_percent`, an integer percentage of this host's RAM, refused over 100.
  Absolute sizes are not portable, and a percentage over 100 asks the generator for a device
  larger than the memory behind it — which the generator itself only *warns* about
  (`would require improbable compression ratio`), so refusing it is guarden's job rather than
  the tool's. "What happens when it is set on a box that already has zram": the converge takes
  the existing device down first, because `disksize` and `comp_algorithm` cannot be written to an
  initialised device.
- **Swap.** zram **is** swap, and that is the answer to the §8 question: a zram device is RAM,
  so it does not move the free-space floor `FREE_LIMIT` reads and the retention story is
  unaffected. What it does change is `vm.swappiness`, which joins `soil sysctl`'s canonical set —
  and only when the knob is present.
- **Interaction with `soil sysctl`.** `vm.swappiness = 180`, above 100, so the kernel prefers
  the RAM-backed device over a disk swapfile and stops using disk while it has room. The
  kernel's default of 60 would do the opposite and leave the device idle, which is the one thing
  an operator who asked for it did not ask for.
- **Converge in both directions.** A marker at `/var/lib/guarden/soil/zram` records that the
  device is guarden's, because nothing else on the box says which of two zram devices guarden
  made. Its absence with the knob absent is the teardown.

### What could not be done as the ticket asks, and why

- **"The chosen algorithm **and level** are read back from the running device."** The algorithm
  is: `/sys/block/zram0/comp_algorithm` brackets the one in force. **The level is not, and cannot
  be** — `algorithm_params` is `DEVICE_ATTR_WO` in the driver, so there is no sysfs read-back for
  it and a check claiming one would be checking the file guarden wrote. What stands in for it is
  that the device exists at all: a level the backend rejects fails `disksize_store` and leaves
  nothing initialised, which the predicate does require. This is stated in spec §3.1 and in the
  runbook rather than papered over.
- **"A load test is not in this ticket."** Agreed and not attempted; it is ticket 15's
  `assumptions` work and the answer is a property of the box.

### The suites

- `tests/t170-zram.sh` — the host, on the real machine: absent means absent, present means
  converged, the device read back from the kernel, the second apply a no-op, the teardown, and
  the two refusals. `fresh`, because it creates and removes a real block device.
- `tests/t170-zram-parsers.py` (driven by `tests/t170-zram-parsers.sh`) — the knob's two exit
  codes and the size arithmetic, under the seam's one exception for parsers whose failures are
  invisible from outside.
- `tests/t170-zram-refusals.sh` — `zram:` refused by name in all three vocabularies a
  repository speaks.
- `tests/t170-zram-userdata.sh` — the rendered document and `tools/golden-vm --print` agree, and
  neither carries the generator.
