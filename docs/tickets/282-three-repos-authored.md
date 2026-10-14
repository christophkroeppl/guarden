# 282 — the three deployment repositories: what was authored, and one correction

2026-10-14. Each repository got a `feat/guarden-deploy` worktree off `develop`, and
the deployment files were authored or verified there. **Not committed** — the
worktrees hold the changes for review.

## supplements — authored

A deployment-scoped `compose.yaml` (three services: `nutristack`, `dailydose`,
`catalog-admin`), `.guarden/service.yml` (`project: supplements`, `units:
compose.yaml`, a `needs:` edge to `postgres-production` as `db`, `schema:
.guarden/.env.schema`, three `routes:`), `.guarden/.env.schema` (`NUXT_AUTH_SECRET`
and `NUXT_AGENT_API_KEY`, both `@required @sensitive`), and
`deploy/guarden-entrypoint.sh` (assembles `DATABASE_URL` from `DB_HOST`/`DB_PORT`
plus `/run/secrets/DB_PASSWORD`, exports the two schema secrets from their files,
execs the image CMD). The three Containerfiles gained a `COPY` of the entrypoint.

**Verified by rendering, not by reading.** The manifest was staged and ingested as
`supplements-staging` on the deploy VM: it renders all three units, the
`AddHost=postgres-production:10.0.2.2` edge, `DB_HOST`/`DB_PORT` in the
EnvironmentFile, `Secret=DB_PASSWORD,type=mount`, and both schema secrets as
`type=mount`.

**Two corrections the render forced** (neither was visible by inspection):

- The authored `healthcheck:` blocks used a JS one-liner, and **a compose
  healthcheck with a space is refused** — `HealthCmd` is not a quotable systemd
  key (ticket 281). Removed; the images' own `HEALTHCHECK` is what runs.
- The image references are `supplements-<app>:latest`, which is a **local tag**.
  Whether the host's build produces that tag is unverified — `weedr service build`
  is declared in the service tuple but has **no handler** (`weedr.py`: it falls
  through to `cli.pending()`), so the build verb is not implemented and the tag the
  host would produce cannot be checked. Flagged rather than guessed.

## bases-mcp — verdict (a): it is not a guarden service

Both implementations are **stdio** MCP servers:

- Rust: `src/main.rs:1` (`//! The stdio MCP server entrypoint.`), `:25`
  (`use rmcp::transport::stdio;`), `:71` (`let transport = stdio();`), `:75`
  (`.serve(transport)`). No `TcpListener`, no HTTP, no SSE, no socket.
- TypeScript: `ts-implementation/src/index.ts:30` (`StdioServerTransport`), `:268`
  (`server.connect(new StdioServerTransport())`).

Enabling HTTP/SSE is **not** a small change: `rmcp`'s
`transport-streamable-http-server` is not enabled in `Cargo.toml`, and the server
holds `Rc<Vault>` (`main.rs:70`), which is `!Send` by construction — the vault is
indexed behind a `RefCell` and every `file.*` accessor is an `Rc` closure into it
(`Cargo.toml:46-49`), and `local` is rmcp's single-threaded mode. Streamable HTTP
requires `Send` handlers, so it would be a rewrite of the vault/resolver with
correctness implications.

So a stdio server is **spawned by its consumer**, not deployed as a host service:
the "deployment" is client-side configuration, and no unit was invented. The
repository's own ticket was sharpened with this evidence.

## klimafit — verified, two real defects fixed

The existing files were checked against guarden's source. Most were correct
(`project`/`units`/`needs`/`routes` keys, the `auth: database` variable names, the
Dockerfiles, and the absence of every refused compose key). Two were not:

- **`as: s3` is refused.** `edges.check()` requires the `as:` value to be one of
  the provider's `provides:` kinds; `rustfs-production` provides exactly `secret`
  (its registry: `kinds = ["secret"]`), and the only kinds guarden has are `db` and
  `secret` (`manifest.PROVIDES_KINDS`). Measured live: *"the consumer wants the
  kind 's3' and the provider does not list it"*. Changed to `as: secret`.
- **The entrypoint read the wrong variable names.** With `as: s3` the rendered
  variables are `S3_HOST`/`S3_PORT`/`S3_SECRET`; with `as: secret` they are
  `SECRET_HOST`/`SECRET_PORT`/`SECRET_SECRET`. The entrypoint was rewritten for the
  correct names, and its comment now states the rule (`<AS>_<KIND>` from
  `edges.credential_key`) rather than the wrong one.

**A correction to the verification itself:** the verifying agent reported fixing a
literal `***` in `DATABASE_URL` and marked the manifest keys correct by regex. Both
were wrong. The raw bytes of that line were always
`postgres://guarden:${_db_pass}@...` — the `***` was **redaction in the agent's own
tool output**, not file content; and `as: s3` matches `AS_RE` while being
semantically refused, which is exactly why a regex is not a verification. The
spurious edit was reverted and the real defects fixed.

## What this round demonstrates

Every defect found here was found by **rendering or ingesting** the files, never by
reading them: the healthcheck refusal, the `as: s3` refusal, the variable names. A
verification that reads the manifest and checks names against a regex passes on all
three. That is the same vacuous-verification shape as ticket 276 — a check that
reads like a check and cannot fail on the defect.
