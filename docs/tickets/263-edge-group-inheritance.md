# 263: the edge container cannot read the route directory, and the fix is not `GroupAdd=keep-groups`

**Blocked by:** nothing. **Blocks:** nothing today; it makes `t50-slice.sh` red, so it blocks any
release gate that runs the whole suite.

**What to build:** A decision, recorded as an ADR, and then whichever answer it carries. This
ticket exists because the obvious fix was reached first, is unsafe, and was correctly not merged.

## What is measured

`tests/t50-slice.sh` asserts the edge can read the routes it is given:

```
run runuser -u traefik-production -- podman inspect --format '{{.Mounts}}' traefik-production-traefik
assert_stdout_has "/var/lib/guarden/edge/dynamic"
assert_stdout_has "ro"
assert_supplementary_group traefik-production edge
assert_mode /var/lib/guarden/edge/dynamic 2750
```

`/var/lib/guarden/edge/dynamic` is `2750 guarden:edge` (spec §2.1 line 238 — "**not** `roots`,
which cannot set a group it is not in"), and `traefik-production` is in the `edge`
supplementary group. The service *user* therefore has the access. The suite fails on the
`curl` to the edge's publication — `curl` exit 28, a connection timeout.

## The fix that was reached first, and why it is wrong

An agent added to the renderer:

```python
unit.put("Container", "GroupAdd", ["keep-groups"])
```

emitted whenever the service is the edge **or** the admin granted supplementary groups via
`[groups] add`. `GroupAdd` was added to both `OWNED_KEYS` and `GUARDEN_OWNED_ORDER`.

**It was not merged, for three reasons.**

1. **It is unverified.** The suite still failed with `curl` exit 28 after the change. A fix for
   a failure you have not fixed is not a fix, and this one was carried on a hypothesis — that
   the container does not inherit supplementary groups — that was never tested.

2. **It widens the container's group set for every granted-group service**, not just the edge.
   `[groups] add` exists so a hardware-transcoding service can reach `/dev/dri`. `keep-groups`
   hands the container *every* supplementary group its user holds, which is a broader grant
   than the one an admin asked for. The renderer refusing `GroupAdd` from repository input while
   emitting it for privileged reasons is the right shape; emitting it for a different reason
   than the one it was designed for is not.

3. **It may not be the cause at all.** `assert_supplementary_group traefik-production edge`
   proves the *user* is in the group. Nothing yet establishes that the failure is group
   membership inside the container rather than the route file not being written, the mount not
   being read-only, the edge not listening, or pasta mapping something differently than the
   rule assumes.

`GroupAdd` does not appear anywhere in `src/guarden/`, `docs/spec.md` or `AGENTS.md` on
`develop`. Adding it is a change to the security model and needs a decision, not a patch.

## Acceptance

- The cause is **established**, not hypothesised: a measurement says why the edge cannot read
  the routes, and that measurement distinguishes the candidates above.
- If container group inheritance is the cause, the fix is the **narrowest** one that supplies
  the access — a group the container is given for this purpose, or the file made readable by a
  route the design already sanctions — and it is recorded as an ADR.
- `GroupAdd=keep-groups` is either justified against `[groups] add`'s stated purpose or not used.
- `t50-slice.sh` is green on `develop` with no branch applied.

## Note on the suite's own diagnostics

The failure's `curl` exit 28 names a timeout and nothing else. An agent reading only that cannot
tell a permission failure from an edge that never started. Whatever the cause turns out to be,
the suite should say which of its own assertions the edge failed, so the next reader is not
guessing from an exit code. That is the same class of defect as ticket 262's silent `set -e`
death: a harness reporting a fact without reporting the thing behind it.