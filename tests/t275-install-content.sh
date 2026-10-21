#!/usr/bin/env bash
# soil install converges guarden's own tree by CONTENT, and from the CHECKOUT.
#
# Ticket 275, second site. The item asked whether eight files existed, while its
# converge wrote the eight programs *and* every module of the package — so a
# changed module kept its name, the question answered "yes", and `--apply` left
# the old bytes installed. The source was also the installed tree itself, so the
# runbook's update path — `git pull` in the checkout, then `soil install
# --apply` — could not install anything whatever the question answered.
#
# Both halves are driven here, because the pair is what was broken: a checkout
# run had a source and no comparison, and an installed run had a comparison and
# no source. So this suite edits a checkout at the documented path and runs
# `/usr/bin/soil`, which is the copy an operator runs.

. "$(dirname "$0")/lib.sh"

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GUARDEN_PREFIX=/

CHECKOUT=/usr/local/src/guarden
INSTALLED=/usr/lib/guarden

# The phase's starting state is this file's, so every line of drift below is
# proven rather than inherited from whichever suite ran on this machine first.
rm -rf "$INSTALLED" "$CHECKOUT"
rm -f /etc/guarden/guarden.toml

run soil install --apply
assert_exit 0
assert_stderr_empty
assert_file_exists "$INSTALLED/bin/soil"
assert_file_exists "$INSTALLED/lib/guarden/unitsource.py"

# A converged host asks 0. Without this the drift below could be the install's
# rather than the edit's.
run soil install --check
assert_exit 0
assert_stderr_empty

# The checkout the installer clones, and the file a pull would land in. The
# suite's own tree is copied rather than edited, so the edits below are the
# operator's and not the harness's.
mkdir -p "$(dirname "$CHECKOUT")"
cp -a "$GUARDEN_ROOT" "$CHECKOUT"

# A module the installed programs import: `loom` runs this file, so a change to
# it is a change to the host. It keeps its name, which is what existence missed.
printf '\nMARKER_T275_MODULE = 1\n' >>"$CHECKOUT/src/guarden/unitsource.py"

run env -u PYTHONPATH /usr/bin/soil install --check
assert_exit 1
assert_stderr_has "drift: guarden's programs are installed root-owned"
assert_file_lacks "$INSTALLED/lib/guarden/unitsource.py" "MARKER_T275_MODULE"

run env -u PYTHONPATH /usr/bin/soil install --apply
assert_exit 0
assert_stderr_empty
assert_file_has "$INSTALLED/lib/guarden/unitsource.py" "MARKER_T275_MODULE"

# The installed copy is the checkout's bytes and not the tree the installed
# program was reading before this ticket.
run cmp -s "$CHECKOUT/src/guarden/unitsource.py" "$INSTALLED/lib/guarden/unitsource.py"
assert_exit 0

# A program is the same fact, and the installed copy is the module plus the
# interpreter line that makes `/usr/bin/<program>` a command.
printf '\nMARKER_T275_PROGRAM = 1\n' >>"$CHECKOUT/src/guarden/soil.py"

run env -u PYTHONPATH /usr/bin/soil install --check
assert_exit 1
run env -u PYTHONPATH /usr/bin/soil install --apply
assert_exit 0
assert_stderr_empty
assert_file_has "$INSTALLED/bin/soil" "MARKER_T275_PROGRAM"
assert_file_has "$INSTALLED/bin/soil" "#!/usr/bin/env python3"
assert_file_has "$INSTALLED/bin/soil" "_guarden_lib"

# A file that is gone is drift too: the question answered "the seven that are
# left" and the run reported success, which is the same silent answer.
rm -f "$INSTALLED/bin/stakes"

run env -u PYTHONPATH /usr/bin/soil install --check
assert_exit 1
run env -u PYTHONPATH /usr/bin/soil install --apply
assert_exit 0
assert_stderr_empty
assert_file_exists "$INSTALLED/bin/stakes"
assert_executable "$INSTALLED/bin/stakes"
assert_file_has "$INSTALLED/bin/stakes" "#!/usr/bin/env python3"

# Everything above converged, so the host asks 0 again: a converge that left its
# own question open would report drift on every later run.
run env -u PYTHONPATH /usr/bin/soil install --check
assert_exit 0
assert_stderr_empty
