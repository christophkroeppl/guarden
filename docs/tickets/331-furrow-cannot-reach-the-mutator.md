# 331 — the second sudoers rule: `furrow` cannot reach the mutator, so the poke path is broken on every real host

Blockers: none. Found 2026-10-19 by the adversarial review of the merged train
(`nous/longcat-2.5-preview-free`, VERDICT: REJECTED), which named it as one of
two BLOCKERs. Ticket 329 fixed the FIRST rule — the one a poke uses to reach
`furrow`. This ticket is the SECOND rule, and it is the one that makes the poke
path work end to end.

## What was measured

**The chain a poke takes is `hose` → `furrow` → `weedr`, and the last hop has
no rule.**

- `hose` (the account a poke arrives as) runs `furrow` — that is the rule
  ticket 329 wrote and measured working.
- `furrow` runs as `guarden` and calls the mutator through
  `sudo -n weedr …` whenever it is not root (`furrow.py:116-128`).
- **There is no rule granting `guarden` that.** The spec writes it out in §6.6
  (spec.md:2098-2107) — fourteen verbs, `guarden ALL=(root) NOPASSWD: …` — and
  nothing in the repository writes it. `grep -rn 'NOPASSWD' src/ tools/`
  matches only the hose rule from ticket 329.

**Measured on a live host, with the spec's rule written by hand:**

```
$ cat /etc/sudoers.d/guarden
guarden ALL=(root) NOPASSWD: /usr/lib/guarden/bin/weedr service ingest

$ sudo -n -u guarden sudo -n -l /usr/lib/guarden/bin/weedr service ingest
/usr/lib/guarden/bin/weedr service ingest          ← the rule matches the bare command

$ sudo -n -u guarden sudo -n /usr/lib/guarden/bin/weedr service ingest someapp --from poke someapp@9f2c1ab
sudo: I'm sorry guarden. I'm afraid I can't do that   ← THE REAL CALL IS REFUSED
```

**So the rule as the spec writes it does not work even when it is written.**
sudoers matches the command *and its arguments* as written, and the real
invocation carries `<name> --from poke <project>@<sha>` — arguments the rule
does not name. A rule that named the arguments would have to name every
argument, and the arguments carry a service name and a sha, which is exactly
what the "a rule cannot tell one argument from another" rule (spec 5.1) says
a sudoers rule must not be asked to do.

**The VM suites do not see this**, because the harness runs everything as root
and `furrow.py:123-127` calls `weedr` directly when `euid == 0`. So the
gitops path is green in every suite and broken on every real host — the
failure mode is invisible to the test harness by construction.

## Why the chain cannot simply be given a rule

The two rules grant different things to different identities, and the
difference is the point:

| rule | grantee | runs as | verbs |
|---|---|---|---|
| the hose rule (329) | `hose` | `guarden` | `furrow deploy`, `furrow preview drop`, `furrow queue list`, `furrow status`, `weedr project list` |
| the furrow rule (this ticket) | `guarden` | `root` | the mutator's verbs |

The second is a much bigger grant: `guarden` reaching the mutator as root is
the capability that creates services, starts them and (if `purge` were in the
list) destroys data. **The spec's list has `service ingest`, `service remove`,
`service gate`, `service start`, `service stop`, `service restart`,
`service snapshot`, `service build` — and the read verbs — but NOT `purge`,
NOT `rollback`, NOT `port open`, NOT `firewall open`.** So the spec's own
list keeps the destructive and the granting verbs out, and the list is right;
what is missing is a way to express it that sudoers can honour.

## What to decide

**The shape of the fix is a design decision, and the ticket exists to have it
made deliberately.** Three ways, in increasing order of privilege:

