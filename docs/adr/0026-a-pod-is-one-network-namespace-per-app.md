# A pod is one network namespace per app, and it is not a shared network

A repository may hold several apps, and each app is a service of its own (§4, §5.3). Two things
follow that the contract did not answer, and this decision answers both.

The first is **a name inside one app**. Every container of a service ran in its own pasta
namespace, so a container could not reach a sibling container except through the host's loopback
and its allocated publication; that is why §7.3 has a name map with a port translation in it
(ADR-0023). It is a workable mechanism, and it exists because of an accident of how pasta is
invoked rather than because anything needed the isolation.

The second is **a Compose file that declares `networks:`**. Guarden refused it, by name, on the
grounds that the network it names does not exist on a guarden host (§6.3). That refusal was right
about the fact and wrong about the consequence: the declaration a real repository actually writes
— "these two containers may talk" — is a fact about the repository, and guarden had no answer for
it but a refusal and a name map.

## Status

accepted (2026-10-22). Supersedes the "no shared podman network" line as an absolute: AGENTS.md
carries it in two places and §6.3 stated the refusal of `networks:`, and this decision replaces
all three with the bounded form — no network *between services*, one namespace *inside* one.
Narrows ADR-0023's "one repository is one service", which becomes "one app is one service", and
leaves ADR-0019's user-namespace pin intact on the unit that now carries it.

## The decision

**The containers of one app run in one network namespace, and that namespace is called a pod.**
There is exactly one pod per app. Its name is the manifest's `[pod] name`, and with no such key it
is the service's **workload** — `<project>` for the app at the tree root, `<project>-<app>` for a
named app — so a single-app repository's pod is named after its project exactly as its service is,
and two apps of one repository cannot collide.

The pod is a unit of its own in the service's own quadlet directory — `<pod>.pod` — and each
container unit of the app carries `Pod=<pod>.pod`. The **pasta backend moves to the pod**: the pod
unit carries the pinned `[network] pasta_options` on `Network=pasta:`, and a member container
carries no `Network=` line at all, because podman refuses the two together and the namespace is
the pod's (§6.3). `AddHost=` stays where it is — on the member container units — because
`/etc/hosts` is the container's file and not the namespace's, so every name §7.3 writes still
resolves, to the same address, for the same reason.

**`networks:` is pod membership, and the only pod there is belongs to the app.** A document-level
`networks:` table is accepted when its only key is the pod's name and it states no options, and a
service's `networks:` list is accepted when it names the pod. Every other name is refused by name,
exit `2`, on the repository's own declaration and before the converter is driven. That is the
refusal this decision *keeps*: a name that cannot be granted must not silently do nothing, and a
name that is not this app's pod is a name guarden cannot give it.

## What the pod is not

Four things it is not, because each of them would be the boundary change the old rule was written
against:

- **It is not a network any other service can join.** A pod carries the containers of one app and
  nothing else: the unit source is the service's, the pod unit is written into the service's own
  quadlet directory, and there is no key — in a manifest, an `overrides.toml`, a module or a poke
  — that names another service's container as a member.
- **It is not a host-wide or cross-service address space.** Two services still have two pods in
  two user managers, two uids, and two sets of publications. The only address that reaches the
  host from either is the pinned gateway `10.0.2.2`, mapped by pasta to the host's `127.0.0.1`,
  where the uid-matched accept set and the default deny (§7.6) are exactly what they were.
- **It is not a name map.** A shared namespace gives a container a loopback it does not share with
  the host; it gives it no name service. Names are still `AddHost=` entries the renderer writes,
  and the port a repository reads is still the publication (§7.3).
- **It is not where a port is granted.** Publications are allocated per container and persisted in
  the registry exactly as before (§7.4); the pod publishes them, because podman binds a pod's
  ports on the pod, and the host-side set is unchanged — `127.0.0.1:<publication>:<container
  port>`, one per container, with the same accept set.

## The isolation property that is traded

**Per-container network isolation inside one service.** Before this decision each container of a
service had its own pasta namespace, so one container's `127.0.0.1` was not another's: reaching a
sibling meant leaving the container, arriving at the host's loopback, and coming back in through
the sibling's publication — which is a real, if thin, separation. After it, the containers of one
app can dial each other's ports on the pod's loopback, and a container can bind a port another one
expected.

