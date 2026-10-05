#!/usr/bin/env bash
# Ticket 120, the deploy order: ensure, render, build, gate, stop, install,
# start — in that order, with the build and the gate both before the stop, and
# **a blocked gate leaving the deploy succeeding** (spec 6.6, ADR-0011).
#
# **`GUARDEN_PREFIX=/` and the machine's own tools**, the way `t30-create`,
# `t60-gate` and `t80-edges` already do. These are real services: a real
# `useradd`, a real uid, a real home, a real delegated `/etc/subuid` range and
# real btrfs subvolumes. `weedr service ingest` reads back the database it
# promised to be written to, so a staged `/etc/passwd` reconciled with that
# reports a uid no account carries — a true sentence about two databases and a
# fact about no service.
#
# **What this host can and cannot answer, stated once.** No container of these
# services has ever run here, so "the container running before the deploy is
# still running" is not a fact this machine holds, and an assertion about it
# would pass whatever furrow did. What *is* a fact here: the order the steps ran
# in, the exit code of each outcome, the verdict the mutator recorded in the
# registry, and the requests still on disk. Sampling a build for overlap and
# sampling a container for survival are the golden VM's work (ticket 140).
#
# machine: fresh

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GUARDEN_PREFIX=/

install -d -m 0770 -o root -g guarden /var/lib/guarden/queue
# `guarden-measured.toml` rather than `guarden.toml`: this project's manifest
# declares a `needs:`, so its units carry `AddHost=` and the renderer refuses an
# empty `ingress.alias` (spec 6.3). `t60-gate` makes the same choice.
ensure_accounts
stage_config guarden-measured.toml

# `soil install` is this suite's precondition and not its subject: the deploy
# reaches the mutator and the renderer at the paths that phase installs them,
# and a test driving a copy in the checkout would test something no host runs.
stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_not_rejected
assert_file_exists /usr/lib/guarden/bin/weedr
assert_file_exists /usr/lib/guarden/bin/loom
assert_file_exists /var/lib/guarden/render

# The `gate` module is what creates the edge service every `needs:` in this
# project's manifest resolves against; nothing ingests it.
run weedr module add gate
assert_exit 0

registry=/var/lib/guarden/registry
queue=/var/lib/guarden/queue

# The provider this project's manifest declares a `needs:` on, staged and
# ingested first. A poke creates services in dependency order, and the renderer
# refuses an edge whose provider has no registry entry — so without this the
# render below would fail for a reason that has nothing to do with the order.
stage_poke pgprov 9f2c1ab
run weedr service ingest postgres-staging --from poke pgprov@9f2c1ab
assert_exit 0
assert_file_has "$registry/postgres-staging.toml" 'kinds = ["db", "secret"]'

# The staged tree, copied out of the fixture the way `t60-gate` does it: a
# poke's own repository content, staged where the mutator resolves it from.
stage_qapp() {
    local sha=$1
    local staged=/var/lib/guarden/staging/qapp/$sha
    mkdir -p "$staged/.guarden/quadlet" "$staged/.guarden/widgets"
    cp "$GUARDEN_ROOT/fixtures/projects/quadlet-app/.guarden/service.yml" \
       "$staged/.guarden/service.yml"
    cp "$GUARDEN_ROOT/fixtures/projects/quadlet-app/.guarden/.env.schema" \
       "$staged/.guarden/.env.schema"
    cp "$GUARDEN_ROOT/fixtures/projects/quadlet-app/.guarden/quadlet/"*.container \
       "$staged/.guarden/quadlet/"
    cp "$GUARDEN_ROOT/fixtures/projects/quadlet-app/.guarden/widgets/web.yml" \
       "$staged/.guarden/widgets/"
    chmod -R a+rX "$staged"
}

stage_qapp 9f2c1ab
# A second commit whose unit source asks for an image to be built. `BuildContext`
# is a build instruction in the unit source's own vocabulary, which is where the
# question is decided: a deploy of a source that declares none makes no build
# call and waits for no lane.
stage_qapp 8a1d2f0
printf '%s\n' 'BuildContext=.' >> \
    /var/lib/guarden/staging/qapp/8a1d2f0/.guarden/quadlet/web.container

# --- step zero: the poke creates the service, and the mutator is the verb -----

