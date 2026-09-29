# 80: declared edges — host entries, firewall, database provisioning

**What to build:** One `needs` entry in a manifest produces three things: a name the consumer
resolves, a firewall rule that lets that one service *connect* to that one port, and a credential
of its own. Nothing else can connect to the port. What a service *binds* is not policed, and
this ticket does not pretend otherwise; the port allocator refusing a duplicate at install time
is all the policing there is.

**Blocked by:** 15 (prove the assumptions), 40 (loom), 60 (credentials), 70 (state)

Public ingress grants are ticket 160. The refusal of undeclared volumes and out-of-tree host
paths is ticket 40, and both are needed before the edge is complete.

**Status:** ready-for-agent

- [ ] `auth` is a required field on every `needs` entry, with no default, and is one of
      `database`, `secret`, `none`; a kind the provider's `provides` list does not offer is
      refused naming both services and both kinds
- [ ] `auth: secret` mints a random secret **distinct per edge** and plants it in **both** the
      consumer and the provider under the edge's `as` prefix; two consumers of one provider
      never share a value, and the two services' credentials are never the same
- [ ] `auth: none` plants nothing, and says so in the registry
- [ ] The provider's `provides` list is validated at render: `engine: postgres` is the only
      engine-aware field in guarden and appears in exactly one place in the code
- [ ] For each edge, `loom` writes `AddHost=<provider>:<alias>` into every unit of the consumer.
      There is no name map and no `/etc/hosts`; the name is the provider's service name, with no
      suffix and no alias
- [ ] **The firewall rules' destination address is `127.0.0.1`, never the alias.** Pasta maps the
      container's gateway onto the host's loopback in userspace, before the kernel's packet path,
      so by the time `OUTPUT` sees the connection it is already `127.0.0.1` and a rule matching the
      alias matches nothing. The measured alias is written into `guarden.toml` as `ingress.alias`
      by `soil install` from its own probe and appears in `AddHost=` only; the edge does not start
      without it
- [ ] For each edge, `weedr` renders an `OUTPUT` accept rule matching the consumer's uid and the
      dependency's publication, followed by a drop rule for every other uid
- [ ] **The edge is permitted, by uid, to reach every route publication.** That is
      deliberate: reaching the container is the edge's entire job, and the blast radius of a
      compromised edge is the routed surface. The permission is an explicit uid rule, not a gap
      in the drop set
- [ ] **Route targets get allocated publications from the same namespace as everything else.**
      They need no grant and no confirmation, the allocator picks a number no service has
      published, and that is what lets several instances of one preview service coexist: the
      branches do not contend for a port, they are each handed one, and the edge is pointed at the
      instance it meant
- [ ] **The loopback is closed to service uids by default.** The `OUTPUT` set is a default deny on
      `-o lo -d 127.0.0.0/8` for every service uid, with the per-publication accepts above it.
      The deny does not touch outbound traffic, and pasta's DNS forward is explicitly excluded
      from the loopback mapping, so the earlier justification about name resolution and package
      updates was false. A container cannot reach `sshd` on 22, and there is no fifth grant table:
      a service needing a host loopback port which is not a publication needs that daemon to be a
      service
- [ ] **Render, diff and install happen under one `firewall` lock.** Two mutations that each
      render would otherwise let the stale render install last, silently dropping the rule the
      other one had just granted
- [ ] Every rule is IPv4. `soil` disables IPv6, so there is no `[::1]` form of the address to
      forget and no second address family in the rule set
- [ ] The rules are rendered in full from the union of all declared edges and grants, written
      atomically, with the diff against the installed set printed before installation
- [ ] For each publication the accept set is the edge's uid, each declared consumer's uid, the
      service itself for its own granted port, and `host.admin_user` for the edge's API, and
      every accept precedes the single deny. A rule set that omits the owner refuses the owner's
      own listener; one that omits the edge makes every route 502; one that omits the admin
      refuses the dashboard from the operator's own shell
- [ ] Two services declaring the same edge produce one rule, because the set is deduplicated by
      construction rather than by a mechanism
- [ ] Two services publishing the same port is refused at install with exit 1 and the holder
      named
- [ ] `weedr port list` shows requested, granted and pending for every service; pending is
      sticky and survives until an admin grants or the manifest drops the request
- [ ] `weedr port open <name> 8080/tcp` creates the service's `overrides.toml` if absent,
      adds the port, and re-renders `30-services.conf` under the firewall lock; `weedr port close`
      revokes and re-renders the same way
- [ ] **A grant is a translation, never a bind.** The public port is DNATed to the service's own
      loopback publication and no unit gains a `PublishPort` for a non-loopback address. There is
      no `private`/`public` prefix on the argument and no such distinction to make
- [ ] **The translation is the DNAT and nothing else.** A `nat POSTROUTING` masquerade is not
      written: a DNAT to `127.0.0.1` makes the packet local, so it never reaches `POSTROUTING`,
      and conntrack unwinds the translation on the reply. A masquerade would match no packet in
      either direction. The service sees the client's real address as its peer, which is
      recorded so nobody "fixes" it with an INPUT SNAT
- [ ] `weedr service ingest` never grants a port, because it has no flag that can. The grant is
      `weedr port open`, which is not on `furrow`'s sudoers rule, so a poke leaves the requested
      ports pending and a `warning:` line names them and the exact command to run
- [ ] `weedr port open` never grants a port the manifest did not request
- [ ] For a database edge, `weedr` creates one role and one database in the provider, mints the
      password, plants it as a podman secret in the consumer's store, and generates the
      `DB_HOST`, `DB_PORT` and `DB_PASSWORD` variables for the consumer
- [ ] No path in the mutator reuses a password across services or environments, and a clone of
      a state volume contains no credential
- [ ] The postgresql provisioning is one function with a version feature check, and the only
      engine-aware code in guarden
- [ ] On the golden VM: a member reaches the dependency and a non-member cannot **connect** to
      the port, with and without the rule. Nothing polices what a service *binds*: two
      compromised services can talk over any port they both choose, and the test above is the
      whole of what the firewall guarantees
- [ ] Verified at the CLI seam with the fast harness
