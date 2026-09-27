# 160: on-VPS single-build deploy queue

**What to build:** Never more than one container build at a time on the VPS — one lane, the default. Redeploy requests — from gitops (the GH Action pokes `hose`) and from manual redeploys of multi-service beds — enter one queue that is FIFO with production priority, debounced and deduped so repeated identical requests collapse into one build. `weedr redeploy --now` bypasses the queue for an operator who needs to jump it. The lane count is a root-owned override: `weedr queue lanes <n>` (default 1) takes effect between builds and never kills an in-flight one, so the box can run two builds when it has headroom and drop back to one when it has not.

**Blocked by:** T80 (hose redeploy loop on manifest delete)

**Status:** ready-for-agent

- [ ] Requesting a second redeploy while a build is running queues it; at the default lane count the fake build binary's entries in the call log never overlap (one build at a time)
- [ ] Two queued production requests run before a queued staging request; within one priority the order is FIFO (call-log order matches request order)
- [ ] N identical redeploy requests for the same bed and ref inside the debounce window collapse into one build (the call log shows one build)
- [ ] A manual redeploy of a multi-service bed routes its changed services through the same queue, still serialised with gitops builds
- [ ] A gitops-triggered redeploy (the GH Action poke leads to `hose sync`) enters the same queue
- [ ] `weedr redeploy --now <bed>` runs immediately, bypassing queue position, and is visible as such in the call log
- [ ] `weedr queue lanes 2` lets two builds run concurrently and the call log never shows more than the configured count in flight; production requests still run before queued staging requests
- [ ] Lowering the lane count while builds are in flight never kills one: the new count applies when the running builds finish, and a following check sees it
- [ ] The lane count survives a `weedr` process exit (it is a root-owned file, not process state)
- [ ] A queued build that fails does not stall the queue: the next queued request still runs
- [ ] Queue state survives a `weedr` process exit between enqueue and run (a request enqueued while busy is built later)
- [ ] All of the above is verified at the CLI seam with the fast harness
