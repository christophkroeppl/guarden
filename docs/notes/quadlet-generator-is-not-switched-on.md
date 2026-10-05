# Quadlet never generates a unit, so no container can ever start

**Status: open, measured, not fixed. This is a product gap, not a test problem.**

## What is measured (podman 5.7.0, the family `packages.toml` declares)

- `/usr/lib/systemd/user/quadlet.service` **does not exist**. podman 5.7 ships
  `/usr/libexec/podman/quadlet` and a user unit named **`podman.service`**
  instead — the generator's unit was renamed.
- Guarden writes `.container` and `.volume` files into the service user's
  `~/.config/containers/systemd/`, which is the correct uid-scoped rootless search
  path (`paths.QUADLET`).
- `podman quadlet list` for the service user is **empty**: the generator is not
  reading that directory.
- Consequently `web.container.d/` contains only guarden's own
  `10-guarden-order.conf` drop-in and **no generated `.service`**, and the start
  answers `Job for web.service failed because the control process exited with error
  code` — the unit name resolves, but to nothing quadlet produced.
- `Quadlet=true` in `/etc/systemd/user.conf.d/` does **not** fix it on this
  family, and `podman quadlet install` installs quadlet *files*, not the generator.

## What this means

Nothing in guarden enables the generator. The renderer emits quadlet
declarations and the mutator installs them, but no code path starts `podman.service`
in the service user's manager, so the `.container` file never becomes a unit.

Every claim that depends on a container actually running is therefore blocked —
which is the claim `tests/t70-fork.sh` cannot make (see its own comment at the
stop/start assertion: it needs "a running container on a real user manager").
`tests/t50-slice.sh` is blocked on the same thing: it starts the edge and asks it a
question over the wire.

`podlet` translating Compose to `.container` files works, and the renderer's own
unit tests pass, which is why this stayed invisible: **the render is not the
start.** Nothing tested the hop between a declaration on disk and a loadable unit.

## The decision this needs

Where the generator gets switched on. Three candidates, and the spec does not say:

1. `soil install` starts `podman.service` once per service user, or once per
   session — root, mutating another user's manager.
2. A `podman.service` preset/drop-in is installed into the service user's home by
   the mutator, so the user's own manager pulls it.
3. Guarden keeps a `podman quadlet install` of each rendered unit — a second
   mechanism for the same job, which ADR-0012's "no second way" shape argues
   against.

Option 2 is the smallest and keeps the mutator out of the user manager's runtime
state, but it is a real decision rather than an obvious default: it decides whether
a service's units are the service user's business or guarden's.

**Do not "fix" this by making `start_units` tolerate exit 5 for a start.** That
exit code is the one case `_unit`'s docstring says must stay a failure — it would
report work that did not happen as success, which spec 1.2 forbids.

## Suites blocked on it

Three suites fail on this and for no other reason:

- `tests/t30-remove.sh:114` — `systemctl --user stop node` answers
  `Transport endpoint is not connected` and exit 1. `_unit`'s docstring calls that
  the one answer a stop must not treat as success: a manager that cannot be reached
  is not a manager whose units are stopped. The verb refuses, and it is right to.
- `tests/t70-fork.sh` — the stop/start half of a fork, same cause.
- `tests/t50-slice.sh` — starts the edge and asks it a question over the wire.

All three are correct refusals of a host that cannot run a container, so the fix is
the generator and not a tolerance. The `t30-remove` consequence is worth stating
plainly: **`weedr service remove` cannot currently remove a service whose units
quadlet never generated**, which on such a host is every service.
