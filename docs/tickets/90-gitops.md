# 90: projects, poke keys, and the gitops receiver

**What to build:** A project is registered, a CI key is bound to it, and a push pokes the box.
The box takes the source, maps the ref to an environment from a root-owned allowlist, and asks
`furrow` to deploy. No git state, no credentials on the box beyond one ssh key per project.

**Blocked by:** 50 (the edge), 80 (edges), 120 (the queue)

**Status:** ready-for-agent

- [ ] `weedr project add` writes the entry and the per-project copy in
      `/etc/guarden/projects.d/`, with the ref to environment mapping as an **allowlist**
- [ ] A ref matches the first applicable pattern, `*` matches any ref, and a ref matching
      nothing is refused with exit 1 and the reason
- [ ] A project entry in `/etc/guarden/projects.toml` and one in `projects.d/` are both
      honoured, the latter winning
- [ ] **The environment a ref maps to must be one the `[[environments]]` table in
      `guarden.toml` defines.** A mapping naming an unknown environment is refused naming the
      file and the key, rather than creating a track by accident
- [ ] `weedr project grant <project> <pubkey>` appends to `/etc/ssh/authorized_keys.d/hose` a
      line of the form
      `command="/usr/lib/guarden/bin/hose --project <name>",no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty <type> <key>`,
      refusing a key that is not ed25519 and refusing a project that does not exist
- [ ] A forced command naming a different project is refused, so one repository's workflow can
      only ever reach its own services
- [ ] **It is `weedr project grant`, never `hose grant`.** Writing a line into an
      `authorized_keys` file is a root action and the only network-facing program has no
      business holding one
- [ ] **`weedr project revoke <project> <pubkey>` removes that project's lines from
      `/etc/ssh/authorized_keys.d/hose` and nothing else**, and `weedr project keys <project>`
      lists what is installed. A poke cannot name either verb
- [ ] **`hose` takes no project argument at all, and refuses a `--project` one with exit `2`.**
      The project comes from the forced command and nowhere else. This is the whole of the
      per-project binding: sshd appends the client's command to the forced command, so a client
      supplying a second `--project` would win the last-occurrence rule in every conventional
      argument parser and deploy another repository's project with their own key
- [ ] `hose drop <ref>` **derives** the service name from the project and the ref and never
      accepts one, so a key for one project cannot drop another project's instance
- [ ] **No verb takes a path.** `weedr service ingest <name> --from poke <project>@<sha>` builds
      `/var/lib/guarden/staging/<project>/<sha>` itself from a project validated against
      `projects.toml` and a hex sha, and `weedr service add --from <service>` copies a service
      tree. `weedr service build` takes no `--from`. There is nothing to confine, because a
      caller can no longer choose a location — a poke can only ship its own tree
- [ ] `hose poke <ref> <sha>` unpacks the tar archive on stdin into
      `/var/lib/guarden/staging/<project>/<sha>/` — keyed by project, so the path exists before
      any service does — creates the service and instance the allowlist permits, and calls
      `furrow deploy`, whose `weedr service ingest` carries no flag that could grant a port
- [ ] **The archive is unpacked safely and the test says so:** as a non-root user under
      `umask 022`, with absolute member names refused, `..` components refused, no preserved
      ownership or timestamps from the archive, and no symlink followed. A member that would
      escape the staging directory is refused and the poke fails without touching a service
- [ ] Requested ports stay pending and the `warning:` line reaches the workflow log
- [ ] A poke whose sha equals the deployed sha in the registry makes no `furrow` call and exits
      0
- [ ] A malformed poke — bad sha shape, ref outside `[A-Za-z0-9._/-]` — exits non-zero without
      touching a service
- [ ] The first poke for `main` creates the production service with an empty database, no fork
      in the journal, and the service does not start until the operator plants its credentials
- [ ] **`hose drop <ref>` never removes a service in a track with `gated = true`,**
      refused with exit 1 and the reason unless `/etc/guarden/allow-gated-drop` exists. **The
      refusal is enforced root-side in `weedr service remove`, and `hose` never reads that file**
      — and the mode is not what stops it. `0444` is world-readable, so `hose` could read the
      file if it wanted to; what stops it is that the refusal lives in the verb `hose` is not
      permitted
- [ ] The box keeps no clone and no checkout: the repository directory is absent afterwards
- [ ] **The sudoers surface is exactly, with its runas target:** `furrow deploy`,
      `furrow preview drop`, `furrow queue list`, `furrow status`, `weedr service list` and
      `weedr project list`, installed as
      `hose ALL=(guarden) NOPASSWD: /usr/lib/guarden/bin/furrow deploy, ...`. The `(guarden)` is
      what makes the escalation a property of the file: the default reading of "a sudoers rule
      naming X" is that X runs as root, and the program that handles repository-supplied paths
      must not be that. The removal verb is `furrow preview drop`, not a direct `weedr service
      remove` — a workflow cannot even name the removal path, it can ask for one instance to be
      dropped and `furrow` decides whether that is allowed. `weedr` is reachable from a poke
      only as `weedr service list` and `weedr project list`, so a poke cannot create a service,
      grant a port, or remove one. Note that `weedr service list` reports a service's granted
      ports as part of its status, so a poke can *read* which ports are open; what it cannot do
      is reach `weedr port list`, `weedr port open` or `weedr port close`. Say it here rather than
      claiming `weedr` is unreachable, because it is not. A poke cannot reach a shell
- [ ] **`hose check` actually verifies**, and is not a stub: the project is in `projects.toml`, the
      forced command names this project, the per-project staging directory exists and is writable
      by the `hose` user, the ref maps to a track, and `guarden` can read what `furrow` needs. Each
      failure is a `warning:` naming what failed, and the exit is 1 if any failed. It changes
      nothing, so CI may call it on every push
- [ ] The staged tree is removed after the deploy
- [ ] The shipped workflow template contains the poke key and nothing else, with
      `concurrency: { group: <project>/<ref>, cancel-in-progress: true }`
- [ ] Verified at the CLI seam, in the VM
