#!/usr/bin/env bash
# The operator documents agree with the code they describe.
#
# (tickets 310, 311, 312)
#
# **There was no mechanism for this before, and this file is it.** Every other
# suite in this repository asserts on a machine: a program's exit code, a file
# on a disk, a rule in a ruleset. The documents had no keeper at all, so a
# runbook could name a path that does not exist and a phase order the code does
# not implement, and nothing would say so until an operator followed the
# runbook on a fresh box and it failed. Three such claims were measured on two
# fresh boxes (deploy-verify-fresh-boxes.md, findings 1, 2, 3, 4, 5, 6, 7).
#
# So this suite asserts on **the documents as text**, and the assertions are
# of three kinds:
#
#   * a claim a document makes that the code contradicts — the update path,
#     the phase order, the checkout's location;
#   * a claim a document must make and does not — the fresh-install section,
#     the cwd before the template copy, a way to see a service answer, the
#     two-cycle cloud-init contract;
#   * a claim two documents must make the **same** way — the phase order and
#     the installer command appear in several places, and a rule stated twice
#     is a rule that drifts.
#
# **The comparison is against the program's own answer wherever one exists.**
# `soil list` prints the phases and `soil packages --list` prints the packages,
# so the phase order here is compared with the program's rather than written
# out a third time. A doc that names the wrong order fails against the program,
# not against a copy of the program in this file.
#
# machine: shared
# it reads files and drives two read-only commands; it converges nothing and
# starts no machine.
#
# reads: docs/sysadmin.md README.md examples/README.md tools/install.sh
# reads: src/guarden/templates/cloud-init/template.yaml
# reads: src/guarden/templates/cloud-init/provision.sh
# reads: packages/packages.toml
# reads: docs/spec.md CONTEXT.md AGENTS.md docs/PRD.md SECURITY.md
# reads: src/guarden/publications.py src/guarden/service.py tests/t50-route.sh
# reads: tests/routename.py

. "$(dirname "$0")/lib.sh"

DOC=$GUARDEN_ROOT/docs/sysadmin.md
README=$GUARDEN_ROOT/README.md
EXAMPLES=$GUARDEN_ROOT/examples/README.md
INSTALL=$GUARDEN_ROOT/tools/install.sh
TEMPLATE=$GUARDEN_ROOT/src/guarden/templates/cloud-init/template.yaml
PROVISION=$GUARDEN_ROOT/src/guarden/templates/cloud-init/provision.sh
PACKAGES=$GUARDEN_ROOT/packages/packages.toml
SPEC=$GUARDEN_ROOT/docs/spec.md
CONTEXT=$GUARDEN_ROOT/CONTEXT.md
AGENTS=$GUARDEN_ROOT/AGENTS.md
PRD=$GUARDEN_ROOT/docs/PRD.md
SECURITY=$GUARDEN_ROOT/SECURITY.md

# The one checkout location, read out of the code rather than written here.
# `install.sh` and `userdata.py` both carry it, and a runbook that names a
# different one is a runbook that sends an operator to a path that is not
# there — which is exactly what ticket 310 measured.
REPO_DIR=$(sed -n 's/^REPO_DIR="\${GUARDEN_REPO_DIR:-\(.*\)}"$/\1/p' "$INSTALL")
[ -n "$REPO_DIR" ] || _fail "install.sh states no REPO_DIR"
[ "$REPO_DIR" = "/usr/local/src/guarden" ] \
    || _fail "install.sh's REPO_DIR is $REPO_DIR, and the runbook is written against /usr/local/src/guarden"

# The phase order, read out of the program.
run soil list
assert_exit 0
phases=$(awk '{print $1}' "$GUARDEN_STDOUT" | tr '\n' ' ')
[ -n "$phases" ] || _fail "soil list printed no phase"
# The order the installer runs them in, read out of the installer.
install_order=$(sed -n 's/^PHASE_ORDER=(\(.*\))$/\1/p' "$INSTALL" \
    | tr -d '"' | tr ' ' '\n' | tr '\n' ' ')
[ -n "$install_order" ] || _fail "install.sh states no PHASE_ORDER"

