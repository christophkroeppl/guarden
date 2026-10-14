# 272 — deployment.newest: what the real repositories need that guarden refuses

Blockers: none (this is a findings ledger). Found 2026-10-13 during the first
real deployment attempt against `supplements/develop`, `klimafit/develop`,
`bases-mcp/develop` and `deployment.newest/*`.

An adversarial review of the deployment plan (before any service was deployed)
named the following, and each was re-verified against the repositories by the
parent. They are guarden-level findings because the fix is either a decision
about what guarden accepts or a change to the renderer's refusal set — not a
change to a service.

## Hard refusals the repositories currently trip

1. **A bind of the repository root.** `supplements/develop/compose.yml:73,91,111`
   bind `.:/workspace`. `loom` refuses any host path outside the service's own
   volumes, `/etc/guarden` and `[mounts] allow` (spec §6.3). The service must
   receive its source through a **poke** (staged at
   `/var/lib/guarden/staging/<project>/<sha>/`) and reference it there, or the
   image must be built with the source inside it. This is the refusal working as
   designed; the deployment has to change, not the refusal.

2. **Resource caps in a compose file.** `klimafit/develop/compose.development.yml:105-106`
   carry `mem_limit: 2g` and `cpus: '2.0'`. Spec §4 refuses a manifest key that
   states a resource cap or weight; weights come from the root-owned environment
   table and caps from a root-owned drop-in. The deployment's compose file must
   drop them.

3. **No unit source at all.** `bases-mcp/develop` has neither `compose.yaml` nor
   `.guarden/quadlet/` (spec §4 requires exactly one). It is a Rust MCP server
   with a `justfile` and `src/`; a manifest and a unit have to be authored before
   it can be rendered. Not a guarden defect — a missing service definition.

4. **A custom bridge network.** `klimafit/develop/compose.development.yml:162-164`
   declares `networks: … driver: bridge`. Spec §7.1: there is no shared podman
   network; `loom` overwrites `Network=` with `Network=pasta:`. The compose file
   is not a faithful description of what runs, so it should not declare one.

## The design gap: RustFS's two-key credential

**A `secret` edge mints ONE credential and presents it as `/run/secrets/<AS>_PASSWORD`.**
RustFS (S3) reads `RUSTFS_ACCESS_KEY` and `RUSTFS_SECRET_KEY` — two distinct
values, not a password. The edge model has no mechanism to rename the credential
or to provide a second key.

Two ways out, and the choice is a decision worth recording:

- **Per-service keys, planted by hand**: `weedr secret set rustfs-production
  RUSTFS_ACCESS_KEY` and `… RUSTFS_SECRET_KEY`, declared `@required @sensitive`
  in the provider's `.env.schema`, so the renderer emits `Secret=<KEY>,type=mount`
  and podman presents both at `/run/secrets/<KEY>`. This works today and is what
  the deployment will use. The cost is that the credential is **not minted per
  consumer** — every consumer that declares the RustFS edge must be given the
  same access key, so the per-consumer boundary the `database` edge provides does
  not exist here.
- **An `auth: s3` edge kind** that mints a key pair per consumer (as
  `auth: database` mints a role+password). This is the clean answer and it is a
  guarden change: a new edge kind, a minter that talks S3's admin API, and the
  same `provides:`/`as:` validation. It is not needed to deploy; it is needed for
  the RustFS edge to mean what a `database` edge means.

## Not blockers

- `deployment.newest` 230/240/250/260/270/280 are requirement lists and the
  current guarden satisfies them (the volume rule, per-service retention, public
  grants, `secret` edges, `auth: true` routes, supplementary groups).
- TKT-300 (the herdr hub) and TKT-310 (sandboxes) are explicitly out of this
  deployment; TKT-300's §0 spike has not been run.

## The verb, corrected

The deployment does **not** use `weedr service add` (which copies from another
service, `--from <service>`). A repository reaches the host through a **poke**:
`weedr service ingest <name> --from poke <project>@<sha>` (spec §5.3,
`docs/sysadmin.md:221`). `soil` phases are run one at a time — `soil install
--apply`, then `soil packages --apply`, and so on.
