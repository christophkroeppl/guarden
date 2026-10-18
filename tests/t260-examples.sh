#!/usr/bin/env bash
# Example service templates: the copyable set under examples/services/ is what
# `weedr service create` reads once it is installed into a prefix's template
# directory, and the set does not ship — `src/guarden/templates/` has no
# `services/` subdirectory, so a fresh host refuses `create` until one is
# installed (docs/sysadmin.md, "Deploying a service by hand").
#
# What the suite is about, in order: the refusal a host with no templates gives,
# the refusal a host with no terminal gives, what `create` does make (the
# account, the registry record, the template's quadlet file — and no manifest
# and no volume), the refusal a name the registry already holds gives for a whole
# `--env` list at once, and the one thing that brings such a service a manifest
# and its volumes: `weedr service add` from a service that has one.
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

# --- a fresh host has no template set -----------------------------------------
#
# `soil install` installs the checkout's `src/guarden/templates/`, and that tree
# carries no `services/` subdirectory: the directory `create` reads is the one
# that is absent, which is why the first refusal below names a path that holds
# nothing rather than a name that is unknown.
assert_file_missing /usr/lib/guarden/templates/services

run weedr service create emptyapp --env staging --template postgres
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "the template 'postgres' does not exist at"
assert_stderr_has "/usr/lib/guarden/templates/services"
assert_stderr_has "holds none"
assert_stderr_lacks "usage:"
assert_stdout_empty
assert_file_missing /var/lib/guarden/registry/emptyapp-staging.toml
assert_no_passwd emptyapp-staging

# The same refusal without `--template`, where the verb would have asked at a
# terminal: an empty set is `None` rather than a prompt, and the line the
# operator gets is the one that names the problem, not a list of nothing.
run weedr service create emptyapp --env staging
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "no template was chosen"
assert_stderr_has "holds none"
assert_stdout_empty

# `--template` is on the verb's own surface, which is what makes the runbook's
# synopsis complete.
run weedr service create --help
assert_exit 0
assert_stdout_has "--env"
assert_stdout_has "--template"

# --- install the examples into this prefix's template directory ---------------
#
# The install command the runbook gives: the directory first, then the examples
# copied in beside it. Root-owned `0755`/`0644` is what a root `cp` leaves and
# what a root-owned template set is supposed to be.
install -d -m 0755 /usr/lib/guarden/templates/services
cp -r "$GUARDEN_ROOT/examples/services/postgres" /usr/lib/guarden/templates/services/
cp -r "$GUARDEN_ROOT/examples/services/vaultwarden" /usr/lib/guarden/templates/services/

# Two templates and no terminal: the verb asks for one at a prompt when it is
# omitted, and under a harness whose stdin is /dev/null there is nothing to ask.
run weedr service create promptapp --env staging
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "create needs a terminal to answer its prompts"
assert_stdout_empty
assert_file_missing /var/lib/guarden/registry/promptapp-staging.toml

# --- create from the postgres example -----------------------------------------
#
# The three promises: an account, a registry record, and the template's quadlet
# file in the service's own unit directory — `0640` under the service uid, the
# way a rendered unit lands, because a copy that kept `root:root 0644` would be
# a file the service's own podman generator cannot read.
run weedr service create pgexample --env staging --template postgres
assert_exit 0
assert_stdout_has "created pgexample-staging"
assert_stdout_has "from postgres"
assert_stderr_empty
assert_passwd pgexample-staging
assert_linger pgexample-staging
pg_uid=$(getent passwd pgexample-staging | cut -d: -f3)
assert_file_exists /var/lib/guarden/services/pgexample-staging
assert_mode /var/lib/guarden/services/pgexample-staging 700
assert_owner /var/lib/guarden/services/pgexample-staging \
    "pgexample-staging:$(id -gn pgexample-staging)"

pg_unit=/var/lib/guarden/services/pgexample-staging/home/.config/containers/systemd/postgres.container
assert_file_exists "$pg_unit"
assert_owner "$pg_unit" "pgexample-staging:$(id -gn pgexample-staging)"
assert_mode "$pg_unit" 640
assert_file_has "$pg_unit" "Image=docker.io/library/postgres:17-alpine"
assert_file_exists "/etc/containers/systemd/users/$pg_uid"

