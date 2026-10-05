#!/usr/bin/env bash
# Ticket 120, the queue: a request is a service, a ref and a sha, the state is a
# directory of files under /var/lib/guarden/queue so `ls` answers what is
# waiting, priority is the track's `weight`, and `--now` moves one request to the
# front without moving anybody else.
#
# **Every assertion below is a question to the machine**: the mode and owner of
# the queue directory, `ls` on it, the exit code and the one diagnostic line each
# verb wrote, and the JSON `furrow queue list --json` printed. Nothing is read
# out of a record of what furrow was about to do.
#
# The deploys here fail at the first step on purpose — no staged tree, no
# service, no loom on this host — because the claims under test are about the
# request and its place in the queue, and a request whose deploy failed keeps
# its file and its message. What a deploy does with a real service is
# t120-deploy.sh.
#
# machine: fresh

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GUARDEN_PREFIX=/

getent group guarden >/dev/null 2>&1 || groupadd --system guarden
# `soil storage` owns this directory's mode and owner and is not this file's
# phase. It is made here with the mode and the owner spec 2.1 states, because
# `furrow` runs as `guarden` and a directory it created would be its own: a
# queue a `guarden` program can read but not enqueue into is the 0750 defect
# spec 2.1 names, and the mode is what the first two assertions are about.
install -d -m 0770 -o root -g guarden /var/lib/guarden/queue
install -d -m 0770 -o root -g guarden /run/guarden/locks
stage_config guarden.toml

queue=/var/lib/guarden/queue

assert_mode "$queue" 770
assert_owner "$queue" "root:guarden"
# The queue is on disk and the locks are on tmpfs. A request acknowledged
# before a reboot must survive one and a lock must not: two directories, two
# filesystems, and `mount` is the machine's own answer about one of them.
run mount
assert_exit 0
assert_stdout_has "on /run type tmpfs"
assert_file_exists /run/guarden/locks

# --- the request is a service, a ref and a sha, and never a path --------------

# `--from` is `poke <project>@<sha>`. A path in either slot is rejected input
# naming the form, and nothing was enqueued by the refusal.
stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_not_rejected
run furrow deploy qapp-production --from /var/lib/guarden/staging
assert_exit 2
assert_stderr_has "never a path"
assert_stdout_empty
assert_file_missing "$queue/qapp-production@9f2c1ab.json"

run furrow deploy qapp-production --from poke qapp@nothex
assert_exit 2
assert_stderr_has "hexadecimal"
assert_file_missing "$queue/qapp-production@nothex.json"

# No `--from` at all, and no registry entry: spec 6.6 fixes this as exit 1
# naming the service, not 2. 2 would claim the caller's input was rejected when
# the refusal is about the host — there is nothing here to deploy — so this
# assertion follows the spec and the two codes are not interchangeable.
run furrow deploy qapp-production
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "qapp-production"
assert_stderr_has "--from"
assert_stdout_empty

# A `--sha` that is not the commit the `--from` names is two deploys in one
# command line, and it is refused rather than resolved by a rule nobody wrote.
run furrow deploy qapp-production --from poke qapp@9f2c1ab --sha 8a1d2f0
assert_exit 2
assert_stderr_has "different commits"

# A staged tree with no manifest in it is the host, not the input: the path was
# assembled by the system from two components and there is nothing behind them.
install -d -m 0755 /var/lib/guarden/staging/qapp/9f2c1ab
run furrow deploy qapp-production --from poke qapp@9f2c1ab
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has ".guarden/service.yml"

# --- the request lands on disk, and `ls` answers what is waiting --------------

stage_tree() {
    local project=$1 sha=$2
    local staged=/var/lib/guarden/staging/$project/$sha
    mkdir -p "$staged/.guarden/quadlet"
    cp "$GUARDEN_ROOT/fixtures/projects/routed/.guarden/service.yml" \
       "$staged/.guarden/service.yml"
    cp "$GUARDEN_ROOT/fixtures/projects/routed/.guarden/quadlet/web.container" \
       "$staged/.guarden/quadlet/web.container"
    cp "$GUARDEN_ROOT/fixtures/projects/quadlet-app/.guarden/.env.schema" \
       "$staged/.guarden/.env.schema"
    printf 'schema: .guarden/.env.schema\n' >> "$staged/.guarden/service.yml"
    chmod -R a+rX "$staged"
}

stage_tree qapp 9f2c1ab

# The request was carried out, so it is not on disk: a queue that kept what it had
# already done would re-run it. This asserted a FAILURE once — "this host has no
# installed mutator for furrow to reach" — which was this suite's own missing
# precondition, and with guarden installed the deploy succeeds.
#
# The other half is twenty lines up: an empty staged tree refuses, and THAT request
# keeps its file, which is the pair that makes the queue readable either way.
# The request for this service and sha is on disk and readable after a REFUSAL. It
# used to assert a failure for a reason this suite did not own — "this host has no
# installed mutator for furrow to reach", which was a missing precondition and is
# now installed. The refusal is the gate's instead: `production` is gated, the
# staged manifest declares a required sensitive key, and nothing plants it. The
# request is enqueued BEFORE the gate runs, so this is the case where the file must
# survive — the one an operator reads at three in the morning.
run furrow deploy qapp-production --from poke qapp@9f2c1ab
assert_exit 1
assert_one_diagnostic "error:"
assert_file_exists "$queue/qapp-production@9f2c1ab.json"

