#!/usr/bin/env bash
# A tree an OLDER guarden made wrong is repaired by the create that reconciles
# the service (ticket 334).
#
# Ticket 333 made the CREATION path right: an instance's own quadlet directory
# is now made by `_make_tree`'s walk, `0700` to the service user. A host that
# ran guarden BEFORE that fix carries the directory the older installer made —
# `conf.write_file`'s `path.parent.mkdir`, so root-owned with the mutator's
# umask — and NOTHING repaired it:
#
#   * a CONVERGED create returns at `_converged` before the walk, so it walks
#     nothing;
#   * `weedr service start` walks nothing at all.
#
# **The measurement is a create of the SAME source.** A re-ingest of a
# DIFFERENT source is not converged, so the walk runs and repairs the tree —
# which is why ticket 333's own second-install block is GREEN today and
# proves nothing about this. The converged create is the case that repairs
# nothing, and it is the case a host upgrade runs every time.
#
# What is asserted is state on a real machine: `stat` on a directory the
# mutator really made. Nothing here reads the source.
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
home=/var/lib/guarden/services/routed-preview/home
instance_home="$home/$escaped"
instance_quadlet="$instance_home/.config/containers/systemd"
slot_quadlet="$home/.config/containers/systemd"

run weedr service ingest routed-preview/feature/x --from poke routed@9f2c1ab
assert_exit 0
assert_stdout_has "created routed-preview"

group=$(id -gn routed-preview)

# The shape an older guarden left behind: root-owned, with the mutator's
# umask. The pre-fix mutator created the whole chain that way — the quadlet
# directory itself and the levels above it — and the drop-in directory with it.
break_it() {
    chmod 0755 "$1"
    chown 0:0 "$1"
}

break_it "$instance_quadlet"
break_it "$instance_home/.config"
break_it "$instance_home/.config/containers"
break_it "$slot_quadlet"
break_it "$home/.config"
break_it "$home/.config/containers"
break_it "$instance_quadlet/web.container.d"

# The SAME source again. The deploy is converged, so the create returns before
# anything walks the tree — and that is the case this ticket is about.
run weedr service ingest routed-preview/feature/x --from poke routed@9f2c1ab
assert_exit 0
assert_stdout_has "converged"

# The tree is the service's own again, and the tree's mode. Every level of the
# chain, because the older mutator created every level of it.
for path in "$instance_quadlet" "$instance_home/.config" \
    "$instance_home/.config/containers" "$slot_quadlet" \
    "$home/.config" "$home/.config/containers" \
    "$instance_quadlet/web.container.d"; do
    assert_mode "$path" 700
    assert_owner "$path" "routed-preview:$group"
done

# The deploy is still converged: the repair is not a redeploy, and a verb that
# re-rendered the units on every converge would not be a converge.
assert_file_exists "$instance_quadlet/web.container"
assert_file_has "$instance_quadlet/web.container" "Image=docker.io/library/nginx:1.27"
