# 150: ferm, overrides, watchers

**What to build:** Firewall openings come from `.guarden/bed.yaml` `ports:` plus bed-scoped admin overrides: an `overrides.yaml` in the bed (root:root 0444) and root-owned `<unit>.container.d/` drop-ins in the bed, paths that `hose` and unit regeneration never touch. `weedr` can list the active ferm rules. Connectivity stays per-group: loopback blocks `127.1.<g>.<n>` plus ferm OUTPUT uid-owner rules so only the group's members (the pond user and its member bed users) reach that group's block (DB roles are the second layer). systemd `.path` units with recursive globs over the `bed-*` / `pond-*` schema watch for changes and trigger `daemon-reload` only.

**Blocked by:** T130 (soil: optional ponds, fixed dir schema, ladder ownership)

**Status:** ready-for-agent

- [ ] A bed declaring `ports:` in `.guarden/bed.yaml` gets those ferm openings after apply; removing the entry and re-applying removes the rule from the rendered ferm configuration
- [ ] An admin `overrides.yaml` in the bed (root:root 0444) and root-owned `<unit>.container.d/` drop-ins are honored by `weedr`, and a regenerate or `hose check` leaves both untouched (same content, no write in the call log)
- [ ] `weedr` has a command that prints the active ferm rules and exits 0
- [ ] Each group's loopback block `127.1.<g>.<n>` is reachable only by that group's member bed users: the ferm OUTPUT uid-owner rules allow members and drop non-members, visible in the rendered rules
- [ ] On the golden VM, a connection attempt from a non-member bed user to a group's block fails, while a member reaches it
- [ ] A systemd `.path` unit exists per watched schema with a recursive glob over `bed-*` / `pond-*`; touching a matching file triggers exactly `systemctl daemon-reload` in the call log — no restart, no redeploy
- [ ] Touching a non-matching path triggers nothing
- [x] `--check` / `--apply` on the firewall phase keeps the drift semantics (exit 1 with `drift`, second `--apply` exits 0)
- [ ] All of the above is verified at the CLI seam with the fast harness; the uid-owner isolation drill is also run on the golden VM
