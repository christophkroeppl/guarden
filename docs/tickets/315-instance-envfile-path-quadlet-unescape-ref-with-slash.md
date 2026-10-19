# 315 — an instance ref containing `/` names an env-file quadlet unescapes into a file that does not exist

Blockers: none. Found 2026-10-19 measured in a VM during the 295 fix
(instance-start-path report: "quadlet unescapes the instance env-file path so a ref
containing / names a file that does not exist").

## What happens
Instance units carry an EnvFile= (or similar path) containing the escaped ref; quadlet
unescapes the path, and a ref like `feature/x` produces a path pointing at a directory
that is not a file → the unit fails to load at podman start. Refs with slashes are a
documented instance shape (start <name>/<ref> is the verb surface), so the file name
and the ref shape disagree.

## What to build
Encode the ref into the file name quadlet reads without an unescape collision
(escaping rule or flat name derived from the escaped form), red-first: an instance
with a slash ref starts (unit loads, no "no such file" from podman). Check every
place the file is written and the unit reads it — both sides of the disagreement.
