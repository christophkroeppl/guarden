#!/usr/bin/env bash
# An instance's own quadlet directory is the service's, and the mode is the
# tree's (ticket 333).
#
# `weedr service ingest` creates the service's own quadlet directory and, for
# an instance, the instance's HOME — but not the instance's own QUADLET
# directory. That directory was therefore created by the first `units.install`,
# through `conf.write_file`'s `path.parent.mkdir`: root-owned, with the
# mutator's umask (0755, typically), inside a `0700` home.
#
# **Two things were false at once.** The spec's "nothing root-owned lives
# inside a service's home" was false for that directory, and the service could
# not write its own unit directory — the one thing a service's own quadlet tree
# is for. The mode also depended on who invoked the mutator, which is a
# property no assertion can pin down until it is stated.
#
# The mode and the owner are TWO properties of the SAME path, so both are
# asserted, and each is broken on its own below: the assertion is run against
# the mutated path and must fail. Two mutations that produce the same
# diagnostic would mean one of the two assertions is not load-bearing, so the
# two failures are named apart.
#
# What is asserted is state on a real machine: `stat` on a directory the
# mutator really made. Nothing here reads the source, and nothing here stands
# in for the tool that would have made it.
#
# machine: fresh

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GUARDEN_PREFIX=/

ensure_accounts
stage_config guarden-nomodules.toml
stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_not_rejected

# The preview track is `kind = "instance"`, so this ref is an instance and not
# a slot. The service has one route, which is what makes it need a unit
# directory at all.
stage_poke routed 9f2c1ab

escaped='feature\x2fx'
instance_quadlet="/var/lib/guarden/services/routed-preview/home/$escaped/.config/containers/systemd"
slot_quadlet="/var/lib/guarden/services/routed-preview/home/.config/containers/systemd"

run weedr service ingest routed-preview/feature/x --from poke routed@9f2c1ab
assert_exit 0

# The service's own identity, read from the host's own database: the uid
# podman's generator runs as, and the gid the tree is owned by.
uid=$(id -u routed-preview)
gid=$(id -g routed-preview)

# The two properties, as functions, so the mutation below runs the SAME
# assertion the product is held to. An assertion that cannot be run against a
# broken path is not an assertion.
#
# **The numbers and not the names.** A name is resolved through the host's
# user database, and a uid is the fact: the assertion is about who owns the
# directory, and the number is what the kernel and the generator use.
assert_quadlet_mode() {
    assert_mode "$1" 700
}

assert_quadlet_owner() {
    local path=$1 actual
    actual=$(stat -c %u:%g "$path")
    if [ "$actual" != "$uid:$gid" ]; then
        _fail "$path is owned by uid:gid $actual, not the service's own $uid:$gid"
    fi
}

# The directory is asserted to EXIST, not assumed: a conditional assertion is a
# vacuous one, and a suite that checked a mode on a path nothing made would
# report about a directory that is not there.
assert_file_exists "$instance_quadlet"

# --- the mode ----------------------------------------------------------------
# `0700`, the tree's own mode (spec 2.1: `/var/lib/guarden/services/<name>`
# and everything under it is `0700` to the service user). It was the mutator's
# umask before the fix, so it varied with the umask that happened to be in
# force — and a `0755` directory inside a `0700` home is a hole in the one
# rule the home exists for.
assert_quadlet_mode "$instance_quadlet"

# --- the owner ---------------------------------------------------------------
# The SERVICE's own user, and not root. The service user is the uid podman's
# generator runs as: a root-owned directory inside the home is a directory the
# generator cannot write its own units into.
assert_quadlet_owner "$instance_quadlet"

# And the service can write it. This is the property the owner assertion is
# about, asked of the service user rather than read off a number: a directory
# the service cannot create a file in is a directory the service does not own
# in any way that matters.
run runuser -u routed-preview -- touch "$instance_quadlet/.written-by-the-service"
assert_exit 0
assert_file_exists "$instance_quadlet/.written-by-the-service"

