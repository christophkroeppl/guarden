# hyphae is loopback ports and host names, not a podman network

Rootless podman networks are per-user: a `bed-*` user cannot join another user's podman
network, and user-scope units stay isolated. A shared L2 network is impossible without
giving up rootless multi-user podman.

We define **hyphae** as a contract, not a network: shared services publish on
`127.0.0.1`, `weedr` writes stable names (`<pond>.internal`, `bed-<name>.internal`) into
`/etc/hosts`, and beds reach them over the host loopback with `pasta`. No new daemon,
per-bed isolation intact. Hyphae is optional — a bed that talks to no shared service
needs none.

Isolation is per group. Each pond group owns its own loopback block (`127.1.<g>.<n>`),
and ferm OUTPUT rules matched on `uid-owner` let only that group's member bed users reach
the block; database roles are the second layer inside it. A bed outside the group cannot
open the port at all.

Considered: a rootful shared network for the shared tier (mixed privilege), one shared
network namespace (kills per-bed isolation).
