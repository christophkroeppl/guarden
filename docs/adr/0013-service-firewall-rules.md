# ferm is the firewall, and a service may ask for a rule but never install one

guarden's host firewall is `ferm`, in whole. There is no second firewall manager on the box: no
`ufw` rule, no firewalld zone, no hand-written nftables table kept in step. **`ufw` is uninstalled
by installation and is not in any package list, on any family, for any reason.** The dead-man failsafe
does not re-enable `ufw`; it opens the firewall directly by stopping `guarden-firewall.service` and
clearing guarden's own chains. The failsafe is strictly weaker: it can open the firewall but cannot
restore the previous ruleset, because there is no previous ruleset. Nothing in guarden ever writes, reads
or reconciles a `ufw` rule, and there is no path by which a service, a module or a poke gets one.

> **Revised 2026-10-08:** `ufw` is uninstalled rather than disabled; the dead-man failsafe no longer names it and cannot restore a previous ruleset (there is none). The original text stated `soil packages` installs both and `soil firewall --apply` turns `ufw` off — that was reversed by the decision in commit 07f76db.

Everything else about that firewall was already decided in ADR-0006, and none of this changes
it: a rule set is rendered whole from a union of grants, deduplicated by construction, printed
as a diff, and installed under one lock. What this document adds is that **the union has one
more member**, and that a member of it can come from a repository.

## The problem

Most traffic goes through the edge. A service that publishes HTTP declares a route and never
thinks about the firewall again, and the design's preference is visible everywhere: one edge, no
second ingress path, no service binding a non-loopback address. But "almost all" is not "all",
and the exceptions are real services with real needs — a WireGuard endpoint, a full node's peer
port, a source range the operator wants to name rather than imply. Two honest answers were
available and both were worse than asking:

- **Teach every protocol to the edge.** Then the edge is the only place a new protocol has to be
  understood, and a repository that wants it waits on guarden rather than on itself.
- **Let a service write its own rules.** Then the host's ruleset has an unprivileged writer on
  a file the security model depends on being derived, and there is no diff to print because
  there is no render.

## The decision

A manifest may **ask** for firewall rules and only an admin may **install** them, and the shape
of that is exactly the shape of a port grant, because it is the same problem: repository input
naming something the host owns.

- A `firewall:` entry in the manifest is a **request**: a stable name, a chain guarden renders,
  and one iptables-shaped rule line. It installs nothing. Creation records it in the registry
  and it stays pending, which is what a requested port does.
- The grant is `weedr firewall open <service> <rule-name>`, writing that **name** into a
  root-owned `overrides.toml`, re-rendering the whole service half, printing the diff and
  installing under the `firewall` lock. `weedr firewall close` withdraws it. Neither verb is on
  any sudoers rule, so a poke cannot reach either, and a module's service requests its rules the
  same way any other service's does.
- A request is **purely additive**. It may add a rule to a chain guarden owns; it may not open,
  close, flush, rename or set a policy on a chain or a table, and it may not jump to a chain
  guarden does not render. That is enforced by a closed shape rather than by a list of
  prohibitions, for the reason `host:` is closed.
- **Position is guarden's.** A granted rule renders above the default deny, so a grant is always
  reachable and the invariant that every accept precedes the single deny survives one. There is
  no position field in the manifest, because a field that could put a rule after the deny is a
  field that makes the deny advisory.
- **Deduplication is by content and the count is by name.** Two services asking for the same
  rule line produce one rule carrying both names, and closing one leaves it while the other
  still asks. The same reference-count-by-name, deduplicate-by-content shape as `[[switches]]`
  (ADR-0008).
- `weedr firewall list` reports the deduplicated set with the services behind each rule, so
  "which service put this here" is a command rather than an archaeology exercise through
  `overrides.toml` files.

## What it costs, stated here rather than discovered

**A granted rule is root firewall authority, and the grant is the whole of the review.** An
admin agrees to one rule line, not to a service's intentions: a rule whose match is broader than
its author expected reaches everything the match covers. That is why the grant is a verb, why it
is root, and why nothing that answers a push can invoke it.

**This is the fifth table in `overrides.toml`, and the old "no fifth grant table" line was
about something narrower.** The refusal was to a `[loopback] allow` table — a table whose entire
content is a destination, which would have been a second way to grant one beside the
publication set. `[firewall] allow` is not that: it holds names, not destinations, and the rule
behind a name lives in the manifest that asked for it. But the honest consequence is stated
plainly, because it used to be phrased as an impossibility: **a granted rule that matches `-o lo`
and accepts does reopen loopback for exactly the match it names.** The default deny is still the
last line of the chain and everything else about the loopback posture is unchanged; the position
of a grant is above that deny by design, because a grant that could never be reached would be
worse than useless. Making that daemon a service remains the right answer; this is the door for
the cases where it is not possible.

**Nothing else widens.** The renderer still owns every rule guarden derives from the
registries, still refuses the same things, and still cannot emit a firewall rule at all — a
renderer that wrote one would be a second writer on `30-services.conf` with no `firewall` lock.

## What did not happen

No second firewall engine, and no per-service one. A service may not run its own firewall
manager, install its own rules into the host's tableset, or be given a capability or a raw table
handle; `30-services.conf` is the only file the mutator writes and its union now has one more
kind of member. A service that needs a *destination* rather than a *rule* still needs that
destination to be a publication, because that is not what this grants.