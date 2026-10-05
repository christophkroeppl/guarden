#!/usr/bin/env bash
# Ticket 90: the gitops receiver. A project's key is bound to it by a forced
# command, a push pokes the box, and the box asks the deploy queue to do the
# work. Every assertion is a question to the machine — the exit code and the
# one diagnostic line each verb wrote, the mode and owner of a staging
# directory, and the bytes of the `authorized_keys` file. Nothing here reads a
# record of what a program was about to do, and there is no stand-in on `PATH`.
#
# `GUARDEN_PREFIX=/` and the machine's own identity databases, the way
# `t120-deploy` and `t30-create` do it: the per-project staging directory is
# `chown`ed to the real `hose` user, and a staged `/etc/passwd` reconciled
# against a real `useradd` is a true sentence about two databases and a fact
# about no project.
#
# **`weedr project` is not exercised here.** The receiver is. The projects are
# staged exactly as `weedr project add` writes them — a per-project copy in
# `projects.d/`, `0444` and root-owned, because that mode is the carve-out that
# lets the network-facing program read a ref allowlist and nothing else under
# `/etc/guarden` — and the forced commands are staged exactly as
# `weedr project grant` writes them. The mutator's own verbs need a dispatch
# entry in `weedr.py`, which this ticket does not own; they are in
# `t90-projects.sh`.
#
# No poke below reaches a deploy: this machine installs no `furrow` and this
# file does not run `soil install`, so the receiver's own refusal is what
# answers and it is asserted by name. What is under test is the receiver's own
# behaviour — the allowlist, the archive, the derived name, the refusals, and
# the staging directory's lifecycle.
#
# machine: fresh

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GUARDEN_PREFIX=/

id -u hose >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin \
    --home-dir /var/lib/guarden hose
ensure_accounts
mkdir -p /etc/guarden/projects.d /etc/ssh/authorized_keys.d

# `furrow` must EXIST for the track claim to be checkable. Its absence is a real
# refusal the suite tests separately (a poke reaches the queue only through it),
# but on that path the diagnostic names the missing program and cannot name the
# service — so "the deploy named myapp-production on the production track", which
# is what this file is about, is unobservable without it.
install -d -m 0755 /usr/lib/guarden/bin
for prog in soil weedr furrow hose; do
    [ -f "$GUARDEN_ROOT/src/guarden/$prog.py" ] || continue
    # The harness has no venv in the guest: it runs the programs from the checkout,
    # so the wrapper points at /usr/bin/python3 and puts the checkout on the path.
    printf '#!/bin/sh\nPYTHONPATH=%s/src exec /usr/bin/python3 -m guarden.%s "$@"\n' \
        "$GUARDEN_ROOT" "$prog" > "/usr/lib/guarden/bin/$prog"
    chmod 0755 "/usr/lib/guarden/bin/$prog"
done

staging=/var/lib/guarden/staging
tree=/var/lib/guarden/staging/myapp
keys=/etc/ssh/authorized_keys.d/hose
manifest=$staging/myapp/9f2c1ab/.guarden/service.yml

install -d -m 0755 -o root -g root "$staging"
install -d -m 0770 -o root -g guarden /var/lib/guarden/queue
install -d -m 0770 -o root -g guarden /run/guarden/locks
install -d -m 0750 -o root -g guarden /var/lib/guarden/registry
install -m 0640 -o root -g guarden "$GUARDEN_ROOT/fixtures/guarden.toml" \
    /etc/guarden/guarden.toml
# The per-project directory, pre-created and owned by the `hose` user, because
# `hose` is unprivileged and cannot `mkdir` under a `0755 root:root` parent. A
# poke's own tree inside it is `0755` with `0644` files, so `guarden` can render
# it and root can read it.
install -d -m 0755 -o hose -g root "$tree"

seed /etc/guarden/projects.d/myapp.toml \
    '[projects.myapp]' \
    'repository = "git@github.com:you/myapp.git"' \
    'environments = { "main" = ["production"], "develop" = ["staging"], "*" = ["preview"] }'
chmod 0444 /etc/guarden/projects.d/myapp.toml

