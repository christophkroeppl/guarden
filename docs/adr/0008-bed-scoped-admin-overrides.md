# Admin overrides live in the bed and survive gitops

Any bed setting must be overridable by the server admin and stay overridden across
redeploys: the admin wins over git. Two mechanisms, both bed-scoped and root-owned:

- `/home/bed-<env>-<name>/overrides.yaml` — root:root, mode 0444, readable by the bed
  user and the CLIs, writable only by root.
- Root-owned drop-ins in the bed's quadlet dir (`<unit>.container.d/`) for unit-level
  overrides.

Systemd `.path` watchers with globs over the `bed-*` / `pond-*` folder schema (recursive,
so nested preview refs are caught) run `daemon-reload` on change — never an auto-restart.
No regex and no registration daemon: the folder schema is the registry.

Why: `hose` regenerates units from git on every pull, so anything the admin owns must
live outside the regenerated paths — regeneration and gitops never touch root-owned
files.

Consequences: regeneration can run at any time, and an override is a file you can read,
diff, and remove to hand the setting back to git.
