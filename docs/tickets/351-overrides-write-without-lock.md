# 351 — the service create reseeds `overrides.toml` without the lock, so a concurrent verb's setting is silently dropped

Found by adversarial review (NEEDS_IMPROVEMENT) of the t309/t318/t328 merges, and
confirmed by measurement here.

## What is broken

`src/guarden/service.py:446-447` performs a read-modify-write of
`/etc/guarden/services/<name>/overrides.toml`:

```python
granted = overrides_mod.seeded(resolved.track, overrides_mod.load(resolved.name))
overrides_mod.save(resolved.name, granted, root_owner)
```

**No `conf.lock("overrides")` is taken.** Every other writer of that file takes
it — measured with `grep -rn 'lock("overrides")' src/guarden/`:

| writer | line |
|---|---|
| `firewallrules.py` | 35, 59 |
| `ports.py` | 43, 70 |
| `units.py` | 135 |
| `weedr.py` (the `basicauth on/off` verb) | 2267 |

## The failure

A service re-ingest runs the load → `seeded` → `save` above while the operator's
verb is between its own load and save. The re-ingest's `save` writes a document
seeded from **its** read, and the operator's key is gone.

For `[basicauth] required = false` that is the whole contract broken: the
setting is documented as root-owned and movable only by the operator's verb, and
a background re-ingest silently turns the login back on — or, in the other
interleaving, silently discards the opt-out the operator just made.

**The same window already applies to `[ports] open` and `[firewall] allow`**, so
this is not a defect t318 introduced. What t318 changes is the consequence: the
dropped key is now the one that decides whether a route is served with a login.

## The fix

Take the lock around the pair:

```python
with conf.lock("overrides"):
    granted = overrides_mod.seeded(resolved.track, overrides_mod.load(resolved.name))
    overrides_mod.save(resolved.name, granted, root_owner)
```

It is legal under the repo's own lock order. Measured
`conf.LOCK_ORDER` = `[(0,'modules'), (1,'projects'), (2,'overrides'),
(3,'registry'), (4,'preview-cap'), (5,'queue'), (6,'firewall'),
(7,'snapshots')]`, and `service.py`'s `registry` lock is at `:548` — **after**
this write. So `overrides` (rank 2) is taken while nothing is held, and it is
released before `registry` (rank 3) is acquired. No inversion, and no call site
holds `overrides` earlier on this path.

## Acceptance

- The read-modify-write in `src/guarden/service.py`'s `create` — the one measured
  at `:446-447` above, and moved down by the fix itself — is inside
  `conf.lock("overrides")`.
- A test that demonstrates the lost update: hold the `overrides` lock in one
  process (or interleave a load/save pair), run the re-ingest path, and assert
  the operator's key survives — RED against today's code, GREEN after. If a
  deterministic interleaving is not reachable from a suite, say so in the ticket
  and pin the lock with an assertion that the writer takes it, rather than
  claiming a race that was never observed.
- The other three unlocked-or-locked writers listed above keep working: `ports`,
  `firewallrules`, `units` and the basicauth verb are unchanged.

## What the suite pins, and what it does not

**The interleaving that would DROP a key is not reachable from a suite, and
`tests/t351-overrides-lock.sh` does not claim it.** The read and the save are
two adjacent statements — `seeded(load(...))`, then `save(...)` — so the window
an operator's write has to land in is microseconds wide and there is no seam to
stop the process in. A test that slept "long enough" and then looked would
report the machine's speed rather than the code, passing most runs and failing
the rest.

What the suite pins is the property that makes the loss impossible: **the deploy
waits for the `overrides` lock**, and the document written while it waits is the
one it reads and preserves.

- An external process takes `/run/guarden/locks/overrides.lock` with `flock(1)`
  and writes the document `weedr basicauth off` writes —
  `[basicauth] required = false`. The verb itself cannot be used: it refuses a
  service with no minted login, and the service in question does not exist yet.
- `weedr service ingest` is started against a service that does not exist. It
  creates the user, makes the tree and copies the source, all of them before the
  write, and then the assertion is on what it has **not** done: `overrides.toml`
  is still byte-for-byte the operator's document three seconds after that copy
  landed, and no registry entry exists.
- Measured RED on the unfixed code, the deploy's own document appeared inside
  the held lock. Measured GREEN after, the write waits for the release.
- After the release the file carries **both** halves: the operator's
  `required = false` and the retention the seed writes, at the mode and owner
  `overrides.save` states. That is the read happening after the operator's
  write, which is what the lock buys. A file carrying only the first would be a
  deploy that never saved; only the second, one that dropped the key.

The one thing the RED run shows plainly is that in **that** interleaving the key
survived: the deploy's read simply landed after the operator's write, and
nothing in the code made that true. That is the honest report — the lock is what
makes it true by construction.

## Not in scope

Whether `seeded()` should preserve an operator-set key it does not recognise.
That is a separate question about the seeder's contract; this ticket is only
about the missing lock.
