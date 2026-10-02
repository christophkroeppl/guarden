#!/usr/bin/env bash
# Modules are configuration, not plugins: `[modules] enabled` in guarden.toml, and
# a converge that reads it.
#
# (ticket 130, spec 3.5, 6.1, ADR-0008)
#
# **Three writers share `guarden.toml` and two of them share a lock.** `weedr
# module add` appends to `[modules] enabled`, `soil install` writes the measured
# `ingress.alias` and seeds `[modules] enabled` from cloud-init, and an operator
# edits it. Every one of them takes the `modules` lock, goes through the write
# protocol, and **re-reads the file under the lock** rather than trusting what it
# saw before it — so a `weedr module add` that appended while an install waited for
# the lock is still in the list, and the installer adds its selection alongside it
# rather than replacing the key.
#
# That composition is the claim this file is about, and it is asserted against the
# **file on disk** rather than against a record of the write: a stand-in could
# report a lock taken and a write made, and neither of those is the composition.
# The state is a `guarden.toml` that names both writers' contributions.
#
# The whole run is against the real machine: `GUARDEN_PREFIX=/`, the real
# `/etc/guarden`, the real `getent`, and no `install` that wrote a line into a
# fixture. The one thing the suite plants is the host configuration itself, and
# that is not a stand-in for anything — it is the file the claim is about, and a
# table this file did not write would make every assertion below a statement
# about whatever the machine happened to boot with.

. "$(dirname "$0")/lib.sh"

# The machine's own tools, not the stand-ins in fixtures/bin. `.venv/bin` is kept
# first because it is the checkout's interpreter and not a stand-in for anything.
export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

export GUARDEN_PREFIX=/
mkdir -p /etc/guarden
if ! getent group guarden >/dev/null 2>&1; then
    groupadd --system guarden
fi
config=/etc/guarden/guarden.toml

# `soil install --modules` names the selection once and records it, and the
# **subset** check is the rule: a selection is a narrowing of what a host needs,
# so naming a superset of what is installed is not an error — the extra names are
# simply not converged yet.
#
# The staged table carries `[modules] enabled` **empty** and `ingress.alias`
# **measured**, and both halves earn their place. The empty selection is what
# makes the merge claim non-vacuous: every shipped fixture already carries
# `["gate", "homepage"]`, so a test that started from one of those could never
# distinguish "the installer's selection was merged" from "the file already said
# this" — the first assertion would have been satisfied before the apply ran.
# The measured alias is what keeps the non-zero exits in this file honest: the
# alias is the one item of `install` that only the probe can write, this
# repository ships no probe image for it, and a suite whose exit codes came from
# that item would be asserting the probe's absence rather than anything about
# modules. So every exit code below is the phase's own answer on a host whose
# state this file set: the drift the fixture states is reported before the apply
# that fixes it, and a converged host is silent.
stage_config guarden-nomodules.toml
run soil install --check --modules gate
assert_exit 1
# The drift this suite introduced is named, and it is the selection: the file
# records no module and the caller named one.
assert_stderr_has "[modules] enabled records a selection nobody has to choose twice"
# Nothing else supplies that exit code. An `install --check` on this host that
# reported `ingress.alias` would be reporting an item no phase owns here, and the
# suite would be green for the wrong reason.
assert_stderr_lacks "ingress.alias"
# `--check` never writes, and the only way to see that is to ask twice: a second
# `--check` on a host the first one did not change finds exactly what the first
# found. A `--check` that wrote would make the drift line disappear on the second
# run, which is the shape of a bug this assertion is here to catch.
run soil install --check --modules gate
assert_exit 1
assert_stderr_has "[modules] enabled records a selection nobody has to choose twice"
run soil install --apply --modules gate
assert_exit 0
assert_stderr_empty
assert_file_has "$config" 'enabled = ["gate"]'

# A converged host is silent about the selection, because the item holds as soon
# as **any** choice is recorded. A later `weedr module add` is not drift the next
# apply would erase — which is only worth asserting if the check is silent about
# everything else too.
run soil install --check --modules gate
assert_exit 0
assert_stderr_empty

# Naming a second module appends rather than replacing, which is the composition:
# the installer's selection is merged with what the file already says, under the
# lock, with a re-read.
run soil install --apply --modules homepage
assert_exit 0
assert_file_has "$config" 'enabled = ["gate", "homepage"]'

