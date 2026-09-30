#!/usr/bin/env bash
# soil install: what it creates, and the two things it must not.
#
# It creates the two program users and the one group, and it is the only phase
# that writes outside the host's own storage. It must create no service
# identity of any kind -- no service user, no service directory, no state
# volume, no snapper configuration for anything guarden does not own -- and it
# must create no group beyond `guarden`, because a host with no edge module has
# no `edge` group and the edge's group belongs to `weedr module add gate`.

. "$(dirname "$0")/lib.sh"
scratch_host

run soil install --check
assert_exit 1
assert_stderr_has "drift: the host configuration exists"
assert_stderr_has "drift: guarden's programs are installed root-owned"

# The alias probe cannot run in the fast harness, because a fake podman starts no
# container, and spec 6.1 says what that means: exit 1, naming which of the four
# failed, with `ingress.alias` left empty. Everything else the phase converges has
# already happened, because a failed probe is a finding and not a rollback.
run soil install --apply
assert_exit 1
assert_stderr_has "alias probe 1 of 4"

# The shipped table is seeded, and it is a table and not a list in the code: a
# track is a row, and adding one is appending a block.
assert_file_has "$(host etc/guarden/guarden.toml)" "[[environments]]"
assert_file_has "$(host etc/guarden/guarden.toml)" 'name = "production"'
assert_file_has "$(host etc/guarden/guarden.toml)" 'name = "preview"'
assert_file_has "$(host etc/guarden/guarden.toml)" 'fork_from = "production"'

# The programs, templates and units are in /usr/lib/guarden, root-owned and
# never written by a deploy.
assert_file_exists "$(host usr/lib/guarden/bin/soil)"
assert_file_exists "$(host usr/lib/guarden/bin/weedr)"
assert_file_exists "$(host usr/lib/guarden/bin/hose)"
assert_file_has "$(host etc/systemd/system/guarden-tmpfiles.conf)" "d /run/guarden"

# The two program users and the one group, and nothing else. `admin_user` is the
# uid allowed to reach the edge's API, so it is recorded when it is empty.
assert_called "groupadd --system guarden"
assert_called "useradd --system --no-create-home --shell /usr/sbin/nologin --gid guarden guarden"
assert_called "useradd --system --no-create-home --shell /usr/sbin/nologin --gid guarden hose"
assert_not_called "groupadd --system edge"
assert_called_count 2 "useradd"
assert_called_count 1 "groupadd"
assert_file_has "$(host etc/guarden/guarden.toml)" 'admin_user = "'
assert_file_has "$(host etc/guarden/guarden.toml)" 'name = "production"'

# No service identity of any kind.
assert_not_called "myapp"
assert_file_missing "$(host var/lib/guarden/services/myapp-production)"
assert_file_missing "$(host var/lib/guarden/services/myapp-production/state)"

# The render directory is the one the unprivileged programs may write into, and
# the lock directory takes the same mode because unprivileged programs take
# those locks.
assert_called "install -d -m 0770 -o guarden -g guarden $GUARDEN_HOST/var/lib/guarden/render"
assert_called "install -d -m 0770 -o root -g guarden $GUARDEN_HOST/run/guarden/locks"

# The credential materialiser decrypts once, in the system manager, and the
# generated unit for a service carries no LoadCredentialEncrypted= because it
# runs in that service's user manager and cannot read a 0600 root host key.
assert_file_has "$(host etc/systemd/system/guarden-credential-materialiser@.service)" \
    "LoadCredentialEncrypted=credentials:"
assert_file_has "$(host etc/systemd/system/guarden-credential-materialiser@.service)" \
    "ExecStart=/usr/lib/guarden/bin/weedr secret materialise %i"
assert_file_has "$(host etc/systemd/system/guarden-credential-materialiser@.service)" \
    "After=snapperd.service"

# The probe is the one thing this phase cannot converge without, so it is drift
# on every run until the probe has run: an alias that is wrong is worse than an
# alias that is absent, because the edge refuses to start without it.
run soil install --check
assert_exit 1
assert_stderr_has "drift: ingress.alias holds an address the probe measured"
assert_file_has "$(host etc/guarden/guarden.toml)" 'alias = ""'
assert_stderr_has "the edge does not start without it"

# The probe runs a throwaway rootless container with the `[network]` table's
# options, because pasta recomputes the gateway per container and the alias may
# not be derived from the host's route on faith.
assert_called "podman run --rm --network pasta:--map-gw"

# guarden.toml has three writers and two of them share a key, so a write takes
# the modules lock and rewrites only the key it owns. The file is otherwise the
# shipped one, with the operator's own tracks intact.
assert_file_exists "$GUARDEN_HOST/run/guarden/locks/modules.lock"
assert_file_has "$(host etc/guarden/guarden.toml)" 'publication_range = [20000, 32767]'
assert_file_has "$(host etc/guarden/guarden.toml)" 'pasta_options = [ "--map-gw" ]'

# A second apply changes nothing that it can converge, and re-runs the probe
# because the alias is still not measured.
rm -f "$GUARDEN_CALLS"
run soil install --apply
assert_exit 1
assert_not_called "useradd"
assert_not_called "groupadd"
assert_not_called "install -m"
