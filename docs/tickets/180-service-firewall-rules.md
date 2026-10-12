# 180: service-requested firewall rules

**What to build:** A manifest may ask for a firewall rule and only an admin may install one.
Most traffic goes through the edge, so most services never need this; the ones that cannot be
reached through it — a WireGuard endpoint, a full node's peer port — put the rules they want in
a `firewall:` block and an admin runs `weedr firewall open` on the ones they agree to. Nothing
is installed until they do, a poke can never install anything, and `weedr firewall list` reports
every rule on the host deduplicated with the services behind each one.

The rule is the same shape as a port grant and for the same reason: repository input naming
something the host owns (ADR-0013, spec §7.7).

**Blocked by:** 160 (public grants), and 40 (the manifest validator)

**Status:** ready-for-agent

- [ ] A `firewall:` block in the manifest is a **request** and installs nothing. Each entry takes
      `name`, `chain` and `rule` and nothing else, `name` matches `^[a-z0-9][a-z0-9._-]*$` and is
      unique within the manifest, and there is no position, priority or comment field
- [ ] `rule` is one iptables-shaped line matching `^-` followed by option tokens and exactly one
      `-j` or `-g` target. The pattern is **closed**, for the same reason `host:` is
- [ ] **A request is additive only.** A rule that opens, closes, renames, flushes or sets a
      policy on a chain or a table, or jumps to a chain guarden does not render, is exit `2`
      naming the rule and the key. A repository cannot remove a rule guarden rendered, reorder
      one, or take a chain policy away
- [ ] `chain` may be omitted and defaults to `guarden-svc`, the chain guarden owns and jumps to
      from `filter OUTPUT`. Naming a chain guarden does not render is exit `2`. Growing the set
      of grantable chains is a change to spec §7.7, not a configuration change
- [ ] The request is recorded in the registry's `[firewall] requested` at creation, exactly as
      `[ports] requested` is, and `weedr service ingest` installs none of it — the same answer a
      requested port gets
- [ ] `loom` validates the entry's shape and **writes no firewall rule at all**. A renderer that
      emitted one would be a second writer on `50-services.conf` holding no `firewall` lock
- [ ] `weedr firewall open <name> <rule-name>` adds that **name** to the service's
      `[firewall] allow` in `overrides.toml`, renders `50-services.conf` whole, prints the diff
      and installs, all under the `firewall` lock. `weedr firewall close` removes it and renders
      the same way
- [ ] **A rule no manifest requested may not be granted at all**, exit `2` naming the `firewall:`
      entry it would have to be. The manifest asks, the admin decides, and neither does the
      other's job
- [ ] **The grant is a root verb on no sudoers rule.** `weedr service ingest` cannot reach it, so
      a poke leaves the request pending and `furrow`'s deploy reports it in the push's log the way
      it reports a pending port. `weedr firewall open` and `close` are never on the `guarden`
      rule and never will be
- [ ] **A granted rule renders above the default deny and the deny is still the last line of the
      chain.** Position is guarden's and the request carries no position field, so a grant can
      never land where the deny has already matched
- [ ] **Deduplication is by content and the count is by name.** Two services asking for the same
      rule line produce one rule carrying both names; `weedr firewall close` on one leaves it in
      force while the other still asks, and the rule leaves when the last one closes
- [ ] `weedr firewall list [--json]` reports `rules` — one object per rule text after
      deduplication, each with `rule`, `chain`, `file`, `granted` and `requested_by` (a list of
      `{ service, name }`). It is a read of the registries and the overrides, both `root:guarden`,
      so it needs no privilege a `guarden` program lacks and it **is** on the `guarden` sudoers
      rule beside `weedr port list`. It is not on `hose`'s rule, so a poke learns which projects
      exist and nothing about the host's rule set
- [ ] `weedr service remove <name>` drops that service's grants with its `overrides.toml` and
      re-renders, so a rule it alone was holding leaves the ruleset rather than being orphaned
- [ ] **A module grants no rule.** `module.toml` has no rule key, and `weedr module add` installs
      a module's services with their requests pending exactly as a poke's services are. Removing
      the module leaves nothing granted to remove
- [ ] The honest limit is written down where an operator will meet it: a granted rule is root
      firewall authority, the admin agrees to one line rather than to a service's intentions, and
      a rule matching `-o lo` and accepting reopens loopback for exactly that match. README,
      `SECURITY.md` §2.5, `docs/sysadmin.md` and ADR-0013 all say it; none of them may drift from
      the others
- [ ] Verified at the CLI seam, in the VM: an ungranted request renders nothing, a
      grant renders one rule above the deny, two services asking for one line render one rule,
      and closing one of them keeps it

## What this ticket does not do

- It does not add a second firewall engine. `ferm` is the host firewall; `ufw` is not
  installed. Nothing here writes, reads or reconciles a `ufw` rule
- It does not let a service bind, forward or publish anything. A grant is a rule, and a rule is
  not a destination: a service needing a host loopback port that is not a publication still
  needs that daemon to be a service wherever that is possible
- It does not let the manifest set a chain policy or a table policy, and it does not grow the set
  of grantable chains