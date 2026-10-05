# Quadlet never generates a unit, so no container can ever start

**Status: open, measured, not fixed. This is a product gap, not a test problem.**

**This note's conclusion is WRONG and superseded.** It says nothing enables
quadlet's generator. The generator is reached — `podman-user-generator` is a
systemd generator and runs at the `daemon-reload` `start_units` already performs.
The real cause is guarden's own rendered `.volume` unit naming a key quadlet does
not accept, which stops that unit being generated at all, and the container then
cannot resolve the volume it names.

See
[`quadlet-volume-key-is-not-a-spelling-fix.md`](quadlet-volume-key-is-not-a-spelling-fix.md)
for the generator's own dry-run output and the decision the fix needs.

Kept because the measurements here are what ruled the earlier hypotheses out, and
because they stop the next reader re-deriving them.

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

**Correction to that first reading, from measurement.** podman 5.7 ships **no
`quadlet.service` at all**, and `podman.service` — the unit of that name — is the
**REST API** (`ExecStart=/usr/bin/podman system service`), not the generator.
Starting it as the service user succeeds and generates nothing.

What podman 5.7 actually ships is `/usr/lib/systemd/user-generators`, so quadlet
generates at **daemon-reload** rather than from a unit of its own. `start_units`
already reloads, so the remaining question is narrower than "nothing enables it":
the generator runs and does not produce a unit for these files.

**Also measured, and it narrows it further:** a
`SYSTEMD_LOG_LEVEL=debug systemctl --user daemon-reload` in the service user's
manager logs **nothing at all** about quadlet, a container, or a skip. So the
generator is not declining these files with a reason — it is not being invoked for
this directory, which points at the search path rather than at the file's contents.
`Image=`, `Network=` and the drop-in are therefore not yet suspects.

**Not yet measured:** whether the generator is reached at all on this family, and
if not, what reaches it. `podman quadlet list` being empty is the same fact seen
from the other side. The next step is to find what a generator run on this machine
*does* produce for a service user's home — `systemd-analyze --user verify` or the
generator binary run by hand as that user — rather than another inference.

So the fix is **not** "guarden starts quadlet.service" — that unit does not exist
on this family, and the earlier note's options 1 and 3 are wrong for that reason.
What remains is a generator invocation, and the next measurement is
`SYSTEMD_LOG_LEVEL=debug systemctl --user daemon-reload` in the service user's
manager, which will say what the generator decided and why.

Every claim that depends on a container actually running is therefore blocked —
which is the claim `tests/t70-fork.sh` cannot make (see its own comment at the
stop/start assertion: it needs "a running container on a real user manager").
`tests/t50-slice.sh` is blocked on the same thing: it starts the edge and asks it a
question over the wire.

`podlet` translating Compose to `.container` files works, and the renderer's own
unit tests pass, which is why this stayed invisible: **the render is not the
start.** Nothing tested the hop between a declaration on disk and a loadable unit.

## The decision this needs

Where the generator gets invoked. Two candidates, and the spec does not say:

1. Guarden runs the generator itself — `systemd-run --user` or a reload the mutator
   already performs — which keeps one mechanism and one owner.
2. A drop-in or preset is installed into the service user's home so their own
   manager pulls the generator in, which leaves the mutator out of the user
   manager's runtime state but adds a file whose only job is to make systemd do
   something guarden could ask for directly.

Option 1 is smaller and stays inside the existing `start_units` reload. It is
still a real decision: it decides whether generating a service's units is
guarden's job or the user manager's.

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

## The verified state, for comparison

With everything else landed, the VM reports **50 suites green and 3 red**, and the
three are exactly the ones above. `tests/t35-env-schema.sh` is deliberately
excluded from VM runs by `tests/lxc.sh` (`HOST_ONLY`): it asks git about the
repository, and a checkout pushed without `.git` cannot answer that. It is
repository hygiene, not guarden, and `just test` still runs it.
