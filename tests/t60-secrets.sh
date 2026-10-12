#!/usr/bin/env bash
# Ticket 60, the credential half: one encrypted blob per key, the units that turn
# it into a podman secret, and the trust boundary stated in both directions.
#
# `stage_poke` cannot stage this project: it writes the sentinel
# `environment=SHOULD_NOT_BE_USED` into `guarden-poke.json`, and this project
# declares a credential schema and a gate depends on it, so the sentinel is
# exactly the thing that must not be there. The staging is spelled out instead.
#
# Every assertion below is a fact about the machine, not about a record of what
# guarden was about to do: the mode of the blob, the fact that the host key
# decrypts it, the value's absence from every file on the host, and its presence
# in the one place the documents say it cannot be kept out of.
#
# The one place the fakes were load-bearing is the materialise step near the end,
# and that is named where it stands rather than here.
#
# **There is no staged host here, and that is the whole of what this file
# changed.** The suite creates its subject with `weedr service ingest`, which is
# step 2 of spec 5.3: a real `useradd` for `qapp-production`, a real uid, a real
# delegated `/etc/subuid` range. A staged `/etc/passwd` cannot be reconciled with
# that — the mutator reads back the database it promised to be written to, finds
# nothing, and reports "qapp-production was created but is not in <staged>/etc/passwd",
# which is a true sentence about two databases and a fact about no service. So
# `GUARDEN_PREFIX=/` and the machine's own tools, the way `t30-create` already does,
# and every path below is the real one.

. "$(dirname "$0")/lib.sh"

# The value is obviously a fixture. It is searched for by `grep -rl` over the whole
# prefix at the end of the test, so it must not occur in any file guarden writes.
VALUE=top-secret-value-77

# The fixture names `operator` as admin_user and nothing creates it; the API
# accept set is keyed on that uid.
id -u operator >/dev/null 2>&1 || {
    getent group operator >/dev/null 2>&1 || groupadd --system operator
    useradd --system --no-create-home --gid operator --shell /usr/sbin/nologin operator
}

stage_quadlet()
{
    local project=qapp ref=9f2c1ab
    local staged=$GUARDEN_PREFIX/var/lib/guarden/staging/$project/$ref
    mkdir -p "$staged/.guarden/quadlet" "$staged/.guarden/widgets"
    cp "$GUARDEN_ROOT/fixtures/projects/quadlet-app/.guarden/.env.schema" \
       "$staged/.guarden/.env.schema"
    cp "$GUARDEN_ROOT/fixtures/projects/quadlet-app/.guarden/service.yml" \
       "$staged/.guarden/service.yml"
    cp "$GUARDEN_ROOT/fixtures/projects/quadlet-app/.guarden/quadlet/web.container" \
       "$staged/.guarden/quadlet/web.container"
    cp "$GUARDEN_ROOT/fixtures/projects/quadlet-app/.guarden/quadlet/worker.container" \
       "$staged/.guarden/quadlet/worker.container"
    cp "$GUARDEN_ROOT/fixtures/projects/quadlet-app/.guarden/widgets/web.yml" \
       "$staged/.guarden/widgets/"
    printf '%s\n' "services: [qapp-production, qapp-staging]" \
        >"$staged/guarden-poke.json"
    mkdir -p "$GUARDEN_PREFIX/var/lib/guarden/staging/$project/HEAD"
}

# The machine's own tools. Nothing is faked (ADR-0014), so this line is a
# statement rather than a mechanism: `useradd`, `systemd-creds` and `snapper` are
# the machine's, and `.venv/bin` is kept first because it is the checkout's
# interpreter and not a stand-in for anything.
export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

export GUARDEN_PREFIX=/
# The real path, not a relocated one: `stage_config` writes where guarden reads,
# and /etc/guarden is absent on a host where `soil install` has never run.
ensure_accounts
stage_config guarden-measured.toml

# `soil install --apply` is a precondition, not the subject: ingest renders through
# `loom`, and the programs are not on this host until install has run. It goes AFTER
# stage_config, because install probes the host's gateway and writes what it
# measured into the config it is reading.
stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_not_rejected
stage_quadlet
# The project's `needs:` names a database the render resolves out of the registry,
# and there is no database on this host yet, so its record is seeded rather than
# created: the credential assertions are about this service's own keys.
registry=$GUARDEN_PREFIX/var/lib/guarden/registry
seed "$registry/postgres-staging.toml" \
    'service = "postgres-staging"' 'workload = "postgres"' 'project = "postgres"' \
    'environment = "staging"' 'uid = 1099' 'created = "2026-09-30T09:00:00Z"' \
    '[provides]' 'kinds = [ "db" ]' '[publication]' 'api = 20107' 'db = 20108'

