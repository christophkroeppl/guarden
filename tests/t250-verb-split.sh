#!/usr/bin/env bash
# The verb split: ingest accepts only poke, add accepts only service, create
# is a new verb for manual service creation.
#
# The staged tree is never named by an argument. `ingest` takes
# `poke <project>@<sha>` and guarden resolves the pair to the staging directory
# itself; `add` takes a service name and copies that service's own manifest and
# unit source out of its home; `create` takes no --from at all and builds a
# service from a template.
#
# machine: fresh

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GUARDEN_PREFIX=/

stage_config guarden.toml
stage_poke myapp 9f2c1ab

stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_not_rejected

# --- ingest accepts only poke -------------------------------------------------

# ingest --from poke works (the happy path, already tested in t30-create.sh)
run weedr service ingest myapp-production --from poke myapp@9f2c1ab
assert_exit 0
assert_stdout_has "myapp-production"
assert_stderr_empty

# ingest --from <service> is refused with the right error
run weedr service ingest myapp-staging --from myapp-production
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "ingest takes a poke"
assert_stderr_has "weedr service add"

# ingest --from <path> is refused with the right error
run weedr service ingest myapp-staging --from /tmp
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "ingest takes a poke"
assert_stderr_has "weedr service create"

# ingest --from poke with a bad format is refused
run weedr service ingest myapp-staging --from poke nothex
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "--from poke takes <project>@<sha>"

# --- add accepts only service -------------------------------------------------

# add --from poke is refused with the right error
run weedr service add myapp-staging --from poke myapp@9f2c1ab
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "add takes a service"
assert_stderr_has "weedr service ingest"

# add --from <path> is refused with the right error
run weedr service add myapp-staging --from /tmp
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "add takes a service"
assert_stderr_has "weedr service create"

# add --from <service> works (the happy path)
run weedr service add myapp-staging --from myapp-production
assert_exit 0
assert_stdout_has "myapp-staging"
assert_stderr_empty

# --- create is a new verb -----------------------------------------------------

# create --help works and mentions --env
run weedr service create --help
assert_exit 0
assert_stdout_has "--env"

# create requires a template (none installed on a fresh host)
run weedr service create myapp-preview
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "template"

# `--env` is parsed and the verb reaches the template stage with it, rather than
# only parsing as far as --help: the refusal names the template, and it is the
# host's, so exit 1 rather than the 2 a rejected argument would carry.
run weedr service create myapp-staging --env staging
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "template"
assert_stderr_lacks "usage:"
assert_stdout_empty

# --- where the re-deploys went ------------------------------------------------
#
# This suite used to carry the source-hash section as well: a converged second
# ingest, then one ingest per edited input. Those three ingests (two of them
# full re-deploys) are t30-create.sh's subject rather than this suite's —
# convergence is what that suite is about, and this one is the verb surface —
# so they run there now. The gate still runs every one of them; this suite runs
# fewer rebuild cycles for a claim it does not make.

# --- add and create need root, and answer in guarden's own line ---------------
#
# The suites run as root (tests/lib.sh), so the caller here has to be a real
# unprivileged account. `hose` is the one: a program user `soil install` made,
# in group `guarden` so it reads the `0640 root:guarden` guarden.toml -- which
# happens **first**, spec 5.1's configuration gathered before anything is asked
# of the caller -- and on no sudoers rule. `nobody` cannot reach this refusal at
# all: it is in no group, the configuration is not world-readable, and it would
# stop at the config read instead.
#
# The refusal is exit 1, not 2: nothing about the name or the `--from` is
# rejected, the host is simply not in the state the request assumed -- a caller
# that may not become root.
#
# stdin is /dev/null under the harness (`lxc exec -T ... </dev/null`), so
# `sudo -v` is taken as `sudo -n -v`: it never prompts on a stream nobody is
# feeding, and what sudo would have said is folded into guarden's one line
# rather than printed by sudo after `execvp` has replaced the process.

run runuser -u hose -- /usr/lib/guarden/bin/weedr service add otherapp-staging --from myapp-production
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "add requires root"
assert_stdout_empty
assert_file_missing /var/lib/guarden/registry/otherapp-staging.toml

