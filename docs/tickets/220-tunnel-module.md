# 220: the tunnel module — reaching a hidden track from outside

**What to build:** A second public terminator on the box, which dials **out** and is reached by
nobody. `cloudflared` runs as an ordinary service with no capability and no publication of its own,
holds no public port, and carries the routes a track has decided are not published on the edge. A
grant is time-bounded by construction and revocable in one verb, and the record of who may reach
what is guarden's, not the vendor's.

The edge is not replaced and does not change. Production keeps serving `myapp.$DOMAIN` from
Traefik on the kernel's forwarded ports, and the production zone's nameserver does not move. The
tunnel answers on a **separate hostname in a zone delegated to Cloudflare**, so nothing about the
production path depends on Cloudflare being up, reachable, or paid for.

**Blocked by:** 50 (the edge), 80 (declared edges), 150 (the auth module — the shape of a
sign-in in front of a route, which this reuses rather than reimplements)

**Status:** partially landed. The `tendril` module shipped: ADR-0015 (a second terminator),
`weedr share issue` / `weedr share`, `[ingress] tunnel_domain`, `modules/tendril/`, and the
suite is `tests/t220-tendril.sh`. **19 checklist items remain open below** — credentials in
the service's own secret store, preview-instance publication, URL-unsafe ref refusal, the
runbook, and the customer-facing acceptance criteria. Ticket restored 2026-10-08 after being
removed on the mistaken belief that the tendril module discharged it.

**Since then `c949878` closed four of them**, verified green in the VM: a preview ref is RFC
3986 unreserved or it is refused with exit 2 naming the ref, so two refs cannot collide after
percent-decoding; `weedr module remove tendril` deletes the Access application and fails closed
with `UNCONFIGURED` rather than claiming a success it did not achieve; preview instances are
published at a path built from the escaped ref; and the tendril service carries a
`TUNNEL_CREDENTIAL` schema entry, `0600` and never rendered into a unit.

**Measured 2026-10-12, on the credential item this ticket carries open.**
The schema entry above declares nothing today, twice over: `service.yml` reads
`schema: .env.schema`, which resolves under the service root and not
`.guarden/`, so `secretschema.read` is handed a missing file and returns an
empty schema (silently, by design); and the schema's own key and annotations
at `.guarden/.env.schema:9–13` are plain lines, which `secretschema` skips —
it reads comment lines only. The renderer strips the container's
`Secret=TUNNEL_CREDENTIAL,type=file` as an owned key and re-emits it from the
schema alone, so the rendered tendril unit requests no credential at all — and
nothing in `tests/` asserts one. That is the state to build from: the path is
`.guarden/.env.schema`, the annotations are comments, and the acceptance is an
assertion on the rendered unit's `Secret=`. (`t220-tendril.sh` asserts the
unit's image, `[Container]` and absent `ExecStart=` and nothing about the
credential.) Ticket 267 carries the same measurements.

**19 boxes are still unticked and each needs its own work.** An agent reported several done in
prose and the boxes were not ticked, because the assertions do not exist. In particular
**the structural SSH guarantee is TESTED**: `tests/t220-ssh-guard.sh` asserts that after
`weedr share issue` and `weedr share revoke`, the SSH chain remains intact: 00-ssh.conf
stays 0600 root:root, its accept stays first in guarden-ssh, INPUT's jump to guarden-ssh
stays first, and soil firewall --check reports no drift on SSH items.

**Blocked by:** 50 (the edge), 80 (declared edges), 150 (the auth module) — all landed.

## The decision this ticket rests on

**The tunnel is a second edge, and `CONTEXT.md`'s definition of `edge` says "the one service that
terminates public traffic". That sentence is now wrong and the glossary is not negotiable
mid-change.** The first checklist item is therefore the ADR, and the ticket does not begin
without it. The ADR also covers the second thing this changes: `soil` currently performs exactly
one fetch from outside a distribution repository — the pinned `podlet` release — and
`cloudflared` is either a distribution package or the second such fetch, which is a decision and
not an implementation detail.

## Sources

The facts below are taken from the vendor's own documentation, cited at the point of claim.
Everything marked UNVERIFIED is an assertion this ticket must test rather than trust.

- egress-only, no inbound port, and "block all ingress traffic for a positive security model" —
  <https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/>
- egress destination `7844` TCP/UDP, and the specific CF IP ranges an SNI-enforcing firewall must
  allow — <https://developers.cloudflare.com/tunnel/configuration/>
