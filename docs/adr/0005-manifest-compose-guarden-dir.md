# Manifest is root Compose or .guarden/quadlet plus thin contract files

A project repo carries either `compose.yaml` at its root or quadlet units in
`.guarden/quadlet/` — exactly one; neither is a pre-commit error. `compose.yaml` stays
pure Compose, so local `podman compose` and existing tooling keep working.

`.guarden/` holds the thin contract files: `bed.yaml` (routes for `roots`, `pond`
databases with roles and grants, hyphae aliases, `ports:` for ferm), `widgets/<service>.yml`
(exactly one per service, for `twig`), and `.env.schema`. `weedr` (manual) and `hose`
(gitops) read the same files.

Conversion on the server uses **podlet** as a pinned binary behind `weedr`, plus a small
pass that emits `.volume` units for bare named volumes; a repo that ships quadlet keeps
its units as they are. Bed-specific and admin overrides are `<unit>.container.d/`
drop-ins, so regeneration rewrites units and leaves overrides standing;
`/etc/containers/systemd/users/<uid>/` is the admin injection path for units that must
outlive a regenerate.
