# Ports are requested by a repository and granted by the admin

A service's manifest may list the host ports it wants opened. That list is a *request* and
has no effect on its own. The grant lives in `/etc/guarden/services/<name>/overrides.toml`,
which is root-owned, outside the service's home, and written only by the admin.

Two kinds of port cross that boundary and they are not the same thing. A **granted public port**
is a door from outside the host: someone asked for it, an administrator agreed, and it is
reachable only because the kernel translates it onto a loopback publication the service already
binds. An **allocated publication** is an internal hop from the edge to a container: no grant, no
confirmation, and a number the allocator picked out of the one shared namespace, because several
instances of one preview service each need one and none of them may have the same. They are
governed by different rules and this document does not conflate them; ADR-0004 explains why the
second kind exists at all.

`weedr port open <name> 8080/tcp` grants, `close` revokes, `list` shows every service with its
requested ports, its granted ports and what is still pending. Granting a port for the
first time creates the overrides file. A port the manifest did not request **cannot be
granted**: a grant is a translation to a publication, a publication is allocated per container,
and a request naming only a public port names no container, so the grant had no destination and
the renderer had nothing to render. `ports:` entries therefore carry `container:` and the
container's `port:`, exactly as `routes:` entries do, and an operator who wants a port open
adds the request to the repository first. There is no apply verb: every mutation renders the
whole firewall rule set, prints a diff against what is installed, and installs it. Render,
diff and install all happen while holding one lock, because two mutations that each render
will otherwise let the stale render install last and silently drop the rule the other one had
just granted.

**A grant is one rule, not two.** The `PREROUTING` `DNAT` from the public port to the service's
loopback publication, plus the `route_localnet` on the ingress interface that a `127.0.0.1`
destination requires and which is set once for the whole host rather than per grant. An earlier
revision of this document made the grant a *pair* — the `DNAT` and a `nat POSTROUTING`
masquerade — on the reasoning that a loopback source is unacceptable to an external client.
That reasoning was wrong, and it is recorded here because the wrong rule was a genuinely
plausible thing to believe: after the `DNAT` the packet's destination is a local address, so it
is delivered to `INPUT` and never reaches `POSTROUTING`, and on the way back connection
tracking unwinds the destination translation and rewrites the reply's source to the public
address the client dialled. A masquerade written as `-o <if> -d 127.0.0.1 --dport <pub> -j
MASQUERADE` matches no packet in either direction — the forwarded packet is local, and the
reply's destination is the client. The grant is a `DNAT`, `weedr port open` writes it, and it
delivers.

What is true, and is the thing an operator actually needs to know, is that the service sees
the **client's real address** as its peer rather than `127.0.0.1`, because `PREROUTING` `DNAT`
rewrites the destination only. An application that requires a loopback peer needs a
per-application `nat INPUT … --ctstate DNAT -j SNAT --to-source 127.0.0.1`, which collapses
every client onto one source address and costs the service its ability to identify who called.
That is a property of one application, not a property of the grant model.

**A grant is never a bind.** No service ever binds a non-loopback address, and there is no such
thing as a private grant versus a public one: the distinction would be a second thing to get
wrong for no reachability gained. What a grant adds is a translation of a public port to a
publication, which is how a service speaks a protocol the edge cannot — a full node's peer port,
a VPN endpoint. Both protocols are carried: a grant names its protocol, the rule carries it, and
a grant never means both protocols at once.

Rendering the whole rule set is the point. Incremental firewall management — add this rule,
remember which rules we added, remove them later — is where duplicate rules, orphaned rules
and drift come from. One pure function of the union of all grants and allocations, rewritten
atomically, deduplicates by construction and makes "what is open" answerable by reading a
file. `soil firewall` owns the framework, the edge's forwarding and the dead-man timer; the
mutator owns `30-services.conf`, which is the service half, and the two files are disjoint.

That union has one more kind of member since ADR-0013: a service may **ask** for a firewall rule
of its own — a protocol the edge cannot speak — and an admin installs it with `weedr firewall
open`, which is the same request-then-grant shape as a port and on the same kind of root-only
verb. `30-services.conf` is rendered by one writer either way, and a rule no manifest requested
is still not grantable.

The renderer owns the published-port set completely. A project's `compose.yaml` or its
hand-written quadlet units may not introduce a published port of their own: every `PublishPort`
the renderer finds in the unit source is stripped, and the whole set is regenerated from the
grants and the allocations. Without that step the grant model is only advisory, because a
`ports:` entry in a Compose file becomes a `PublishPort=` line verbatim and the ceiling this
document sets is a suggestion.

**There is one path a deploy can add a service by, and it cannot grant a port.**
`weedr service ingest` takes `--from poke <project>@<sha>` and nothing else. The grant is `weedr port open`, a separate verb, and it is not on
the `guarden` rule — so a deploy creates the service and the ports its manifest asked for
stay pending. `hose` prints a `warning:` line naming the ports and the exact command to run,
which reaches the pull request's log, and the pending state is sticky: `weedr service list`
shows it until an admin grants or the manifest drops the request.

An earlier version of this had two paths differing by a flag, and enforced the second's absence
with a sentence. That sentence was not enforceable: a sudoers command with no argument
specification matches any arguments and sudoers has no negation, so a rule permitting `weedr
service add` also permitted `weedr service add --grant-ports`, and no argument specification
could have withheld it because every legitimate call carries a different staging path and a
different sha. Two paths became one and the grant became a verb, which is the only version in
which the guarantee below is a property of the file.

Provenance changes nothing: `weedr` decides on the verb and never on who asked. The deploy path
cannot reach `weedr port open`, because the rule does not name it, so a poke grants nothing
however it was invoked. A grant is made by a person at a terminal and recorded in a file the
repository cannot write.

Reaching a publication is not the same as being reachable from outside. A service must declare
an edge to connect to another service's publication, and the other question has the same shape:
may a service reach a granted public port without declaring an edge? No. A grant is reachable
from outside the host, which is the whole reason it exists; a service that wants to dial it
declares the edge and is policed like any other consumer.

The grant is the ceiling. The only file that records an open host port is root-owned and sits
outside the service's tree, and the only thing that writes it is the mutator, so a repository
can request a host port and cannot open one.

A repository *can* be allowed to grant its own ports, and the mechanism is documented in
`docs/notes/repo-ports.md` — a path unit and a service that promote pending requests. It is
not in the codebase, because it hands the repository exactly the authority this decision
removes, and an administrator who wants it can write forty lines of systemd in ten minutes.
