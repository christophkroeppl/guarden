# 170: templates + python libs

**What to build:** Shell-embedded templates move out of heredocs into real jinja2 template files — jinja2 is the one allowed new runtime dependency — and python code embedded inside shell scripts moves into separate files and libs. Externally nothing changes: the same commands produce the same generated files with the same exit codes, so this is a pure refactor behind the existing CLI seam.

**Blocked by:** T10 (Skeleton + CLI seam harness)

**Status:** ready-for-agent

- [ ] `jinja2` is declared as a runtime dependency and is the only new runtime dependency added
- [ ] Rendered outputs previously produced by shell heredocs (quadlet units, drop-ins, ferm rules, roots/twig config) are produced from template files that live next to the code that renders them
- [ ] A changed template file changes the generated output on the next command run (proving the templates are actually read, not inlined copies)
- [ ] No shell script contains embedded python (no inline `python3 -` heredoc/`-c` blocks); python lives in files or libs invoked as commands
- [ ] Before/after equivalence at the seam: the same commands generate byte-identical files and the same fake-call logs as before the refactor
- [ ] `make test` exits 0
- [ ] No test imports an internal function; every test still goes through the command line
