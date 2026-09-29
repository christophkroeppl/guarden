# 10: harness and program skeletons

**What to build:** Every program in the layout exists with a command-line entry point, and the
one test seam is in place: the command line of `weedr`, `loom`, `soil`, `stakes`, `roots`,
`twig`, `furrow` and `hose`. `just test` runs the fast harness and exits 0. This is the
prefactor every later ticket reuses.

**Blocked by:** None (frontier)

**Status:** ready-for-agent

- [ ] Each program exists and answers `--help` with its verbs from the spec, and nothing else
- [ ] **Every program's `--help` lists the alias beside the long form.** There is exactly one
      alias in guarden and it is `rm` for `remove`; it is not derived from the long form, no
      other verb has one, and a new verb brings none by default
- [ ] `soil` accepts `--check` and `--apply` for every phase in the spec; `soil list` names them
- [ ] `fixtures/bin` provides fakes for `useradd`, `usermod`, `userdel`, `loginctl`, `podman`,
      `podlet`, `runuser`, `systemctl`, `snapper`, `btrfs`, `chattr`, `systemd-creds`, `ferm`,
      `iptables`, `ip`, `tar`, `sudo`, `git`, and the distribution's package tools; each appends
      to a shared call log
- [ ] **The `snapper` fake answers `list --machine-readable json` with a real `userdata` object and
      answers `get-config`**, because those are the two interfaces guarden reads. A fake that
      only answers the human-readable table would let a CSV parser pass its tests. Its `modify`
      records the userdata it was given, because a pin test that does not inspect the mark
      tests nothing
- [ ] The fast harness puts `fixtures/bin` first on `PATH`, invokes commands, and asserts on
      exit code, diagnostic lines, resulting files and the call log
- [ ] A golden-VM runner entry point exists and can be pointed at a throwaway machine
- [ ] `just test` exits 0
- [ ] No test imports a program; every test goes through a command line
- [ ] `just check` confirms `python3-yaml` and `python3-jinja2` are importable and that no
      program imports anything outside the standard library and those two