- declarative `ingress:` rules in a local config file, first match wins, mandatory catch-all, and
  the path being forwarded **unstripped** —
  <https://developers.cloudflare.com/tunnel/features/locally-managed-tunnels/configuration-file/>
- `cloudflared tunnel ingress validate` and `cloudflared tunnel ingress rule <url>` for testing a
  rendered file offline — same page
- the CNAME-to-`<UUID>.cfargotunnel.com` shape, and that it **only proxies for DNS records in the
  same Cloudflare account** — <https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/routing-to-tunnel/dns/>
- email one-time PIN, single-use, invalidating its predecessor, and a 10-minute code TTL —
  <https://developers.cloudflare.com/cloudflare-one/integrations/identity-providers/one-time-pin/>
- Access policies are action + rule type + selector + value, with `Allow`/`Include Emails` and
  `One-time PIN` as a login method —
  <https://developers.cloudflare.com/cloudflare-one/access-controls/policies/>
- non-HTTP access needs a client on the user's device; only SSH/RDP/VNC have a clientless
  browser-rendered path —
  <https://developers.cloudflare.com/cloudflare-one/access-controls/applications/non-http/>

## What to build

- [x] **ADR first**, superseding the `edge` entry in `CONTEXT.md` and the "exactly one fetch"
      sentence in `AGENTS.md`. It states that a host may terminate public traffic in more than one
      place, that the second terminator is *egress-only and therefore not a door*, and which of
      `cloudflared`'s distribution routes guarden takes. Nothing below is implemented before it
