# Auth is opt-in per bed in bed.yaml, and roots renders the rule

Sign-in runs at the fence: Traefik checks every protected request with the auth bed
before the request reaches the service. The auth bed — Authelia or Authentik — is a bed
like any other: `bed-<env>-<name>`, its own user, its own quadlet dir, a hyphae name,
secrets planted with `weedr secret set`, its store self-contained or taken from a pond.
Beds never talk to the auth bed; only Traefik does.

Traefik's routers come from `roots`' dynamic config, and a route file cannot be patched
from outside — `roots` owns the directory and rewrites the file when the bed changes. So
the forward-auth rule must be rendered by `roots`, from the bed's own manifest:

- A protected bed declares `auth: true` in `.guarden/bed.yaml`. `roots` attaches the
  forward-auth middleware, aimed at the auth bed's hyphae name, to that bed's routers.
- One root-owned file (mode 0444) beside the dynamic config names the auth bed. The
  admin writes it once; `hose` and regeneration never touch it. Beside, not inside: the
  dynamic-config directory is the one `fence`-writable leaf, so the unprivileged `roots`
  user can read the marker but can never unlink it — "the marker exists" is held by file
  permissions, not by `roots` behaving well.
- A bed without `auth:` gets exactly the routes it gets today.
- The auth bed's own routers never carry the rule, whatever it declares — otherwise
  Traefik would ask the auth bed to authenticate itself.

Why: enforcement belongs at the edge, in one place, with no per-app integration and no
second writer of route config. The bed asks in its own repo; the admin names the auth
bed once.

Consequences: `roots` grows one feature — no new `weedr` verb, no change to the fence
bed or the fence group, and no app integrates with the auth bed. Finer, per-route auth
can grow from the same key later. Rotating the auth bed is an edit to one root-owned
file, not a redeploy of every protected bed.
