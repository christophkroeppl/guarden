# 287 — the credential materialiser uses a flag podman does not have, so NO service's secrets materialise

Found 2026-10-14 starting the first `odoo-btc-bcr` service. **The most consequential
defect of the deployment work so far: it silently disables the credential path for
every service on the host.**

## What happens

`credentials.materialise` removes a secret before recreating it, and the removal
command is:

```python
tool.call(["runuser", "-u", name, "--", "podman", "secret", "rm", "-f", key], cwd=where)
```

**`podman secret rm` has no `-f` flag.** Measured on the deploy VM:

```
$ podman secret rm -f HERMES_GATEWAY_TOKEN
Error: unknown shorthand flag: 'f' in -f
See 'podman secret rm --help'

$ podman secret rm HERMES_GATEWAY_TOKEN
cf4931c6ebc63088697a1a158          # works; the secret is gone
```

So the removal fails, the following `podman secret create <key> -` fails with
`Error: <KEY>: secret name in use`, and `tool.run` raises.

## Why it disables everything, not just one secret

`materialise()` iterates **every blob on the host in one loop**, and the failure is
not caught: the first already-existing secret aborts the function. Measured:

```
guarden-creds-boot.service: error: runuser exited 125:
  Error: HERMES_GATEWAY_TOKEN: secret name in use
guarden-creds-boot.service: Main process exited, code=exited, status=1/FAILURE
```

`guarden-creds-boot.service` is `failed`, and the only reason **any** secret exists
in any service's podman store on this host is that they were created by hand
(`printf ... | podman secret create ...`) during this deployment. Every secret that
was planted through the supported verb — `weedr secret set` — is in guarden's
encrypted store and **not** in podman, which is exactly the state that makes a unit
fail to start with `no secret with name or id "<KEY>": no such secret`.

This is why `hermes-production` could only be started after its secrets were
hand-created, and why `odoo-btc-bcr-staging` cannot start now.

## The fix

Drop the `-f`. `podman secret rm` is already idempotent enough for this use if its
"no such secret" exit is tolerated, but the simplest correct form is a bare
`podman secret rm <key>` whose failure is ignored when the secret is absent — the
`create` that follows is the operation that must succeed. (`--force` does not exist
for this subcommand; a reader who assumes it does, as this code did, gets an error
that names the flag rather than the problem.)

## The class

This is the same shape as tickets 275 and 284: a command that is *written* to
converge but never does, whose failure is invisible because the next step reports
something else. Here the next step's message (`secret name in use`) points at the
secret rather than at the flag that failed to remove it, and the unit that fails is
a boot unit rather than the deploy that needed it.

## What it hid

- `weedr secret set` has never worked end to end on this host.
- Every `Secret=<KEY>` line in every rendered unit has been unsatisfiable.
- The only reason the deployment appeared to work is that the operator (this
  session) worked around it by hand, twice, without recognising the workaround as a
  workaround.
