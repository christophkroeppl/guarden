#!/usr/bin/env bash
# Non-default modules, selected from cloud-init and from the script, and the
# lock that makes the selection survive a later `weedr module add`.
#
# spec 3.5: `guarden.toml` has three writers and two of them share a key. `soil
# install` writes the measured `ingress.alias` and seeds `[modules] enabled`;
# `weedr module add` appends to `[modules] enabled`. Both take the `modules`
# lock, both go through the write protocol, and both re-read the file under the
# lock rather than trusting what they saw before it.
#
# The selection is seeded, not converged: an operator who chose a module set at
# boot keeps that choice, and a later `weedr module add` appends to it rather
# than being erased by the next `soil install --apply`. That asymmetry is the
# whole reason the seeding takes the lock.

. "$(dirname "$0")/lib.sh"
scratch_host

# A root-owned guarden.toml with the environment table, so the environment name
# resolves. Without it every `soil install` here refuses before reaching the
# module selection, and the suite reports a config error for what is a module
# test. scratch_host makes only the host root, so the directory is ours to make.
mkdir -p "$GUARDEN_PREFIX/etc/guarden"
stage_config guarden-measured.toml

# A module the operator did not ask for is not recorded, and one they did is.
# The selection is what cloud-init's `modules:` key and the script's `--modules`
# flag both put into `guarden.toml`. The fixture has a measured alias, so this
# converge finishes and exits 0.
run soil install --apply --modules gate,homepage
assert_exit 0
assert_called "install -m"
assert_file_has "$(host etc/guarden/guarden.toml)" 'enabled = ["gate", "homepage"]'

# Seeded, not converged. A selection that is a subset of what is already
# recorded holds, so a second apply with the same names changes nothing.
run soil install --check --modules gate,homepage
assert_stderr_lacks "[modules] enabled records a selection"

# And a `weedr module add` that appended to the key keeps what it appended: the
# next `soil install --apply` calls that drift-free rather than narrowing the
# list back to the boot selection. Two writers, one key, and the seeding one
# yields — which is the claim the `modules` lock exists to make safe. The
# fixture is the state that verb leaves behind.
stage_config guarden-module-added.toml
run soil install --check --modules gate,homepage
assert_stderr_lacks "[modules] enabled records a selection"
assert_file_has "$(host etc/guarden/guarden.toml)" 'enabled = ["gate", "homepage", "auth"]'

# A selection naming a module that is not enabled is real drift, and `--apply`
# adds it alongside rather than replacing the list.
run soil install --check --modules auth,media
assert_exit 1
assert_stderr_has "drift: [modules] enabled records a selection"

run soil install --apply --modules media
assert_exit 0
assert_file_has "$(host etc/guarden/guarden.toml)" 'enabled = ["gate", "homepage", "auth", "media"]'

# The lock is taken for that write. A file under /run/guarden/locks is what a
# lock is, per spec 3.5, and its absence is what made the write unsafe.
assert_file_exists "$GUARDEN_HOST/run/guarden/locks/modules.lock"

# And the file carries the two keys its own writers own and nothing else: the
# measured alias and the selection, with the operator's tracks intact.
assert_file_has "$(host etc/guarden/guarden.toml)" 'name = "production"'
assert_file_has "$(host etc/guarden/guarden.toml)" 'name = "preview"'
assert_file_has "$(host etc/guarden/guarden.toml)" 'publication_range = [20000, 32767]'

# `--check` never writes: the selection the apply just recorded is still there,
# and the only thing still not converged is whatever this host has not done.
run soil install --check --modules auth,media
assert_exit 0
assert_stderr_empty

# --- an empty or malformed selection is a rejected input ---------------------

# `--modules` takes names, not a path and not a flag: a selection carrying
# either is the caller asking for something the key cannot hold.
run soil install --apply --modules ""
assert_exit 2
assert_stderr_has "--modules"

run soil install --apply --modules "gate, --apply"
assert_exit 2
assert_stderr_has "--modules"

run soil install --apply --modules "a b"
assert_exit 2
assert_stderr_has "--modules"

# And it is `soil install`'s alone: a selection on a phase that does not record
# one would be a flag that does nothing and looks like it did.
run soil packages --check --modules gate
assert_exit 2
assert_stderr_has "--modules"

run soil list --modules gate
assert_exit 2
assert_stderr_has "--modules"