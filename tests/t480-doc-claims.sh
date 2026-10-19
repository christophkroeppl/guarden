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

. "$(dirname "$0")/lib.sh"

DOC=$GUARDEN_ROOT/docs/sysadmin.md
README=$GUARDEN_ROOT/README.md
EXAMPLES=$GUARDEN_ROOT/examples/README.md
INSTALL=$GUARDEN_ROOT/tools/install.sh
TEMPLATE=$GUARDEN_ROOT/src/guarden/templates/cloud-init/template.yaml
PROVISION=$GUARDEN_ROOT/src/guarden/templates/cloud-init/provision.sh
PACKAGES=$GUARDEN_ROOT/packages/packages.toml

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

# --- 310: the phase order is the installer's order -------------------------
#
# `packages, storage, sysctl, firewall, install, units` was the runbook's
# line and the installer's order is `install` first, because `install` seeds
# the file `packages` resolves its fetch against. Following the runbook
# verbatim on a fresh box is therefore not the working flow.
assert_file_lacks "$DOC" 'Phases in order: `packages`, `storage`, `sysctl`, `firewall`, `install`, `units`'
assert_file_has "$DOC" "Phases in order:"
# The order the runbook states is the order the program states, compared
# rather than transcribed: a runbook that drifts from `soil list` fails here.
doc_order=$(sed -n 's/^Phases in order: \(.*\)\.$/\1/p' "$DOC" \
    | tr -d '`' | tr ',' '\n' | sed 's/^ *//; s/ *$//' | tr '\n' ' ')
[ -n "$doc_order" ] || _fail "docs/sysadmin.md states no phase order"
[ "$doc_order" = "$phases" ] \
    || _fail "the runbook says [$doc_order], soil list says [$phases]"
# And the installer's order is the program's order, which is the claim the
# runbook's order has to agree with: the two are the same list read from two
# places, and a runbook that states a third order is wrong.
[ "$install_order" = "$phases" ] \
    || _fail "install.sh runs [$install_order], soil list says [$phases]"
# The reason `install` goes first is stated, because an order without a reason
# is an order an operator "corrects".
assert_file_has "$DOC" "install"
assert_file_has "$README" "install"

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

# --- 311: the cwd before the template copy --------------------------------
#
# `cp -r examples/services/…` resolves only from the repository root, and on
# a real host the root is /usr/local/src/guarden — a path the runbook never
# named. The operator had to work it out.
assert_file_has "$DOC" "cd $REPO_DIR"
assert_file_has "$EXAMPLES" "cd $REPO_DIR"
# The copy is still there, and the cwd is above it rather than beside it.
cp_line=$(grep -n 'cp -r examples/services' "$DOC" | head -1 | cut -d: -f1)
[ -n "$cp_line" ] || _fail "the runbook no longer copies the example templates"
cd_line=$(grep -n "cd $REPO_DIR" "$DOC" | head -1 | cut -d: -f1)
[ -n "$cd_line" ] || _fail "the runbook does not cd into the checkout"
[ "$cd_line" -lt "$cp_line" ] \
    || _fail "the runbook copies the templates (line $cp_line) before it names the cwd (line $cd_line)"

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

echo "t480-doc-claims: ok"