# The provider's own manifest names the container serving 5432; without it the
# edge records no publication and the refusal below is correct.
pg_home=$GUARDEN_PREFIX/var/lib/guarden/services/postgres-staging/home
mkdir -p "$pg_home/.guarden"
printf '%s\n' \
    'project: postgres' \
    'units: .guarden/quadlet/' \
    'ports:' \
    '  - container: db' \
    '    port: 5432' \
    >"$pg_home/.guarden/service.yml"

# Not assert_stderr_empty: the firewall and not-running-provider warnings are
# correct on an unconverged host, so the claim is that the edge resolves.
run weedr module add gate-traefik
assert_exit 0
# This host has no podman for a service user, so the credential materialiser cannot
# work here; masking it says so plainly. Without this, `secret set` reports the
# unit's failure for a credential it wrote correctly — and the suite's own header
# records that the fakes were load-bearing at exactly this step.
systemctl daemon-reload
for unit in guarden-creds.path guarden-creds-boot.service; do
    if [ -e "/etc/systemd/system/$unit" ]; then
        mv "/etc/systemd/system/$unit" "/etc/systemd/system/$unit.off"
    fi
done
systemctl daemon-reload
run weedr service ingest qapp-production --from poke qapp@9f2c1ab
assert_exit 0
assert_stderr_lacks "the edge is recorded with no publication"

# A database edge mints a value (key = prefix uppercased + _PASSWORD), so the
# blob is on disk after ingest.
assert_file_exists "$GUARDEN_PREFIX/etc/guarden/creds/qapp-production/DB_PASSWORD.cred"

run weedr secret set qapp-production DB_PASSWORD <<<"$VALUE"
assert_exit 0
assert_stdout_has "planted DB_PASSWORD"
# The materialiser is INSTALLED here — this file runs `soil install --apply` as a
# precondition because ingest renders through `loom` — and it cannot work on this
# golden, which carries no podman for a service user. So `secret set` reports the
# unit's failure as an error rather than warning that the unit is missing. What the
# suite can assert, and does, is the state that is real: the blob is on disk and the
# diagnostic names the unit and where the value is.

blob=$GUARDEN_PREFIX/etc/guarden/creds/qapp-production/DB_PASSWORD.cred

# The blob is `0600 root` and the directory holding it is `0700`, which is what
# makes it unreadable at rest by anything but the one service that owns it — and
# unreadable by *that* service too, which is why the materialiser is a separate
# root unit rather than something the container's own podman did on its behalf.
assert_file_exists "$blob"
assert_mode "$blob" 600
assert_mode "$GUARDEN_PREFIX/etc/guarden/creds/qapp-production" 700

# The encryption key is the **host** key, and the state says so: the blob
# decrypts under the host key and returns the value.
#
# This replaced a call-log assertion that read
# `systemd-creds encrypt --name=DB_PASSWORD --with-key=host -` out of the log and
# checked `--with-key=auto` appeared nowhere. Decryption is the stronger of the
# two forms, because it asks the box a question about the artefact rather than
# about an intent: a blob that comes back with the right value is encrypted with
# a key this machine holds.
#
# The `auto` half is **partly dropped, and the part that is dropped is named**.
# `auto` is not used because its meaning varies with the hardware, and on a
# machine with no TPM `auto` *is* `host` — so on the golden VM, decrypting with
# the host key cannot distinguish an implementation that said `host` from one
# that said `auto`. That distinction is only observable on a box with a TPM2
# device, and this repository has no such fixture. Asserting it here would mean
# asserting something the machine cannot distinguish from the alternative, which
# is a test that can only ever pass.
run systemd-creds decrypt --with-key=host "$blob"
assert_exit 0
assert_stdout_has "$VALUE"

# A blob encrypted under a different key is not one, and the decrypt above is
# what distinguishes the two: the value came back, so this blob is one the host
# can read and the materialiser is not guessing.
assert_file_lacks "$blob" "$VALUE"

# The blob asks the materialiser to run rather than waiting for the path unit to
# notice, so a rotated value is not sitting un-materialised until the next boot.
#
# This was `assert_file_has "$GUARDEN_CALLS" "systemctl start
# guarden-creds-boot.service"` and it is **dropped rather than ported**: whether
# the oneshot was started is not a state this box reports once the run is over,
# and the path unit that would do it is asserted as installed below. What the
# claim actually protects — that a rotated value reaches the materialiser at all —
# is the `PathChanged=` line on the path unit, which is asserted below by name.

# The value is not in the blob, and the blob is not something a reader can
# substitute for it: `systemd-creds` wrote the ciphertext to stdout and guarden
# wrote what came back, and the same blob decrypts only under the host key. The
# decrypt above is what proves the second half; this line is the first.
assert_file_lacks "$blob" "$VALUE"