**A — the mutator splits.** The verbs `furrow` actually needs as root
(`service ingest`, `service remove`, `service start`, `service stop`,
`snapshot`, `build`) move into a SECOND PROGRAM — a mutator whose verbs are
exactly the ones a poke may drive — and the sudoers rule names THAT program
with no arguments. The argument problem disappears because the program takes
its arguments from the invocation and the rule names only the program path…
except that a bare program path matches any arguments, which is the other
half of the same trap. So the split only works if the new program takes its
inputs from something other than argv: a file the rule names, or stdin.

**B — the rule names the program and the mutator refuses the rest.** The rule
grants `guarden` the mutator as root, and the MUTATOR decides what a call
from `guarden` may do. That is a policy in the program rather than in the
file, which is the opposite of the platform's stated model ("a rule that
named a command without an argument specification matches *any* arguments,
and sudoers has no negation, so a rule granting …" — spec 5.1) — but it is
the only place the argument problem can honestly be solved, because only the
program knows what a call means.

**C — the poke path stops needing root.** `furrow` runs the mutator's work
itself, as `guarden`, and the mutator's root-only steps are the ones that
genuinely need root. The poke can then create and start a service without any
rule at all. The cost: the mutator's design has root in it, and this is the
biggest change of the three.

**My recommendation is B**, for a reason that is not about elegance: the
platform already has a program that decides what a call may do — the
mutator — and the rule's job is only to let the CALLER'S IDENTITY reach it.
The rule that is missing is the one that says "the `guarden` account may run
the mutator", and the *verbs* are the mutator's business, because only it
knows that `purge` destroys data and `port open` publishes a port. **The
list of verbs in the spec's §6.6 is a policy written in the wrong language**:
sudoers cannot express "these verbs, with any arguments", and the mutator
can.

**What B looks like, concretely.** The rule becomes one line:

    guarden ALL=(root) NOPASSWD: /usr/lib/guarden/bin/weedr

— a bare program, which matches ANY arguments, and therefore grants the
`guarden` account the whole mutator. That is a much bigger grant than the
spec's list, and it is the mutator that narrows it: the mutator reads
`SUDO_USER` (which sudo sets to the account the rule ran as) and refuses any
verb that is not on the list when the caller is `guarden`. The list is
therefore enforced in the place that can enforce it, and the rule's own
granularity is the only thing sudoers can offer.

**The shape of the refusal matters**: the mutator's refusal must be the same
one-line refusal every other refusal is, and it must name the verb and the
caller, so an operator who reaches the mutator the wrong way learns why. The
existing `errors.GardenError` with `REJECTED_INPUT` is that shape.

**The rule that B does NOT need:** the `hose` rule from ticket 329 stays as
it is, because it grants a *different* identity (`hose`) a *different* target
(`furrow`, running as `guarden`) and its verbs are whole — `furrow deploy` is
a program and a verb, and the rule names both. It is the `furrow` → `weedr`
hop that needs the argument-less form, and the reason is that the arguments
there are data (a service name, a sha) rather than a verb.

**Whatever is chosen, the suite that proves it must run the chain as the
unprivileged user.** Every VM suite runs as root, which is why this class of
defect is invisible to the harness. A suite that runs `hose` → `furrow` →
`weedr` as `hose` would have caught it, and the harness has no way to do
that today. **That is a second, separate gap** — the harness cannot exercise
the unprivileged path at all — and it is worth closing whatever is decided
here, because until it is closed, every claim about the poke path is a claim
about a root-only path that happens to resemble it.

## Notes

- Ticket 329's rule and this one belong in ONE file — the same
  `/etc/sudoers.d/guarden` — and they grant to two different identities, so
  the file's shape changes from "one rule" to "two rules, two identities".
- The spec's §6.6 list is the best statement of the intended policy that
  exists, and it should be kept — as the list the MUTATOR enforces, if B is
  chosen, and as the list the spec's table names.
- The same argument ("sudoers cannot tell one argument from another") is what
  makes the *first* rule name whole verbs; this ticket is the other half of
  that same fact, and the two halves together are the platform's privilege
  model.