# `weedr module add` is the third writer of that key and it appends too. It is
# **not implemented yet** — `cli.pending` is what answers it, and no `modules/`
# directory ships in this repository — so the verb's behaviour is asserted as
# pending rather than exercised, and the append it would perform is asserted
# through the writer that *is* implemented.
#
# The assertion that used to sit here was `assert_called "install -m"`, read from a
# call log after the verb ran. It was asking a stand-in what it had been asked to
# write, and the honest answer to that claim on this tree is that there is nothing
# to ask: the verb has no body yet. **No probe was invented to preserve it** — a
# probe that wrote a module file itself would be asserting that the probe works,
# which is the failure ADR-0014 retires.
#
# What is left is the composition claim, which is about the *key* and is therefore
# about the two implemented writers: a second `soil install --modules` merges with
# what the file already says rather than replacing the value, and it does so
# because it re-reads under the lock.
assert_file_missing /usr/lib/guarden/modules/gate/module.toml
run weedr module add gate
assert_exit 1
assert_stderr_has "not implemented"
assert_file_missing /usr/lib/guarden/modules/gate/module.toml

# The append composed rather than replacing, so both the installer's selection and
# the module's own are in the list. This is the whole of the shared-key claim and
# it is a fact about the file.
assert_file_has "$config" 'enabled = ["gate", "homepage"]'

run soil install --check --modules gate
assert_exit 0
assert_stderr_empty
# And the other keys survive both writers, because a write rewrites one key and
# not the file. A `module add` that replaced the table would have dropped the
# environment rows along with them, and every track would have gone with it.
assert_file_has "$config" "[[environments]]"
assert_file_has "$config" 'name = "production"'
assert_file_has "$config" 'gated = true'
assert_file_has "$config" 'alias = "192.0.2.1"'
assert_file_has "$config" 'domain = "example.com"'

# An operator's own edit is the third writer, and the failure two writers sharing
# one key cause is the next `soil install --apply` narrowing the list back. The
# staged fixture states the situation — a table whose `[modules] enabled` names a
# module the installer was never told about — so the claim does not depend on a text
# substitution working.
#
# The installer does **not** narrow it. The item holds as soon as any choice is
# recorded, and a converge that replaced the list would erase a selection nobody
# re-entered, which is the whole reason the value is merged under a re-read rather
# than written from the caller's selection alone. So `--check` is silent about the
# key on a host that has it, and the apply that follows converges nothing.
stage_config guarden-module-added.toml
assert_file_has "$config" 'enabled = ["gate", "homepage", "auth"]'
run soil install --check --modules gate
assert_exit 0
assert_stderr_empty
assert_file_has "$config" 'enabled = ["gate", "homepage", "auth"]'
run soil install --apply --modules auth
assert_exit 0
# Merged, not replaced: the operator's `auth` survived and the caller's selection
# was found already present, so the list is unchanged rather than duplicated. A
# writer that appended without de-duplicating would carry `auth` twice, and a
# module's own edge group would then be added to the box twice.
assert_file_has "$config" 'enabled = ['
assert_file_has "$config" '"auth"'
assert_file_has "$config" '"homepage"'
# And every other key survived both writers, because a write rewrites one key and
# not the file. A writer that replaced the table would have dropped the environment
# rows along with it, and every track would have gone with them.
assert_file_has "$config" "[[environments]]"
assert_file_has "$config" 'name = "production"'
assert_file_has "$config" 'gated = true'
assert_file_has "$config" 'alias = "192.0.2.1"'
assert_file_has "$config" 'domain = "example.com"'

# An unknown module is rejected input rather than a module that silently enables
# nothing — but the verb is pending, so on this tree the verb is what answers and
# the name never reaches a parser. The input assertion is left to the ticket that
# writes the verb's body; asserting it now would be asserting a diagnostic this
# repository does not produce.
run weedr module add nosuchmodule
assert_exit 1
assert_stderr_has "not implemented"
assert_file_lacks "$config" "nosuchmodule"

# The lock directory is where the `modules` lock lives, and it is tmpfs: only the
# queue is durable, and a lock that outlived a boot would be a lock nobody can take.
# The entry that recreates it at boot is `soil storage`'s, and the assertion is
# that the directory exists and is not in the durable tree.
assert_file_exists /run/guarden/locks
assert_file_missing /var/lib/guarden/locks

# A host with no `[modules]` key at all is the state a fresh box is in, and the
# seed writes one. The shipped table has the key, so a host staged with a table
# that has none is the case worth asserting — and it is the one case where the
# value genuinely is replaced rather than merged, because there is nothing to merge
# with. It is also the one case where the converge *has* something to do, so the
# exit code follows the state the file was just put into rather than an item
# borrowed from the probe.
sed -i '/^\[modules\]/,+1d' "$config"
# The key is gone. The assertion names the key rather than the word `[modules]`,
# because this fixture's own header comment names the table and a search for that
# string alone matched the comment and never described the host.
assert_file_lacks "$config" "enabled = "
run soil install --check --modules gate
assert_exit 1
assert_stderr_has "[modules] enabled records a selection nobody has to choose twice"
run soil install --apply --modules gate
assert_exit 0
assert_file_has "$config" 'enabled = ["gate"]'
run soil install --check --modules gate
assert_exit 0
assert_stderr_empty
