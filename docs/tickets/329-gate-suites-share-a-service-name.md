# 329 — two suites share the service name `pgprov-staging`, so the gate is red in sequence and green alone

## What is broken

`tests/t80-edges.sh` fails in the full gate and passes on its own.

Measured on 2026-10-21, full gate (`tests/lxc.sh run "t" --no-cache`):

```
rm: cannot remove '/var/lib/guarden/services/pgprov-staging/home': Directory not empty
error: failed at line 43: grep -qF -- "$1" "$2" (exit 1)
FAIL t80-edges.sh
```

Same suite, its own run (`tests/lxc.sh run t80-edges.sh --no-cache`):

```
ok   t80-edges.sh
1 suites: 1 ran, 0 inherited, 0 failures, 1 machines cut
```

## Cause

Both suites drive a service named `pgprov-staging`:

| suite | gate position |
|---|---|
| `tests/t315-envfile-ref.sh` | 60 |
| `tests/t80-edges.sh` | 114 |

`t315-envfile-ref.sh:47` purges it on `EXIT`:

```sh
cleanup() {
    purge pgprov-staging envconsumer-preview
    rm -f /etc/guarden/firewall/50-services.conf
}
trap cleanup EXIT
```

and `purge` is `rm -rf` of the service's directories plus `userdel`. That
`rm -rf` **cannot remove `.../home`** — the diagnostic is the signature of a
path `rm` cannot traverse, a mount point. So `t315` leaves the service's home
behind, `t80` starts against a name that was never cleared, its own `purge`
hits the same `Directory not empty`, and the assertion that follows fails.

Lower-numbered suites run first in gate order, so `t315` poisons `t80`
**deterministically**. Nothing about this is flaky: it is invisible in
isolation and reliable in sequence, which is why per-suite runs have been
green while the gate is red.

## The fix

One of, in order of preference:

1. **Give each suite its own service name.** `pgprov-staging` in `t315` and
   something else in `t80` — a shared *name* is the collision, and renaming is
   the change that cannot silently regress. (A numbered or named runtime
   resource is shared even when the files are not.)
2. **Make `purge` able to clear a mount point**: unmount or `rm -rf` the
   contents before the directory, and report rather than ignore a failure.
   This is the weaker fix: it makes a shared name survivable instead of
   removing the sharing.

Whichever is chosen, `purge` must **not** swallow the failure — today the
`rm` error is printed and then ignored, so the next assertion fails for a
reason unrelated to what the suite was testing.

## Acceptance

- The full gate is green, specifically with `t315-envfile-ref.sh` running
  before `t80-edges.sh` on the same machine.
- A test that creates `pgprov-staging`, purges it, and asserts nothing is
  left under `/var/lib/guarden/services/pgprov-staging` — RED if `.../home`
  survives.
- No suite loses its own coverage by being renamed; any rename updates the
  registry and firewall assertions that name the service.

## Not in scope

Whether the home is *legitimately* a mount point after a service is created —
that is the tree's design. This ticket is about two suites disagreeing over
one name.
