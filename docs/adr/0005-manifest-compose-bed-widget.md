# Manifest is pure Compose plus two thin contract files

A project repo carries three tracked YAML files and nothing else: `compose.yaml` (pure Compose — the app), `bed.yaml` (infra contract: routes for roots, databases for pond, hyphae aliases), and `widgets/<service>.yml` (exactly one dashboard widget per service, for twig).

Why not a single `bed.yaml` with extensions: we want `compose.yaml` to stay a real Compose file so existing tooling and humans can read it, and so the compose→quadlet converter sees a clean input. Why not `bed.toml`: YAML matches Compose and the Homepage widget format.

Conversion on the server uses **podlet** (containers org) as a pinned binary behind `weedr`, plus a small Python pass to emit `.volume` units for bare named volumes. Bed-specific overrides are `<unit>.container.d/` drop-ins written by `weedr`, so regeneration cannot clobber them.
