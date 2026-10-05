# Ticket 190's remaining proof, as a procedure — not yet run

**Status: the two open boxes both need VM runs, and the box is not in a state to
produce an honest result.** This note is the procedure, written while the machine was
busy so that it is a command to run rather than a plan to reconstruct.

## Why it is not run yet

At the time of writing:

```
$ cut -d' ' -f1-3 /proc/loadavg
1293.00 1174.19 684.45
$ vmstat 1 2 | tail -1
... 53 %us  46 %sy   0 ni  196 id  800 in 53 46 ...
```

**53 % iowait, 46 % idle, no D-state processes.** That is not CPU contention — it is
storage. Load average 1293 with the CPU idle is a box waiting on I/O, and it means a
suite failure right now would be indistinguishable from contention.

The standing rule is: *a failure count that changes between identical runs is
contention, not a finding.* Running the dual-order proof in that state would produce a
number nobody could interpret, and it would also corrupt the three suites the parallel
agents are running on their own runners.

## The group

The 18 suites that declare `# machine: shared`:

```
t10-alias.sh  t10-golden-vm.sh  t10-help.sh  t10-imports.sh  t10-no-fakes.sh
t30-parsers.sh
t40-converter.sh  t40-edges.sh  t40-manifest.sh  t40-mounts.sh  t40-parsers.sh
t40-refusals.sh  t40-render.sh  t40-volumes.sh
t170-zram-parsers.sh  t170-zram-refusals.sh  t170-zram-userdata.sh
t210-cache-suite-results.sh
```

`t40-untrusted.sh` is **not** in the group — it declares nothing, so it is `fresh` by
the safe default, and it was under repair while this was written.

## What has to be run

**The shared group, forward.** `--shared` forces one machine for the whole group, so
every suite after the first inherits whatever the earlier ones left behind. This is the
adversarial direction: a contaminated suite shows up here.

```
GUARDEN_LXC_SUITE_TIMEOUT=900 GUARDEN_LXC_RUNNER=guarden-190 \
  tests/lxc.sh run --shared --no-cache > /home/rumlyne/.cache/scratch/190-fwd.txt 2>&1
```

**The same group, reverse order.** `--reverse` runs the same files in the opposite
order on a fresh cut. This is the half that matters: a suite that silently depends on
something an earlier suite installed fails here and nowhere else.

```
GUARDEN_LXC_SUITE_TIMEOUT=900 GUARDEN_LXC_RUNNER=guarden-190 \
  tests/lxc.sh run --shared --reverse --no-cache > /home/rumlyne/.cache/scratch/190-rev.txt 2>&1
```

**Both must be identical.** The claim is not "the suites pass" — several are red for
other reasons — it is **"the result does not depend on the order"**. So compare:

```
diff <(grep -E '^(ok|FAIL)' /home/rumlyne/.cache/scratch/190-fwd.txt | sort) \
     <(grep -E '^(ok|FAIL)' /home/rumlyne/.cache/scratch/190-rev.txt | sort)
```

Empty diff is the proof. A non-empty one names the contaminating suite directly: the
suite that is green in one order and red in the other.

**Then the whole suite green before and after**, with the wall clock of each run
recorded either side — that is the second open box, and it is the one that makes the
claim worth anything, because sharing is only worth it if it is not slower.

## What would falsify it, and what to do

A suite that is order-dependent is not a test-harness bug to be papered over: it is a
suite declaring `# machine: shared` while touching host state, which is exactly what the
declaration is for. The fix is to remove the declaration, not to reorder or to
`|| true` the failure. If a suite genuinely needs a clean host and says `shared` to get
a cheaper run, that is the bug this proof exists to find.

## The cache is not part of this

`--no-cache` is deliberate and it is what makes the comparison honest. With the suite
cache on, an inherited result in the second run could be a *cache hit* rather than a
clean machine, and "the order does not matter" would then be a statement about the
cache rather than about contamination.
