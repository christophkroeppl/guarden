#!/usr/bin/env bash
# Ticket 90, the mutator's half: `weedr project add|list|keys|grant|revoke|remove`.
# A project is registered, a CI key is bound to it, and the key is taken away
# again — all of it root work on files the network-facing program may only read.
#
# **This file needs a dispatch entry in `weedr.py`, which ticket 90's author did
# not own.** The verb bodies are in `guarden/projects.py` and the four lines the
# program needs are the import and the six `HANDLERS` entries; until they are
# in, every verb below answers "weedr project … is not implemented" with exit
# 1 and the first assertion is the failure. That is recorded in
# `docs/tickets/90-gitops.md` rather than worked around, because a test that
# passes without the dispatch is a test that passes whatever it is about.
#
# `GUARDEN_PREFIX=/` and the machine's own identity databases: the staging
# directory `grant` creates is `chown`ed to the real `hose` user, and a staged
# `/etc/passwd` reconciled against a real `useradd` would be a true sentence
# about two databases and a fact about no project.
#
# machine: fresh

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GUARDEN_PREFIX=/

getent group guarden >/dev/null 2>&1 || groupadd --system guarden
id -u hose >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin \
    --home-dir /var/lib/guarden hose
mkdir -p /etc/guarden/projects.d /etc/ssh/authorized_keys.d
install -d -m 0755 -o root -g root /var/lib/guarden/staging
install -m 0640 -o root -g guarden "$GUARDEN_ROOT/fixtures/guarden.toml" \
    /etc/guarden/guarden.toml

keys=/etc/ssh/authorized_keys.d/hose
projects_d=/etc/guarden/projects.d
staging=/var/lib/guarden/staging

# Real keys, generated on this machine: the verb hashes the blob to print a
# fingerprint, and a made-up base64 string would make that assertion vacuous.
ssh-keygen -q -t ed25519 -N '' -C myapp-ci -f "$GUARDEN_FIXTURES/poke"
ssh-keygen -q -t ed25519 -N '' -C other-ci -f "$GUARDEN_FIXTURES/other"
pubkey=$(cat "$GUARDEN_FIXTURES/poke.pub")
second=$(cat "$GUARDEN_FIXTURES/other.pub")

# --- the dispatch entry this file is here to pin ------------------------------

run weedr project add myapp --repository 'git@github.com:you/myapp.git'
assert_exit 0

# --- `add` writes the per-project copy, and the mapping is an allowlist -------

assert_file_exists "$projects_d/myapp.toml"
assert_mode "$projects_d/myapp.toml" 444
assert_owner "$projects_d/myapp.toml" "root:root"
assert_file_has "$projects_d/myapp.toml" 'repository = "git@github.com:you/myapp.git"'
# The shared file is not written, so an edit is one file and a rollback is one
# `rm`. A project added into `projects.toml` would collide with every other.
assert_file_missing /etc/guarden/projects.toml
assert_file_has "$projects_d/myapp.toml" 'main = ["production"]'
assert_file_has "$projects_d/myapp.toml" 'develop = ["staging"]'
assert_file_has "$projects_d/myapp.toml" '"*" = ["preview"]'

# An environment the `[[environments]]` table does not define is refused naming
# the file and the key, rather than creating a track by accident.
run weedr project add unknown --repository u --environments 'main=nosuchtrack'
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "nosuchtrack"
assert_stderr_has "main"
assert_stderr_has "unknown.toml"
assert_file_missing "$projects_d/unknown.toml"

run weedr project add second --repository u --environments 'main'
assert_exit 2
assert_stderr_has "ref=track"
assert_file_missing "$projects_d/second.toml"

run weedr project add third --repository u --environments 'main=production|preview'
assert_exit 0
assert_file_has "$projects_d/third.toml" 'main = ["production", "preview"]'

# --- both files are honoured and `projects.d/` wins ---------------------------

seed /etc/guarden/projects.toml \
    '[projects.myapp]' \
    'repository = "git@github.com:shared/myapp.git"' \
    'environments = { "main" = ["staging"] }' \
    '[projects.onlyshared]' \
    'repository = "git@github.com:you/onlyshared.git"' \
    'environments = { "*" = ["preview"] }'
chmod 0444 /etc/guarden/projects.toml

run weedr project list
assert_exit 0
assert_stdout_has "myapp"
# The copy wins over the shared file, so the shared repository and the shared
# allowlist are both gone: an edit in one file and not two is the whole point.
assert_stdout_has "git@github.com:you/myapp.git"
assert_stdout_lacks "git@github.com:shared/myapp.git"
assert_stdout_has "onlyshared"

run weedr project list --json
assert_exit 0
assert_json projects.0.name '"myapp"'
assert_json projects.0.environments.main '["production"]'
assert_json projects.0.environments.develop '["staging"]'
assert_json_missing projects.0.deployed_sha
assert_json_missing projects.0.keys

# --- `grant` writes the forced command and creates the staging directory ------

run weedr project grant nosuch "$pubkey"
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "no project"
assert_file_missing "$keys"

# A key that is not ed25519 is refused: the line would name a key type this
# host does not read, and the poke would fail at the far end instead of here.
rsa=$(cut -d' ' -f2 <<<"$pubkey")
run weedr project grant myapp "ssh-rsa $rsa"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "ssh-ed25519"
assert_file_missing "$keys"

run weedr project grant myapp "not-a-key"
assert_exit 2
assert_stderr_has "ssh-ed25519"

# A blob that declares ed25519 and is not one is refused rather than written.
run weedr project grant myapp "ssh-ed25519 AAAA"
assert_exit 2
assert_stderr_has "not"
assert_file_missing "$keys"

