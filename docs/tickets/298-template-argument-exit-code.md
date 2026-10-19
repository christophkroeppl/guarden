# 298 — a malformed --template argument answers exit 1 where spec 1.2 requires exit 2

Blockers: none. Found 2026-10-19 by an adversarial review of develop 10f7457
(verified: service.py:363 HOST_NOT_AS_ASSUMED).

## What happens
`require_template` raises HOST_NOT_AS_ASSUMED (exit 1) for `--template ../x` /
`--template BAD`, although spec 1.2 defines exit 2 as "the input was rejected", while
the same-shaped `add --from /tmp` correctly yields 2 (service.py:139-146, pinned by
t250-verb-split.sh:43). docs/sysadmin.md:267 ("what is missing is on the host and not
in the argument") is untrue for that branch — a template NAME is argument, not host.

## What to build
Move the malformed-name rejection to exit 2 (keep the genuinely-missing-installed-set
case at 1 if the spec's host/input split demands it — read spec 1.2 and state the
split), red-first, update the sysadmin sentence.
