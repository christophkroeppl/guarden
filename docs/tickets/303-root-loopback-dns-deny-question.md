# 303 — spec 7.6 question: root's loopback DNS queries are denied by the uid-matched accepts

Blockers: none. Found 2026-10-19 via ticket 263's measurement (root getent rc=2, deny
counter moved; on both the cut and guarden-deploy), and cross-referenced by 296.

**DECIDED 2026-10-21. The answer is that root DOES get a stub-resolver accept**, and the
denial it replaces was breaking the host's own tooling. The reasoning is in
`docs/adr/0023-root-stub-resolver-accept.md`; the spec amendment is §7.6; the test is
`tests/t303-root-resolver.sh`.

## What happens

Every render emits uid-matched `127.0.0.53:53` accepts for registry uids, above the
global loopback DROP. Root was not among them: root-side resolution on the host path
died at the deny. 263's report called this "spec 7.6's accept set as written" and
kicked the question to a decision.

## What to build

A decision: spec amendment or an ADR stating whether root gets a stub-resolver accept
(owner-matched uid 0, like the service set) — with the security reasoning either way,
and a test pinning whatever the answer is (firewall render asserts the accept exists
or asserts its deliberate absence). Related: 296 (template-service accepts).

## What was delivered

- **`docs/adr/0023-root-stub-resolver-accept.md`** — the decision and the reasoning.
  Root gets the accept. The measurement that decided it is in the ADR: on a converged
  host root's `getent hosts <name>` exited 2, `curl <url>` exited 6, and
  `apt-get update` reported "Temporary failure resolving archive.ubuntu.com" **while
  still exiting 0** — a host whose package index silently stopped refreshing reads as a
  host with an unreachable mirror.
- **`docs/spec.md` §7.6** — amended. The section chosen is the one that states the
  resolver's uid set ("The uid set is the service uids and no other"), because that
  sentence is exactly what the decision changes.
- **`src/guarden/rules.py`** — `resolver_lines` now renders root's two accepts beside
  the service set's. The uid list the function takes is still the registry's service
  uids; root is added from the host's own knowledge, because root is not a workload and
  the registry is a record of the workloads.
- **`tests/t303-root-resolver.sh`** — the test, which pins the DECISION rather than a
  rule's text: root's two accepts are in the rendered file and in the enforced chain;
  the service set is unchanged (the service uid's accepts are asserted present and
  counted at exactly two); and the deny's own packet counter does NOT move across a
  root datagram to the resolver, while it also does not move for the service uid's.

## The decision was reached twice, and the first answer was wrong

An earlier draft concluded the opposite — root refused — on the reasoning that "every
name-resolving path guarden runs is either outbound or runs as the service user" and
"root's outbound resolution is untouched by the deny". **Both sentences are false.** The
outbound *packet* is untouched; the name *lookup* that precedes it is not, because
`/etc/resolv.conf` names `127.0.0.53` and the deny is on `127.0.0.0/8`. The adversarial
review caught it and the measurement on a real cut confirmed it; the reversal and the
wrong claim are recorded in the ADR rather than edited out.

## Not changed, deliberately

- `src/guarden/weedr.py` — untouched. The renderer needed no change: the accept set is
  built in `rules.resolver_lines`, and the uid list the mutator passes is still the
  registry's service uids.
- The deny, the publications, the service accepts, the reply accepts, the granted rules
  and the firewall's one-writer-per-file split — all unchanged.
- `AGENTS.md` — it carries the canonical statement of the resolver rule and would want
  the same "root is in that set" clause. The file is protected against edits from a
  worker and is not in this ticket's ownership list, so the clause is left to the
  parent.
