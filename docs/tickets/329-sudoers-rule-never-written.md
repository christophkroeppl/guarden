# 329 — the `guarden` sudoers rule the spec writes out is never written: the model is documented, not implemented

Blockers: none. Found 2026-10-19 by the must-fail security suites (ticket 328's
sibling work, `tests/t502-service-user-root.sh`), which had to state what the
security model does NOT guarantee.

## What was measured

**Nothing in this repository writes a sudoers file.** The whole tree was
searched — `src/`, `tools/`, the templates, the package manifest:

    grep -rn 'sudoers.d\|/etc/sudoers' --include='*.py' --include='*.sh' \
      --include='*.j2' --include='*.toml' .

    → no writer, anywhere.

`src/guarden/hostprep.py` — the program that owns every other part of the
host's layout — writes `/etc/guarden`, the programs, the templates, the
package list and the modules, and writes no sudoers rule.

## What the spec and the code say about it

The spec states the rule as a **capability table** (docs/spec.md:1166-1180):

| capability | verb | on the `guarden` sudoers rule? |
|---|---|---|
| create a service from a poke | `weedr service ingest` | **yes** |
| create a service from another service's tree | `weedr service add` | **no** |
| create a new service from a template | `weedr service create` | **no** |
| fork, with a chosen source | `weedr service fork` | **no** |
| grant a public port | `weedr port open` | **no** |
| install a requested firewall rule | `weedr firewall open` | **no** |
| destroy a service's volumes | `weedr service purge` | **no** |
| roll a service back to a snapshot | `weedr service rollback` | **no** |

and the sentence that carries the model's weight:

> Every verb that *is* granted is granted whole. A caller that can run
> `weedr service ingest` creates a service and nothing else: it cannot grant a
> port, cannot destroy data, cannot roll anything back, and cannot choose
> where a service's tree or data comes from, because none of those is a flag
> on something it can run.

Nine source files refer to "the sudoers rule" as the thing that makes these
verbs safe — `weedr.py:5` ("a sudoers rule cannot tell one argument from
another, so a flag on a granted verb would grant the capability with it"),
`lineage.py:663`, `projects.py:544`, `firewallrules.py:4`, `hose.py:5`, and
the rest. **The rule those arguments rest on does not exist on the host.**

## The part that is worse than a missing feature

`src/guarden/hose.py:302-307` tells the operator a thing that is false:

```python
    raise errors.GuardenError(
        f"{FURROW} is not installed, and a poke reaches the deploy queue only through "
        f"it; `soil install --apply` installs it and writes the sudoers rule that "
        f"names it",
```

`soil install --apply` installs `furrow` and writes **no** sudoers rule. An
operator who reads this and runs the command is told a boundary exists that
does not.

## What the security model actually rests on, today

Not on the sudoers rule. On:

- the per-service uid — a service user is its own uid and nothing else;
- the `0700` service tree (`service.py:62` `TREE_MODE = 0o700`);
- the `/etc/guarden` placement — `0751 root:guarden`, files `0640 root:guarden`,
  the credential blobs `0700 root` (`hostprep.py:86` for the soil directory,
  `0750 root:guarden`);
- the subuid band and the kernel's own `newuidmap` refusal;
- the empty capability set (`CapEff`) and `mount`'s setuid rule — the kernel's
  rules, not guarden's;
- the firewall's owner-matched accepts.

`t502-service-user-root.sh` asserts the sudoers **absence** as well, so a
future grant goes red — the suite is written to notice the change in either
direction.

## What to decide

This is a design decision, not a mechanical fix, and the ticket exists to
have it made deliberately.

**Option A — write the rule.** `soil install --apply` writes
`/etc/sudoers.d/guarden` granting the `guarden` group exactly
`furrow deploy`, `furrow preview drop`, `furrow queue list`, `furrow status`
and `weedr project list` — the list `hose.py:5` already names — and the
host's `weedr service ingest` becomes reachable by the poke. Then the spec's
table becomes true and the nine places that rest on it are resting on
something.

**Option B — delete the rule from the model.** The spec's table becomes "no
verb is granted; every mutating verb needs a real root shell", the nine
references are corrected, `hose.py:302` stops claiming the rule exists, and
the capability split is made by the *verbs themselves* — which is what the
code already does in practice (`add` and `create` are not on any rule, and
`ingest` re-execs under sudo like the rest).

**Option C — the middle.** Write the rule for the *poke* only (the one
capability that genuinely needs an unprivileged path, since a poke arrives
from outside), and leave every `weedr` mutating verb root-only. This is the
shape `hose.py:5` describes ("the guarden sudoers rule naming `furrow deploy`,
`furrow preview drop`, `furrow queue list`, `furrow status` and `weedr project
list`, run as `(guarden)`") — note that **the list it names contains no
`weedr` mutating verb at all**, which is evidence that the intended rule was
always Option C and the spec's table drifted.

## Why it is worth deciding now

- the spec's capability table is the document the whole security argument
  rests on, and it currently describes a host that does not exist;
- `hose.py:302` actively misleads the operator;
- the must-fail suites (ticket 328's work) now assert the absence, so any
  implementation of Option A or C must update them — which is the right
  moment to make the decision rather than after the fact;
- the fourth operator requirement — "get 10 security reviews on our security
  setup" — is not satisfiable while the central claim is unimplemented. A
  reviewer that finds this will say so, and it will be the first thing they
  find.

## Notes

- The `weedr.py:5` argument — "a sudoers rule cannot tell one argument from
  another, so a flag on a granted verb would grant the capability with it" —
  is a reason to grant verbs WHOLE, and it survives any of the three options.
  It is not a reason to have no rule.
- `hose.py:5`'s list is the strongest evidence for Option C and should be
  read before the decision is made.