run weedr project grant myapp "$pubkey"
assert_exit 0
assert_file_exists "$keys"
assert_mode "$keys" 644
assert_owner "$keys" "root:root"
# The forced command is the whole per-project binding: the project is in it and
# in no verb signature, so there is nothing for a client to supply or override.
assert_file_has "$keys" 'command="/usr/lib/guarden/bin/hose --project myapp"'
assert_file_has "$keys" 'no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty'
assert_file_has "$keys" 'ssh-ed25519'
assert_file_has "$keys" "guarden-added-"
# The per-project staging directory is created here, not when the poke arrives:
# `hose` is unprivileged and cannot `mkdir` under a `0755 root:root` parent.
assert_mode "$staging/myapp" 755
assert_owner "$staging/myapp" "hose:root"

# A second grant of the same key is already true, which is exit 0 and not a
# second line.
run weedr project grant myapp "$pubkey"
assert_exit 0
assert_stdout_has "already"
# Match the BLOB, not the whole `ssh-keygen` line: grant writes
# `<type> <blob> guarden-added-<stamp>` and does not carry the comment over, so a
# grep for the three-word original matches nothing and reports 0, which is not 1.
[ "$(grep -c -- "$(printf '%s' "$pubkey" | cut -d' ' -f2)" "$keys")" = 1 ] ||
    _fail "the key is installed twice"

run weedr project grant onlyshared "$second"
assert_exit 0
assert_file_has "$keys" 'hose --project onlyshared'
assert_mode "$staging/onlyshared" 755

# --- `keys` lists what is installed, and one project's list is one project's --

run weedr project keys myapp
assert_exit 0
assert_stdout_has "ssh-ed25519"
assert_stdout_has "SHA256:"
assert_stdout_lacks "onlyshared"

run weedr project keys myapp --json
assert_exit 0
assert_json project '"myapp"'
assert_json keys.0.type '"ssh-ed25519"'
# `assert_json` compares EXACTLY, so a bare `"SHA256:` prefix could never match a
# real digest — the assertion could not pass. The claim is the SHAPE: the standard
# SSH prefix, then 43 base64 characters with no padding. Checked here rather than
# through a new lib.sh helper, because lib.sh is shared with every other suite.
fp=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["keys"][0]["fingerprint"])' \
    "$GUARDEN_FIXTURES/last-stdout")
printf '%s' "$fp" | grep -qE '^SHA256:[A-Za-z0-9+/]{43}$' ||
    _fail "the reported fingerprint is $fp, not SHA256: plus 43 unpadded base64 characters"
assert_json_missing keys.0.key

run weedr project keys nosuch
assert_exit 1
assert_stderr_has "no project"

# --- `revoke` removes that project's lines and nothing else -------------------

run weedr project revoke myapp "ssh-ed25519 AAAA"
assert_exit 2
assert_stderr_has "not"
assert_file_has "$keys" "$rsa"

run weedr project revoke nosuch "$pubkey"
assert_exit 1
assert_stderr_has "no project"

run weedr project revoke onlyshared "$pubkey"
assert_exit 0
assert_stdout_has "no such key"
assert_file_has "$keys" 'hose --project myapp'

run weedr project revoke myapp "$pubkey"
assert_exit 0
assert_file_has "$keys" 'hose --project onlyshared'
assert_file_lacks "$keys" 'hose --project myapp'
assert_file_lacks "$keys" "$pubkey"
# The staging directory the grant created goes with the key, and the project
# does not: a repository an operator has not removed still deploys by hand.
assert_file_missing "$staging/myapp"

run weedr project keys myapp
assert_exit 0
assert_stdout_has "no poke key"

# --- `remove` is refused under a live key -------------------------------------

# A key whose every poke fails for a reason naming nothing is worse than no key.
# myapp's key was revoked above, so it needs one back: `remove` is refused while
# a live key names the project, and with nothing installed there is nothing to
# refuse.
run weedr project grant myapp "$pubkey"
assert_exit 0
run weedr project remove myapp
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "revoke"
assert_file_exists "$projects_d/myapp.toml"

run weedr project revoke onlyshared "$second"
assert_exit 0
run weedr project remove onlyshared
assert_exit 0
assert_file_missing "$projects_d/onlyshared.toml"
assert_file_missing "$staging/onlyshared"

run weedr project remove nosuch
assert_exit 1
assert_stderr_has "no project"

# --- a poke cannot name either verb -------------------------------------------

# `grant`, `revoke`, `keys` and `remove` are not in any verb signature of the
# network-facing program: the sudoers rule names `furrow deploy`,
# `furrow preview drop`, `furrow queue list`, `furrow status` and
# `weedr project list`, and `weedr project list` reads rather than writes.
for verb in grant revoke keys remove add; do
    run hose --project myapp "$verb"
    assert_exit 2
    assert_stderr_has "invalid choice"
done

# And `hose` has no verb that writes a key at all, which is why installing one
# is `weedr project grant` and never `hose grant`.
run hose --help
assert_exit 0
# The claim is about the VERB SET, not the word: the epilog says a poke "grants
# nothing", which is prose. What must not appear is `grant` as a command, so match
# it as one — at the start of a line in the command list, or as `hose grant`.
assert_verbs hose poke drop check
if printf '%s' "$GUARDEN_STDOUT" | grep -qE '(^|[[:space:]])grant([[:space:]]|$)'; then
    _fail "hose --help lists grant as a verb"
fi
if printf '%s' "$GUARDEN_STDOUT" | grep -q 'hose grant'; then
    _fail "hose --help names a 'hose grant' command"
fi