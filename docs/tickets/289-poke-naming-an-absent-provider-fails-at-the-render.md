# 289 — a poke naming a provider that does not exist yet refuses at the render, and leaves the service behind

Blockers: none. Found 2026-10-21 while closing ticket 290, by running the `nowhere`
scenario of `tests/t84-provider-diagnostics-mutator.sh` for the first time: it
asserted exit `0` and could never have passed.

## What happens

`edges.install` treats a `needs:` entry whose resolved provider has no registry
entry as a **warning**, not a refusal. Spec 4 says so: "a service that does not
exist *yet* is not an error: a poke creates services in dependency order and a
manifest may name a service a later deploy brings into being." The mutator
records the edge with no publication and appends the warning to
`outcome.warnings`.

`service.create` then saves the registry and calls `units.install`
(`src/guarden/service.py:562`), which renders the service's units as `guarden`.
`render.edge_publications` refuses the edge that was just recorded with no
allocation — exit `1`, correctly, because the answer came from the host — so
`weedr service ingest` fails, and `_emit` never runs. The render's answer is:

```
nowhere-staging needs 'absent' on port 5432, which resolves to 'absent-staging',
and that provider's registry entry names no allocated publication for the edge;
the mutator allocates one when it installs the edge, and the renderer does not
guess a loopback port
```

Both consequences are defects:

- **The warning is never printed.** It is raised before the render and dies with
  the exception, so the operator sees only the renderer's refusal.
  `edges.install`'s no-registry-entry warning and its concrete provider name
  cannot be observed from a poke at all — which is why `t84` asserts only the
  mutator's "offers" refusal and says this ticket is the reason.
- **The service is left half-created.** By the time the render raises, the
  mutator has created the system user, the home, the copied tree, every declared
  volume and the registry record. Nothing rolls them back and there are no units
  to start: `weedr service list` shows a service that cannot be started, and
  re-ingesting the same name is the only way to finish it.

## What to build

Decide the contract, then make the code and spec 4 agree — and say which, because
the renderer is also `loom render`, which must keep refusing:

- **Refuse before identity.** Move the check into `edges.check`, where the
  "offers" refusal already lives, so nothing is created and the operator gets one
  line. The cost is spec 4's sentence: a poke may not name a provider it does not
  ship, and the "will exist" case narrows to the module path — `service.create`
  skips the render for a `module` source, so a module's warning survives and is
  printed.
- **Tolerate the edge in the render the ingest runs.** The service lands with no
  unit for that edge and the warning is the record, which keeps spec 4 as it
  reads and makes the render answer differently depending on its caller.

Either way: the warning must be printed on the path that keeps it, no path may
leave a service with a registry record and no units, and spec 4's sentence must
match what the mutator does. `t84-provider-diagnostics-mutator.sh` is the suite;
its second scenario comes back when this is decided.

**Status:** ready-for-agent