# The forced command `weedr project grant` writes, with a real key generated on
# this machine: `hose check` decodes the blob and prints its fingerprint, so a
# made-up base64 string would make that check vacuously pass or fail.
ssh-keygen -q -t ed25519 -N '' -C myapp-ci -f "$GUARDEN_FIXTURES/myapp"
ssh-keygen -q -t ed25519 -N '' -C other-ci -f "$GUARDEN_FIXTURES/other"
write_key() {
    printf 'command="/usr/lib/guarden/bin/hose --project %s",no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty %s guarden-added-2026-01-01T00:00:00Z\n' \
        "$1" "$(cat "$2")" >>"$keys"
}
: >"$keys"
write_key myapp "$GUARDEN_FIXTURES/myapp.pub"
chmod 0644 "$keys"

tree_tar=$GUARDEN_FIXTURES/tree.tar
tar -C "$GUARDEN_ROOT/fixtures/projects/quadlet-app" -cf "$tree_tar" .

# --- the interface ------------------------------------------------------------

# The verb sets are the contract (spec 6.7): `poke`, `drop`, `check`, and no
# `--project` argument anywhere, because a client's would beat the forced
# command's.
assert_verbs hose poke drop check
stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_not_rejected
run hose --help
assert_exit 0
assert_stdout_lacks "--project "

# --- the project comes from the forced command and nowhere else --------------

# sshd appends the client's command to the forced one, so a client's
# `--project` would be the last occurrence and the one a conventional parser
# read. Two occurrences is exit 2 naming the argument, and nothing is unpacked.
run hose --project myapp poke main 9f2c1ab --project other
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "--project"
assert_file_missing "$manifest"

# The forced command is the only place a project name appears at runtime, so an
# invocation carrying none is refused rather than guessed at. `hose` run by
# hand, the way a poke is not, has no project and can deploy nothing.
run hose poke main 9f2c1ab <"$tree_tar"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "--project"

# A project nobody registered is the host, not the request.
run hose --project nosuch poke main 9f2c1ab <"$tree_tar"
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "no project"
assert_file_missing "$manifest"

# --- the allowlist decides the track, and a permission set is not an assignment

# `main` maps to `production`, which is `gated = true`. The poke still creates
# the service: with no git clone reachable from CI, the staged tree a poke
# carries is the only way code reaches a workload that does not exist yet, and
# what stands between a push and a running production container is the gate, not
# the creation. So the deploy names `myapp-production`, and a track table this
# program may not read does not change that.
#
# The deploy then fails, because no `furrow` is installed here, and that is
# stated rather than worked around. What is under test is that the tree was
# unpacked, that the right service on the right track was named, and that the
# tree is gone afterwards whatever the deploy returned.
run hose --project myapp poke main 9f2c1ab <"$tree_tar"
assert_exit 1
assert_stdout_has "unpacked"
assert_one_diagnostic "error:"
assert_stderr_has "myapp-production"

# The missing-`furrow` refusal is a real one and it is checked on its own
# precondition, because it is the only diagnostic that CANNOT name the service:
# it names the program that is not there.
mv /usr/lib/guarden/bin/furrow /usr/lib/guarden/bin/furrow.away
run hose --project myapp poke main 9f2c1ab <"$tree_tar"
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "not installed"
mv /usr/lib/guarden/bin/furrow.away /usr/lib/guarden/bin/furrow
assert_file_missing "$manifest"
# The per-project parent survives for the next poke; `weedr project revoke` is
# what removes it.
assert_file_exists "$tree"

# A ref the allowlist maps to an instance track deploys an instance, and the ref
# is escaped internally so `feature/x` and `feature-x` cannot collide.
# The instance retry fires: `hose` cannot read guarden.toml, so it tries the bare
# name, the mutator refuses with the shape it wanted, and `hose` retries with
# `myapp-preview/feature/login`. What is refused here is the retry's own argument
# — this fixture's allowlist maps `*` to a track whose container is not in the
# registry — so exit 2, a rejected input, and both refusals are on stderr.
run hose --project myapp poke feature/login 9f2c1ab <"$tree_tar"
assert_exit 2
assert_stderr_has "myapp-preview"
assert_file_missing "$manifest"