- [x] **The ADR decides where `cloudflared` comes from, and the honest options are narrow.**
      `cloudflared` is **not in Debian, Ubuntu or Fedora repositories** — the vendor publishes it
      through its own APT repository at `pkg.cloudflare.com` and its own RPM repository, with a
      separately-rolled signing key (<https://pkg.cloudflare.com/>). So this is **not** a
      distribution package and it is **not** the same class of fetch as `podlet`: adding a
      third-party APT repository is a different trust decision from adding a pinned release to a
      congerger, because the repository's *contents* change under guarden's version pin.
      **Decided, and the ADR is amended: the container image.** ADR-0015's first revision took the
      pinned-binary route and this ticket's implementation exposed why it cannot: the tunnel ran as
      a raw systemd unit with a multi-word `ExecStart=`, which `unitsource.format_line` refuses by
      design, while a `[Container]` unit passes its arguments one `Exec=` line each — which is how
      `gate`'s traefik already runs and what spec §2 means by "everything deployed is a service".
      So `PINNED_ARTEFACTS` is `(podlet,)`, `cloudflared.release` is deleted, and the version in
      force is the image tag in the module's own unit source rather than a `*.release` file. A
      vendor APT repository is still refused, for the reason above
- [x] `/usr/lib/guarden/modules/tendril/module.toml` declares one service, `tendril-production`,
      the shared program it switches on, and **no ingress** — it declares no ports because it binds
      none. `weedr module add tendril` creates the service, its user and its home, and touches no
      other module
- [x] `tendril-production` is an ordinary service: its own user, its own home, `0700`, no
      capability, no `PublishPort`, and **no publication of its own**. It is not an edge in any
      sense the firewall cares about, because nothing connects to it
- [ ] **Two credentials, both in that service's own podman secret store, both gated like any
      other.** The tunnel's own credential lands as a **file** at `/run/secrets/TUNNEL_CREDENTIAL`
      and is named as `credentials-file:` in the rendered config; the Cloudflare API token is the
      second, read by the mutator and never rendered into a unit or a log. An empty or example
      value blocks the start and the reason is a `warning:` naming the key — the gate is a state,
      not a failure
- [x] `[ingress]` gains a root-owned `tunnel_domain`, empty by default. Empty means the tunnel is
      **not configured** and `weedr module add tendril` refuses to install it, naming the key. A
      repository cannot set it and no manifest carries it. **Corrected:** the first revision also
      said `soil --check` reports the absence, and that was implemented as a warning on every
      converged host whose tunnel_domain is empty — i.e. every host that has not adopted the
      tunnel. Removed in `be4e498`: the diagnostic belongs where the action is refused, not in the
      ambient output of a host that is converged. `t20-packages` caught it by asserting stderr is
      empty on a converged host
- [x] **A track gains one field, `expose`, on its `[[environments]]` row**, `edge` or `tunnel`,
      defaulting to `edge`. It is a **default for that track's services**, it is root-owned, and
      nothing in guarden branches on a track's *name* — only on this field
- [x] **A service's `overrides.toml` gains exactly one new table, and it can only ever remove
      from the edge:**

      ```toml
      [expose]
      tunnel = ["web"]              # route LABELS published through the tunnel INSTEAD of the edge
      ```

      There is deliberately **no `[expose] edge`**, because "not through the tunnel" is what the
      track's `expose` already says and a second spelling of it is a second place to be wrong. An
      unknown route label is exit `2` naming the label and the routes the manifest declared. A
      route that appears in neither list follows its track
- [x] **`weedr service list` prints each route's destination** — `edge` or `tunnel` — next to the
      route host, because "is this thing public?" must be answerable in one command and not by
      reading three root-owned files
- [x] **A route published through the tunnel is not rendered into the edge's dynamic directory at
      all.** Not rendered disabled, not rendered behind a deny — absent. A second route table the
      two terminators both honour is how a service ends up reachable by both
- [x] `roots` renders the tunnel's ingress file from the same route slice it already renders the
      edge's, into a second directory it owns, and writes **only** the routes whose destination is
      `tunnel`. `roots` has no intermediate route format and grows none: it emits one file per
      terminator from the routes it has, which is what it is for
- [x] The rendered ingress file's catch-all is `http_status:404` and is **last**. A hostname in the
      tunnel's zone that no service claims is a 404 from the tunnel, not a default page and not a
      fall-through to the edge
- [ ] A preview instance is published at `preview.<tunnel_domain>/<ref>` — **a path on one host**,
      the same shape as `preview.$DOMAIN/<ref>` (ticket 110) and for the same reason: the ref is a
      path segment, so there is no wildcard certificate and no per-ref DNS. The tunnel's own path
      regex matches it and the full path is forwarded unstripped, so the application still sees
      `/<ref>/...`
- [ ] **A ref that is not URL-safe is refused at publication with exit `2` naming the ref, and two
      refs that differ only by percent-encoding cannot both be published.** The ref is taken raw
      by every verb and escaped internally, and that guarantee now has to hold in the tunnel's
      path space as well as in `systemd-escape`'s — a second namespace with the same collision
      property is a second thing to get wrong
- [x] **The tunnel adds no firewall rule to `20-ingress-nat.conf`, and `soil firewall --check`
      fails if it ever does.** It dials out, so no `nat PREROUTING` DNAT exists for it and no
      public port forwards to it. This is the assertion that distinguishes this ticket from the
      Pangolin one, and it is checked rather than asserted in prose
- [x] **`50-services.conf` gains `OUTPUT` accept rules for the tunnel's uid against the
      publications it fronts, and nothing else.** Destination is `127.0.0.1`, never `ingress.alias`
      — pasta maps the gateway onto host loopback in userspace before the kernel's packet path
      (spec §7.7), so a rule matching the alias matches no packet. It is rendered under the
      `firewall` lock, in the same pass, by the same writer
- [x] **The loopback deny still applies to the tunnel's uid.** The tunnel is one more service uid
      and is closed to loopback by exactly the same rule as every other; being the thing that
      reaches the publications is an explicit uid accept above the deny, not a gap in it
- [x] The structural SSH guarantee still holds, and a tunnel grant cannot disable it: the
      tunnel is egress-only, so it can neither lock an operator out nor be locked out
- [x] **`cloudflared` runs as a service like every other** — a `[Container]` unit in its own user
      manager, nothing in `/etc/guarden` it can write, and a restart of the edge does not restart
      it. The two terminators fail independently, which is the point of having two. **Superseded
      the first revision's "a systemd user unit":** that shape is refused by `unitsource`, and the
      container is the one model every other service already uses

## The grant: temporary, revocable, and guarden's to answer for

- [x] **A grant is an issuance, and an issuance always expires.** `weedr share issue <name>[/<ref>]
      <email> --until <duration>`; `--until` is **required** and refusing a value above a
      root-owned maximum. There is no spelling of "never", because a grant that cannot be
      time-bounded is a grant whose expiry is somebody's memory. The maximum is `[share] max` in
      `guarden.toml`, `168h` by default; the duration grammar is guarden's own
      (`<number><unit>`, `s m h d w`) in `src/guarden/durations.py`
- [x] An issuance is recorded in the mutator's own state with an **absolute** expiry computed at
      issue time. A root-owned wall clock that can move backwards must not be able to extend a
      grant, so the stored value is the deadline and not a duration. One file per issuance under
      `/var/lib/guarden/share/`, `0750 root:guarden`, named by its id
- [x] `weedr share issue` on a route whose destination is `edge` is **exit `2`** naming the route
      and its destination. There is no `--via tunnel` flag: which terminator carries a route is
      configuration, and a flag that chose it would be a second place
- [x] `weedr share revoke <id>` ends one issuance immediately and is **not** undone by a
      redeploy, a re-render, a reboot, or a `weedr module add`. `weedr share list [--json]` shows
      live, expired and revoked issuances with their absolute deadlines, so "who can see this right
      now" is one command
- [x] **The vendor's Access policy is a projection of the issuances, never the record.** The
      union of live issuances for a hostname is written as one `Allow` policy with
      `Include Emails [live emails]` and `Require Login Methods [One-time PIN]`. `weedr share
      reconcile` recomputes it from the local record and is idempotent, adds before it removes,
      and **stops rather than clearing anything when its own state is unreadable** — the same
      posture as `weedr pin sync`, for the same reason: an unreadable state must never be
      indistinguishable from an empty one. The projection is rendered to
      `/var/lib/guarden/share/projection.json` before any vendor call, so it is a file a suite can
      assert without a real account
- [x] **Expiry is enforced by that reconciler on a root-owned timer, not by the vendor.** An
      Access policy has **no `expir*` key at all** — the policies API schema carries none, and the
      schema was searched for `expir`, `expires`, `expires_at`, `expiration`, `ttl`, `valid_until`
      and `not_after` with zero hits across all four response objects. **But the second half of
      this item was wrong and is corrected:** a policy response *does* carry a top-level
      `session_duration`, "the amount of time that tokens issued for the application will be
      valid", which is a browser-login duration — so "the only durable-duration primitive is a
      service token" is false. See `docs/notes/cloudflare-session-duration-exists.md`. The design
      is unchanged: a session duration bounds one authenticated session, it cannot remove an
      address from the policy, and removing the email is still the act that ends a grant. **Decided:
      `session_duration` is set to `[share] max`**, converted to the vendor's Go syntax (`7d` ->
      `168h`) — a second, shorter bound under guarden's deadline. A deadline-derived value would
      change on every run and could never be idempotent; see
      `docs/notes/220-session-duration-decision.md`. So "expires in seven days" is guarden's timer
      removing the email from the policy, and a stopped timer means the grant outlives its
      deadline. That is stated in the runbook and in `SECURITY.md` as the failure it is. The timer
      is `guarden-share-reconcile.timer`, every ten minutes, enabled only with the `tendril` module