# --- 310: the update path is the checkout the installer made --------------
#
# The old line was `git -C /usr/lib/guarden pull`, and `/usr/lib/guarden` is
# where the programs are **installed** — root-owned files, never a git
# checkout. Measured on both fresh boxes: `fatal: not a git repository`. The
# checkout is the one `install.sh` clones, and it is named by the constant the
# installer itself uses.
assert_file_lacks "$DOC" "git -C /usr/lib/guarden pull"
assert_file_has "$DOC" "git -C $REPO_DIR pull"
# And the reason is stated, because a bare path with no reason is a path
# somebody will "fix" back to where the programs live.
assert_file_has "$DOC" "/usr/lib/guarden"
assert_file_has "$DOC" "root-owned"
# The two documents that carry the update path agree, and neither names the
# installed tree as the checkout.
assert_file_lacks "$README" "git -C /usr/lib/guarden pull"
# The installed tree is a real place with a real meaning, and the runbook
# says which one it is: the programs live there, the checkout does not.
assert_file_has "$DOC" "the programs live"

# --- 310: the phase order is the DESCRIPTION order, not the bootstrap one ----
#
# The runbook states the DESCRIPTION order, and says so: `soil list` prints
# that order and it is not the order a fresh host runs them (`install` comes
# first there, because `install` seeds the file `packages` resolves its fetch
# against). The parsed comparison below is what holds the runbook to the
# program, and the assertion under it requires the line to be present.
#
# There used to be an `assert_file_lacks` here for that same line, and it
# contradicted the assertion immediately below it. It passed because
# docs/sysadmin.md is 106,213 bytes — larger than one pipe buffer — so
# `assert_file_lacks` could not fail on it at all. `e177cbe` made that helper
# able to fail — it added `tests/t212-assert-file-lacks.sh`, and `t212` there is
# the suite's number, not a ticket — and that is what surfaced this; the line is
# correct and the negative assertion was stale from the day it was written.
# Ticket 352 is a different defect — the provision probe's storage wait in
# tests/lxc.sh — and does not touch this helper.
assert_file_has "$DOC" "Phases in order:"
# **The qualifier is the sentence that makes the phase list not a falsehood.**
# Without it the runbook states an order and leaves the reader to assume it is
# the one a fresh host runs, which is the mistake ticket 310 measured. This is
# the assertion that replaces the stale `assert_file_lacks` removed in t353:
# that one demanded the line be ABSENT, this one demands the line be HONEST.
assert_file_has "$DOC" "not the order a fresh host runs them"
# The order the runbook states is the order the program states, compared
# rather than transcribed: a runbook that drifts from `soil list` fails here.
doc_order=$(sed -n 's/^Phases in order: \(.*\)\.$/\1/p' "$DOC" \
    | tr -d '`' | tr ',' '\n' | sed 's/^ *//; s/ *$//' | tr '\n' ' ')
[ -n "$doc_order" ] || _fail "docs/sysadmin.md states no phase order"
[ "$doc_order" = "$phases" ] \
    || _fail "the runbook says [$doc_order], soil list says [$phases]"
# **There are two orders, and the spec says which is which** (ticket 310's
# measured correction). The PHASE LIST — the order `soil list` prints and the
# spec states — is `packages, storage, sysctl, firewall, install, units`: the
# order the phases are *described* in. The BOOTSTRAP order — the order a fresh
# host runs them in — puts `install` first, and that is tools/install.sh's
# PHASE_ORDER, the only implementer of the fresh-host flow. `install` goes
# first because `soil packages` resolves the pinned podlet release against a
# record `soil install` writes, and `soil install` is what puts the programs on
# PATH at all.
#
# So the installer's order is NOT the phase list, and a suite that demands the
# two be equal is demanding a falsehood. The bootstrap order is checked
# against its own literal, and the runbook's statement of it is checked to
# agree with the installer.
assert_file_has "$DOC" "soil install  --apply"
assert_file_has "$DOC" "soil packages --apply"
bootstrap_line=$(grep -n 'soil install  --apply' "$DOC" | head -1 | cut -d: -f1)
packages_line=$(grep -n 'soil packages --apply' "$DOC" | head -1 | cut -d: -f1)
[ -n "$bootstrap_line" ] || _fail "the runbook states no bootstrap order"
[ "$bootstrap_line" -lt "$packages_line" ] \
    || _fail "the runbook's bootstrap order puts packages before install"
