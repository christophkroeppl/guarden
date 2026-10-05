# 250: the service user's manager does not load generated units

**Blocked by:** nothing. **Independent of** ticket 240 — that one makes the render
correct, this one makes the unit load. Both must land before a container starts.

**What to build:** Make a service user's systemd **user manager** run
`daemon-reload` through podman's quadlet generator, so a rendered `.container` file
becomes a loadable `.service` in that manager.

## What is measured

`podman quadlet list`, as the service user, on a rendered home:

```
NAME           UNIT NAME    PATH ON DISK                                    STATUS
web.container  web.service  …/home/.config/containers/systemd/web.container  Not loaded
```

Run by hand exactly as systemd runs it — the generator demands three output
directories, which is why an earlier probe's "missing output directory argument" was
its own fault and not the answer:

```
$ /usr/lib/systemd/user-generators/podman-user-generator \
      /tmp/genout.normal /tmp/genout.early /tmp/genout.late
$ ls /tmp/genout.normal
web.service
```

**The generator is reached and produces the unit.** The unit is not loaded.

## Why this supersedes the earlier reading

`docs/notes/quadlet-generator-is-not-switched-on.md` previously concluded the
generator "is not being invoked for this directory", pointing at the search path
rather than the file's contents, on the evidence that a debug `daemon-reload` logged
nothing about quadlet. That was wrong. It is invoked, and it writes `web.service`.

Two candidate causes remain, and this ticket exists to separate them by measurement
rather than by inference:

1. The generated unit lands in a runtime directory the manager is not reading, or
2. `daemon-reload` in that manager never reaches the generator at all.

Cause 2 has a concrete suspect and it is a design fact, not a hunch: **nothing gives a
service user a `/run/user/<uid>` runtime directory.** A user manager needs one it
owns. guarden gives every service a home under
`/var/lib/guarden/services/<name>/home`, a `0700` tree owned by the service uid, and
nothing in `weedr`'s install path establishes `XDG_RUNTIME_DIR` for it. That also
explains the null debug log: a manager with no runtime directory has nowhere to run a
generator and nothing to say about it.

## The first measurement, before any code

As the service user, with the runtime directory named explicitly:

```
runuser -u <service> -- env XDG_RUNTIME_DIR=/run/user/<uid> systemctl --user daemon-reload
ls -1 /run/user/<uid>/systemd/user/generator.normal/
runuser -u <service> -- env XDG_RUNTIME_DIR=/run/user/<uid> systemctl --user status web.service
```

`web.service` appearing in `generator.normal` and resolving in `status` means the
cause is the runtime directory, and the fix belongs in `weedr`'s install path. It
does not, and the fix is elsewhere. **Do not skip this step and guess**, the way
`Source=` was guessed and found to be a mechanism problem rather than a spelling one.

## Constraints this must not break

- **No second daemon.** The user manager is systemd's own, started for the service
  user. Nothing new is introduced.
- **`0700` on the service tree stays.** Whatever establishes the runtime directory must
  not widen the home's mode.
- **No host network, no capability, no privilege.** Nothing here touches the
  isolation boundary; it is about a directory existing.
- **`/run/user/<uid>` is tmpfs and is recreated at boot.** Whatever creates it has to
  run at boot — a `tmpfiles.d` entry, a user unit, or the login path guarden already
  uses for the queue locks.

## Proof

A generated unit that `systemctl --user status` resolves, and a container that starts.
`podman quadlet list` showing `Loaded` rather than `Not loaded` is the intermediate
fact and is worth asserting on its own: it distinguishes "the generator ran" from "the
manager loaded what it produced", which are the two things that were conflated.