# A poke names a service the box has never heard of, and `weedr service ingest`
# brings it into being — a verb with no flag on it that could grant a port,
# because the grant is the separate verb `weedr port open` and `furrow` may not
# run it.
run furrow deploy qapp-production --from poke qapp@9f2c1ab
assert_exit 0
assert_passwd qapp-production
assert_file_exists "$registry/qapp-production.toml"

# --- a blocked gate is a state, not a failure -------------------------------

# LOG_LEVEL is required — `@defaultRequired=infer` makes a key declared with a
# value required — and nothing plants it, so the gate is blocked. DB_PASSWORD is
# also required but a `database` edge mints the consumer's copy at ingest. The deploy **exits 0**: the service exists, its units are
# installed and it is waiting, and one `warning:` says why. A red X on every push
# until the operator plants credentials is noise, and noise teaches people to
# want the gate gone.
assert_one_diagnostic "warning:"
assert_stderr_has "credential gate"
assert_file_has "$registry/qapp-production.toml" 'state = "blocked"'
assert_file_has "$registry/qapp-production.toml" "missing required key: LOG_LEVEL"

# **The order is the point, and it is asserted as an order.** The step names
# appear on stdout in this sequence, and the journal carries the same lines.
#
# `stop` IS in the alternation even though this deploy must not reach it: with
# `stop` left out of the pattern, a stop that ran between the gate and the
# install would still produce `[ensure,render,build,gate,install]` and this
# assertion would pass on a deploy that violated the order it exists to prove.
order=$(grep -oE '^(ensure|render|build|gate|stop|install|start) ' "$GUARDEN_STDOUT" \
    | tr -d ' ' | tr '\n' ',')
want="ensure,render,build,gate,install,"
[ "$order" = "$want" ] || _fail "the deploy ran [$order], expected [$want]"

# **The stop never ran.** It sits between the gate and the install, and a blocked
# gate stops the sequence before it — which is the whole of "a failed build or a
# blocked gate leaves the running container running", and here it is visible in
# what was printed rather than in a container nobody has started.
# The padding is the assertion: `_step` writes `f"{name:<7} {detail}"`, so a
# step name is padded to seven columns and then followed by ONE space. A token
# written with the wrong number of spaces can never appear in stdout, so
# `assert_stdout_lacks` passes on a deploy that DID run the step.
assert_stdout_lacks "stop    qapp-production"
assert_stdout_lacks "start   qapp-production"

# --- a source with no build instruction makes no build call ------------------

# The `9f2c1ab` tree declares no `Build*` key, so the deploy above made no build
# call and therefore waited for no lane. A deploy that pulls a prebuilt image
# competes for no resource with anything and does not go behind one (ADR-0010).
#
# **This is asserted here, above the `weedr service gate` run below, because
# `run` overwrites the captured stdout.** Asserted after it, the assertion would
# read the gate verb's stdout, which carries no step lines at all, and would
# pass on a deploy that DID make a build call.
assert_stdout_has "no build instruction, so no build call"

# The verb itself answers `1` about the same condition, and the deploy converted
# nothing: `weedr service gate` was asked whether it could start and it cannot,
# it changed nothing, and the deploy reads the verdict it recorded and branches.
run weedr service gate qapp-production
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "cannot start"

run furrow status --json
assert_exit 0
assert_json in_flight 0

# --- a failing build exits non-zero and stops at the build -------------------

# The `8a1d2f0` tree carries `BuildContext=`, so the build step is
# `weedr service build <name>` — the mutator verb, with no `--from`, because a
# build has exactly one tree it may build and it is the service's own. That verb
# has no body yet and `t10-help.sh` asserts so, so it answers non-zero; what is
# under test here is the branch, which is the one a broken Dockerfile takes.
before=$(sha256sum "$registry/qapp-production.toml" | cut -d' ' -f1)
run furrow deploy qapp-production --from poke qapp@8a1d2f0
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "build"
# Nothing after the build ran. A failed build is the first of the two ways a
# deploy can fail while the old container is still serving.
assert_stdout_lacks "gate   qapp-production"
# The padding is the assertion: `_step` writes `f"{name:<7} {detail}"`, so a
# step name is padded to seven columns and then followed by ONE space. A token
# written with the wrong number of spaces can never appear in stdout, so
# `assert_stdout_lacks` passes on a deploy that DID run the step.
assert_stdout_lacks "stop    qapp-production"
assert_stdout_lacks "start   qapp-production"
after=$(sha256sum "$registry/qapp-production.toml" | cut -d' ' -f1)
[ "$before" = "$after" ] || _fail "a failed build changed the registry of qapp-production"