expected_bootstrap="install packages storage sysctl firewall units "
[ "$install_order" = "$expected_bootstrap" ] \
    || _fail "install.sh runs [$install_order], the bootstrap order is [$expected_bootstrap]"
# The reason `install` goes first is stated, because an order without a reason
# is an order an operator "corrects". These read the claim, not the word
# "install", which every one of these documents contains for other reasons.
assert_file_has "$DOC" "needs what it seeds"
assert_file_has "$README" "seeds the file"

# --- 311: a fresh-install section, with the canonical command -------------
#
# The canonical command lived only in the script's own header and in its
# exit-75 banner. `grep 'install.sh' README.md docs/ AGENTS.md` found the TEST
# and nothing else, so no operator document said how to install a host.
assert_file_has "$DOC" "curl -fsSL"
assert_file_has "$DOC" "tools/install.sh"
assert_file_has "$DOC" "sudo bash"
# The section exists under a heading an operator can find, and the heading
# names what it is.
assert_file_has "$DOC" "## Installing a fresh host"
# The three-run contract: the installer exits 75 at each of the two staged
# btrfs reboots, so three runs converge the host — 75, 75, 0.
assert_file_has "$DOC" "75"
assert_file_has "$DOC" "exit 75"
# The pointer to the phase-by-hand alternative, which is the README's.
assert_file_has "$DOC" "README.md"
assert_file_has "$README" "soil install"


# --- 311: a verification subsection per example ---------------------------
#
# `grep pg_isready README.md docs/ examples/` was 0 hits, and the operator had
# to apt-install postgresql-client by hand to prove the example answered.
assert_file_has "$DOC" "pg_isready"
assert_file_has "$DOC" "accepting connections"
# The client tooling is named, because a command that is not on the box is
# not a command an operator can run.
assert_file_has "$DOC" "postgresql-client"
# Both examples are covered, and the postgres one is the one that was proven
# on a real box.
assert_file_has "$DOC" "postgres"
assert_file_has "$DOC" "vaultwarden"
# The verification lives in a section of its own, not in a sentence.
assert_file_has "$DOC" "### verifying a service answers"

# --- 312: the two-cycle cloud-init contract -------------------------------
#
# A correct cloud-init run ends `cloud-init status: error` twice, because
# install.sh exits 75 at each of the two staged reboots and cloud-init reads
# a non-zero exit as a failed module. Nothing said so: the only record was a
# deployment-audit note in the operator's working directory.
assert_file_has "$README" "cloud-init"
assert_file_has "$README" "75"
assert_file_has "$README" "cloud-init status"
assert_file_has "$DOC" "cloud-init"
assert_file_has "$DOC" "75"
# The re-run command is the same one the first run used, and it is named.
assert_file_has "$README" "curl -fsSL"
assert_file_has "$DOC" "curl -fsSL"
# The third run is the one that converges, and that is said.
assert_file_has "$README" "three"
assert_file_has "$DOC" "three"

# --- 312: the template's own header says it -------------------------------
#
# The template is editable (it is a template, and the vps profile is the
# operator's own document), so the contract is in the document the operator
# reads rather than only in this repository's prose.
assert_file_has "$TEMPLATE" "cloud-init status"
assert_file_has "$TEMPLATE" "75"
assert_file_has "$TEMPLATE" "re-run"
# And the render carries it, because the template is rendered into the
# document a machine boots from and the header travels with it.
run soil packages --render-user-data "$GUARDEN_FIXTURES/user-data.vps.yaml" --profile vps
assert_exit 0
assert_file_has "$GUARDEN_FIXTURES/user-data.vps.yaml" "cloud-init status"

