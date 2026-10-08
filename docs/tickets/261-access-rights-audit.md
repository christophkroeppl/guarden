# 261: access rights audit — tighten every file guarden writes

**What to build:** A systematic audit of every file and directory guarden creates, converging each to the tightest mode that still lets the documented readers work. The current state after ticket 260 is:

- `00-ssh.conf` (if it exists) is `0600` — root only
- Everything else under `/etc/guarden/**` is heading toward `0640` (was `0644`)
- `/etc/guarden/projects.toml`, `projects.d/`, `allow-gated-drop` are `0444` so `hose` can read the ref allowlist
- `/etc/guarden/creds/` is `0700` root
- `/etc/ssh/authorized_keys.d/hose` is `0644` root

**Blocked by:** 260 (stub resolver under the deny)

**Status:** backlog

- [ ] Enumerate every path guarden writes in `hostprep.py`, `conf.py`, `firewall.py`, `hosttool.py`, and the mutator verbs
- [ ] For each, state the reader(s) and the tightest mode that serves them
- [ ] Update `MODE_CONFIG`/`MODE_DIR`/`MODE_DIR_GROUP` constants and every `write_file` call to match
- [ ] Add a regression test that fails if any guarden file is world-readable (`0644` or `0755` on files) unless explicitly listed as a carve-out
- [ ] Document the carve-outs in `spec.md §2.1` with the same table that exists today

**Carve-outs to record:**
1. `projects.toml` / `projects.d/` / `allow-gated-drop` — `0444` for `hose`
2. `stakes/` — `0770` for `stakes` (runs as `guarden`)
3. `queue/` — `0770` for `furrow` (runs as `guarden`)
4. `shared/dashboard/` — `0755` for the dashboard service (not in either group)
5. `00-ssh.conf` — `0600` root (if/when created)

**Notes:**
- `UNIT_MODE = 0o644` in `units.py` is for **systemd unit files** which systemd may read as a non-root user in some paths; that is a separate decision and not in scope for this ticket
- A full audit of every file guarden writes has not been done — this ticket tracks doing it
- The change from `0644` to `0640` in `hosttool.py:40` (`MODE_CONFIG`) is the first step; this ticket finishes the job