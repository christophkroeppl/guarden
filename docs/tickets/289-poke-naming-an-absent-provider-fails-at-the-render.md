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

## The decision, measured on the branch

**Refuse before identity.** `edges.check` now makes every edge answer the
renderer makes — an absent provider, a port the provider names no container for,
a provider whose entry allocates no publication for that port, and a self-edge —
before the system user exists; `edges.install` asks the same question through
`_installable` and records the answer. The alternative was rejected: the renderer
is also `loom render`, which must keep refusing, and it cannot invent a loopback
port, so tolerating the edge for one caller would put the same rule in two places
with two answers.

`t84`'s absent-provider scenario comes back, with a self-edge one beside it, and
`t80`'s two incomplete-edge scenarios change with them: both asserted the
registry record the old path saved, which is the service this ticket is about.
`t80`'s "nowhere" scenario was also not measuring what its comment said — it
named the consumer itself (`nowhere-staging` needs `nowhere-staging`), so it was
a self-edge whose exit `2` arrived as `1` through `tool.run`'s collapse; it now
names a provider that is actually absent.

**RED** — `2978ffa`, the tests with the source at its pre-fix state:

```
$ GUARDEN_LXC_RUNNER=guarden-run-t289 tests/lxc.sh run t84 --no-cache
error: expected exit 2, got 1
  stderr: error: runuser exited 2: error: the manifest /var/lib/guarden/staging/ghost/9f2c1ab/.guarden/service.yml needs 'ghost-staging', which resolves to 'ghost-staging' — the service that declared it: a self-edge has no consumer and is nearly always a copy-paste
error: failed at line 103: return 1 (exit 1)
FAIL t84-provider-diagnostics-mutator.sh
1 suites: 1 ran, 0 inherited, 1 failures, 1 machines cut
```

The suite stops at its first failure, so the absent-provider scenario is not
reached there. The same tree with the self-edge scenario set aside reaches it,
and the failure is the half-created service itself:

```
$ GUARDEN_LXC_RUNNER=guarden-run-t289m tests/lxc.sh run t84 --no-cache
error: passwd entry for nowhere-staging exists: nowhere-staging:x:994:981::/var/lib/guarden/services/nowhere-staging/home:/usr/sbin/nologin
error: failed at line 567: return 1 (exit 1)
FAIL t84-provider-diagnostics-mutator.sh
1 suites: 1 ran, 0 inherited, 1 failures, 1 machines cut
```

**GREEN** — `d908801`:

```
$ GUARDEN_LXC_RUNNER=guarden-run-t289g tests/lxc.sh run t8 --no-cache
ok   t80-edges.sh
ok   t83-provider-diagnostics.sh
ok   t84-provider-diagnostics-mutator.sh
3 suites: 3 ran, 0 inherited, 0 failures, 3 machines cut

$ GUARDEN_LXC_RUNNER=guarden-run-t289c tests/lxc.sh run t60-secrets --no-cache
ok   t60-secrets.sh
1 suites: 1 ran, 0 inherited, 0 failures, 1 machines cut

$ GUARDEN_LXC_RUNNER=guarden-run-t289d tests/lxc.sh run t120-deploy --no-cache
ok   t120-deploy.sh
1 suites: 1 ran, 0 inherited, 0 failures, 1 machines cut
```

`t60-secrets` carried a stale assertion for the warning this ticket removes
(`assert_stderr_lacks "the edge is recorded with no publication"`, which no
longer names anything); it now asserts the record's own allocation, which is the
fact the credential hangs on.

**What this does not change.** The four `needs:` answers no longer reach the
render. A refusal from the unit source itself — a duplicate `PublishPort`, a
sibling host in an `Environment=`, a mount outside the allow list — is still made
by the render after identity, and that ordering is untouched here.
