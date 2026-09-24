# hyphae is loopback ports and host names, not a podman network

Rootless podman networks are per-user. A `bed-*` user cannot join another user's podman network. Every candidate that looked like "shared networking for rootless multi-user podman" was either rootful (Docker, Swarm, Coolify, Dokploy) or a no-op (user-scope quadlet units stay isolated and fall back to `pasta`/`host`).

We therefore define **hyphae** as a contract: shared services publish on `127.0.0.1`, `weedr` writes stable names (`pond.internal`, `bed-<name>.internal`) into `/etc/hosts`, and beds use `pasta` to reach the host loopback. No shared L2 network, no new daemon, per-bed isolation intact.

Considered: rootful shared network for the shared tier only (more moving parts, mixed privilege), one shared netns (kills per-bed isolation), everything rootful (becomes Docker).