It is traded knowingly, and it is the *only* thing traded. Everything else the containers of one
service already share, by decision rather than by accident: one uid, one `0700` home, one podman
secret store, one image store, and the same trust domain — §5.2 states that argument at length for
instances, and it applies unchanged to the containers of one service. A container was never
isolated from its siblings in the way that matters: it can read every secret the service holds and
it runs as the same user. The per-container namespace never enforced anything between them; it
only made the supported path (a publication and a name) the only path.

Nothing between services moves. The boundary this platform actually has is the per-service uid and
the `0700` on its tree, and a pod sits entirely inside it.

## Why one pod and not one per declared network

Compose's `networks:` can express a partition — these two containers together, that one apart —
and that partition could be translated into two pods. It is refused, because a second network
namespace inside one service is a boundary that does not exist anywhere else in the design:

- the containers of one app share one uid, one home and one secret store, so a container in pod A
  can read everything a container in pod B can read, and the namespace between them protects
  nothing;
- a distinction that its own mechanism cannot enforce is the shape this repository retires
  everywhere else, and a second namespace would read as isolation to an operator who then relies
  on it;
- and every extra pod is another unit to order, another object in a user manager, and another
  place a publication can be spent, for a property that is not one.

So the connectivity a Compose file asks for — "these containers may talk" — is granted in full by
the one pod, and a file that names two networks is naming a distinction guarden will not pretend
to make. A container in two pods is likewise not expressible, because a container has one
namespace.

## What is still refused

- **A `networks:` name that is not the app's pod**, in either vocabulary, by name and with the pod
  named in the diagnostic.
- **Options on a `networks:` entry** — `driver:`, `ipam:`, `external:`, `internal:`,
  `attachable:`, `labels:` — because each describes a network, and there is no network.
- **A pod as repository input.** `Pod=` in a hand-written quadlet unit is refused as a directive
  the renderer owns, exactly as `Userns=` is, and a `.pod` unit file in a repository's
  `.guarden/quadlet/` is refused for the same reason: the pod's name and its membership come from
  the manifest and the source's own containers, and a repository that could ship the unit could
  put a second service's container in it.
- **`network_mode: service:<container>`**, which becomes a meaningful spelling of namespace
  sharing the moment a namespace can be shared. It joins the list `network_mode: host` and
  `network_mode: container:` are on, and for the same reason: the namespace is the renderer's.
- **Everything the old rule protected.** `network_mode: host`, a non-pasta backend, a bind of a
  host path outside the service's own tree: unchanged, and `Privileged` still refused.

## The measurement this rests on

The pod is the mechanism only if two things hold on a real machine, and neither had been measured
when this was written:

1. **The pinned option set applies to a pod.** The pod's namespace is the one pasta is attached to,
   so the container's default route is still `via 10.0.2.2` and the host is still reachable at
   `10.0.2.2:<publication>`. If pasta's options cannot be applied to a pod, the pod is not the
   mechanism and this ADR is superseded rather than amended — the fallback is the per-container
   namespace with the name map, which is what the host runs today.
2. **ADR-0019's user-namespace pin works inside a pod.** The pin is `keep-id:uid=…,gid=…` rendered
   from the image's probed user, and in a pod it belongs to the pod's namespace rather than to each
   container's. If the pin cannot be expressed on a pod, the same fallback applies.

The decision is therefore made before the measurement and is conditional on it, which is the
honest order for a contract: the alternative is code that discovers the requirement after the spec
has stopped describing it.

## What this costs

- **One more unit per service.** A pod is a systemd unit, so start order grows an edge: the pod
  starts before its containers and stops after them, and a pod with one container is still a pod
  because the unit source may grow a second one without the render changing shape.
- **A publication is published by the pod, not by the container.** The registry and the firewall
  see no difference; the place the `PublishPort=` line lives changes (§7.4).
- **The specification carries one exception where it carried an absolute.** "No shared podman
  network" becomes "no network between services, and one namespace inside a service". That is a
  weaker sentence, and it is the true one: a document that states an absolute the code breaks is
  the false green this repository pays for most often.