# --- 312: the latent git dependency ---------------------------------------
#
# The vps document's runcmd runs provision.sh, which does `git clone`, while
# the rendered packages block listed no git. Not hit on ubuntu:26.04, which
# ships it — and on an image that does not, the whole path stops at the clone
# with no diagnostic.
assert_file_has "$PROVISION" "git clone"
# The document that clones installs git, and the check is against the
# rendered document rather than against a copy of the list.
assert_file_has "$GUARDEN_FIXTURES/user-data.vps.yaml" "git"
# And git is in the one package list the document is rendered from, so the
# two cannot drift.
assert_file_has "$PACKAGES" '"git"'

# The one list the renderer reads, read with the program rather than out of
# the TOML, and the two agree.
run soil packages --list
assert_exit 0
assert_stdout_has "git"

# --- 358: no sentence with no subject, and the route's name stated once -----
#
# **A paragraph's opening was rewritten and its tail was left behind.** The
# defect this measures is not a typo and not a stale claim: it is a document
# edit that replaced a paragraph's first half and left the second half in
# place, so the paragraph reads
#
#     **A claim.**<newline>
#     these two with a `${domain}` substitution and validated nothing, ...
#
# The second line has no subject and no verb, because the words that made it a
# sentence were in the part that was rewritten. A reader gets a fragment and
# nothing says so — and `docs/spec.md` is the document the suites check the
# code against, so a fragment there is a claim about the code that nobody can
# read.
#
# **It happened four times in one commit.** `67740995` folded the ADRs into
# the spec, and in four places it rewrote a paragraph's opening and left the
# tail behind: the `stakes query` field set, the instance-volumes layout, the
# route-host paragraph, and the alias-probe paragraph. All four were repaired,
# and the repair restored the words the rewrite had dropped rather than
# rewriting the sentences — a fragment is a fragment because of the half that
# is missing, and the missing half is known.
#
# **The check is structural, and that is the point.** A phrase list would name
# the four fragments someone has already found and leave the next one
# uncaught, so `tests/docfragments.py` asks a question about the SHAPE of a
# document: does a sentence begin with a lowercase word where the previous
# line ended a complete sentence? That is the shape a rewrite leaves behind,
# and it is narrow enough to be precise — a fenced code block is not prose, a
# list item is a new block, and a blank line ends a paragraph.
#
# **It is measured, not asserted from a reading.** The helper found exactly
# those four fragments in the spec before the repair and none after it, and
# none in `docs/sysadmin.md`, `CONTEXT.md`, `AGENTS.md`, `docs/PRD.md` or
# `SECURITY.md` — so it is measuring the defect and not the documents' prose
# style. It runs over every document the repository ships, so a fragment in
# any of them is caught.
run python3 "$GUARDEN_ROOT/tests/docfragments.py" \
    "$SPEC" "$DOC" "$CONTEXT" "$AGENTS" "$PRD" "$SECURITY"
assert_exit 0

# --- 358: the spec's route name, against the allocator that computes it ------
#
# **A document that says what a program computes has to be checked against
# that program, not against a copy of its answer.** Spec §4 said a route's full
# name was `<track host_prefix><host:>` inside the host's domain, and gave
# `web.myapp.com` as the example — while the allocator computes
# `<host_prefix><label><zone>` and `service._zone` returns `""` for every
# non-tunnel destination, so an edge route is `staging.web` with no domain at
# all. The spec's own formula and its own example disagreed with each other
# AND with the code, and three suites (`t50-route.sh`, `t50-slice.sh`,
# `t455-tunnel-hostname.sh`) pinned the allocator's answer while the contract
# said otherwise.
#
# **So the check asks the allocator.** `tests/routename.py` imports
# `publications.claim_host` and `service._zone` and calls them with the real
# arguments, then asks whether the spec says what those calls returned. An
# assertion written as a string copied out of the spec would be green the
# moment the two drifted apart — which is the defect itself — so the examples
# are checked by ALLOCATING them rather than by reading them.
#
# **`host.domain` is checked the same way.** It reaches exactly one thing, the
# `${domain}` manifest substitution, and it is in no allocated name — so the
# spec's old sentence that a repository "cannot claim a name outside
# `host.domain`" named a boundary the name does not have. That claim is
# asserted absent, and the absence is what the allocator's answers support.
run python3 "$GUARDEN_ROOT/tests/routename.py" "$SPEC"
assert_exit 0

echo "t480-doc-claims: ok"
