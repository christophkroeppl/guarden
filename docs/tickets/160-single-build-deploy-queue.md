# 160: on-VPS single-build deploy queue

**What to build:** Never more than one container build at a time on the VPS. Redeploy requests — from gitops (the GH Action pokes `hose`) and from manual redeploys of multi-service beds — enter one queue that is FIFO with production priority, debounced and deduped so repeated identical requests collapse into one build. `weedr redeploy --now` bypasses the queue for an operator who needs to jump it.

**Blocked by:** T80 (hose redeploy loop on manifest delete)

**Status:** ready-for-agent

- [ ] Requesting a second redeploy while a build is running queues it; the fake build binary's entries in the call log never overlap (one build at a time)
- [ ] Two queued production requests run before a queued staging request; within one priority the order is FIFO (call-log order matches request order)
- [ ] N identical redeploy requests for the same bed and ref inside the debounce window collapse into one build (the call log shows one build)
- [ ] A manual redeploy of a multi-service bed routes its changed services through the same queue, still serialised with gitops builds
- [ ] A gitops-triggered redeploy (the GH Action poke leads to `hose sync`) enters the same queue
- [ ] `weedr redeploy --now <bed>` runs immediately, bypassing queue position, and is visible as such in the call log
- [ ] A queued build that fails does not stall the queue: the next queued request still runs
- [ ] Queue state survives a `weedr` process exit between enqueue and run (a request enqueued while busy is built later)
- [ ] All of the above is verified at the CLI seam with the fast harness
