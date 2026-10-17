#!/usr/bin/env bash
# Ticket 180: the install script. A one-shot host installer must be
# syntactically valid, print usage on --help, refuse to run without root,
# and expose a --check mode that reports drift without applying.
#
# This test runs on the development machine (no VM needed) because it
# exercises the script's own interface — argument parsing, syntax, and
# the root check — not the soil phases that need a real host.
#
# machine: shared

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
script="$root/tools/install.sh"

pass() { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# 1. The script exists and is executable
[[ -f "$script" ]] || fail "install.sh not found at $script"
[[ -x "$script" ]] || fail "install.sh is not executable"
pass "install.sh exists and is executable"

# 2. Syntax is valid
bash -n "$script"
pass "bash -n: syntax valid"

# 3. --help prints usage and exits 0
help_output=$(bash "$script" --help 2>&1)
[[ $? -eq 0 ]] || fail "--help exited non-zero"
echo "$help_output" | grep -q "Usage:" || fail "--help output missing 'Usage:'"
echo "$help_output" | grep -q "curl -fsSL" || fail "--help output missing curl example"
echo "$help_output" | grep -q "\-\-check" || fail "--help output missing --check option"
pass "--help prints usage with curl example and --check option"

# 4. --check mode is accepted as an argument
echo "$help_output" | grep -q "report drift" || fail "--help output missing --check description"
pass "--check mode documented"

# 5. Root check: the script refuses to run without root.
#    We test this by checking the script's source for the EUID check,
#    since running it as non-root in the test harness would fail for
#    the wrong reason (the harness may not have sudo).
grep -q 'EUID -ne 0' "$script" || fail "root check (EUID) missing from script"
grep -q 'must be run as root' "$script" || fail "root check error message missing"
pass "root check present in script source"

                                                  
grep -q 'PHASE_ORDER=("install" "packages" "storage" "sysctl" "firewall" "units")' "$script" \
    || fail "phase order missing install-before-packages for podlet record"
pass "phase order matches hostprep.PHASES"

# 7. The script handles exit code 75 (btrfs conversion reboot)
grep -q 'reboot-required' "$script" || fail "reboot marker check missing"
grep -q 'exit 75' "$script" || fail "exit 75 message missing"
pass "btrfs conversion reboot marker handling present"

                                                    
grep -q 'flock' "$script" || fail "flock concurrent-run guard missing"
pass "flock concurrent-run guard present"

# 9. The script always uses the checkout for soil_cmd (not stale installed copy)
grep -q 'PYTHONPATH=src python3 -m guarden.soil' "$script" \
    || fail "soil_cmd does not use checkout"
pass "soil_cmd always uses checkout"

# The template lives with the installed templates so soil can render it on a
# host; tools/render-user-data is a thin wrapper over the CLI, not a second
# renderer. The '## template: jinja' marker is for cloud-init's own jinja
# pass, which we do not use -- the renderer pre-renders, so the marker must
# be absent from both the template and any render.
template="$root/src/guarden/templates/cloud-init/template.yaml"
[[ -f "$template" ]] || fail "cloud-init template.yaml not found"
grep -q 'template: jinja' "$template" && fail "template.yaml carries a cloud-init jinja marker the renderer does not need"
grep -q 'install.sh' "$template" || fail "template.yaml does not run install.sh (vps profile)"

renderer="$root/tools/render-user-data"
[[ -x "$renderer" ]] || fail "tools/render-user-data not found or not executable"
grep -q 'guarden.soil' "$renderer" || fail "render-user-data does not forward to soil packages --render-user-data"

# The `--branch VALUE` space form must parse: a `for arg in "$@"` loop expands
# the list once, so `shift` cannot consume the value and it is re-iterated into
# the unknown-argument arm. Both forms must reach the root check.
# Output is captured rather than piped: under `set -o pipefail` the pipeline
# returns install.sh's own exit 1, so `| grep -q` would fail even on a match.
branch_out=$(bash "$script" --branch develop 2>&1 || true)
echo "$branch_out" | grep -q 'must be run as root' \
    || fail "--branch VALUE (space form) does not parse"
branch_out=$(bash "$script" --branch=develop 2>&1 || true)
echo "$branch_out" | grep -q 'must be run as root' \
    || fail "--branch=VALUE (equals form) does not parse"
branch_out=$(bash "$script" --bogus 2>&1 || true)
echo "$branch_out" | grep -q 'unknown argument' \
    || fail "an unknown argument is not refused"
pass "--branch parses in both forms, unknown arguments refused"

provision="$root/src/guarden/templates/cloud-init/provision.sh"
[[ -f "$provision" ]] || fail "provision.sh not found"
grep -q 'git clone' "$provision" || fail "provision.sh does not clone the repo"

# The renderer must produce a document that names install.sh and the branch,
# and must not carry the golden-VM half (the evidence directory and the phase
# sequence) in the vps document.
vps_doc=$(mktemp)
PYTHONPATH="$root/src" python3 -m guarden.soil packages \
    --render-user-data "$vps_doc" --profile vps --branch feat/testing >/dev/null 2>&1 \
    || fail "vps profile could not be rendered"
grep -q 'install.sh' "$vps_doc" || fail "vps document does not run install.sh"
grep -q 'feat/testing' "$vps_doc" || fail "vps document does not carry the branch"
grep -q 'guarden-evidence' "$vps_doc" && fail "vps document carries the golden-VM evidence directory"
grep -q 'soil packages --apply' "$vps_doc" && fail "vps document carries the golden-VM phase sequence"
rm -f "$vps_doc"
pass "cloud-init template + renderer + provision.sh consistent"

printf 't180-install: all checks passed\n'