# **The service's OWN quadlet directory is the same kind of thing, and it is
# asserted here too** — because it is the same walk that owns it, and a fix
# that only covered the instance would leave the slot's mode dependent on the
# umask as well. The slot's directory is made by `_make_tree` with the rest of
# the tree, so it was already right; asserting it pins the claim rather than
# assuming it.
assert_file_exists "$slot_quadlet"
assert_quadlet_mode "$slot_quadlet"
assert_quadlet_owner "$slot_quadlet"

# --- the drop-in directory ---------------------------------------------------
# `<unit>.container.d` is a directory nothing else made: the render's plan
# names the file inside it and the mutator's `conf.write_file` created the
# parent. It is inside the service's own quadlet directory, so it is inside
# the service's home, and it is the service's own — the same rule the
# instance's quadlet directory is under, for the same reason (spec 2.1: the
# whole tree is `0700` to the service user).
dropin="$instance_quadlet/web.container.d"
assert_file_exists "$dropin"
assert_mode "$dropin" 700
dropin_owner=$(stat -c %u:%g "$dropin")
[ "$dropin_owner" = "$uid:$gid" ] \
    || _fail "$dropin is owned by uid:gid $dropin_owner, not the service's own $uid:$gid"

# --- the MIRROR's drop-in directory -----------------------------------------
# An instance's units are declared in the instance's own quadlet directory AND
# given an entry in the SERVICE's own, named `<unit>-<escaped-ref>` — because
# podman's generator searches the home's quadlet directory and the uid-scoped
# system paths and nothing below them, so a declaration only in the instance's
# directory is one systemd never makes.
#
# **This one is asserted directly, and not by the sweep below.** The sweep
# asks whether anything under the home is root-owned, and a mirror drop-in
# that was `0755` and owned by the SERVICE would pass it — it is not
# root-owned, it is just wide. The mode is what the tree's rule is about, so
# it is asked of this directory by name.
mirror_dropin="$slot_quadlet/web-$escaped.container.d"
assert_file_exists "$mirror_dropin"
assert_mode "$mirror_dropin" 700
mirror_owner=$(stat -c %u:%g "$mirror_dropin")
[ "$mirror_owner" = "$uid:$gid" ] \
    || _fail "$mirror_dropin is owned by uid:gid $mirror_owner, not the service's own $uid:$gid"

# --- nothing root-owned lives inside the service's home ----------------------
# The general claim the two directories above are instances of, asked of the
# whole tree. Podman's own store and snapper's subtree are excluded: the first
# is podman's to own and the second is snapper's, and neither is guarden's
# (spec 2).
root_owned=$(find /var/lib/guarden/services/routed-preview/home \
    -user root -not -path '*/.local/share/containers/*' \
    -not -path '*/.snapshots/*' -print 2>/dev/null)
[ -z "$root_owned" ] \
    || _fail "these paths under the service's home are root-owned: $(echo "$root_owned" | tr '\n' ' ')"

# --- the mutation that proves each assertion has teeth -----------------------
#
# The two properties are asserted on the SAME path, so a fix that restores one
# and not the other would still fail one of the two assertions — and a suite
# that cannot tell them apart proves nothing about either. So each is broken
# on its own, and the SAME assertion function is run against the broken path
# and must fail. An assertion that passes on a path it should reject is not an
# assertion, and this is where that is shown rather than assumed.
#
# **The mode is broken first.** The directory is re-moded to 0755 — the mode
# the mutator's umask produced before the fix — and the mode assertion is run
# against it.
chmod 0755 "$instance_quadlet"
if ( assert_quadlet_mode "$instance_quadlet" ) >/dev/null 2>&1; then
    _fail "the mode assertion passed on a 0755 directory, so it is not load-bearing"
fi
# The failure has to be the MODE's failure and not the owner's: the owner was
# not touched, so the owner assertion still holds, and the diagnostic names
# the mode. Two mutations with one diagnostic would mean one assertion is
# decoration.
mode_failure=$( ( assert_quadlet_mode "$instance_quadlet" ) 2>&1 >/dev/null || true)
case "$mode_failure" in
    *"is mode"*) : ;;
    *) _fail "the mode assertion failed with a diagnostic that does not name the mode: $mode_failure" ;;