- [x] **The reconciler holds the Cloudflare API token and is the only thing that calls the vendor.**
      It needs an API token with the narrowest scopes that work, named in this ticket, and the
      scopes are recorded next to the token's name in `guarden.toml` so an operator can audit what
      a leaked token would reach. The token value is read from `/etc/guarden/share.api-token`,
      `0600 root`, and is never an argv; `[share] token_name` and `[share] scopes` record the name
      and the scopes (`Access: Apps and Policies Write`)
- [x] **A failed API call leaves the local record and warns.** The grant is refused with a
      `warning:` naming the endpoint and the vendor's error rather than being recorded as issued,
      because an issuance that exists locally and not at the vendor is a grant the operator
      believes is closed and is not. A call that was attempted and refused is exit `1` and the
      projection is not marked applied, so the next reconcile retries. A host with no `[share]
      account`/`app` or no token is a **state**, not a failure: it warns and exits `0`
- [ ] **`weedr module remove tendril` removes every tunnel route from the edge, and deletes the
      Access application**, so removing the module cannot leave a hostname in Cloudflare proxying
      to a box that no longer answers. **Not done**: `module remove` today removes the module's
      services and re-renders the firewall, and the tunnel's routes leave with the service's
      `routes.toml` slice — but the Access application and its policies are not deleted, and that
      needs a vendor call. Left as the follow-on it is
- [x] `hose` cannot reach `weedr share`. The sudoers rule is unchanged by this ticket, which is the
      whole reason a customer-facing grant is safe to have: a poke can deploy to a preview and
      cannot mint, extend, or revoke access to one. `weedr share` is on no sudoers rule at all, and
      the `hose --help` surface names no share verb

## Customer experience — asserted, not assumed

