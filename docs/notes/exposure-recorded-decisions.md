# Recorded decisions in the registry: `route_destinations`, `basicauth`, `[exposure]`

Decided 2026-10-19 with tickets 292/293/294 (exposure cluster). Spec 3.4's projection
principle — "anything derivable from the manifest and the host is recomputed, and only what
cannot be … is stored" — names three values the exposure cluster stores anyway, and this
note records why, because the reason is a decision and not an accident.

## The three values

- `route_destinations` — where each route was resolved to when it was created: `loopback`,
  `tunnel` or `edge`. Written by the mutator at creation (`service._allocate`) and rewritten
  only by `weedr expose set`/`unset`.
- `basicauth` — whether the default edge login was minted for this service at creation, while
  the gate module's basic-auth policy was in force. Grandfathering is the absence of the flag.
- `[exposure] value` — the operator's act: `loopback`, `tunnel` or `public`, per service per
  environment.

## Why they are not recomputed

Each is a **decision made once, by an act**, and the first answer stands. Recomputing them
from the current module set or track would re-posture a running fleet behind its operator's
back: installing `cloudflared` would move every running service onto the tunnel, removing it
would strip basic auth from services created behind it, and a track edit would silently
publish services nobody promoted. That is exactly the surprise the cluster exists to remove.

## How the drift is handled instead

`soil firewall --check` reports a recorded exposure that no longer matches what it resolves
to now — one `drift:` line naming the offender, `correctable = False` — and the way back is
the act (`weedr expose set`), never a converge. A default that moves underneath a record is
an operator's to see and to answer, and a check that corrected it would be a second writer
for a decision with exactly one writer.

Spec 3.4 carries this rule in the contract text (the projection paragraph and the three
fields in the registry example); this note records the decision behind it.
