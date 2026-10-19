# 322 — a uid recycled after a removal leaves the new service without a user manager

Blockers: none. Found 2026-10-19 while implementing ADR-0019's drop-in model
(t353-dropin-overrides), where a build of a SECOND service in one suite failed
and the first service's build did not.

## What happens

`weedr service remove <name>` takes the service's account away, and it takes
the **user manager** with it:

```python
def destroy(name: str, uid: int) -> None:
    tool.run(["systemctl", "stop", f"user@{uid}.service"])
    tool.run(["userdel", name])
```

The uid is then free, and **the next service created on the host is allocated
the same uid** — the allocator walks the free space and takes the lowest one.

**The new user's manager is never started.** `user@<uid>.service` is a
per-uid systemd unit, and the one that was stopped belonged to the OLD user:
its unit is keyed by uid, and the new user with the same uid finds the unit
**inactive** — the previous removal stopped it, and nothing starts it again.

Measured on a cut, with the exact shape guarden creates:

```
=== guarden removal: stop the manager, then userdel
=== the uid is free now:
uid 999 free
=== the NEXT service gets the SAME uid (the allocator reuses it)
uid2=999  (uid1 was 999)
=== is the NEW manager up?
inactive
```

**The symptom it produces is a build that dies in crun.** A rootless podman
build puts its `RUN` steps in the systemd sandbox cgroup of the user running
it, so it asks that user's manager for a cgroup. The manager is down, so:

```
error running container: from /usr/bin/crun creating container for
[/bin/sh -c adduser -D -u 10001 dropuser]: sd-bus call: Access denied as the
requested operation requires interactive authentication. However,
interactive authentication has not been enabled by the calling program.:
Permission denied : exit status 1
Failed to add pause process to systemd sandbox cgroup: dial unix
/run/user/994/bus: connect: connection refused
```

**The stale bus socket is the tell.** `/run/user/<uid>/bus` EXISTS — it is
the dead manager's — and the connection is refused. A suite that waits for
the directory's existence is therefore waiting for nothing, and the build
still dies. The check has to be the manager's own state, not the directory's.

This is why the FIRST service in a suite builds and the SECOND does not: the
first one's manager was started by its own ingest, and the second one
inherits a uid whose manager the first one's removal stopped.

## What to build

**Start the manager for the new user, and make the check the manager's
state.** Two things, and the second is what makes the first observable:

- `users.ensure` (or the path that creates the account) has to bring
  `user@<uid>.service` up for a uid that a previous service has vacated —
  `loginctl enable-linger` is what makes the manager come up on its own for
  a user that has never had one, and it is not enough for a uid that had one
  and lost it.
- **The wait has to be on `systemctl is-active user@<uid>.service`, not on
  `/run/user/<uid>` existing.** The directory and its stale socket outlive
  the manager, so a directory check passes on a dead manager — which is
  exactly what a suite that waits for the directory does, and why the build
  still failed with the wait in place.

The suite-side workaround is in `tests/t353-dropin-overrides.sh` and is
marked as one. It is not the fix: a service created on a recycled uid has no
manager, and the *first* container it starts would meet the same window.

## Where the evidence is

- the removal path: `src/guarden/users.py`, `destroy`
- the creation path: `src/guarden/users.py`, `ensure`
- the measured repro: the block quoted above, on a cut from the golden
