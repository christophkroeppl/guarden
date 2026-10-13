# the container alias is pinned, and the probe is gone

Accepted 2026-10-13. It supersedes the measured-alias paragraphs of ADR-0004 — "The address a
consumer *dials* is the host-loopback alias as the machine actually has it" through "…no longer
means this host" — and amends spec §3.1, §3.5, §6.1, §6.3, §7.1 and §9. It does **not** reopen
ADR-0004's connectivity decision: one loopback namespace, `AddHost=` as the only name map, the
uid-matched rules and the default deny all stand.

## What was measured, and what could not be

The design's central address was a **measurement**: `soil install` ran a probe container, read the
gateway out of its route table, checked that a connection to it arrived on the host's loopback
with the consuming uid as the socket owner, and wrote the address into `guarden.toml` as
`ingress.alias`. The probe cannot run at all, and it never did:

- **`soil install` is root, and podman 5.7 refuses pasta as root.** `podman run --network pasta:`
  fails with *"pasta networking is only supported for rootless mode or when inside a nested
  userns"*. The phase runs before any service user exists, so there is no rootless user to run it
  as either. This is not a missing package or a missing option: the mechanism the probe is
  written in cannot execute on a host guarden installs on.
- **The probe image is external to this repository.** `localhost/guarden-probe` is built by
  nobody here and shipped by nobody here, so every host stops on the image — which is the one
  drift every host has reported since the probe was written.
- **The suites that name the probe never exercised it.** They assert its failure — exit `1`, the
  missing item, the image named — and no run has ever recorded the four facts the probe exists to
  record, because no run could.

Four adversarial reviews established this, and the conclusion is architectural rather than
diagnostic: **a root-run phase cannot use the rootless network backend, so per-host measurement
of the alias is dead, not broken.** What remained was to establish the facts once and freeze them.

**The facts, measured on a real VM** (podman 5.7, pasta 0.0~git2026*), with the pinned set below:

- the container's default route is `via 10.0.2.2` **on any host and any network** — the address
  is pasta's, configured per container, and does not come from the host's route;
- a connection from the container to `10.0.2.2` arrives at the host's `127.0.0.1`;
- on the host side the connection has both source and destination `127.0.0.1`, with the socket
  owned by the uid the container runs as — the fact the uid-matched `OUTPUT` accepts rest on;
- DNS and egress are unaffected, and **nothing leaks to the host's route table**.

## The decision

**The option set is pinned.** `[network] pasta_options` is the set guarden runs pasta with, and
it is now a fixed one:

```toml
pasta_options = [ "--map-gw", "--ipv4-only", "-a", "10.0.2.100", "-n", "24", "-g", "10.0.2.2" ]
```

Each entry is load-bearing. **`--map-gw` is podman's token, not a pasta(1) option**: podman
configures pasta with `--no-map-gw` by default, and this is the only spelling that turns the
gateway mapping back on. `--ipv4-only` keeps the container side IPv4, the only family the rest of
guarden has. `-a` and `-n` fix the container's own address and network, and `-g` fixes the
gateway — the one address a consumer can reach the host on.

**`ingress.alias` is derived, not measured.** `soil install` reads the `-g` value out of the set
and writes it into `[ingress] alias` under the `modules` lock, exactly where the measured value
used to be written. It stays a normative key, it stays a *name the consumer resolves* and never a
firewall destination, and the edge still refuses to start without it. It is simply a constant
now: `10.0.2.2`, the same on every host and every network.

**The set is validated as a shape.** A `pasta_options` set missing `--map-gw`, `--ipv4-only`,
`-a`, `-n` or `-g` is exit `2` naming the key; `--no-map-gw` and `--map-host-loopback none` stay
refused. This is what keeps the constant constant: no host can run a set that maps nothing, or
maps an address `ingress.alias` does not name, and keep a configuration that reads as converged.

**The drift re-check is deleted.** `soil sysctl --check` no longer compares the recorded alias
against the host's default route: a constant cannot drift, and the comparison would now fire on
every host whose default route is not `10.0.2.2`, which is every host. What replaces it is a
**warning**: `soil sysctl --check` warns when the host's own routing table carries an on-link
route overlapping the reserved `10.0.2.0/24`. It is a warning rather than drift because the host
is not in a wrong state — its LAN is simply in the way — and the remedy is the one-place range
change below.

**The canary.** The one check that stays is the golden VM's: a rootless container reaches a
dependency by the pinned alias, and the connection arrives on the host with the consumer's uid as
the socket owner. It runs on the harness rather than on every host, it is the only thing in the
system that exercises the mapping end to end, and if podman or pasta ever changes what `--map-gw`
or `-g` mean, it is where that shows.

## Why not the alternatives

**Keep measuring, per host.** Dead on the mechanism, above. A measurement that cannot execute is
not a verification; it is a failure item every host carries forever — and that is what every host
has carried.

**Build the probe image in-repo.** Ticket 268 left this open; it closes here as the wrong fix.
The image was never the only problem — a root-run `soil install` still cannot pass
`--network pasta:` to podman 5.7, and running the probe as a service user would make the phase
depend on an identity that does not exist until a service does. A new image would change the
failure text, not the outcome.

**Map the host's own gateway per host** (`--map-host-loopback <the host's gateway>`), which is
what "measure it" reduces to when written as configuration. It works until the route changes — a
DHCP renewal, a VPS migration, a VPN — and then every rendered `AddHost=` points at an address
that no longer means this host. That drift is the thing the old design needed a re-check for; the
pin deletes the failure mode instead of watching for it.

## What it costs, stated plainly

**The trade is a constant for a per-host verification, and the constant wins because the
verification could not run.** The cost is real and it is named here rather than discovered: with
`ingress.alias` written from the configuration, **no host-side check can tell a working mapping
from a broken one.** A host with a wrong mapping keeps a plausible `guarden.toml` and a green
`soil --check`; the first symptom is a consumer whose connection to `<provider>:10.0.2.2` reaches
nothing — a 502 at the edge, a refused connection inside a container — and nothing in guarden's
reporting says why.

**What catches it.** Three things, and none of them is a per-host measurement: the golden VM's
criterion (the canary above), which fails the first time podman or pasta changes the mapping's
meaning; the on-link overlap warning, for the one host state that can collide with the reserved
range; and the validation, which refuses a set that cannot be the pinned one. The set itself is
one root-owned line, reviewed as one.

## The consequences

**The migration.** An existing host keeps the `pasta_options` it was installed with, and the
validation **refuses it** — exit `2` naming `[network] pasta_options` — until the operator
replaces the set with the pinned one. Updating the set and running `soil install --apply`
rewrites `ingress.alias`; but the units already on the box were rendered with the **old** alias,
and a rendered `AddHost=` is re-rendered by nothing on its own. **Every service must be
re-deployed once** (or its consumers re-rendered), or its containers resolve their dependencies
to the old gateway. `docs/sysadmin.md` carries the section and the check that says it is done.

**`10.0.2.0/24` is reserved.** The pin writes the range once — `-a 10.0.2.100`, `-n 24`,
`-g 10.0.2.2` — and `ingress.alias` derives from it. An operator whose LAN already uses
`10.0.2.0/24` changes the range in that one place: the three values together in
`[network] pasta_options`, after which `soil install` derives the new alias. That is the whole
remedy, and it is why the warning exists.

## What did not happen

No probe and no probe image; no per-host measurement and no drift check; no change to the
publications, the default deny, the uid-matched rules, `AddHost=`'s shape or the loopback story.
The address changed from whatever the host's route happened to say to `10.0.2.2`, and nothing
else did.
