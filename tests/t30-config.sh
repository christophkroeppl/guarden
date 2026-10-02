#!/usr/bin/env bash
# guarden.toml is TOML read with the standard library, and the environment set is
# that table rather than a code enum (spec 3.1, ticket 30 item 1).
#
# The two exit codes are the point and they are not the same code: a file that
# will not parse, or a key whose type is wrong, is the host and so is exit `1`
# with the file and the key named; a well-formed file that breaks a rule the
# document states is exit `2` naming the track. The proof that the table is data
# — that a `preprod` block works and nothing in the code knows the word — is in
# t30-create.sh, because it needs a service to exist.

. "$(dirname "$0")/lib.sh"

export GUARDEN_PREFIX=/
# The real path, not a relocated one: stage_config writes where guarden reads,
# and /etc/guarden is absent on a host where `soil install` has never run.
mkdir -p /etc/guarden
stage_config guarden.toml

# A host with the shipped table and no services is a done state, not a failure.
run weedr service list
assert_exit 0
assert_stdout_has "no services"

# With the shipped table staged, the complaint is about the poke's tree rather
# than about the configuration: that is what this ticket's first item claims, and
# it is the only thing a staged host can say about the table before a service
# exists. That a row's free_limit is read as a number when the shipped table
# writes one as a float and two as strings is proven where a value is used, in
# t30-create.sh.
run weedr service ingest myapp-production --from poke myapp@9f2c1ab
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "the manifest"
assert_stderr_lacks "free_limit"

# A file that will not parse names the file and the line.
stage_config guarden-badtoml.toml
run weedr service ingest myapp-production --from poke myapp@9f2c1ab
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "guarden.toml is not valid TOML"
# The status command still answers on a host whose table will not parse: it reads
# the registries and not the configuration, so a corrupt file is a rejected
# ingest rather than a box that cannot report itself.
run weedr service list
assert_exit 0
assert_stdout_has "no services"

# A key of the wrong type names the key. `weight = "heavy"` is a typo in a
# root-owned file, not a manifest a stranger wrote, and the dividing line in
# spec 1.2 is input against host.
stage_config guarden-badweight.toml
run weedr service ingest myapp-production --from poke myapp@9f2c1ab
assert_exit 1
assert_stderr_has "weight is not an integer"
assert_stderr_has "guarden.toml"

# cap on a slot track: a rule the document states about a track, so exit 2, and
# it names the track. `cap` appears nowhere else in the file, because a second
# place to set it is a second place for it to be wrong.
stage_config guarden-slotcap.toml
run weedr service ingest myapp-production --from poke myapp@9f2c1ab
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "'lab'"
assert_stderr_has "must not carry a cap"

# fork_from naming no track in the same table, which is the rule that stops a
# production service forking from a track the operator never wrote down.
stage_config guarden-badfork.toml
run weedr service ingest myapp-production --from poke myapp@9f2c1ab
assert_exit 2
assert_stderr_has "fork_from 'nope' names no track"
run weedr service list
assert_exit 0
assert_stdout_has "no services"

# A track with kind = "instance" and no cap is the same rule from the other side,
# so it is checked in a file of its own rather than a copy of the shipped one.
stage_config guarden-nocap.toml
run weedr service ingest myapp-production --from poke myapp@9f2c1ab
assert_exit 2
assert_stderr_has "'previews'"
assert_stderr_has 'must carry a cap'

# The shipped table's own free_limit is a float on one row and a string on the
# other two, and both are read as numbers: a retention value that is sometimes
# 0.1 and sometimes "0.2" is one two programs would round differently. What it
# rounds to is proven where a value is actually used, in t30-create.sh.
stage_config guarden.toml
assert_file_has "$GUARDEN_PREFIX/etc/guarden/guarden.toml" 'free_limit = 0.10'
assert_file_has "$GUARDEN_PREFIX/etc/guarden/guarden.toml" 'free_limit = "0.20"'
