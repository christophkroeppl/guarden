# One build at a time: FIFO with production priority

The VPS is small: two builds at once thrash CPU and disk, and a deploy racing another
deploy leaves half-written units. So container builds and deployments are serialized —
never more than one in flight. A build is a rootless `podman build` run as the bed user
from the poked source (ADR-0010).

The queue is FIFO, with production jumping the queue. Repeated pokes for the same bed,
ref, and sha debounce and dedupe, so a burst of pushes becomes one build. Both paths respect
it: `hose` (poked by the GitHub Action) and manual redeploys of a multi-service bed. The
operator can bypass it with `weedr redeploy --now`.

One lane is the default, but the lane count is an admin override, not a code change: it
lives in one root-owned file beside the queue state, and `weedr queue lanes <n>` sets it.
The new count applies between builds — adding a lane starts the next queued build sooner;
removing a lane drains and never kills an in-flight build. With several lanes nothing
else changes: production still jumps to the front of whichever lane frees up first,
per-lane order stays FIFO, and debounce and dedupe still collapse a burst into one build.
Scaling the lane count from VPS load — add a lane when the box has headroom, drop one
when it has not — is the backlog; the override is how we get there without re-litigating
the default.

Why: order is predictable, production waits for nobody, and a single builder keeps the
box responsive while it runs.

Consequences: a long build delays the beds queued behind it, the last push in a burst is
the one that ships, and both the queue state and the lane count are files we can read
with `ls`.
