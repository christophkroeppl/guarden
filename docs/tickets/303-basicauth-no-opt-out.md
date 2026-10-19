Blockers: none. Carried out of ticket 292's "Known gaps" so that merging the
exposure cluster does not erase it (implemented tickets are deleted; the gap is
not). Adversarial review of this branch (review-exposure.out finding 10): all
four declared gaps lived only in tickets 292/293's prose.

## What happens

The default basic-auth gate has no opt-out. The flag is on for every service
created while the policy is in force, no repository can remove it (by design),
and no root-owned surface can either: spec 3.3 closes `overrides.toml` ("nothing
else is overridable") and spec 3.1's `guarden.toml` table set carries no
per-service defaults table. An operator who needs one service without the
middleware — a machine-to-machine endpoint, a webhook target — has no act to
perform.

## What to build

A spec decision first (a new table or a new key is a contract change, and
inventing one in code is the mistake this repository keeps refusing), then the
root-owned per-service "no auth" setting the backlog's acceptance seed asks for,
refused to every repository surface the way `exposure:` is refused.

## Status: ready-for-agent

- [ ] A spec surface for a per-service basic-auth opt-out exists and is
      root-owned; no manifest key reaches it.
- [ ] `weedr` (or `soil`) carries the act, off the guarden sudoers rule.
- [ ] A flagged service without the opt-out still renders the middleware
      byte-identically to today.
