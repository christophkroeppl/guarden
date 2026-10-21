# 350 — a resource cap in a hand-written quadlet unit reaches the generated unit

Blockers: none. Found 2026-10-21 while working 272, and deliberately not fixed
there: 272's finding is about a `compose.yaml`, and the rule here is one ticket
per change.

## What happens

272 refuses a resource cap in the Compose vocabulary: `mem_limit:`, `cpus:`,
`pids_limit:`, `ulimits:`, the `cpu_shares:` weight and a non-empty
`deploy.resources.{limits,reservations}` are exit `2`, by name, before the
converter is driven. **The same statement in the other vocabulary is not
refused**, and a repository that ships units rather than a compose file writes
the other one:

- `[Container] Memory=2g`, `PidsLimit=512`, `Ulimit=nofile=1024:2048` —
  quadlet's own table (`podman-systemd.unit(5)`). None of the three is a key the
  renderer owns, so each lands in the generated unit verbatim and really caps
  the container.
- `[Service] MemoryMax=2G`, `CPUQuota=200%`, `TasksMax=512`, `LimitNOFILE=…` —
  systemd's (`systemd.resource-control(5)`, `systemd.exec(5)`). The renderer's
  `_service_keys` writes the track's `CPUWeight`/`IOWeight` and then the
  source's `[Service]` keys beside them, so these reach the unit too.

One rule in two vocabularies and only one of them holds, which is the failure
`zram:` (ticket 170) exists to avoid: a refusal in one vocabulary and not the
other leaves the door open in the one a developer actually writes.

`[Service] CPUWeight=` is **not** a hole: `_service_keys` overwrites it with the
track's weight, so the source's value does not survive. That exemption is the
honest one and it should be kept — a key is refused where it would otherwise
reach the unit.

## What to build

1. State the rule once, in the spec, in the quadlet vocabulary as well as the
   Compose one — 272's §4 sentence is the canonical one and this points at it —
   so the two refusals cannot disagree about which key is a cap.
2. Refuse on the repository's own unit source, by name with exit `2`, before the
   generated unit is written: the `[Container]` cap keys and the `[Service]`
   resource-control keys.
3. **Measure the key list in the VM against the machine's man pages**
   (`podman-systemd.unit(5)`, `systemd.resource-control(5)`,
   `systemd.exec(5)`) rather than transcribing one. A list written from memory
   during 272 included manager-level keys — `DefaultMemoryLow`,
   `DefaultStartupMemoryLow`, `MemoryPressureWatch`, `DefaultTasksMax` — that are
   not valid in a `[Service]` section at all, so refusing them refuses nothing
   while claiming to.
4. **The admin's drop-in must keep working.** Ticket 40's acceptance list says a
   drop-in at `/etc/containers/systemd/users/<uid>/<unit>.container.d/` setting
   `[Service] MemoryMax=`/`MemoryHigh=` lands in the generated scope, and
   `tests/t40-render.sh` asserts it. `refuse_directives` runs on the source and
   `_dropins` is merged afterwards; that order is load-bearing, because the
   drop-in is the only way an operator grants a cap. A refusal that caught the
   drop-in would take away the answer it points at.
5. A suite, red first: `loom check` on a quadlet source for each key, the
   negative case (a unit stating no cap renders), and the drop-in case staying
   green in `t40-render.sh`.

## The narrow version, if the wide one is the wrong answer

`[Container] Memory=` is two lines of code and is the one key that is
unambiguously the same statement as `mem_limit:`. A refusal that covered only it
would close the loudest hole; the `[Service]` family is the part that needs the
decision, because those keys are also how an operator's own drop-in expresses
itself and the two live in one table.
