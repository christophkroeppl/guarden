#!/usr/bin/env bash
# The path constants exist in exactly one place, and they follow the FHS.
#
# spec 2: programs and modules under `/usr/lib/guarden` with symlinks in
# `/usr/bin`, configuration under `/etc/guarden`, state under `/var/lib/guarden`,
# runtime under `/run/guarden`. One place means `guarden.paths` — a path written
# there and nowhere else, because the second copy of a path is the one that
# drifts from the first, and a symlink pointing into a tree that moved is a
# broken installation rather than a wrong line of code.
#
# The symlinks are the part that is easy to leave out and expensive to: a
# program installed under `/usr/lib/guarden/bin` that nothing links into
# `/usr/bin` is a program nothing can run by name, and no phase notices.

. "$(dirname "$0")/lib.sh"
scratch_host

# programs and modules. The phase stops at the credential materialiser's
# enable items — `systemctl enable` cannot converge under a staged prefix —
# and this suite only needs the files the earlier items installed, so the
# exit is the enable item's and not a failure of anything asserted here.
run soil install --apply
assert_exit 1
assert_file_exists "$(host usr/lib/guarden/bin/soil)"
assert_file_exists "$(host usr/lib/guarden/bin/weedr)"
assert_file_exists "$(host usr/lib/guarden/lib)"
assert_file_exists "$(host usr/lib/guarden/templates)"
assert_file_exists "$(host usr/lib/guarden/modules)"

# /usr/bin, one symlink per program, each pointing into the tree above. All
# eight, because the eight are the interface and a set of seven is a machine
# where one program cannot be run by name.
for program in soil weedr loom roots twig furrow hose stakes; do
    assert_file_exists "$(host usr/bin/$program)"
    assert_executable "$(host usr/bin/$program)"
done

# The symlink target is the *installed* tree, not the checkout it was installed
# from: a symlink into a developer's working directory is a broken installation
# on every other machine and passes every test that only checks the link exists.
# Under GUARDEN_PREFIX the target carries the prefix, which is the whole point
# of the seam — a link that ignored it would point at the real /usr.
#
# `readlink`, not `grep`: grep follows the link and reads the program it points
# at, so a grep would pass on a link aimed anywhere as long as the target file
# happened to exist.
assert_link() {
    local program=$1 expected=$2 found
    found=$(readlink "$(host "usr/bin/$program")")
    if [ "$found" != "$expected" ]; then
        _fail "/usr/bin/$program points at $found, not $expected"
    fi
}

for program in soil weedr loom roots twig furrow hose stakes; do
    assert_link "$program" "$GUARDEN_HOST/usr/lib/guarden/bin/$program"
done

# And the link resolves to something the kernel can run. The programs are
# modules with no shebang in the checkout, so an installed copy without one is a
# symlink the shell quotes rather than executes — `soil list` would report
# `--check: command not found` on a host where every other assertion above
# passed. This is the check the golden VM found and the fast harness could not.
assert_file_has "$(host usr/lib/guarden/bin/soil)" "#!/usr/bin/env python3"
assert_file_has "$(host usr/lib/guarden/bin/weedr)" "#!/usr/bin/env python3"

# An installed program without the interpreter line is drift, and the converge
# puts it back rather than leaving a link that cannot be followed. Rewritten
# whole rather than appended to: the shebang is the first line, and appending a
# comment to the end of a file changes nothing about whether it is there.
seed "$(host usr/lib/guarden/bin/loom)" "# not an interpreter line" "print('loom')"
run soil install --check
assert_exit 1
assert_stderr_has "interpreter line"

run soil install --apply
assert_file_has "$(host usr/lib/guarden/bin/loom)" "#!/usr/bin/env python3"

# And the symlinks converge: a second apply on a converged host re-links nothing,
# and a link that was removed is drift the phase repairs.
run soil install --apply
assert_link soil "$GUARDEN_HOST/usr/lib/guarden/bin/soil"

rm -f "$(host usr/bin/loom)"
run soil install --check
assert_exit 1
assert_stderr_has "every program is on PATH as a symlink"

run soil install --apply
assert_link loom "$GUARDEN_HOST/usr/lib/guarden/bin/loom"

# A link pointing somewhere else is drift too, not merely a link that exists: a
# /usr/bin/soil aimed at an old checkout runs code nobody just wrote.
rm -f "$(host usr/bin/twig)"
seed "$GUARDEN_HOST/usr/bin/twig" "#!/bin/sh
echo not guarden"
run soil install --check
assert_exit 1
assert_stderr_has "every program is on PATH as a symlink"

run soil install --apply
assert_link twig "$GUARDEN_HOST/usr/lib/guarden/bin/twig"

# configuration, state and runtime keep the names spec 2 gives them
assert_file_exists "$(host etc/guarden)"
assert_file_exists "$(host var/lib/guarden)"
assert_file_exists "$(host run/guarden)"

# --- the constants are in one place ------------------------------------------

# `paths.py` is that place, and a path spelled as a literal tuple anywhere else
# is the second copy. Checking the module rather than the behaviour is the point
# here: the behaviour is what every other suite in this harness already covers,
# and what is new is that there is nowhere else for a path to be written.
assert_file_has "$GUARDEN_ROOT/src/guarden/paths.py" "USR_LIB_GUARDEN"
assert_file_has "$GUARDEN_ROOT/src/guarden/paths.py" "BIN ="
assert_file_has "$GUARDEN_ROOT/src/guarden/paths.py" "USR_BIN ="
assert_file_has "$GUARDEN_ROOT/src/guarden/paths.py" "MODULES ="

# A `usr/lib/guarden` literal outside paths.py is a path that can drift from the
# constant, so the one file that has them is the only one allowed to.
assert_file_lacks "$GUARDEN_ROOT/src/guarden/hostprep.py" '"usr", "lib", "guarden"'
assert_file_lacks "$GUARDEN_ROOT/src/guarden/hostprep.py" '"usr", "bin"'

# `soil install`'s own description of what it owns names the tree, so the help
# and the code cannot describe different installations.
run soil list
assert_stdout_has "/usr/lib/guarden"