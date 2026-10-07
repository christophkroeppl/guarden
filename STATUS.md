# STATUS

**Last updated:** 2026-10-07
**Branch:** develop
**Commit:** 1dd6a03

## What's done and committed

| Commit | Description |
|--------|-------------|
| `1dd6a03` | fix(lineage): fork should not start units after swap |
| `52e7991` | fix(rules): DNS reply accepts belong in INPUT, not OUTPUT |
| `dc2ea02` | fix(firewall): DNS reply accepts in guarden-in, and _capture signal safety |
| `3238c93` | fix(tests): two measurements that read the wrong field and the wrong block |
| `685f406` | merge(220): the tunnel is a container, and the harness records failures |
| `1c8dfef` | fix(lxc): a failing suite was recorded as a pass |
| `f13935c` | docs(220): the ticket matches what was built |
| `be4e498` | fix(220): soil does not warn about a tunnel that is not installed |

## What's still broken

### t50-slice — the first real deploy

**Error:** `weedr service start routed-staging` exits 1 with:
```
error: routed-staging: systemctl start of the unit web exited 1: Job for web.service failed because the control process exited with error code.
```

**What we know:**
- The unit file is correct (ExecStart, Image, Network, PublishPort all present)
- The image `docker.io/library/nginx:1.27` is pullable (DNS works from root)
- The service user is `routed-staging` (uid 993)
- The container should bind `127.0.0.1:20003:80`
- `Network=pasta:--map-gw` is used
- The test runs: `weedr service ingest` → `roots sync` → `module add gate` → `service start routed-staging`
- The error is from `weedr`'s `_unit()` function which calls `systemctl --user --machine routed-staging@ start web`
- The real podman error is hidden behind the systemctl wrapper message

**What we've ruled out:**
- DNS resolution from service uid: WORKS (STUB=0->1, DENY=0->0)
- Firewall rules: CORRECT (stub accept above deny, reply accepts in INPUT)
- Unit file: CORRECT (verified by reading the generated file)
- Image pull from root: WORKS

**What we haven't verified:**
- Whether podman can start the container as the service user
- Whether the pasta network setup works in the test VM
- Whether there's a lingering container from a previous test run
- Whether the systemd user manager has the right environment

**Next steps:**
1. Run the test steps manually in a VM to see the real podman error
2. Check if `podman run` works as the service user with the same parameters
3. Check if there's a lingering container: `podman ps -a`
4. Check the systemd user manager journal: `journalctl --user -M routed-staging@ -xeu web.service`

### t70-fork — FIXED

**Commit:** `1dd6a03`
**Root cause:** The fork's `_swap` function called `service.start_units()` after cloning volumes, which started all declared units. The test expects units to NOT be active after a fork — the operator starts them manually.
**Fix:** Removed the `service.start_units(resolved.name, escaped)` call from the `_swap` function in `src/guarden/lineage.py`.

## Test suite status

| Suite | Status | Notes |
|-------|--------|-------|
| t50-slice | FAIL | podman start error (see above) |
| t70-fork | PASS | fixed in 1dd6a03 |
| t130-packages | PASS | fixed in 3238c93 |
| t180-firewall-rules | PASS | reply accepts don't break existing assertions |
| t220-tendril | PASS | merged in 685f406 |
| t221-cred-units | PASS | fixed in 198ba0f |

## VM state

- `guarden-golden`: RUNNING
- `infra-test-golden`: STOPPED
- `probe-c1`: STOPPED
- No test runs in progress

## Load

- 7.16 / 9.47 / 12.44 (1/5/15 min)
- 8 cores

## Subagent issues

All subagents dispatched for t50-slice debugging either:
- Looped on the same reasoning (re-reading the same files, repeating the same thoughts)
- Timed out waiting for model response

The t50-slice failure needs direct debugging by the main agent, not subagents.

## Remaining unimplemented tickets

| Ticket | Status | Blocked by |
|--------|--------|------------|
| 100-homepage-module | ready-for-agent | 40 (loom), 50 (modules) |
| 110-previews | ready-for-agent | 70 (state), 80 (edges) |
| 120-build-queue | ready-for-agent | — |
| 130-cloud-init | ready-for-agent | — |
| 140-golden-vm | ready-for-agent | — |
| 160-public-grants | ready-for-agent | — |
| 180-service-firewall-rules | ready-for-agent | — |
| 200-provisioned-golden | ready-for-agent | needs golden rebuild |
| 240-subvolume-mounts | — | — |
| 250-user-manager-generators | — | — |
| 260-stub-resolver-under-the-deny | — | — |

## How to resume

1. Check this file for current state
2. Run `git log --oneline -10` to see recent commits
3. Run `git status --short` to check for uncommitted changes
4. Run `/snap/bin/lxc list -f csv -c ns` to check VM state
5. To debug t50-slice: run the test steps manually in a VM and capture the real podman error
