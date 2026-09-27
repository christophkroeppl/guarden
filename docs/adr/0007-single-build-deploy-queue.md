# One build at a time: FIFO with production priority

The VPS is small: two builds at once thrash CPU and disk, and a deploy racing another
deploy leaves half-written units. So container builds and deployments are serialized —
never more than one in flight.

The queue is FIFO, with production jumping the queue. Repeated pokes for the same bed and
revision debounce and dedupe, so a burst of pushes becomes one build. Both paths respect
it: `hose` (poked by the GitHub Action) and manual redeploys of a multi-service bed. The
operator can bypass it with `weedr redeploy --now`.

Why: order is predictable, production waits for nobody, and a single builder keeps the
box responsive while it runs.

Consequences: a long build delays the beds queued behind it, the last push in a burst is
the one that ships, and the queue state is a file we can read with `ls`.
