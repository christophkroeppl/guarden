# Identity: one user per service, and previews are the exception

A service owns a Linux user of the same name, with a home under
`/var/lib/guarden/services/<name>/home`, linger enabled, and a subuid/subgid range allocated
by the system rather than by us. The user is a system user, has no login shell, and is
created and destroyed only by `weedr service add` and `weedr service remove`.

**Every directory a program writes into is `0770`; the `0750` this document previously gave
`queue/` and `stakes/` was a defect, not a tight default.** Group bits of `r-x` on a directory
whose group is `guarden` grant `furrow` the right to *read* the queue and the right to *read*
the pin store, and not the right to create a file in either — so the deploy queue could not
accept a request and `stakes pin` could not write a pin. Both are `0770 root:guarden` now, and
the test is a program's whole described behaviour against the mode, not a reviewer's impression
of tightness.

The range comes from `useradd --system --add-subuids-for-system`, which needs shadow-utils
4.11 or later. Where that option is missing the user is created plain and the range is written
afterwards with `usermod --add-subuids` and `usermod --add-subgids`. Either way `weedr` reads
`/etc/subuid` back and exits 1 naming the service if the range it asked for is not there. It
reads it back because an unallocated range is a container that starts and then cannot map its
own root, which is a long way from the cause.

One hardcoded range for every service is not a fallback, it is unacceptable: `100000:65536`
for everyone maps every container's root to the same host uid, and the moment two services
share a directory the ownership is ambiguous and the firewall's uid matching stops meaning
what it says.

Modes are part of the design rather than a detail. A service's whole tree under
`/var/lib/guarden/services/<name>` — its directory, its home and each of its state and bulk
volume directories — is `0700`, owned by the service user, with no carve-out for the home. The
registry and each `overrides.toml` are `0640 root:guarden`; the pin directory and the queue
directory are `0770 root:guarden`, because `stakes` and `furrow` run as `guarden` and
**create and remove** the files in them rather than only reading them. `0750` for both was a
defect in an earlier revision: group bits of `r-x` let `furrow` read the queue and not write
to it, so the deploy queue could not accept a request and `stakes pin` could not write a pin.

The four parent directories `services/`, `registry/`, `shared/` and `staging/` carry modes of
their own rather than inheriting whatever umask created them. `services/` is `0711`: every
service tree under it is `0700`, so a readable directory would leak every workload name and
track on the host, and `0711` still lets a program traverse to a service it owns. The `0700` on the service tree is what the whole scheme
rests on: without it every service user can read every other service's state volumes straight off
the host filesystem, and the per-consumer credentials and the uid-matched firewall rules stop
being controls and become decoration.

Previews are the one exception, and the exception is scoped: **all instances of one service in
one environment share a single user**, one home and one subuid range, and a per-instance user was
considered and rejected — a subuid range, a home and an image store per instance is more disk on
a small host than the isolation is worth, and it would isolate an operator's own branches from
each other while doing nothing about a contributor who can push to the repository. An untrusted
fork is its own service in its own track with a narrowed ref allowlist, not a different user
inside the same one. A preview is a directory inside `<service>/home/<escaped-
ref>`, not a service, so a project that spawns twenty branches spawns twenty directories and not
twenty users, twenty homes, twenty subuid ranges and twenty image stores. The cost is honest and
worth stating: instances of one service are one trust domain, and a malicious instance can read
the others' directories and credentials. That is acceptable for one operator's own forks and
would not be for untrusted outside pull requests; a fork from a stranger should be its own
service, and `weedr service add <fork>-preview` is the way to get that.

Homes live under `/var/lib/guarden` rather than `/home` for three reasons: the service's
whole world is one deletable directory; it sits on one btrfs subvolume rather than several; and
nothing root-owned ever has to live inside a user-owned tree, which is what makes the admin
override mechanism in ADR-0006 safe.

`/var/lib/guarden` is **not** snapshotted, and that is deliberate rather than an omission. Every
declared state volume is its own subvolume with its own snapper configuration, so a host-level snapshot of the
whole state tree would produce a second, overlapping copy of every service's data for no
recovery benefit — the configuration a service depends on is the one on its own volume. Guarden's own
state is therefore never a state volume and never a snapper configuration.

A home is not snapshotted and carries no snapper configuration of its own. It holds the generated unit
files, the rootless container image store, the per-user podman secret database and whatever
build staging is in flight: none of it precious, all of it large, and the secret database
holds credentials in the clear. Only a declared state volume is a subvolume with a snapper
configuration, so the only thing a service can be restored from is the thing it declared to
have.

Nothing root-owned lives under a service's home. Generated units go in the home's quadlet
directory, where the service user owns them and regeneration may rewrite them. Admin grants
live in `/etc/guarden/services/<name>/overrides.toml`; admin units and drop-ins live in
`/etc/containers/systemd/users/<uid>/`, which is podman's rootless quadlet search path and is
scoped by uid, so only that user's session picks them up. The rootless search path is
`$XDG_RUNTIME_DIR/containers/systemd`, then `~/.config/containers/systemd`, then
`/etc/containers/systemd/users/<uid>`, then `/etc/containers/systemd/users`, then
`/usr/share/containers/systemd/users/<uid>`, then `/usr/share/containers/systemd/users`.

That order deserves to be stated rather than glossed. The home's own directory is searched
before the `/etc` one, so the guarantee being bought is that a root-owned drop-in survives a
regeneration instead of being silently clobbered, and that the service user cannot unlink,
replace or symlink over it. It is not a guarantee that the service user cannot affect the
resulting unit, because it can, by writing a file in its own home. A service cannot be
defended from the user it runs as, and nothing here pretends otherwise.