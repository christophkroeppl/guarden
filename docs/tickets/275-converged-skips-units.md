# 275 — a re-ingest short-circuits on `_converged` and never re-installs the units

Blockers: none. Found 2026-10-13 while deploying the first real service.

## What happens

`weedr service ingest <name> --from poke <project>@<sha>` returns `converged`
and does nothing when the registry entry already matches the manifest on
project, environment, instances and volumes:

```python
existing = registry.load(resolved.name)
if existing is not None and _converged(existing, resolved, manifest, project):
    outcome.converged = True
    ...
    return outcome          # <- units.install is never reached
```

`_converged` checks the manifest's declared volumes and the track — **not the
unit source**. So editing `compose.yaml` (adding `PGDATA`, changing an image, any
container key) and re-ingesting is a no-op: the render never re-runs and the
installed unit keeps the old content. The change reaches the host only if the
manifest's volumes or track also changed, or if `units.install` is invoked by
hand.

Measured: after adding `PGDATA` to the compose file and re-ingesting (which
answered `converged`), the installed unit still had no `PGDATA`.

## The same class, second site

`soil install --apply`'s program-install item is the same shape: `_install_programs`
copies `src/guarden/*.py` into `/usr/lib/guarden/lib/guarden/`, and the item's
`holds()` did not detect that the installed copy was stale, so a changed module
was **not** re-installed by `soil install --apply`. Measured: after editing
`unitsource.py` and running `soil install --apply` (rc 0), the installed copy at
`/usr/lib/guarden/lib/guarden/unitsource.py` was still the old one — and that is
the copy `loom` actually runs (`units.render_units` invokes the installed
`/usr/lib/guarden/bin/loom`), so the fix appeared not to work until the file was
copied by hand.

## Why it matters

Both make a change silently invisible on the host while every command reports
success. The unit-content case is the worse of the two because the deploy path
(`weedr service ingest`) is the documented way to converge a service, and it
answers `converged` for a change it did not make.

## What this ticket wants

- `_converged` must account for the unit source: a hash of the rendered units (or
  of the source tree) in the registry, compared on ingest, so a changed
  compose/quadlet re-renders and re-installs.
- The program-install item must compare content, not existence: an installed
  `.py` whose bytes differ from the source is drift, and `--check` should say so.
