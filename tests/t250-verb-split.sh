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

# create requires a template.
#
# **The refusal names the TEMPLATE, and it says why.** The set is not empty on
# a fresh host any more — ticket 330 made the install phase copy the service
# templates — so the chooser has a set to choose from, and with no terminal
# under the harness it refuses with "create needs a terminal to answer its
# prompts". That line does NOT contain the word "template", so an assertion
# that looked for it was reading a refusal the verb no longer gives.
#
# The two refusals are DIFFERENT and the suite asserts each one:
#   * an empty set names the template that was asked for and the path that
#     holds none (the block below, with the set taken away);
#   * a set with a choice in it and no terminal to answer in names the
#     terminal.
run weedr service create myapp-preview
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "create needs a terminal to answer its prompts"

# `--env` is parsed and the verb reaches the template stage with it, rather than
# only parsing as far as --help: the refusal names the terminal, and it is the
# host's, so exit 1 rather than the 2 a rejected argument would carry.
run weedr service create myapp-staging --env staging
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "create needs a terminal to answer its prompts"
assert_stderr_lacks "usage:"
assert_stdout_empty

# --- the template argument: the name's shape is input, the set is the host ----
#
# spec 1.2 draws one line — "The dividing line is input against host. A manifest
# and a unit source are input; the filesystem, the installed services and the
# remote are the host" — and its table writes `2` for "a name that breaks a
# rule", adding "Nothing else writes `2`". A `--template` value that is not a
# template name at all is that row, and it is the same shape as `add --from /tmp`
# above, which this suite already pins at `2` (t250:43 region). The host's own
# state is the other half: a **well-formed** name the installed set does not
# hold, and an empty set with no flag at all, are the filesystem — `1`, as the
# next two runs assert.
#
# No template is installed at this point in the suite, and that must not matter
# to the shape refusal: the argument is at fault whatever the host holds, so the
# run below answers `2` with an empty set, a registry-free name and nothing
# written.

run weedr service create rejectedapp-staging --template ../x
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "not a template name"
assert_stderr_has "../x"
assert_stderr_lacks "usage:"
assert_stdout_empty
assert_file_missing /var/lib/guarden/registry/rejectedapp-staging.toml
assert_no_passwd rejectedapp-staging

run weedr service create rejectedapp-staging --template BAD
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "not a template name"
assert_stderr_has "BAD"
assert_stdout_empty
assert_file_missing /var/lib/guarden/registry/rejectedapp-staging.toml
assert_no_passwd rejectedapp-staging

# The other side of the same line, asked with the same flag: a name that breaks
# no rule, and a set that does not hold it. The answer came from the host's
# filesystem, so it stays `1` — the same answer `add --from <service>` gives for
# a service the host has never heard of, and the answer spec 1.2's `needs:` row
# states for a provider that does not exist.

# The other side of the same line, asked with the same flag: a name that breaks
# no rule, and a set that does not hold it. The answer came from the host's
# filesystem, so it stays `1` — the same answer `add --from <service>` gives for
# a service the host has never heard of, and the answer spec 1.2's `needs:` row
# states for a provider that does not exist.
#
# **The name is one the set does not hold.** It used to be `postgres`, which
# the set did not hold because no template shipped — and ticket 330 made the
# install phase copy the service templates, so `postgres` IS installed now and
# the verb CREATED the service instead of refusing it. The test was asserting
# a refusal against a name that had become a real template.
#
# `absenttemplate` breaks no rule (it is a legal template name) and the set
# does not hold it, which is exactly the case this block is about.
run weedr service create rejectedapp-staging --template absenttemplate
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "does not exist"
assert_stderr_has "absenttemplate"
assert_stderr_lacks "not a template name"
assert_stdout_empty
assert_file_missing /var/lib/guarden/registry/rejectedapp-staging.toml

# The case the argument itself reaches: no name where a set offered a choice.
# An empty `--template` is an answer that named nothing — input, so `2` on the
# same line — rather than the `1` of an empty set and rather than a `0` that
# quietly creates the service from the set's only entry, which is what the
# front end did while `args.template or _choose_template()` swallowed the
# empty value before the line could be drawn. The case needs a set, so this
# run installs one directory the way `staged` and `probe` do below and takes
# it away again; every earlier run in this block keeps its empty set.

install -d -m 0755 /usr/lib/guarden/templates/services/emptyslot

run weedr service create rejectedapp-staging --template ""
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "no template was chosen"
assert_stderr_has "emptyslot"
assert_stderr_lacks "usage:"
assert_stdout_empty
assert_file_missing /var/lib/guarden/registry/rejectedapp-staging.toml
assert_no_passwd rejectedapp-staging

rmdir /usr/lib/guarden/templates/services/emptyslot

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
# The refusal is exit 2, not 1, and it is the VERB LIST's refusal and not
# sudo's: the mutator enforces the list itself (spec 6.6), so a caller that
# may not run `add` is named by guarden and not by sudo.
#
# **This assertion was reading a refusal the program no longer gives.** It
# expected "add requires root" -- the privilege refusal, from the layer that
# re-executes through sudo -- but commit 3e6cf6a (fix 331) put the verb list
# in front of it, so the call is refused before the privilege check is
# reached, and the line is guarden's own: the account may not run the verb,
# and the verbs it may run are listed.
#
# Nothing about the name or the `--from` is rejected, and the caller is still
# told exactly what it may do. The exit is 2 because the CALLER is the
# rejected input (spec 1.2), and the refusal names the verb and the list, so
# the assertion reads the verb and the list rather than a whole sentence that
# a reword would break.
#
# stdin is /dev/null under the harness (`lxc exec -T ... </dev/null`), so
# `sudo -v` is taken as `sudo -n -v`: it never prompts on a stream nobody is
# feeding, and what sudo would have said is folded into guarden's one line
# rather than printed by sudo after `execvp` has replaced the process.

