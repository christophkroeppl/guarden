# 276 — every secret-carrying unit fails to start: `type=file` is not a podman type

Blockers: none. Found 2026-10-14 deploying the first real service.

## What happens

The renderer emits `Secret=<KEY>,type=file` for every schema key and every edge
credential. **podman 5.7 rejects it**, and the unit fails to start:

```
Error: type file is invalid: parsing secret
```

Measured against podman 5.7.0 on the deploy VM:

| directive | result |
|---|---|
| `type=mount` | accepted — secret at `/run/secrets/<KEY>` |
| `type=env` | accepted — secret in the environment |
| `type=file` | `Error: type file is invalid: parsing secret` |
| `type=image` | `Error: type image is invalid: parsing secret` |
| `type=tmpfs` | `Error: type tmpfs is invalid: parsing secret` |

`mount` is exactly what the renderer's own docstring says it does — "podman
resolves `<KEY>` from that service's own secret store and presents it at
`/run/secrets/<KEY>`" — so the literal was wrong and the intent was always
`mount`. Fixed in the same commit as this ticket.

## Why nothing caught it

Three suites pin the wrong literal as *expected output*:

```
tests/t40-render.sh:105  assert_file_has "$unit" "Secret=APP_SECRET,type=file"
tests/t40-render.sh:109  assert_file_has "$unit" "Secret=DB_PASSWORD,type=file"
tests/t60-secrets.sh:245 assert_file_has "$unit" "Secret=DB_PASSWORD,type=file"
tests/t80-edges.sh:258   assert_file_has ... "Secret=DB_PASSWORD,type=file"
tests/t80-edges.sh:259   assert_file_has ... "Secret=SECRET_SECRET,type=file"
```

Every one asserts the **rendered text** and never starts a container that carries
a secret, so a value podman refuses was pinned as correct by three suites at
once. This is the vacuous-verification shape: the check reads like a check and
cannot fail on the defect. The suites now assert `type=mount`, and the deeper fix
— a suite that starts a container with a real secret — is what would have caught
it.

## Consequence

Every service with a database or secret edge — which is every real service —
failed at first start with a message that named podman and not guarden.
