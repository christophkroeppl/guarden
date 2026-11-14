#!/bin/bash
# machine: fresh
# The golden is provisioned at build time from the one package list, and the
# document a cut re-runs installs nothing.
#
# (ticket 200)
#
# **This is a fact about the image, so it is asked of the machine.** A cut is a
# new instance to cloud-init and re-runs the document the image carries, which
# `provision` left provisioned: its packages were installed once, from
# `packages/packages.toml` through `tests/packagelist.py`. Before ticket 200 the
# document itself was a second copy of that list and cloud-init ran it on every
# cut: measured 2026-10-22, 18.5 s of `apt-get update` with apt's locks held from
# ~20 s of uptime to ~40 s. The inventory below is asserted from the list, so a
# package added to it and never installed at build time fails here on the next
# cut rather than in whichever suite needed it.

. "$(dirname "$(readlink -f "$0")")/lib.sh"

# The document this cut re-ran, as cloud-init wrote it for this instance-id.
document=/var/lib/cloud/instance/user-data.txt
assert_file_exists "$document"
assert_file_has "$document" "already provisioned"
assert_file_lacks "$document" "package_update"
assert_file_lacks "$document" "packages:"

# The runner reads the one list and installs its output; it carries no list.
assert_file_exists "$GUARDEN_ROOT/tests/packagelist.py"
assert_file_has "$GUARDEN_ROOT/tests/lxc.sh" "tests/packagelist.py"
assert_file_lacks "$GUARDEN_ROOT/tests/lxc.sh" "package_update: true"

# Every package the one list names for this machine is installed on it: the
# reader composes the substrate and the golden role, which is what provision
# installs, and the question is the machine's own package database.
run python3 "$GUARDEN_ROOT/tests/packagelist.py"
assert_exit 0
missing=''
while read -r package; do
    [ -n "$package" ] || continue
    dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null | grep -qx installed \
        || missing="$missing $package"
done <"$GUARDEN_STDOUT"
[ -z "$missing" ] \
    || _fail "the one list names packages this golden does not carry:${missing}"

echo "t15-golden-list: ok"