run runuser -u hose -- /usr/lib/guarden/bin/weedr service add otherapp-staging --from myapp-production
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "may not run weedr service add"
assert_stdout_empty
assert_file_missing /var/lib/guarden/registry/otherapp-staging.toml

# The same refusal for `create`, and only after its configuration, its name and
# its template choice have been gathered: it must still refuse before it
# copies anything. `otherapp-staging` never appears in the registry.
#
# **The template is NAMED on the command line, and that is a change.** The
# suite used to install an empty `staged` directory and rely on the chooser
# picking the only template — but two real templates now ship (ticket 330
# fixed the install path, so `postgres` and `vaultwarden` are installed), so
# the chooser has a set to choose from and demands a terminal. The refusal
# then became "create needs a terminal to answer its prompts" instead of
# "create requires root", and the assertion below was reading the wrong
# refusal — the test was still passing for the wrong reason on the suites
# where the terminal happened to be there.
#
# Naming the template is what the verb is for: the chooser is for an operator
# at a terminal, and this is a suite with no operator.
#
# **The same staleness, and the same fix.** The suite used to read "create
# requires root" here too, and the refusal became the verb list's before it
# became the terminal's, so the assertion was reading a refusal the program
# no longer gives. It now reads the verb list's line, the same line the `add`
# refusal above gives, because both refusals come from the same place: the
# mutator's own list, ahead of the privilege check.
install -d -m 0755 /usr/lib/guarden/templates/services/staged
run runuser -u hose -- /usr/lib/guarden/bin/weedr service create otherapp-staging --env staging --template staged
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "may not run weedr service create"
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
# (AGENTS.md). `units.install` installs every rendered unit at the tree's own
# `0700` under the record's uid (spec 2.1), and a template's copy has to land
# the same way.

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
assert_mode "$unit" 700
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
assert_mode "$unit" 700

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
# with one line (spec 1.2), and both are asked before anything is written and
# before root is asked for -- the last of those **observed** rather than
# asserted in a comment: each refusal below is also run through `hose`, which
# is on no sudoers rule, so a refusal that had reached the escalation would
# answer `create requires root` with exit 1 instead of its own line with 2.
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

# The same refusal asked of an unprivileged caller, because "before root" is
# a claim about order and a root caller proves nothing about it: `hose` is on
# no sudoers rule, so a run that had reached the escalation answers
# `create requires root` with exit 1 instead of this line with exit 2, and
# would still answer it if anything had been written first.
#
# **And it no longer does: the verb list is now in front of the escalation.**
# The mutator refuses the call because the CALLER may not run the verb, and
# it says so in its own line, before the name is even looked at. The exit is
# still 2 -- the caller is the rejected input either way -- but the line is
# not this block's line, so the assertion reads the verb list's.
#
# The refusal is still a refusal and still before anything is written, and
# the file and the passwd row below are what prove THAT: the same call by
# root refuses on the name, and neither caller leaves a record.
run runuser -u hose -- /usr/lib/guarden/bin/weedr service create refusedapp-production/feat --env production --template probe
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "may not run weedr service create"
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

# The dedupe refusal asked of `hose` for the same reason: the guard runs
# before root is asked for, so an unprivileged caller sees this line and not
# `create requires root`, and nothing of the name it refused exists after it.
#
# **But the verb list is ahead of that guard now**, so the unprivileged caller
# is refused for being a caller at all: it may not run `create`, and that is
# said before the `--env` is even parsed. The exit is 2 either way and
# nothing is written either way, which is what the file and passwd rows below
# assert -- the refusal's REASON is the verb list's, and the assertion reads
# that.
run runuser -u hose -- /usr/lib/guarden/bin/weedr service create dupapp --env staging,staging --template probe
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "may not run weedr service create"
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

# And through `hose` as well, so the ordering claim is a machine observation
# for this refusal too: exit 2 with the guard's own line, no escalation, no
# record, no account -- where an unprivileged run of an unguarded request
# answers `create requires root` with exit 1 instead.
#
# The verb list is ahead of that guard, so the line is the verb list's, as
# above: the caller may not run `create`, and that is said first.
run runuser -u hose -- /usr/lib/guarden/bin/weedr service create svc-foo-staging --env foo-staging,staging --template probe
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "may not run weedr service create"
assert_stderr_lacks "usage:"
assert_stdout_empty
assert_file_missing /var/lib/guarden/registry/svc-foo-staging.toml
assert_file_missing /var/lib/guarden/services/svc-foo-staging
assert_no_passwd svc-foo-staging

# The template goes the way `staged` did above: a test installs what its own
# assertions need and takes it away again, so nothing here depends on the order
# suites happen to run in.
rm -rf /usr/lib/guarden/templates/services/probe