# A ref matching nothing is refused with the reason and the exit the spec gives
# it: `1`, because the allowlist that would have permitted it is the host.
# `myapp`'s own table carries a `*` catch-all, so the ref has to be one that a
# table WITHOUT a catch-all does not cover — hence the narrow project.
seed /etc/guarden/projects.d/narrow.toml \
    '[projects.narrow]' \
    'repository = "git@github.com:you/narrow.git"' \
    'environments = { "main" = ["staging"] }'
chmod 0444 /etc/guarden/projects.d/narrow.toml
run hose --project narrow poke release/9.9 9f2c1ab <"$tree_tar"
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "matches no pattern"
assert_stderr_has "narrow.toml"
assert_file_missing "$manifest"

# **First match wins, and nothing inside the set is decided by order.** A pattern
# carrying two tracks is legal and the poke names the one it wants; a pattern
# carrying several with none named is refused with the set printed, because a
# rule that silently took the first would make a permission set behave like an
# assignment, which is the confusion the allowlist exists to avoid.
seed /etc/guarden/projects.d/multi.toml \
    '[projects.multi]' \
    'repository = "git@github.com:you/multi.git"' \
    'environments = { "release/*" = ["staging", "production"] }'
chmod 0444 /etc/guarden/projects.d/multi.toml
run hose --project multi poke release/1.0 9f2c1ab <"$tree_tar"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "staging"
assert_stderr_has "production"
assert_file_missing /var/lib/guarden/staging/multi/9f2c1ab

# Naming one is accepted, and it is the one the service is named from.
run hose --project multi poke release/1.0 9f2c1ab production <"$tree_tar"
assert_exit 1
assert_stderr_has "multi-production"
assert_stderr_lacks "multi-staging"

# Naming one the ref's set does not grant is refused with the set printed.
run hose --project multi poke release/1.0 9f2c1ab preview <"$tree_tar"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "may deploy to"
assert_stderr_has "staging"
assert_file_missing /var/lib/guarden/staging/multi/9f2c1ab

# **First match wins, and that is decided by the order the file declares — not
# by the specificity of the pattern.** `*` is first here, so it is the set that
# applies to every ref, `release/*` is never consulted, and the release branch is
# offered exactly one environment: the catch-all's. A receiver that sorted the
# patterns or preferred the more specific one would answer differently, and the
# admin's file would then mean something nobody wrote.
seed /etc/guarden/projects.d/order.toml \
    '[projects.order]' \
    'repository = "git@github.com:you/order.git"' \
    'environments = { "*" = ["preview"], "release/*" = ["staging"] }'
chmod 0444 /etc/guarden/projects.d/order.toml
# `*` is the catch-all and it is declared first, so `release/*` is never
# consulted and the branch is offered exactly the catch-all's track. Exit 2: the
# instance retry fires and its own argument is the rejected input, which is the
# whole point — the track chosen is the one the admin's ORDER named.
run hose --project order poke release/2.0 9f2c1ab <"$tree_tar"
assert_exit 2
assert_stderr_has "order-preview"
assert_stderr_lacks "order-staging"

# --- a malformed poke is refused before anything is unpacked ------------------

run hose --project myapp poke main nothex <"$tree_tar"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "hexadecimal"
assert_file_missing /var/lib/guarden/staging/myapp/nothex

run hose --project myapp poke main abc <"$tree_tar"
assert_exit 2
assert_stderr_has "shorter than"

run hose --project myapp poke 'main;rm -rf /' 9f2c1ab <"$tree_tar"
assert_exit 2
assert_stderr_has "[A-Za-z0-9._/-]"

run hose --project myapp poke ../../etc 9f2c1ab <"$tree_tar"
assert_exit 2
assert_stderr_has "path"

# --- the archive is unpacked safely, and this file says so -------------------

escape=$GUARDEN_FIXTURES/escape
mkdir -p "$escape"
printf 'x\n' >"$escape/pwned"
ln -sf /etc/passwd "$escape/link"