# The same refusal for `create`, and only after its configuration, its name and
# its template choice have been gathered: one template has to be installed for
# the verb to get as far as asking for root, and it must still refuse before it
# copies anything. `otherapp-staging` never appears in the registry.
install -d -m 0755 /usr/lib/guarden/templates/services/staged
run runuser -u hose -- /usr/lib/guarden/bin/weedr service create otherapp-staging --env staging
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "create requires root"
assert_stdout_empty
assert_file_missing /var/lib/guarden/registry/otherapp-staging.toml
rmdir /usr/lib/guarden/templates/services/staged

# --- create's happy path: the name is not a service yet ----------------------
#
# The three things `create` promises, each asked of the machine rather than of
# a record: the system account, the registry entry, and the template's quadlet
# files in the service's own unit directory. The unit's owner and mode are
# asserted here because a copy that keeps the template's `root:root 0644` is a
# file the service's own podman generator cannot read -- and a service's home is
# `0700` to its owner (spec 2.1), so nothing root-owned belongs in it
# (AGENTS.md). `units.install` installs every rendered unit `0640` under the
# record's uid, and a template's copy has to land the same way.

install -d -m 0755 /usr/lib/guarden/templates/services/probe
seed /usr/lib/guarden/templates/services/probe/probe.container \
    "[Container]" \
    "Image=docker.io/library/nginx:1.27"
unit=/var/lib/guarden/services/probeapp-staging/home/.config/containers/systemd/probe.container

run weedr service create probeapp-staging --env staging --template probe
assert_exit 0
assert_stdout_has "created probeapp-staging"
assert_stdout_has "from probe"
assert_stderr_empty
assert_passwd probeapp-staging
assert_file_exists /var/lib/guarden/registry/probeapp-staging.toml
assert_file_has /var/lib/guarden/registry/probeapp-staging.toml 'source = "manual"'
assert_file_exists "$unit"
assert_owner "$unit" "probeapp-staging:$(id -gn probeapp-staging)"
assert_mode "$unit" 640
run weedr service list
assert_exit 0
assert_stdout_has "probeapp-staging"

# --- create refuses a name the registry already holds -------------------------
#
# The refusal is exit 1, and the choice is settled by the same line spec 1.2
# draws for everything else: `2` is the **input** rejected and spec 1.2 writes
# `2` for nothing else, and the name here is well-formed; `0` would report work
# that did not happen. What refuses it is the host's own state -- a registry
# entry that already exists -- which is how `weedr service remove` answers an
# instance list and `weedr service purge` an absent record: both `1`, the host
# is not in the state the request assumed.
#
# The record is **compared**, not just read back, because the defect this
# asserts against was a data loss rather than a wrong exit code: `create`
# rebuilt a fresh registry record and saved it over whatever the name held, so
# an `ingest`ed service lost its project, source hash, volumes, provides and
# instances to a second `create` -- and the template's units were copied into
# its live home beside them, which is what the last assertion names.

cp /var/lib/guarden/registry/myapp-production.toml \
    "$GUARDEN_FIXTURES/myapp-production.toml"

run weedr service create myapp-production --env production --template probe
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "already has a registry entry"
assert_stdout_empty
cmp -s /var/lib/guarden/registry/myapp-production.toml \
    "$GUARDEN_FIXTURES/myapp-production.toml" \
    || _fail "create rewrote the record it was meant to refuse"
assert_file_missing \
    /var/lib/guarden/services/myapp-production/home/.config/containers/systemd/probe.container

# The same refusal for the name `create` itself just made: the check is on the
# registry entry, not on who wrote it, so the verb cannot be run twice over any
# service -- a second `create probeapp-staging` answers the same line and
# leaves the account, the record and the unit it created the first time.
cp /var/lib/guarden/registry/probeapp-staging.toml \
    "$GUARDEN_FIXTURES/probeapp-staging.toml"
