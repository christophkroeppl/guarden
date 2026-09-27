# Secrets are human-set on production, generated on staging

The tracked `.env.schema` (varlock syntax: `@required`, `@sensitive`, `@type`,
`@example`) is the source of truth for key names and types — never for values. No value
is committed and no deploy carries secrets; CI needs at most an SSH key to poke `hose`.

- **Production:** the operator sets values by hand with `weedr secret set <bed> KEY`. A
  hard gate runs before the running container is shut down and refuses the deploy when a
  `@required` key is empty or still `EXAMPLE-`/`changeme`, so a deploy failing the gate
  leaves the running container running. Staging and preview warn only.
- **Staging:** `weedr` generates the `@sensitive` values at bed create; they stay stable
  until the bed is dropped, and a local override always wins.
- **Preview:** throwaway credentials that die with the bed.

`weedr` plants into the bed (a written-out `.env` or a podman secret) and forgets: it
holds no long-term secret store. The operator owns the offline copy of production values
for snapshot restore.
