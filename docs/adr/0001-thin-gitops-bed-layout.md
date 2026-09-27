# Thin gitops layer and our own bed layout

One VPS, one operator: the privileged surface is a single CLI. `weedr` is the only
privileged mutator — it creates and drops beds, plants secrets, mints pond roles, and
converts manifests. `hose` is an optional gitops reconciler that pulls a source of truth
and calls `weedr` through a narrow sudoers rule, so git never becomes root. `stakes`
accounts for snapshot pins; `roots` accumulates Traefik dynamic config from bed routes.

Each bed is one Linux user with a user-scope quadlet directory, its env files, and its
hyphae names. Bed-scoped overrides live in that layout as unit drop-ins, so regenerating
units leaves them standing. `roots` runs unprivileged and shares only the dynamic-config
directory and the `fence` group with the Traefik bed user, so a `roots` bug cannot run
containers.

Why: sudo is one narrow door, every mutation is a command we can log and test at the
command-line seam, and gitops is an optional driver rather than a second source of truth.
Consequences: manual and gitops beds share one layout — no privileged mode in a bed —
and debugging is `ls` and `cat` over files and paths, with no internal HTTP API.
