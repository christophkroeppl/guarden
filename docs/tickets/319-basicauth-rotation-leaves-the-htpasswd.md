Blockers: none. Carried out of ticket 292's "Known gaps" so that merging the
exposure cluster does not erase it (review-exposure.out finding 10).

## What happens

`weedr secret set <name> GUARDEN_BASICAUTH` replaces the encrypted blob and
asks the materialiser to re-push, and the edge keeps serving the **old**
password.

The reason is that the edge never sees the podman secret. Its `basicAuth`
middleware reads a **file** — `usersFile: /etc/guarden/basicauth/<service>.htpasswd`
(`src/guarden/templates/edge-routes.yml.j2`) — and that entry is written in
exactly one place, `basicauth.mint` (`src/guarden/basicauth.py:150`), at
creation. `basicauth.restore` (the remove→add path) is the only other writer.

So after an operator replaces the credential, the two halves of one credential
disagree: the blob holds the new value, the entry in front of the edge holds
the old one. The verb reports success — it prints `planted …` and exits `0` —
and nothing tells the operator that the password they just set is not the one
the edge will accept. The state is only reachable by hand.

**Nothing rotates on its own.** There is no TTL, no expiry, and no scheduled
rotation of this credential; the login is minted once at creation and lives
until the service is removed. The act above is the only rotation that exists,
and it is one an operator performs deliberately — typically because they
believe the credential leaked. That is why a half-working rotation matters
more than a routinely-working one: it gets used when it matters most.

## What to build

Make that one existing act consistent. The same root-side act that replaces
the blob re-derives the entry from the **same value**, so the entry and the
blob are written together or not at all.

The shape is `basicauth.restore`'s — read the value, write the entry — and
the difference is only where the value comes from: `restore` reads it back out
of the blob, because the blob is all it has; this path is handed the value
that was just written, so the two halves are derived from one value rather
than from two reads of one file.

**This is a consistency repair, not a rotation feature.** No mechanism, no
schedule, no expiry is added, and no verb's surface changes: the operator's
act is the same act, and it now leaves the host in a describable state.

**The blast radius decides the shape.** `weedr secret set` is the general verb
for every credential, so the hook sits in its path. A key that no owner claims
must be completely unaffected: `weedr secret set` on an ordinary credential
still writes the blob, still asks the materialiser, consults no owner, and
rewrites no entry.

## Status: ready-for-agent

- [ ] Replacing `GUARDEN_BASICAUTH` rewrites `<service>.htpasswd` in the same
      act, and the new entry verifies against the new blob.
- [ ] A replacement that fails writes neither half's successor state silently —
      the diagnostic names the service, and the ticket says what the operator
      is left holding.
- [ ] An ordinary credential's `weedr secret set` is unaffected: same blob,
      same materialiser call, no owner consulted, no entry rewritten.
- [ ] Nothing rotates on its own — no TTL, no expiry, no schedule is added.
- [ ] Red first, in the t450–t459 range.
