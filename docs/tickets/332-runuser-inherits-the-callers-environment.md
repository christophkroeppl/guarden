# 332 — the `runuser` call sites inherit the caller's environment

Blockers: none. Found 2026-10-20 by the first of the ten security reviews
(`nous/longcat-2.5-preview-free`, F4) — and it is the SAME defect as ticket
321, found independently, so the two are one piece of work.

## What the review says

> **F4 — `runuser` sites that inherit the caller's environment (already ticket
> 321, still unapplied)**
> **LOW-MEDIUM — denial of service, not escalation.** Confirmed still present at
> every podman site the ticket lists.

The review's severity is LOWER than ticket 321's, and the reasoning is worth
keeping: a wrong `USER` gives a container FEWER privileges inside it, not
more, so the defect is a denial of service on the build path rather than a
privilege escalation. The ticket is not closed by that — a build that fails is
a build that fails — but the finding should not be described as an escalation.

## The seven call sites

```
credentials.py:224,227  runuser -u <name> -- podman secret create <key> -  ← unsanitised
edges.py:265            runuser -u <provider> -- podman <argv>             ← unsanitised
service.py:1578         runuser -u <name> -- env USER=… LOGNAME=… XDG_RUNTIME_DIR=… podman   ← THE ONE THAT SCRUBS
units.py:67             runuser -u guarden -- loom …                      ← unsanitised
weedr.py:880            runuser -u <service> -- podman …                   ← unsanitised
weedr.py:1467/1487      runuser -u guarden -- …                           ← unsanitised
```

`runuser -u` **swaps the uid and keeps the caller's environment**, and the
caller is root. So every one of the six unsanitised sites sees `USER=root`,
and podman's keep-id mapping reads the subid files keyed by that name.

## What to build

Give every one of them the scrub `service.py:1578` already has — `USER=`,
`LOGNAME=` and `XDG_RUNTIME_DIR=` named for the account the command runs as —
and make it the ONE place a `runuser -u` command is built, so a second call
site cannot miss it. The two paths today are the same shape written twice, and
one of the two has the fix.

**The manager wait is a separate question and is NOT part of this ticket.**
`/run/user/<uid>` comes up asynchronously after the ingest, and a build that
lands before it dies in the window above. Whether the mutator waits for it,
retries, or names the cause in its own diagnostic is a decision this ticket
does not make.

## The test that would have caught it

A test that runs `weedr service build` and asserts the build container's
`/proc/self/uid_map` contains the service's subuid range. That test is **not
vacuous**: it measures the actual mapping, not the presence of a
configuration value.
