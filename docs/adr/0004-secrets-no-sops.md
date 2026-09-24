# No secret ciphertext in git; human-set on prod, generated on non-prod

SOPS (and any ciphertext-in-repo scheme) was rejected: the operator does not want encrypted secrets in git. Vaultwarden was rejected: it is a human password manager with no official machine secrets API. OpenBao/Vault is overkill for one VPS and one human (unseal ceremony, TLS, raft, a second availability domain).

The model is a tracked `.env.schema` (varlock syntax) as the source of truth for *names and types*, never for values:

- **Production:** admin runs `weedr secret set <bed> KEY`. A hard gate refuses to start a production service if a `@required` key is empty or still `EXAMPLE-`/`changeme`. Admin owns the offline copy for snapshot restore.
- **Non-prod:** `weedr` generates `@sensitive` values at bed create (stable until the bed is dropped). Local override always wins. Previews get throwaway credentials that die with the bed.
- `weedr` plants and forgets. Nothing long-term is stored outside the bed.

Deploys never carry secrets. GH Actions needs at most an SSH key to poke `hose`.
