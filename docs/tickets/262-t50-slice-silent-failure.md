# 262: t50-slice.sh fails silently, and its deny assertion is racy

**Blocked by:** nothing. **Blocks:** nothing today; it makes `just test` red, so it blocks
any release gate that runs the whole suite.

**What to build:** Nothing. This ticket records a defect found while three parallel agents
were working tickets 220, 240 and 261, and could not be diagnosed inside any of them
because it is not any of their bugs.

## What was found

`tests/t50-slice.sh` is **red on `develop` itself**. Verified by running it in the throwaway
VM from the `develop` worktree with no agent changes applied — it fails identically. Two
agents were spending hours re-running it, each reading the failure as their own regression.

### Fault one — a swallowed newline (fixed, `2f899dd`)

Line 265 read:

```sh
assert_mode /var/lib/guarden/edge/dynamic 2750# **The manager generates it.** ...
```

Bash treats `2750#` as part of the word, so `#` never opens a comment and `assert_mode` was
handed `2750# **The manager generates it.** ...` as its mode argument. Introduced in
`06d79d4` ("test(250): the manager DOES generate the unit"), which swallowed the newline.

### Fault two — a silent death under `set -e`

With fault one fixed, the suite **still fails, printing nothing**. It dies immediately after
the `OTHER_DENY=0->1` echo. `lib.sh` turns on `set -e` so a failed assertion ends the file
where it failed, which is right — but a *bare* command returning nonzero ends it with no
message at all, and the runner then reports `FAIL t50-slice.sh` with no diagnostic anywhere.

**This is the more expensive fault.** A suite that fails loudly costs one run; a suite that
fails silently costs the hours it just cost, because the only visible signal is a `FAIL`
line with nothing under it.

## The red herring, and why it cost what it did

The suite echoes, to stderr, before it fails:

```
STUB=0->1 DENY=0->0
OTHER_DENY=0->1
```

**That line passes all three of its assertions.** `stub 0->1` is the accept taking the
packet; `deny 0->0` is the packet *not* being dropped, which is what that half asserts; and
`OTHER_DENY 0->1` is the deny still refusing a loopback destination other than the stub. It
reads like a failure because `DENY=0->0` looks like "nothing happened", and two agents read
it as the cause and re-ran the suite nine times between them.

If a diagnostic line is going to be mistaken for a failure this easily, it should be on
stdout as a labelled value rather than an unlabelled `DENY=0->0` on stderr, or the assertion
text should be printed next to it.

## A third observation, unresolved

On `develop` the deny counter reads `0->0` and the assertion passes. On the ticket-240
branch at the same line it read `0->4` and failed with:

```
error: the stub was dropped, so the accept is not above the deny
```

One UDP datagram to `127.0.0.53:53` cannot produce four dropped packets. The likely reading
is that the assertion is **racy**: `deny_packets()` sums the counter on a rule that every
loopback packet from that uid touches, so any concurrent traffic from the service user
(systemd-resolved's own retries, a health check) moves it. **This is a hypothesis and was
not tested.** It is recorded here rather than asserted, and it is the first thing to check.

## Acceptance

- The suite names the command that failed. A bare nonzero under `set -e` is either given a
  diagnostic or made explicit, so no future run can fail with an empty stderr.
- The deny assertion either proves the packet it sent is the one counted, or is written so
  that concurrent loopback traffic cannot move the counter under it.
- `t50-slice.sh` is green on `develop` with no branch applied.