# 303 — spec 7.6 question: root's loopback DNS queries are denied by the uid-matched accepts

Blockers: none. Found 2026-10-19 via ticket 263's measurement (root getent rc=2, deny
counter moved; on both the cut and guarden-deploy), and cross-referenced by 296.

## What happens
Every render emits uid-matched `127.0.0.53:53` accepts for registry uids, above the
global loopback DROP. Root is not among them: root-side resolution on the host path
dies at the deny. 263's report called this "spec 7.6's accept set as written" and
kicked the question to a decision. Meanwhile root does resolve names during installs
and image work — so either the denial is intended (root must not use the service-facing
path) or the accept set is incomplete.

## What to build
A decision: spec amendment or an ADR stating whether root gets a stub-resolver accept
(owner-matched uid 0, like the service set) — with the security reasoning either way,
and a test pinning whatever the answer is (firewall render asserts the accept exists
or asserts its deliberate absence). Related: 296 (template-service accepts).
