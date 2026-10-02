# 210: cache suite results, so an unchanged suite is not re-run

**What to build:** `just test` re-runs all 39 suites after a one-line change. A suite's outcome is
a function of two things — the golden it was cut from, and the tree it was run against — so it
can be keyed and reused. After touching one file, a run should run one suite and **inherit** the
other 38, saying so out loud rather than pretending it ran them.

**Blocked by:** 190 (which suites share a machine), 200 (a stable golden), **and a green suite**.
The last one is the real blocker and it is not a formality: see below.

**Status:** ready-for-agent, deliberately **last**

- [ ] The key is a hash of the **golden snapshot's identity** and the **repository tree** the
      suite reads. If the golden is rebuilt, every cached result is invalid and the cache says so
      rather than answering from a machine that no longer exists
- [ ] A cached suite prints something that cannot be mistaken for a fresh pass — it is
      **inherited green, not observed** — and a full run states how many suites ran and how many
      were cached. An operator must never be able to read a cached run as a verification
- [ ] `--no-cache` forces everything to run, and it is what a release gate uses. There is no
      automatic expiry: an expiry would make a run's meaning depend on a clock
- [ ] The cache is **outside the repository** and is disposable. It is not a build artefact that
      gets committed and not a claim about the host

## Why this is last, and the condition on it

A cache inherits a result. That is only honest when the result is **deterministic**, and this
suite stopped being deterministic three times in one day, each time for a different reason:

- the golden's cloud-init held apt's locks while suites called `soil packages --apply`, so seven
  suites failed or passed depending on boot timing (ticket 200 is the fix)
- two `just test` runs shared the single runner instance, so suites were re-cut underneath a
  running test and failed **with no diagnostic at all**
- `timeout` around `lxc exec` put the child in a new process group, which wedged LXD's agent
  session and produced failures that were not failures

Each of those would have been *cached* rather than fixed, which is the worst outcome available:
a permanent green that nothing earned. **Build this after a suite that passes when run twice,
and after 190 and 200 have made a run cheap enough that caching saves real time rather than
hiding real work.**