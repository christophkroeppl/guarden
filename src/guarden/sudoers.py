"""The `guarden` sudoers rule — the one the spec writes out and nothing writes.

**The rule is for the POKE, and only for the poke.** A poke arrives as the
`hose` user over ssh, with a forced command, and it needs exactly one
capability: to reach the mutator's deploy verbs. Every other mutating verb
stays root-only, so the request/grant split (a service ASKS for a port or a
firewall rule; an operator GRANTS it in a separate act) survives — nothing
that answers a push can reach `weedr port open` or `weedr firewall open`.

**A sudoers rule cannot tell one argument from another**, so a rule naming a
command without an argument specification matches ANY arguments (spec §5.1).
The verbs are therefore named WHOLE, and the rule grants the `hose` user the
ability to run them AS the mutator's own identity (`guarden`) and nothing
else:

    hose ALL=(guarden) NOPASSWD: /usr/lib/guarden/bin/furrow deploy
    hose ALL=(guarden) NOPASSWD: /usr/lib/guarden/bin/furrow preview drop
    hose ALL=(guarden) NOPASSWD: /usr/lib/guarden/bin/furrow queue list
    hose ALL=(guarden) NOPASSWD: /usr/lib/guarden/bin/furrow status
    hose ALL=(guarden) NOPASSWD: /usr/lib/guarden/bin/weedr project list

**No `weedr` mutating verb is in the list** — `add`, `create`, `ingest`,
`fork`, `purge`, `rollback`, `port open` and `firewall open` are all absent,
and that absence is the model: a caller that can reach the deploy verbs can
create a service and nothing else.

**The project binding is not in the rule, and it does not need to be.** The
rule grants the deploy VERB; the deploy's project comes from the forced
command `weedr project grant` writes (`command="…/hose --project <name>"`),
and `hose` is the only program that reads it — it is the single argument a
poke can influence, and `hose` resolves it before it reaches `furrow`
(hose.py: "There is no `<project>` argument in any verb, and its absence is
the whole of the per-project binding"). A rule that named the project would
have to be rewritten whenever a project is added or removed; a rule that
names the verb is stable, and the binding it relies on is enforced one layer
up, in the program that owns it.

**The file is `0440 root:root`**, so a service user cannot edit the grant it
runs under, and it is written by the install phase like every other part of
the host's layout.
"""

from __future__ import annotations

from guarden import paths

# The rule's own home. Root-owned and read-only to everyone else: a grant that
# the grantees can edit is not a grant. It comes from `paths` so a prefixed
# install (the harness) writes it where its own sudo would read it.
SUDOERS_FILE = paths.ETC / "sudoers.d" / "guarden"

# The user the rule is FOR: the poke's own account.
GRANTEE = "hose"

# The identity the verbs RUN AS: the mutator's own user, which owns the
# registry and the render tree.
RUN_AS = "guarden"

# The verbs a poke may reach, each named WHOLE.
#
# **The argument is not in the list because the verb's own argument is not the
# grant.** The project a deploy acts on is bound by the forced command, in
# `hose`, and the rule grants the VERB. A rule naming `furrow deploy` with an
# argument would have to be rewritten per project; a rule naming the verb is
# stable, and what it can reach is unchanged.
# The verbs the poke reaches, and the ARGUMENTS each one may be given.
#
# **The arguments are `*`, and the reason is measured, not chosen.**
#
# A sudoers command with associated arguments must match the caller's
# arguments EXACTLY (`man sudoers`: "the arguments in the Cmnd must match
# exactly those given by the user on the command line"). So a rule naming
#
#     …/bin/furrow deploy
#
# admits `furrow deploy` and REFUSES `furrow deploy <service> --from poke
# <project>@<sha>` — which is the invocation a poke actually makes. MEASURED
# on a live host:
#
#     $ sudo -n -u hose sudo -n -u guarden …/bin/furrow deploy svc --from poke p@s
#     sudo: I'm sorry hose. I'm afraid I can't do that
#
# So the rule as written was INERT: it failed closed, which is safe, and it
# also meant **no poke could deploy anything at all** — the whole gitops path
# was dead on every real host.
#
# **The `*` is safe because the per-project binding is not in the rule.** The
# rule grants the VERB to the `hose` account, and `hose` is the only account
# that can reach it — and `hose` derives the project from the SSH forced
# command that `weedr project grant` wrote (`command="…/hose --project
# <name>"`), never from the caller's arguments. A `*` on the rule therefore
# grants the same set of verbs to the same account as before; what it does NOT
# grant is anything new, because the rule never carried the binding.
#
# **`furrow` re-derives the project and does not take it on faith.** The
# `--from poke <project>@<sha>` pair names the project, and `furrow` checks
# that project against the key file's own binding — the project the CALLER's
# key is granted, read from the key file the operator wrote. So a `*` on the
# rule and a project named in an argument cannot disagree: the argument names
# a project, and the key file says which project the caller may name.
VERBS = (
    ("furrow", "deploy"),
    ("furrow", "preview drop"),
    ("furrow", "queue list"),
    ("furrow", "status"),
    ("weedr", "project list"),
)