# A key is a name and never a path, so this is rejected input and exit 2.
run weedr secret set qapp-production ../../etc/shadow
assert_exit 2
assert_stderr_has "credential key"
assert_stdout_empty

# One path unit on the blob directory and one boot-time oneshot, two units for the
# whole host and two in total. The install phase converges all of them, and
# `--check` naming them is a question asked of the machine.
# Drift, and deliberately: this file disables the materialiser's path unit, because
# the golden has no podman for a service user and no instance could succeed. `--check`
# asks the machine, and the machine says so.
run soil install --check
assert_exit 1
assert_stderr_has "the credential materialiser's path unit"

# ADR-0005's two units, and the shape spec 6.9 pins for them: the oneshot is root
# and runs the one program that decrypts, and the path unit triggers that oneshot.
#
# The instantiable `guarden-credential-materialiser@.service` is the third template
# on disk and it is **not** a violation of "two units in total": it is what the
# path unit triggers per blob, and it carries no `[Install]` precisely because a
# `WantedBy=` would fire it at boot and double-materialise against the oneshot.
# (Ticket 221 removed it on the reading that it did nothing; it was restored,
# because the mechanism is the ADR's and the real defect was that
# `credentials.value()` ignored the `$CREDENTIALS_DIRECTORY` systemd handed it.)
oneshot=$PWD/src/guarden/templates/guarden-creds-boot.service
path_unit=$PWD/src/guarden/templates/guarden-creds.path
per_blob=$PWD/src/guarden/templates/guarden-credential-materialiser@.service
assert_file_has "$oneshot" "ExecStart=/usr/lib/guarden/bin/weedr secret materialise"
assert_file_has "$oneshot" "Type=oneshot"
assert_file_has "$path_unit" "PathChanged=/etc/guarden/creds/"
assert_file_has "$path_unit" "Unit=guarden-creds-boot.service"
assert_file_exists "$per_blob"
assert_file_has "$per_blob" "ExecStart=/usr/lib/guarden/bin/weedr secret materialise %i"
assert_file_lacks "$per_blob" "[Install]"

# **The enabled state is asserted where the phase is converged, not here.** This
# file stages a host where `soil install` has never been applied, so the units are
# *not* enabled and their being enabled would mean another suite installed them:
# `t221-cred-units.sh` converges the phase and asserts them enabled.

# The edge table is written by ingest above; appending it here was a duplicate key.

# Likewise the publication table: the registry writes it.

# The generated unit names the secret and nothing else. It is rendered from the
# same project the schema came from, and the whole render tree is searched for the
# directive that would put a key where a user manager would have to read it.
run loom render "$GUARDEN_PREFIX/var/lib/guarden/staging/qapp/9f2c1ab" \
    --service qapp-production --out "$GUARDEN_FIXTURES/render"
assert_exit 0
render=$GUARDEN_FIXTURES/render
unit=$render/units/web.container
assert_file_exists "$unit"
assert_file_has "$unit" "Secret=DB_PASSWORD,type=file"
assert_file_has "$unit" "Secret=SESSION_SIGNING_KEY,type=env"
assert_file_lacks "$unit" "LoadCredentialEncrypted"
if grep -rl LoadCredentialEncrypted "$render" >"$GUARDEN_FIXTURES/leaked" 2>/dev/null; then
    printf 'a rendered file carries LoadCredentialEncrypted=\n' >&2
    exit 1
fi

# `weedr secret list` is names and booleans. It never prints a value, and the
# JSON object's field set is the one spec 1.2 pins.
run weedr secret list qapp-production
assert_exit 0
assert_stdout_has "DB_PASSWORD"
# The human report is tab-separated -- `<name>\t<state>\t<marks>` -- and the
# state word for an unset key is `not set`, which CONTAINS `set`. A bare
# `assert_stdout_has "set"` therefore passes for a key that was never planted,
# which is the opposite of what this line is here for. Anchoring on the name and
# the tab that follows it is the assertion that can fail.
assert_stdout_has $'DB_PASSWORD\tset'
assert_stdout_lacks "$VALUE"

run weedr secret list qapp-production --json
assert_exit 0
assert_stdout_lines 1
assert_json secrets.0.name '"DB_PASSWORD"'
assert_json secrets.0.set true
assert_json secrets.0.source '"planted"'
assert_json secrets.0.example false
assert_json secrets.1.name '"LOG_LEVEL"'
assert_json secrets.1.set false

# Rotation: a value that is still the schema's example is reported as such, and
# it is still only a boolean. The second plant replaces the blob rather than
# leaving the old value behind.
run weedr secret set qapp-production DB_PASSWORD <<<"EXAMPLE-not-a-real-password"
assert_exit 0
run weedr secret list qapp-production --json
assert_exit 0
assert_json secrets.0.example true