run furrow queue list
assert_exit 0
assert_stdout_has "qapp-production"
assert_stdout_has "9f2c1ab"
assert_stdout_has "last failure:"
# The track's `weight`, read from guarden.toml and from nowhere a repository can
# reach, is what the request carries.
assert_stdout_has "weight 1000"

# The JSON field set is closed (spec 1.2): the seven named fields and nothing
# else, so a caller may parse the document without knowing the program's state.
run furrow queue list --json
assert_exit 0
# **Every `assert_json` below reads the pristine copy `last-stdout`,** which the
# first of them replaces `$GUARDEN_STDOUT` with. The exit code is asserted once
# here for that reason: each later `assert_json` sets GUARDEN_EXIT itself, so an
# `assert_exit` between them would be asserting the field reader's exit code.
assert_json requests.0.service '"qapp-production"'
assert_json requests.0.ref null
assert_json requests.0.sha '"9f2c1ab"'
assert_json requests.0.state '"failed"'
assert_json requests.0.lane null
assert_json requests.0.weight 1000
assert_json_missing requests.0.project
assert_json_missing requests.0.pid
assert_json_missing requests.0.error

run furrow status --json
assert_exit 0
assert_json lanes 1
assert_json in_flight 0
assert_json deployed 0

# `queue show` is one service's own requests and their last failure.
run furrow queue show qapp-production
assert_exit 0
assert_stdout_has "9f2c1ab"
run furrow queue show qapp-staging
assert_exit 0
assert_stdout_has "nothing waiting"

# --- N identical requests collapse into one build -----------------------------

# The request file is named by the service, the escaped ref and the sha, so a
# second poke of one commit is the same request rather than a second build: the
# second run overwrites the first's file rather than adding one.
run furrow deploy qapp-production --from poke qapp@9f2c1ab
assert_exit 1
# **The count is inside `if`, not a bare `grep -c` assignment.** tests/lib.sh runs
# `set -euo pipefail`, and `grep -c` exits 1 when it counts nothing, so a queue
# holding ZERO files for this request would kill the suite silently at that
# assignment — passing by never reaching the comparison below.
one=0
if two=$(ls -1 "$queue" | grep -c '^qapp-production@9f2c1ab.json$'); then
    one=$two
fi
[ "$one" = 1 ] || _fail "the queue holds $one files for one service and sha, expected 1"
# `--json`, because the assertion below reads a JSON document: `jsonfield.py`
# is handed `last-stdout`, and on the text rendering it reports "stdin is not
# JSON" and the field is unreachable. The text rendering is asserted above.
run furrow queue list --json
assert_exit 0
assert_json requests.0.sha '"9f2c1ab"'
assert_json requests.0.state '"failed"'

# --- priority is the track's weight, and a preview is last --------------------

stage_tree qapp 8a1d2f0
stage_tree qapp 7b3e1d9

# Three tracks of one project, three requests, three files. The order `queue
# list` prints is the order they would be built in: production (1000), staging
# (100), preview (10). A preview's priority is not negotiable by its manifest,
# because a repository that could set its own priority could set it above
# production.
run furrow deploy qapp-staging --from poke qapp@8a1d2f0
assert_exit 1
run furrow deploy qapp-preview/feature-login --from poke qapp@7b3e1d9
assert_exit 1

run furrow queue list --json
assert_exit 0
assert_json requests.0.service '"qapp-production"'
assert_json requests.1.service '"qapp-staging"'
assert_json requests.2.service '"qapp-preview"'
assert_json requests.2.ref '"feature-login"'
assert_json requests.2.weight 10
# The ref is escaped in the file name because a raw one may carry a `/`, and a
# queue file named after one is a path that does not exist.
assert_file_exists "$queue/qapp-preview-feature\\x2dlogin@7b3e1d9.json"

# --- `--now` moves one request and nobody else --------------------------------

# A staging request with `--now` is built before the production one queued
# before it, and the production and preview requests keep their order to each
# other: `--now` skips queue position for that request and changes nobody else's.
run furrow deploy qapp-staging --from poke qapp@8a1d2f0 --now
assert_exit 1
run furrow queue list --json
assert_exit 0
assert_json requests.0.service '"qapp-staging"'
assert_json requests.1.service '"qapp-production"'
assert_json requests.2.service '"qapp-preview"'

# --- a manifest cannot state a priority --------------------------------------

# `priority` is refused by name by the manifest parser, which is the whole of
# "there is no key for it, and one is refused by name".
seed "$GUARDEN_FIXTURES/priority/.guarden/service.yml" \
    'project: qapp' \
    'units: .guarden/quadlet/' \
    'priority: 1'
mkdir -p "$GUARDEN_FIXTURES/priority/.guarden/quadlet"
cp "$GUARDEN_ROOT/fixtures/projects/routed/.guarden/quadlet/web.container" \
   "$GUARDEN_FIXTURES/priority/.guarden/quadlet/web.container"
run loom check "$GUARDEN_FIXTURES/priority"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "priority"

# --- `build.lanes` is a root-owned file, and it is read per claim -------------

# Raising it is a configuration change and not a program change, and the count
# `furrow status` reports is the one in the file.
assert_file_has /etc/guarden/guarden.toml "lanes = 1"
run furrow status --json
assert_exit 0
assert_json lanes 1
sed -i 's/^lanes = 1$/lanes = 3/' /etc/guarden/guarden.toml
run furrow status --json
assert_exit 0
assert_json lanes 3

# A lane count below one is not a smaller queue, it is no queue, and the table
# carries no value for it.
sed -i 's/^lanes = 3$/lanes = 0/' /etc/guarden/guarden.toml
run furrow status
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "lanes is 0"