tar -cf "$GUARDEN_FIXTURES/absolute.tar" -C "$escape" --transform='s|pwned|/etc/guarden/pwned|' pwned
run hose --project myapp poke main 9f2c1ab <"$GUARDEN_FIXTURES/absolute.tar"
assert_exit 2
assert_stderr_has "absolute name"
assert_file_missing /etc/guarden/pwned
assert_file_missing "$manifest"

tar -cf "$GUARDEN_FIXTURES/traversal.tar" -C "$escape" --transform='s|pwned|../../etc/guarden/pwned|' pwned
run hose --project myapp poke main 9f2c1ab <"$GUARDEN_FIXTURES/traversal.tar"
assert_exit 2
assert_stderr_has "'..'"
assert_file_missing /etc/guarden/pwned

# A regular file reached through a symlink that escapes is refused too. The
# member's own name is an ordinary path, so only the check that the resolved
# path stays inside the staging directory catches this one, and a receiver
# without it would write outside the tree it owns.
sneaky=$GUARDEN_FIXTURES/sneaky
mkdir -p "$sneaky"
ln -sfn /etc/guarden "$sneaky/out"
printf 'y\n' >"$GUARDEN_FIXTURES/payload-body"
ln -sfn "$GUARDEN_FIXTURES/payload-body" "$sneaky/payload"
# `out` has to be a MEMBER, not just a path component: tar recorded only the file
# it reached through the link, so the archive held nothing that could escape and
# the refusal could never fire. WITHOUT -h too — `-chf` would dereference the link
# and record a plain file, which is the same vacuous test wearing a different hat.
tar -cf "$GUARDEN_FIXTURES/escape.tar" -C "$sneaky" out payload
run hose --project myapp poke main 9f2c1ab <"$GUARDEN_FIXTURES/escape.tar"
assert_exit 2
assert_stderr_has "is a link"
assert_file_missing /etc/guarden/payload

# A member that is not a regular file is refused by name: a symlink member is
# refused before it is created, so no symlink is ever followed.
tar -cf "$GUARDEN_FIXTURES/link.tar" -C "$escape" link
run hose --project myapp poke main 9f2c1ab <"$GUARDEN_FIXTURES/link.tar"
assert_exit 2
assert_stderr_has "link"
assert_file_missing "$manifest"

# Nothing outside the staging tree was written by any of the refusals, and no
# refusal left a partial tree behind either.
rm -f /etc/guarden/payload
assert_file_missing "$manifest"

# A well-formed archive is unpacked `0755`/`0644` as the `hose` user, and the
# mode is asserted on the tree while it exists. The tree is gone afterwards,
# which is the next assertion, so the mode is read from a run whose deploy
# answer this suite can see: the deploy is refused after the unpack, and the
# removal happens whatever the deploy returned.
run hose --project myapp poke develop 9f2c1ab <"$tree_tar"
assert_exit 1
assert_file_missing "$manifest"
assert_mode "$staging/myapp" 755
assert_owner "$staging/myapp" "hose:root"

# --- `hose drop` derives the name and never takes one -------------------------

# A ref on a slot track names no instance, so a drop is refused rather than
# turned into a service removal — and the diagnostic says which track and why,
# because a refusal that names nothing is one nobody can act on.
run hose --project myapp drop main
assert_exit 2
assert_stderr_has "slot"
assert_stderr_has "instance"
assert_stderr_has "myapp"

# A ref on the instance track is dropped through `furrow preview drop` with a
# name derived here and never accepted from the caller, so a key for one
# project cannot drop another project's instance.
run hose --project myapp drop feature/login
assert_exit 1
assert_stderr_has "myapp-preview"

run hose --project myapp drop '../../etc'
assert_exit 2
assert_stderr_has "path"

# --- `hose check` verifies, and is not a stub ---------------------------------

# Everything in order: the key names this project, the staging directory is the
# `hose` user's, the ref maps to a track, and what `furrow` reads as `guarden`
# is readable by that group.
run hose --project myapp check
assert_exit 0
assert_stdout_has "could deploy"
assert_stderr_empty

# It changes nothing, so CI may call it on every push. The keys file is byte for
# byte what it was and the staging directory is still there.
keys_before=$(sha256sum "$keys" | cut -d' ' -f1)
run hose --project myapp check
assert_exit 0
keys_after=$(sha256sum "$keys" | cut -d' ' -f1)
[ "$keys_before" = "$keys_after" ] || _fail "hose check changed the authorized_keys file"
assert_file_exists "$tree"

