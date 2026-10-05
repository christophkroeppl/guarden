# The quadlet generator is reached, and produces a unit nobody loads

**Status: root cause found by running the generator the way systemd runs it. This
supersedes the "not reached" reading below.**

## What is measured

`podman quadlet list`, as the service user, on a rendered home:

```
NAME           UNIT NAME    PATH ON DISK                                    STATUS
web.container  web.service  …/home/.config/containers/systemd/web.container  Not loaded
```

**The generator IS reached and DOES produce `web.service`.** Run by hand exactly as
systemd runs it — three output directories, as the generator's own error message
demands ("missing output directory argument" when given none):

```
$ podman-user-generator /tmp/genout.normal /tmp/genout.early /tmp/genout.late
$ ls /tmp/genout.normal
web.service
```

So the earlier conclusion — that the generator "is not being invoked for this
directory", and that this "points at the search path rather than at the file's
contents" — **was wrong.** It is invoked, and it writes the unit.

## The actual cause

Quadlet ships `/usr/lib/systemd/user-generators/podman-user-generator`. That is the
**user** manager's generator directory, and the unit manager runs it at
`daemon-reload` — into `$XDG_RUNTIME_DIR/systemd/user/generator.{early,normal,late}`.

`Not loaded` therefore says the generated `web.service` is not in the user manager's
unit search path. Two candidate causes, and the probe did not separate them:

1. The generated unit went to a runtime directory the manager is not reading, or
2. `daemon-reload` in the service user's manager is not reaching the generator at
   all — which would be consistent with the earlier finding that a debug
   `daemon-reload` logs **nothing** about quadlet, a container, or a skip.

The second is the more likely, and it has a concrete suspect: **nothing sets
`XDG_RUNTIME_DIR` for the user manager of a service whose home is `0700` and outside
`/run/user/<uid>`.** A user manager needs a runtime directory it owns; guarden gives
each service a home under `/var/lib/guarden/services/<name>/home` and a `0700` tree,
and nothing in `weedr`'s install path establishes `/run/user/<uid>` for it.

## What this means for ticket 240

`240-subvolume-mounts.md` says the `.volume` unit is rejected and must be replaced by
a bind mount. **That diagnosis stands** — `Source=` is genuinely not a `[Volume]` key,
and the man page is unambiguous.

But `t50-slice` cannot go green on that change alone, because no generated unit is
loaded *at all*, with or without a `.volume` file. The `Not loaded` status is
independent of the volume question.

So there are **two defects, in different places**:

- **240** — the rejected `[Volume]` unit and the manifest-injection gap in
  `REFUSED_DIRECTIVES`. A renderer fix.
- **this one** — the service user's user manager does not load generated units. A
  mutator fix, and it is the one that blocks a container from ever starting.

## The next step, stated as a measurement

As the service user, with the runtime directory named explicitly:

```
runuser -u <service> -- env XDG_RUNTIME_DIR=/run/user/<uid>   systemctl --user daemon-reload
ls /run/user/<uid>/systemd/user/generator.normal/
```

If `web.service` appears there and `systemctl --user status web.service` then resolves,
the cause is the runtime directory and the fix belongs in `weedr`'s install path: a
`systemd-logind` or `pam_systemd` arrangement for a service user whose home is
elsewhere, or a `RuntimeDirectory=` on the user manager unit.

Do **not** guess this one the way `Source=` was guessed. It is a second, independent
defect and it deserves its own ticket once the measurement above is taken.