- [ ] **A customer needs no account, no client and no install.** They open the URL in any browser
      on any phone, type their email address, and paste a PIN. This is the reason this ticket
      exists and it is a **testable claim, not a preference**: the ticket fails if any part of the
      path needs software on the visitor's device
- [ ] **The customer path is HTTP/HTTPS only, and the ticket says so in the runbook rather than
      discovering it later.** Non-HTTP needs `cloudflared` in a terminal on the visitor's device
      (cited above); the only clientless non-HTTP path Cloudflare offers is a browser-rendered
      terminal for SSH/RDP/VNC, which is not a database port. An operator wanting raw TCP to a
      preview installs one binary on their own laptop, and that is recorded as an operator action
      and not as a customer feature
- [ ] WebSockets and long-lived streams are **accepted behaviour, not a build item** — they ride
      the HTTP ingress path. The vendor's own caveat is that its client-side WebSocket transport
      can close persistent connections unexpectedly, which is a further reason raw TCP is out of
      the customer path rather than in it
- [ ] **A customer on a corporate mailbox is a known failure mode, written into the runbook.**
      Mail security tools consume the PIN before the user sees it and the error reads "This
      One-Time PIN has already been used". The documented mitigations are allowlisting
      `noreply@notify.cloudflare.com` and the `notify.cloudflare.com` sending IPs
- [ ] **The login page's response to a denied address is indistinguishable from success**, because
      the vendor deliberately does not reveal whether an email was allowlisted. The runbook must
      not tell an operator to read that page as a membership test, and a support answer to
      "it says a code was emailed and nothing arrived" must be written down
- [ ] The edge's own API and its dashboard are a **control surface**, so putting them behind the
      tunnel is a decision with a direction: they are reachable through the tunnel and **not**
      rendered on the edge. Ticket 50 keeps them off the public edge and this does not reopen that;
      it gives them a second, authenticated door
- [ ] `homepage-production` is a public route today (ticket 100) and moving it to the tunnel is a
      deliberate withdrawal of a public surface. `weedr service list` shows it moved and the
      operator sees the edge route disappear, rather than discovering it from a 404

## Verification

- [ ] **In the golden VM, with the real `cloudflared` binary and no Cloudflare account**, the
      rendered ingress file passes `cloudflared tunnel ingress validate`, and
      `cloudflared tunnel ingress rule` is asserted to match each expected route and to land on the
      catch-all for an unknown host. This is a real tool validating a real file with no network and
      no fake — it is the reason the vendor's own tooling matters here
- [ ] A tunnel-published route is **absent** from the edge's dynamic directory, asserted by
      reading the directory rather than by inspecting a log
- [ ] `20-ingress-nat.conf` is byte-identical before and after `weedr module add tendril`, and
      `iptables-save` shows no rule matching the tunnel's uid except the publication accepts
- [ ] Every refusal is asserted at the CLI seam: an empty `tunnel_domain`, a `--until` that is
      absent or over the maximum, a share issued against an `edge` route, an unknown route label in
      `[expose] tunnel`, a URL-unsafe ref, and a second ref colliding by percent-encoding
- [ ] **The live criterion is an operator acceptance step and is marked as one**, because it needs
      a real Cloudflare account and a real delegated zone and no fake can stand in for it: a
      browser on a phone with no client installed reaches a staging route, a second browser with no
      access is refused, and the grant is still refused after `weedr share revoke` with no redeploy
      and no restart. `just test` does not depend on it, exactly as the structural verification and the
      reboot phase do not
- [ ] `docs/sysadmin.md` and `SECURITY.md` gain the section: what the tunnel can and cannot reach,
      what happens to every issuance when the reconciler timer stops, and what a leaked API token
      would allow
- [ ] Verified at the CLI seam, in the VM

## What this ticket does not do

- It does not replace or modify the edge, `roots`' edge output, or the `gate` module's three
  forwarded ports. Production is untouched and its zone's nameserver does not move
- It does not give a manifest any say. A route's destination is a track's field and a service's
  root-owned override, and a repository can widen neither — the same shape as a port grant
- It does not give a customer raw TCP, a database port, or a client-side `cloudflared`. HTTP and
  HTTPS are the contract
- It does not add a second account system. Identity is Cloudflare's one-time PIN, and guarden holds
  the record of who was issued what, not a password, a hash, or a session
- It does not make the vendor's policy the source of truth. Deleting a Cloudflare Access policy by
  hand makes no local issuance live, and `weedr share reconcile` puts it back