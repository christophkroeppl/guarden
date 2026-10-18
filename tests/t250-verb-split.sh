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

# --- converged hash includes source files -------------------------------------

# A second ingest of a converged service exits 0, says it converged
run weedr service ingest myapp-production --from poke myapp@9f2c1ab
assert_exit 0
assert_stdout_has "converged"
assert_stderr_empty

# Editing the compose file makes the service NOT converged
seed /var/lib/guarden/staging/myapp/9f2c1ab/compose.yaml "services:" "  web:" "    image: docker.io/library/nginx:1.28"
run weedr service ingest myapp-production --from poke myapp@9f2c1ab
assert_exit 0
assert_stdout_lacks "converged"
assert_stdout_has "myapp-production"

# Editing the Containerfile makes the service NOT converged
seed /var/lib/guarden/staging/myapp/9f2c1ab/Containerfile "FROM docker.io/library/nginx:1.28"
run weedr service ingest myapp-production --from poke myapp@9f2c1ab
assert_exit 0
assert_stdout_lacks "converged"
assert_stdout_has "myapp-production"

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