run weedr service create probeapp-staging --env staging --template probe
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "probeapp-staging already has a registry entry"
assert_stdout_empty
cmp -s /var/lib/guarden/registry/probeapp-staging.toml \
    "$GUARDEN_FIXTURES/probeapp-staging.toml" \
    || _fail "the second create rewrote the record it was meant to refuse"
assert_owner "$unit" "probeapp-staging:$(id -gn probeapp-staging)"
assert_mode "$unit" 640

# The whole `--env` list is asked **before** any of them is created (spec 5.1):
# one name in the list that the registry already holds refuses the request and
# creates none of the others, so a list cannot leave half of itself behind.
# `probeapp-staging` exists -- `create` made it above -- and
# `probeapp-production` does not, so the second name is the one that must not
# appear: the record, the account and the home are each asked of the machine.

run weedr service create probeapp --env staging,production --template probe
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "probeapp-staging already has a registry entry"
assert_stdout_empty
assert_file_missing /var/lib/guarden/registry/probeapp-production.toml
assert_no_passwd probeapp-production
assert_file_missing /var/lib/guarden/services/probeapp-production

# --- create's own input: a plain name, and each environment once --------------
#
# Both are the **input** rejected, not the host's state, so both are exit 2
# with one line (spec 1.2) and both are asked before the template question,
# before root and before anything is written.
#
# `create <name>` takes no /<ref> (spec 5.1 and the verb table in 5.3: the ref
# belongs to `ingest` and `add`). A ref here used to be accepted: the `-ENV`
# suffix was appended to the whole argument, so the suffix landed in the ref,
# `--env` was silently ignored in favour of the track before the slash, the
# ref was rewritten, the template's units were copied into `home/<ref>/` and
# the **parent** service's record was saved -- a service created and reported
# as created while the name and the environment disagreed, which spec 5.1
# forbids.
#
# `--env` naming the same environment twice used to resolve one name twice:
# the whole-list check saw no entry yet, the first create succeeded and
# printed, and the second refused the record it had just written -- a run that
# exits 1 for work it reports as done.
#
# And the same collision from **different** values, which is why the guard is
# on the resolved names: `--env` is matched against the name's tail, so
# `svc-foo-staging` already ends in `-foo-staging` and in `-staging`, both
# values leave the name unchanged and both resolve to one service. Counting
# the raw strings cannot see that one at all.

run weedr service create refusedapp-production/feat --env production --template probe
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "takes no /<ref>"
assert_stderr_lacks "usage:"
assert_stdout_empty
assert_file_missing /var/lib/guarden/registry/refusedapp-production.toml
assert_file_missing /var/lib/guarden/services/refusedapp-production
assert_no_passwd refusedapp-production

run weedr service create dupapp --env staging,staging --template probe
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "--env names"
assert_stderr_has "staging"
assert_stderr_lacks "usage:"
assert_stdout_empty
assert_file_missing /var/lib/guarden/registry/dupapp-staging.toml
assert_file_missing /var/lib/guarden/services/dupapp-staging
assert_no_passwd dupapp-staging

# Two **different** values resolving to one name, and the refusal is the same
# one: `svc-foo-staging` takes the unchanged-suffix branch for both values, so
# the request is one name asked for twice. The run that had no guard here
# created the name, printed `created ...` and then refused the record it had
# just written -- exit 1 for work it reported as done -- so both halves are
# reported by one line, because the assertions below stop at the first failure.
run weedr service create svc-foo-staging --env foo-staging,staging --template probe
[ "$GUARDEN_EXIT" = 2 ] || _fail "distinct --env values resolved to one name and the run went ahead: exit $GUARDEN_EXIT, stdout: $(tr '\n' ' ' <"$GUARDEN_STDOUT")"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "--env names"
assert_stderr_has "svc-foo-staging"
assert_stderr_lacks "usage:"
assert_stdout_empty
assert_file_missing /var/lib/guarden/registry/svc-foo-staging.toml
assert_file_missing /var/lib/guarden/services/svc-foo-staging
assert_no_passwd svc-foo-staging

# The template goes the way `staged` did above: a test installs what its own
# assertions need and takes it away again, so nothing here depends on the order
# suites happen to run in.
rm -rf /usr/lib/guarden/templates/services/probe
