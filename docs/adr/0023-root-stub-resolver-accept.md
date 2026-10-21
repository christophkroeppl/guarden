# Root and the stub resolver: root gets an accept, and the denial was breaking the box

Ticket 303 asked one question the spec had not answered: **does root get a
stub-resolver accept?** Every render emits uid-matched `127.0.0.53:53` accepts for the
registry's service uids, above the global loopback DROP. Root was not among them, so
root's own name resolution on the host path died at the deny. ADR-0016 — the decision
that rendered those accepts in the first place — deferred this by name: *"if a verb
running as `root` ever needs the stub on the host's loopback, it needs an accept naming
that uid and that is a separate decision rather than something this rule quietly
does."* This is that separate decision.

**The answer: root does get one.** The two owner-matched accepts are rendered for uid 0
beside the service set, and the denial they replace was breaking the host's own tooling
in a way that was silent where it cost the most.

Amends spec §7.6.

## Status

accepted (2026-10-21) — implemented in `82b7f7c` on `fix/t303-root-resolver`. The test
is `tests/t303-root-resolver.sh` (`07acace`).

**This decision was reached twice, and the first answer was wrong.** An earlier draft of
this ADR concluded the opposite — that root should be refused — and the reasoning it
offered included a claim that the measurements contradict. The reversal is recorded
below rather than edited out, because the wrong claim is the interesting one and a
future reader who has the same intuition deserves to find out why it does not hold.

## What was measured

Every number below is from a real cut (a throwaway LXD VM from the golden), read from
the kernel's own counters and the tools' own exit codes.

| | before the firewall converges | after the deny is in force | with a uid-0 resolver accept |
|---|---|---|---|
| root `getent hosts github.com` | exit 0 | **exit 2** | exit 0 |
| root's datagram to `127.0.0.53:53` | — | **deny counter 0→8** | deny counter 0→0 |
| root `curl https://github.com` | exit 0 | **exit 6** | — |
| root `apt-get update` | exit 0 | **"Temporary failure resolving archive.ubuntu.com"** — and exit 0 | exit 0 |
| service uid `getent hosts github.com` | — | exit 0, deny counter unmoved | — |

**The host's resolver configuration, read off the machine:** `/etc/resolv.conf` is
systemd-resolved's own stub file and names `nameserver 127.0.0.53`.

**And the last row is the control:** the service uid's lookup is unaffected throughout,
so the difference is root's and not the box's.

## The claim the first draft got wrong, and the measurement that corrected it

The first draft argued that root's needs were met because *"every name-resolving path
guarden runs is either outbound or runs as the service user"*, and that *"root's
outbound resolution is untouched by the deny"*.

**Both sentences are false, and the second is false in a way that decides the ticket.**

The **outbound packet** is untouched — the deny is on `127.0.0.0/8` and an outbound
packet to the internet never has a loopback destination. But the **name lookup that
precedes the outbound packet** is a loopback packet: `/etc/resolv.conf` names
`127.0.0.53`, so every lookup on a systemd-resolved host goes to the stub, and the
stub is inside the deny's range. **The resolver is not an optional convenience on the
outbound path; it is on the path, and the deny is on it.**

So `soil packages`' `apt-get update` and `soil install`'s pinned-artefact fetch are
**not** unaffected. They resolve the archive host and the release host through the
stub, as root. On a converged host that resolution fails:

```
W: Failed to fetch http://archive.ubuntu.com/ubuntu/dists/resolute-backports/InRelease  Temporary failure resolving 'archive.ubuntu.com'
```

**And `apt-get update` still exits 0.** That is the worst shape a failure can have: a
host whose package index silently stopped refreshing reads as a host with an
unreachable mirror, and the operator's next move is the wrong one. A rule whose
failure mode is a wrong answer is worse than one whose failure mode is an error.

## The decision

**Root receives the two owner-matched `127.0.0.53:53` accepts, beside the service set
and not as a member of it.**

## Why, weighed rather than gestured at

**The argument for a refusal** — the one the first draft made, and it is not a weak
one:

- *The accept is a hole in the loopback deny for the most privileged uid on the box.*
  The service accepts exist because each service uid is a *specific workload* with a
  known, narrow DNS need. Root is not narrow: it is every process on the host that
  happens to be root, including anything that could be *driven* to run as root.
