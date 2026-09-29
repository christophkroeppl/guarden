# Modules: shared programs, declared requirements, file contracts

A module is a named bundle. Its definition is a directory under
`/usr/lib/guarden/modules/<name>/` holding a `module.toml` that declares the services it
installs, the shared programs it switches on, the ports it grants, and the modules it
requires; the format of that file is specified in `docs/spec.md`. Which modules are on is the
`[modules] enabled` list in `/etc/guarden/guarden.toml`, and `weedr module add` is its only
writer: it appends the module's name there and rewrites nothing else in the file, under the
`modules` lock and by the same write protocol as every other shared file. `gate` — the edge and
its route renderer — and `homepage` — the dashboard and its renderer — are the two enabled by
default. `auth` is specified and not implemented in v1.

There is no module API, and saying so is a distinction without a difference. A module is data:
a fixed registry that ships with guarden, no plugin interface, no discovery of arbitrary
directories on the host, and no code contributed by a module or executed on its behalf.
`weedr module list` and `weedr module add` are the whole interface. The alternative — a
directory per module that can be dropped in — was rejected because the first module that
needs to change something another module owns is the one that makes you build a plugin
system. Auth is exactly that module: it has to make the edge apply forward-auth, and the edge
belongs to `gate`. Under option one, auth declares `requires = ["gate"]` and communicates
through one documented root-owned file that `roots` reads. Under the pluggable model, auth
would have to duplicate edge configuration or ship a patch into another module's files.

So the rule is: **modules never write each other's files.** A module expresses intent in a
root-owned file, and the shared program that owns that file reads it. Auth is the worked
example: `/etc/guarden/edge/auth-provider` (`0640 root:guarden`) names the auth service, `roots`
reads it, and nothing in either module's directory is touched by the other. The consequence is
that adding auth later is a marker file, a manifest key, and a renderer change in a program we
already own — not a new mechanism.

The two default modules are installed by `weedr module add gate` and
`weedr module add homepage`, and `soil install` installs no service at all. A fresh host that
has run `soil` and nothing else has no ingress and no dashboard, and that is deliberate: what
is on the machine is what somebody asked to be on the machine, not whatever a converger
decided to bring along. `weedr module add gate` is also what creates the `edge` group and adds
the edge's service user to it; `soil install` creates the `guarden` group and no other, so a
host with no edge module has no `edge` group. The `guarden` group is load-bearing rather than
tidiness — the registry, every `overrides.toml` and all of `/etc/guarden` are `root:guarden`,
and the unprivileged programs read them through it. A module can be added months after soil has
run, without re-running it. `weedr module add homepage` reads the registry, creates the
services, grants what the module declares, installs the units, and creates
`/var/lib/guarden/shared/dashboard/` `guarden:guarden 0750` — the one directory `twig` may
write, which is the writer/reader split the edge's directory already draws and the reason a
dashboard module did not need a third group. `weedr module remove <name>` is the inverse in a
stated order (spec §6.2), and its step four is the one that matters: it re-renders the ingress
from the **remaining** modules and installs it, because `soil firewall` is not run by a module
removal and the removed module's forwarding rules would otherwise outlive it. This is why modules are
configuration rather than a compile-time feature list.