run weedr secret set qapp-production DB_PASSWORD <<<"$VALUE"
assert_exit 0

# The trust boundary, first half: the blob is in no state volume, the registry
# holds no value, and the rendered unit holds none. The state volume is the whole
# of what a snapshot or a fork carries, and the whole-tree search at the end of
# this test covers it as well as this.
assert_file_lacks "$blob" "$VALUE"
assert_file_lacks "$GUARDEN_PREFIX/var/lib/guarden/registry/qapp-production.toml" "$VALUE"
assert_file_lacks "$unit" "$VALUE"

# The trust boundary, second half — asserted rather than assumed away. The
# materialiser hands the value to podman as the service user, podman keeps it
# inside that service's own home, and whatever can read that home has it.
#
# **The machine has to carry a real `podman` for this half, so this suite installs
# one with the phase that owns it.** The golden ships substrate only —
# `t20-packages.sh` asserts `podman` is *absent* on a fresh cut, because it is
# that suite's drift to converge — and nothing faked could answer the question, so
# the answer is to ask the distribution repository through `soil packages`, the
# one program whose list names `podman`. It is the real tool and the real phase,
# which is the whole rule; `assert_dpkg` asserts the state rather than the intent,
# and `assert_not_rejected` is right because the phase is asked for the package
# and not for a converged host — the pinned converter is the item after it and
# this suite says nothing about that.
#
# An earlier revision asserted the exit code and the store below and expected both
# to fail here, with a comment saying so and leaving them in place. That made the
# suite knowingly red and left ticket 60's second half unasserted.
install -D -m 0644 "$GUARDEN_ROOT/src/guarden/templates/podlet.release" \
    /etc/guarden/podlet.release
run soil packages --apply
assert_not_rejected
assert_dpkg podman

run weedr secret materialise qapp-production
assert_exit 0
assert_stdout_has "qapp-production DB_PASSWORD"

# **Where podman keeps a secret, measured rather than assumed.** It is not a file
# per key and it is not in the clear: podman's `file` secret driver writes
# `$HOME/.local/share/containers/storage/secrets/filedriver/secretsdata.json` with
# each value base64-encoded, and `.../storage/secrets/secrets.json` naming it.
# Encoding is not protection — it is one `base64 -d` away — so what protects the
# value is the `0700` on the service's own home. That is the documented limit and
# not an accident, and this is where it is recorded instead of assumed away.
#
# The value carries no trailing newline: `credentials.value` drops the terminal's
# framing newline once, and the materialiser hands podman what it read back.
containers=$GUARDEN_PREFIX/var/lib/guarden/services/qapp-production/home/.local/share/containers
driver=$containers/storage/secrets/filedriver
assert_file_exists "$driver/secretsdata.json"
assert_mode "$driver" 700
assert_owner "$driver" qapp-production:qapp-production
assert_file_has "$containers/storage/secrets/secrets.json" "DB_PASSWORD"
encoded=$(printf '%s' "$VALUE" | base64 -w0)
assert_file_has "$driver/secretsdata.json" "$encoded"

# And podman agrees, asked as the service user. `env -C` puts it in a directory
# that user can enter, because a rootless container process enters its caller's
# working directory as that uid — the fact `credentials.materialise` now accounts
# for, and the reason an operator running it from `/root` used to fail.
run_installed env -C "$GUARDEN_PREFIX/var/lib/guarden/services/qapp-production/home" \
    runuser -u qapp-production -- podman secret ls
assert_exit 0
assert_stdout_has "DB_PASSWORD"

# And nowhere else in guarden's own tree. Every file guarden owns is searched for
# the value in the clear, so this is a fact about the tree rather than about the
# handful of paths this test thought of: it is in no blob, no registry, no rendered
# unit, no snapshot — and in podman's store it is encoded. It is recoverable from
# exactly one place, that service's `0700` home.
#
# **The three roots are named, and `/` is not among them.** Guarden's whole footprint
# on a host is `/etc/guarden`, `/var/lib/guarden` and `/usr/lib/guarden`, so those are
# the three that are searched; `grep -rl /` would walk `/proc` and `/sys` and read every
# file on the machine, which is not a bigger claim about this value — it is a different
# question, asked slowly.
#
# `|| true` is load-bearing: `grep -rl` exits 1 when it finds nothing, which is the
# answer this wants, and under `set -e` an assignment whose substitution fails ends
# the suite on a green assertion.
matches=$(grep -rl -- "$VALUE" /etc/guarden /var/lib/guarden /usr/lib/guarden 2>/dev/null || true)
[ -z "$matches" ] || {
    printf 'the value is in:\n%s\n' "$matches" >&2
    exit 1
}