# A ref outside the allowlist is a failure the workflow sees before it pushes.
# `narrow`, not `myapp`: myapp's table carries a `*` catch-all, so release/9.9
# matches it and there is nothing to fail — the same vacuous assertion in a
# different project.
run hose --project narrow check release/9.9
assert_exit 1
assert_stderr_has "matches no pattern"

# A project with no key installed: the warning names what is missing and the
# command that fixes it, and the exit is 1.
seed /etc/guarden/projects.d/keyless.toml \
    '[projects.keyless]' \
    'repository = "git@github.com:you/keyless.git"' \
    'environments = { "*" = ["preview"] }'
chmod 0444 /etc/guarden/projects.d/keyless.toml
install -d -m 0755 -o hose -g root /var/lib/guarden/staging/keyless
run hose --project keyless check
assert_exit 1
assert_stderr_has "warning:"
assert_stderr_has "no poke key"
assert_stderr_has "keyless"

# A key bound to a different project is what one repository's workflow must not
# be able to answer as its own: `myapp`'s key is gone, so `myapp check` says so
# by name rather than passing on the strength of some other project's key.
: >"$keys"
write_key otherapp "$GUARDEN_FIXTURES/other.pub"
run hose --project myapp check
assert_exit 1
assert_stderr_has "no poke key"
assert_stderr_has "myapp"
run hose --project otherapp check
assert_exit 1
assert_stderr_has "no project"
assert_stderr_has "otherapp"

# One key blob bound to two projects is the shape that would let one repository
# reach another's services, and `check` names it rather than passing.
: >"$keys"
write_key myapp "$GUARDEN_FIXTURES/myapp.pub"
write_key keyless "$GUARDEN_FIXTURES/myapp.pub"
run hose --project myapp check
assert_exit 1
assert_stderr_has "keyless"
assert_stderr_has "reach another project"

# The staging directory is what `weedr project grant` creates and a poke cannot
# create for itself, so its absence is the failure a workflow needs to hear.
chmod 0755 /var/lib/guarden/staging/keyless
rm -rf /var/lib/guarden/staging/keyless
run hose --project keyless check
assert_exit 1
assert_stderr_has "staging directory"
assert_stderr_has "grant"

# And the mode: a tree `hose` could not write into is a failure named as one.
install -d -m 0555 -o hose -g root /var/lib/guarden/staging/keyless
run hose --project keyless check
assert_exit 1
assert_stderr_has "not writable"
chmod 0755 /var/lib/guarden/staging/keyless

# What `furrow` reads as `guarden` is a question only a machine answers: take
# the queue's group write away, or the environment table's group read, and the
# check says so by name.
chmod 0750 /var/lib/guarden/queue
run hose --project myapp check
assert_exit 1
assert_stderr_has "not writable by the guarden group"
chmod 0770 /var/lib/guarden/queue

chmod 0600 /etc/guarden/guarden.toml
run hose --project myapp check
assert_exit 1
assert_stderr_has "guarden.toml"
chmod 0640 /etc/guarden/guarden.toml

# --- the box keeps no clone and no checkout, and holds no forge credential ----

find "$staging" -name .git 2>/dev/null | grep -q . \
    && _fail "a poke left a git repository on the box"
assert_file_missing /root/.netrc
assert_file_missing /var/lib/guarden/deploy_key
assert_file_missing /etc/guarden/forge-token
assert_file_missing "$staging/myapp/.git"

# --- the shipped workflow template --------------------------------------------

workflow=$GUARDEN_ROOT/src/guarden/templates/poke-workflow.yml.j2
assert_file_exists "$workflow"
assert_file_has "$workflow" 'concurrency:'
assert_file_has "$workflow" 'cancel-in-progress: true'
# The poke key and nothing else: no registry token, no forge credential.
assert_file_has "$workflow" 'secrets.HOSE_POKE_KEY'
assert_file_lacks "$workflow" 'GITHUB_TOKEN'
assert_file_lacks "$workflow" 'SSH_PRIVATE_KEY'