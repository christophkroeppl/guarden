Blockers: none. Carried out of ticket 292's "Known gaps" so that merging the
exposure cluster does not erase it (review-exposure.out finding 10).

## What happens

Rotating the default basic-auth credential does not rewrite the htpasswd entry.
`weedr secret set <name> GUARDEN_BASICAUTH` replaces the encrypted blob and the
materialiser re-pushes the podman secret, but the edge reads the htpasswd file
that `basicauth.mint` wrote at creation — so the login an operator just rotated
is the one still in front of the edge, and the two halves of the credential
disagree until somebody rewrites the entry by hand.

## What to build

Wire the htpasswd rewrite to the rotation: the same root-side act that replaces
the blob (`weedr secret set` on this key, or a `basicauth` hook it calls)
re-derives the entry with `basicauth.write_entry` from the new value, so blob
and entry are written together or not at all. `basicauth.restore` (the
remove→add path) is the existing shape for "rewrite the entry from the blob".

## Status: ready-for-agent

- [ ] Rotating `GUARDEN_BASICAUTH` rewrites `<service>.htpasswd` in the same
      act, and the new entry verifies against the new blob.
- [ ] A rotation that fails writes neither half's successor state silently —
      the diagnostic names the service.
- [ ] Red first, in the t450–t459 range.
