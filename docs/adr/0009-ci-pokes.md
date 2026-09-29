# CI pokes, the box builds, nothing is stored

A project's GitHub Action sends one message over ssh: `hose poke <ref> <sha>` with
the source tree as a tar archive on stdin, or `hose drop <ref>` with nothing. One
ed25519 key per project, installed by `weedr project grant <project> <pubkey>` as a forced
command bound to that project, so one repository's workflow can only touch its own services.

**The binding is structural rather than a check, and that is the whole content of the design
here.** The project name appears in the forced command and in no verb signature, so there is
nothing for a client to supply, override or mismatch. An earlier revision took the project twice
— once from the forced command's `--project` and once positionally — and looked equivalent. It
was not: sshd *appends* the client's own command to the forced command, so a key holder for
project A could send a second `--project B`, and a conventional argument parser takes the **last**
occurrence of a repeated option, so the client won and deployed another repository's project with
their own key. `hose` refuses a `--project` argument outright. `hose drop` likewise takes no
service name: it derives one from the project and the ref, so a key for one project cannot drop
another project's instance. A per-project Linux user would have contained the blast radius of a
compromised `hose` but would not have fixed either bug, since both live in the same parser.

The keys live in `/etc/ssh/authorized_keys.d/hose`, one line per project:

```
command="/usr/lib/guarden/bin/hose --project <name>",no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty <type> <key>
```

Taking one away is `weedr project revoke <project> <pubkey>`, which removes that project's lines
and nothing else, and `weedr project keys <project>` lists them. It is a separate verb from
`weedr project add` and it is never `hose`, because writing a line into an `authorized_keys`
file is a root action and a network-facing program has no business holding one. That key is the
only secret CI holds: no registry token, no GitHub credential, in Actions or on the box.

The box keeps no git state — no clone, no checkout, no working tree. The source arrives with
the poke, is unpacked into a per-sha staging directory, and is handed to the build. The
authoritative state is the services plus the deployed sha in each service's registry.

**This is also why a service's tree comes from exactly two places, and neither is a path an
argument can name**: a poke's staged tree (`weedr service ingest <name> --from poke
<project>@<sha>`, where the mutator builds the path from a validated project and a hex sha) or a
copy of another service's (`weedr service add <name> --from <service>`, root only). There is
**no `--from git <url>` and no `--from <path>`**. A private repository is therefore a non-event
rather than a special case — CI holds the credential, and the box holds no forge token, no
deploy key and no `.netrc` to steal. And because `--from <service>` is root-only, a branch can
never create a service out of another service's tree, so a compromised `guarden` program cannot
promote a staging manifest into production.

There is no drift check. Reconciling on a timer needs a read credential stored on the box,
which would put a GitHub credential on a server whose entire credential story is that it holds
none, and it would recover a lost poke for an operator who is also the person pushing the
code. The empty commit is the nudge. If drift correction is ever wanted it should be a tool
with credentials on the operator's laptop, not a daemon holding a token on the server.

The ref decides the track, and the decision is the host's, not the repository's.
`/etc/guarden/projects.toml` maps each project to its repository and each ref to the
environments that ref *may* deploy to — `main` to production, `develop` to staging, everything
else to preview. It is an allowlist, not an assignment: a manifest may not widen it, so no feature
branch can talk its way into a production service. The first poke for a project copies the
template into a per-project file the admin can edit.

A poke may create and deploy a service in a gated track, and the first deploy starts with an
empty database because production is the root of the lineage. A poke may never remove a service
in a gated track: the refusal is enforced root-side in `weedr service remove` against
`/etc/guarden/allow-gated-drop`, and `hose` never reads that file. The removal verb in `hose`'s
sudoers surface is `furrow preview drop`, not a direct `weedr service remove`, so a workflow
cannot even name the removal path; it can ask for one thing to be dropped and `furrow` decides
whether that is allowed. Everything else — ports, credentials — follows ADR-0006 and ADR-0005: a
poke creates the service and waits for the admin.

Builds happen on the box, as the service user, in throwaway containers, tagged with the
image reference the manifest already names, so no registry and no image copying exist. They run
through a mutator verb, `weedr service build <name>`, for two reasons: an
unprivileged `furrow` cannot become the service user, and the subuid range belongs to the service
user and only it may map container-root into it. `furrow` never touches podman. Builds are
serialised by lanes; see ADR-0010 and ADR-0011.