- *An accept for uid 0 is a general exemption for the whole uid class, from a rule
  whose purpose is to deny.* The deny is `daddr 127.0.0.0/8 jump DROP;` with **no
  owner match**, and that is precisely what makes it a default deny (spec §7.6: *"A
  default deny that enumerates who it applies to is not a default deny"*).

**The argument for the accept**, and the one the measurements support:

- **Root already holds a broader exemption on the same chain.** The operator's shell
  reaches every publication — `mod owner uid-owner 0 daddr 127.0.0.1 proto tcp jump
  ACCEPT;` (commit `231dd42`: *"a health check, a smoke test and a diagnostic all run
  as root, and the loopback deny stopped them before they reached the service"*). **So
  uid 0 is not outside the loopback deny; it is inside it with a named exception.** The
  question is therefore not *"may root use the loopback"* — it may, and it is granted
  that — but *"may root ask the stub a question"*. The marginal fact of the resolver
  accept is **one address, one port, one added protocol**, for a uid that already holds
  every TCP port on `127.0.0.1`.
- **The asymmetry that looked decisive does not settle it.** The first draft said a root
  process can read `/etc/hosts`, bind a socket and read any file, so the accept adds
  almost nothing. **That is true of the accept's CAPABILITY and it says nothing about
  the accept's NEED.** Root's ordinary tools do not fall back to `/etc/hosts`:
  `apt-get`, `git`, `curl` and `ssh` as root all resolve through the stub, and the
  measurement above is what they do when the stub is refused. The asymmetry establishes
  that the accept is *not a security widening* — which is the strongest argument for it
  — and it does not establish that root does not *need* it. **Root does need it, and
  the file's own measurement says so.**
- **The refusal is invisible where it costs the most.** Measured above: `apt-get
  update` exits 0 while every mirror fails to resolve. A posture whose failure mode is
  a silently stale package index is not a posture a host should be left in.

**Weighing them.** The security argument is about *capability*, and the capability
argument is answered: root already holds every TCP port on `127.0.0.1` through the same
chain, so the resolver accept is not a class-wide exemption from a rule root is
already inside of — it is one address and one port on a uid that holds a broader
exemption. The need argument is about *breakage*, and the breakage is measured, silent,
and reaches the box's own package index. **A rule that breaks the host's own tooling
invisibly is the worse of the two.**

**And the direction of travel is consistent.** ADR-0016 (2026-10-05) deferred root's
case by name. Two days later the tree added a uid-0 accept for the publications — the
*adjacent* case, decided in root's favour. ADR-0016's own words: *"if a verb running as
`root` ever needs the stub on the host's loopback, it needs an accept naming that uid."*
**It needs it. The measurements say it needs it.**

## What the accept costs, stated rather than discovered

- **Root holds one more exception to the loopback deny, for one address and one port.**
  `127.0.0.53` port 53, `udp` and `tcp`, and nothing else on that address and nothing
  else on that port. The deny is unchanged, still names no uid, and is still the last
  rule of the chain.
- **It is drawn from the host's own knowledge, not from configuration.** There is no
  key that adds one, no key that removes one, and no address an operator may
  substitute — exactly as ADR-0016's table said the resolver's accept must be.
- **It is not a new grant surface.** No manifest, no `overrides.toml`, no module and no
  poke can widen it.

## What it is NOT

- **It is not a change to the deny.** Still `daddr 127.0.0.0/8 jump DROP;`, still no
  owner match, still the last rule.
- **It is not a change to the service set.** Every service uid's accepts are unchanged,
  and the reply accepts — which carry no owner match at all — are unchanged.
- **It is not a change to root's publication access.** The uid-0 accept for the
  publications is unchanged; this adds a destination and does not touch one.
- **It is not a `[loopback] allow` table.** Nothing is configurable about it. ADR-0016's
  distinction still holds: this is a rendered rule somebody would have to *write a
  patch to add*, not a key an admin fills in.
- **It is not a claim that root's resolution was never broken.** It was, and the
  measurement above is what it looked like.

## The test that pins it

`tests/t303-root-resolver.sh`, and it is a test about the DECISION rather than about a
rule's text:

1. **The rendered set carries root's two accepts**, and the service set is **unchanged**
   — the service uid's accepts are asserted present and counted at exactly two, so a
   render that answered this decision by widening the *service* set rather than by
   adding root is ruled out.
2. **The enforced chain carries them too**, read out of one snapshot of the live
   ruleset, in the kernel's own spelling.
3. **The deny's own packet counter does NOT move** across a root datagram to
   `127.0.0.53:53`. **This is what tells the two answers apart**: under the other answer
   the counter moves, and the file fails. The service uid's half of the same
   measurement is asserted too, so the file cannot be satisfied by a deny that refuses
   everything.

**The RED/GREEN cycle is recorded in the commits.** `07acace` is the new test with the
renderer reverted, and it fails with *"does not name mod owner uid-owner 0 daddr
127.0.0.53 proto udp dport 53 jump ACCEPT;"*; `82b7f7c` is the fix, and the same suite
then passes with the counter unmoved.

## What did not happen

**No change to the deny, the publications, the service accepts, the reply accepts, the
granted rules, or the firewall's one-writer-per-file split.** `src/guarden/rules.py`
gained a constant and one set union; `src/guarden/weedr.py` is untouched.

**No second resolver, no new key, no `[loopback] allow` table, no `ufw`.**