# The record: manual source, the track from the name, the uid the host itself
# allocated. The record is `0640 root:guarden` like every other.
pg_registry=/var/lib/guarden/registry/pgexample-staging.toml
assert_file_exists "$pg_registry"
assert_mode "$pg_registry" 640
assert_file_has "$pg_registry" 'service = "pgexample-staging"'
assert_file_has "$pg_registry" 'environment = "staging"'
assert_file_has "$pg_registry" "uid = $pg_uid"
assert_file_has "$pg_registry" 'source = "manual"'

# And what it does **not** make: no manifest, and no volume. A template ships
# neither, so the declared volumes a manifest asks for are still the first
# manifest's to create — the claim docs/sysadmin.md makes under "Deploying a
# service by hand".
assert_file_missing /var/lib/guarden/services/pgexample-staging/home/.guarden
assert_file_missing /var/lib/guarden/services/pgexample-staging/state/data
assert_no_subvolume /var/lib/guarden/services/pgexample-staging/state/data
assert_no_snapper_config pgexample-staging-data

# The second example, so the set is more than the one directory the test needed.
run weedr service create vwexample --env staging --template vaultwarden
assert_exit 0
assert_stdout_has "created vwexample-staging"
assert_stdout_has "from vaultwarden"
assert_stderr_empty
assert_passwd vwexample-staging
vw_unit=/var/lib/guarden/services/vwexample-staging/home/.config/containers/systemd/vaultwarden.container
assert_file_exists "$vw_unit"
assert_owner "$vw_unit" "vwexample-staging:$(id -gn vwexample-staging)"
assert_mode "$vw_unit" 640
assert_file_has /var/lib/guarden/registry/vwexample-staging.toml 'source = "manual"'

run weedr service list
assert_exit 0
assert_stdout_has "pgexample-staging"
assert_stdout_has "vwexample-staging"

# --- create refuses a name the registry already holds, whole ------------------
#
# Asked for every environment in the list before any of them is created: here
# `myapp-production` is the second name the list resolves to, and
# `myapp-staging` never reaches the account.
run weedr service ingest myapp-production --from poke myapp@9f2c1ab
assert_exit 0
assert_stdout_has "myapp-production"
assert_stderr_empty

run weedr service create myapp --env staging,production --template postgres
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "myapp-production already has a registry entry"
assert_stdout_empty
assert_file_missing /var/lib/guarden/registry/myapp-staging.toml
assert_no_passwd myapp-staging

# --- the volumes arrive with the first `add` that brings a manifest in ---------
#
# `add` copies the named service's own manifest and unit source out of its home
# — `.guarden/`, `compose.yaml` and the build context — and it is a reconcile
# verb, so it runs over a service `create` already made. What has to appear is
# the state the manifest declares: the subvolume, the snapper configuration and
# the registry's volume table, none of which a template could have written.
run weedr service add pgexample-staging --from myapp-production
assert_exit 0
assert_stdout_has "created pgexample-staging"
assert_stderr_empty

assert_subvolume /var/lib/guarden/services/pgexample-staging/state/data
assert_subvolume /var/lib/guarden/services/pgexample-staging/bulk/chainstate
assert_snapper_config pgexample-staging-data NUMBER_MIN_AGE 3600
assert_file_has "$pg_registry" 'project = "myapp"'
assert_file_has "$pg_registry" "[state.data]"

# The template's own copy is in the unit directory and the manifest's units are
# rendered beside it — `create` put the first there and `units.install` writes
# the second without taking anything away.
assert_file_exists "$pg_unit"
assert_file_exists /var/lib/guarden/services/pgexample-staging/home/.config/containers/systemd/web.container

# Nothing here depends on the order suites happen to run in: the template set
# is this suite's own and goes away with its assertions.
rm -rf /usr/lib/guarden/templates/services/postgres
rm -rf /usr/lib/guarden/templates/services/vaultwarden