# The account the SECOND rule grants: the mutator's own identity, which is
# what `furrow` runs as.
GUARDEN_USER = "guarden"

# The verbs the `guarden` account may run when it is the CALLER, and the
# mutator refuses every other one.
#
# **This is the spec's §6.6 list** (spec.md:2098-2110), which is the best
# statement of the intended policy that exists. It is enforced HERE rather than
# in a sudoers rule because a sudoers rule cannot name a verb together with
# "any arguments": the rule that grants the mutator whole is one line, and
# the verbs are the program's business.
#
# The verbs NOT in it are the point: `purge` destroys data, `rollback`
# replaces it, `port open` publishes a port and `firewall open` grants a rule —
# so a push may deploy and may not do any of those.
GUARDEN_MAY = frozenset(
    {
        "weedr service ingest",
        "weedr service remove",
        "weedr service gate",
        "weedr service start",
        "weedr service stop",
        "weedr service restart",
        "weedr service snapshot",
        "weedr service build",
        "weedr secret list",
        "weedr port list",
        "weedr firewall list",
        "weedr service list",
        "weedr service status",
        "weedr module list",
    }
)

# The programs' home. The rule names the ABSOLUTE path, because a rule naming
# a bare command is resolved through the caller's PATH. It comes from `paths`
# rather than being spelled here, so a prefixed install (the harness) names the
# programs where it actually put them.
BIN = paths.BIN


def rule_text() -> str:
    """The rule's text.

    Two rules, because there are two hops and the hops grant different things
    to different identities.

    **The first rule is the poke's.** It grants the `hose` account the mutator's
    deploy verbs, running as `guarden` — the deploy verbs are whole (a program
    and a verb), and the project they act on is bound by the forced command one
    layer up, in `hose`.

    **The second rule is the mutator's, reached by `furrow`.** It grants the
    `guarden` account the mutator, running as root — and it CANNOT name the
    verbs, because a sudoers rule matches a command's arguments as written and
    the real invocation carries a service name and a sha:

        $ sudo -n -u guarden sudo -n -l …/weedr service ingest
        …/weedr service ingest                              <- the rule matches
        $ sudo -n -u guarden sudo -n …/weedr service ingest someapp --from poke p@s
        sudo: I'm sorry guarden. I'm afraid I can't do that  <- THE REAL CALL

    So the rule is one line and the mutator narrows it: `weedr` reads
    `SUDO_USER` and refuses every verb outside `GUARDEN_MAY` when the caller
    is `guarden`. The verbs are named where a program can name them, because
    only the program knows that `purge` destroys data and `port open` publishes
    a port.
    """
    lines = [
        "# The guarden sudoers rules (spec 5.1, 6.6).",
        "#",
        "# Two rules, two hops, two identities.",
        "#",
        "# The first: the POKE reaches the deploy verbs, running as the mutator's",
        "# own identity. The verbs are named WHOLE — a sudoers rule cannot tell",
        "# one argument from another, so a rule naming a program with no",
        "# argument specification matches any arguments, and an argument is a",
        "# capability.",
        "#",
        "# The second: the MUTATOR is reached by `furrow`, which runs as",
        "# `guarden`. It names the program and not the verbs, because the real",
        "# invocation carries a service name and a sha and a rule cannot name",
        "# those. The verbs are enforced by the mutator itself, which reads",
        "# SUDO_USER and refuses everything outside its list.",
        "#",
        "# Generated by `soil install --apply`. Do not edit: the next install",
        "# rewrites it, and a rule the install owns is a rule the install can",
        "# correct.",
        "",
    ]
    for program, verb in VERBS:
        # **The `*` is what makes the rule match the real invocation.** A
        # sudoers command with arguments must match them EXACTLY, so a rule
        # naming the bare verb admits only the bare verb — and the poke's
        # invocation carries a service name, a `--from` and a sha. The `*` is
        # the whole of the arguments the rule permits, and the per-project
        # binding is NOT here: it is in the SSH forced command `hose` reads,
        # and `furrow` re-derives the project from the key file.
        lines.append(f"{GRANTEE} ALL=({RUN_AS}) NOPASSWD: {BIN / program} {verb} *")
    lines.append(f"{GUARDEN_USER} ALL=(root) NOPASSWD: {BIN / 'weedr'}")
    return "\n".join(lines) + "\n"