# The failure is kept and readable. A request that dropped its file on the way
# out would be a failure nobody could read with `furrow queue list`.
assert_file_exists "$queue/qapp-production@8a1d2f0.json"
run furrow queue list
assert_exit 0
assert_stdout_has "qapp-production"
assert_stdout_has "8a1d2f0"
assert_stdout_has "last failure:"
run furrow queue show qapp-production
assert_exit 0
assert_stdout_has "8a1d2f0"

# --- a failed build does not stall the queue ---------------------------------

# The next request runs: a failure retires its own request and takes nothing
# else with it. This one is the same commit again on another track, so it is a
# second request and not a second build of the first.
run furrow deploy qapp-staging --from poke qapp@8a1d2f0
assert_exit 1
assert_passwd qapp-staging
# Inside `if` because `grep -c` exits 1 on no match and `set -euo pipefail` is
# on: a bare assignment would kill the suite on the count of zero, which is
# exactly the case this assertion exists to catch.
one=0
if two=$(ls -1 "$queue" | grep -c '^qapp-staging@8a1d2f0.json$'); then
    one=$two
fi
[ "$one" = 1 ] || _fail "the queue holds $one files for one service and sha, expected 1"

# --- lanes bound builds, and `deploy-<service>` bounds deploys ---------------

# **The two are different hazards with different mechanisms**, and this is the
# whole of the distinction: the lane count is read out of the root-owned table
# on every claim, while `deploy-<service>` is an flock file whose NAME is the
# claim. A deploy that pulled a prebuilt image took no lane at all (the step
# line above says so) and still left a `deploy-qapp-production.lock` behind,
# because the file is created by the lock itself and outlives the process.
#
# What this does NOT assert is that two deploys of one service cannot overlap:
# that needs two real containers and a real running unit to interrupt, which is
# the golden VM's work (ticket 140). What it does assert is the mechanism, so
# a future refactor that replaced the flock with a lane counter would be caught.
assert_file_exists /run/guarden/locks/deploy-qapp-production.lock
assert_file_has /etc/guarden/guarden.toml "lanes = 1"
# A prebuilt-image deploy is not queued: its request file is gone, because it
# succeeded. A request that dropped its file on failure would be unreadable, and
# one that dropped it on success is the drainer's contract with the `.path`
# unit (spec 6.9).
assert_file_missing "$queue/qapp-production@9f2c1ab.json"
assert_file_exists "$queue/qapp-production@8a1d2f0.json"

# --- the lock is on tmpfs and the request file is not ------------------------

# `deploy-<service>` is the file one deploy of one service holds from its first
# step to its last, and it lives under `/run` because a lock that outlived the
# process that took it would only be a stale lock. The request file lives under
# `/var/lib`, because a request acknowledged before a reboot must still be built
# after one. Two directories, two filesystems, and the paths are the claim.
assert_file_exists /run/guarden/locks/queue.lock
assert_file_missing /var/lib/guarden/locks
run mount
assert_exit 0
assert_stdout_has "on /run type tmpfs"

# --- an instance is deployed as an instance, and its ref is escaped -----------

# A `kind = "instance"` track deploys one instance per ref, so a deploy names its
# ref, and the ref in the request file and in the deploy lock is the escaped
# form: a raw one may contain a `/`, and a file named after one is a path that
# does not exist.
run furrow deploy qapp-preview/feature/login --from poke qapp@9f2c1ab
assert_file_has "$registry/qapp-preview.toml" '[instances."feature\\x2flogin"]'
assert_file_has "$registry/qapp-preview.toml" 'ref = "feature/login"'
assert_file_exists "/run/guarden/locks/deploy-qapp-preview-feature\\x2flogin.lock"

# A deploy of a preview service with no ref names no instance, and one on a
# `kind = "slot"` track is refused the same way: the track says what a name may
# carry, and a repository does not get a say in it.
# Both of these name a staged tree that exists and a service that may exist, so
# neither refusal is about the tree: each is the track saying what a name may
# carry, which is rejected input and exit 2.
run furrow deploy qapp-preview --from poke qapp@9f2c1ab
assert_exit 2
assert_stderr_has "instance"
assert_file_missing /run/guarden/locks/deploy-qapp-preview.lock
run furrow deploy qapp-production/feature-login --from poke qapp@9f2c1ab
assert_exit 2
assert_stderr_has "slot"
assert_file_missing /run/guarden/locks/deploy-qapp-production-feature-login.lock