esac

# **And the owner is broken on its own.** The directory is given back to root,
# with the mode RESTORED, so this mutation cannot be satisfied by the mode
# assertion failing as well — and the owner assertion is run against it.
chmod 0700 "$instance_quadlet"
chown 0:0 "$instance_quadlet"
if ( assert_quadlet_owner "$instance_quadlet" ) >/dev/null 2>&1; then
    _fail "the owner assertion passed on a root-owned directory, so it is not load-bearing"
fi
owner_failure=$( ( assert_quadlet_owner "$instance_quadlet" ) 2>&1 >/dev/null || true)
case "$owner_failure" in
    *"is owned by uid:gid"*) : ;;
    *) _fail "the owner assertion failed with a diagnostic that does not name the owner: $owner_failure" ;;
esac

# The tree is put back as the mutator left it, so the last block below is
# about the product and not about the mutations.
chown "$uid:$gid" "$instance_quadlet"
chmod 0700 "$instance_quadlet"

# --- and the product holds it, once more --------------------------------------
# The re-mutate above is a mutation of the host, and a host left mutated is a
# host the next suite inherits. So the directory is asked again after the
# repair, and the answer must be the product's answer: the tree is the
# service's, and the mode is the tree's.
assert_quadlet_mode "$instance_quadlet"
assert_quadlet_owner "$instance_quadlet"

# --- and a SECOND install holds it too ---------------------------------------
# A first install is the case the fix was written for, and it is the case that
# cannot show what happens when the directory ALREADY exists. A second
# install of the same instance takes the other branch: the tree walk has
# already made the directory, so the installer's own helper finds it there and
# leaves it alone. That is the right answer — the walk owns the tree — and it
# has to be measured rather than assumed, because a helper that re-moded an
# existing directory would fight an admin's widening on every install.
#
# **The instance is re-ingested from a DIFFERENT source, so the install really
# happens.** A re-ingest of the same source is `converged` and returns before
# the tree walk, so it would prove nothing. The source hash is what the
# convergence check compares — it covers `.guarden/`, `compose.yaml` and the
# build inputs — so the second tree differs in the UNIT SOURCE, which is
# inside `.guarden/`.
#
# **The directory is BROKEN first, and then the install has to fix it.** The
# break is what makes the assertion load-bearing: without it, a second install
# that did nothing at all would pass. The instance's quadlet directory is
# given back to root with the mode the pre-fix mutator produced, and the
# re-ingest is what has to make it the service's again.
chmod 0755 "$instance_quadlet"
chown 0:0 "$instance_quadlet"

mkdir -p "$GUARDEN_PREFIX/var/lib/guarden/staging/routed/second"
cp -r "$GUARDEN_ROOT/fixtures/projects/routed/." \
    "$GUARDEN_PREFIX/var/lib/guarden/staging/routed/second/"
# A different unit source, so the source hash differs and the ingest is not
# `converged`. The description is the one line the hash sees.
seed "$GUARDEN_PREFIX/var/lib/guarden/staging/routed/second/.guarden/quadlet/web.container" \
    "[Unit]" "Description=the routed container, second revision" \
    "" "[Container]" "Image=docker.io/library/nginx:1.27"
run weedr service ingest routed-preview/feature/x --from poke routed@second
assert_exit 0

# The tree walk that the install runs owns the directory, so the answer after
# the second install is the same answer the first one gave.
assert_quadlet_mode "$instance_quadlet"
assert_quadlet_owner "$instance_quadlet"

# And the drop-in directory the installer owns is still the service's, on the
# second install as on the first.
assert_mode "$dropin" 700
dropin_owner=$(stat -c %u:%g "$dropin")
[ "$dropin_owner" = "$uid:$gid" ] \
    || _fail "$dropin is owned by uid:gid $dropin_owner, not the service's own $uid:$gid"
