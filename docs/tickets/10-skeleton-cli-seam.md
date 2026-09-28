# 10: Skeleton + CLI seam harness

**What to build:** The guarden monorepo stands up with every part exposing a command-line entry point (stub bodies are fine), and the one test seam is in place: the command line of `weedr`, `stakes`, and the `soil` convergers. An operator runs `make test` and the fast harness is green. This is the prefactor that every later ticket reuses.

**Blocked by:** None (can start immediately)

**Status:** ready-for-agent

- [x] Top-level parts exist with CLI entry points: `soil`, `weedr`, `stakes`, `roots`, `twig`, `pond`, `hose`
- [x] `soil` convergers accept `--check` and `--apply` (stub behaviour allowed)
- [x] A `fixtures/bin` directory provides fake `snapper`, `btrfs`, `systemctl`, `podman`, and `useradd`, each appending to a shared call log
- [x] The fast harness puts `fixtures/bin` first on `PATH`, invokes commands, and asserts on exit code, resulting files, and the call log
- [x] A golden-VM runner entry point exists and can be pointed at a throwaway Ubuntu (LXD or QEMU + cloud-init), even if it only reports "no phases yet"
- [x] `make test` runs the fast harness and exits 0
- [x] No test imports an internal function; every test goes through the command line
