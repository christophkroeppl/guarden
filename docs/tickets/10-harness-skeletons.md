# 10: harness and program skeletons

**What to build:** Every program in the layout exists with a command-line entry point, and the
one test seam is in place: the command line of `weedr`, `loom`, `soil`, `stakes`, `roots`,
`twig`, `furrow` and `hose`. `just test` cuts a throwaway VM from a golden snapshot, runs every
suite in it with the real tools, and exits 0. This is the prefactor every later ticket reuses.

**Blocked by:** None (frontier)

**Status:** ready-for-agent

- [ ] Each program exists and answers `--help` with its verbs from the spec, and nothing else
- [ ] **Every program's `--help` lists the alias beside the long form.** There is exactly one
      alias in guarden and it is `rm` for `remove`; it is not derived from the long form, no
      other verb has one, and a new verb brings none by default
- [ ] `soil` accepts `--check` and `--apply` for every phase in the spec; `soil list` names them
- [ ] **A golden-VM runner entry point exists and can be pointed at a throwaway machine**, and it
      is the only harness: `just test` cuts a VM from a golden snapshot and runs every suite in it
      with the real tools. There is no fake tier and `fixtures/bin` is never on `PATH` (ADR-0014,
      and ticket 35 deletes what this ticket once asked for)
- [ ] **Snapshot state is read with `snapper --machine-readable json --config <config> list` and
      `get-config`**, and that is what the VM asserts: `--machine-readable` is a global option and
      precedes the command, the document is an object keyed by the configuration's name, and
      `userdata` renders as an object, so `important` is a key and its `0` entry is the live
      subvolume rather than a snapshot. A harness that answered only the human-readable table would
      let a CSV parser pass its tests, which is exactly what the retired `snapper` fake allowed
- [ ] `just test` exits 0
- [ ] No test imports a program; every test goes through a command line
- [ ] `just check` confirms `python3-yaml` and `python3-jinja2` are importable and that no
      program imports anything outside the standard library and those two
