#!/usr/bin/env bash
# The service-tree walk over state guarden did not create: podman's image store
# and snapper's `.snapshots` subtree survive an ingest untouched (fix 00d0150,
# BACKLOG-TEST-podman-store-walk).
#
# Both walks -- `_make_tree` on every create and `_copy_source` out of the
# staging tree -- impose `0700` under the service uid on every path in the
# service's tree. On a home podman has already written into, that is wrong
# twice, both measured on app-vm on 2026-10-18 with `postgres:17-alpine`:
#
#   * the overlay carries the image's own modes, and a container's root is
#     subuid-mapped and is not the service uid -- re-moded to `0700` the
#     container could not stat its own entrypoint;
#   * the store holds links whose target the image does not ship
#     (`usr/bin/pinentry -> pinentry-curses`), and `os.chown` follows a link by
#     default, so the walk raised FileNotFoundError and ended the create.
#
# The store is SEEDED, not pulled. This file's subject is what a walk does to
# state guarden did not create, and a pull would make every mode below a
# statement about podman's umask as well as about guarden's walk. Every shape
# here is one the incident named: a 64-hex layer id, the `diff` directory at
# podman's own `dr-xr-xr-x`, an entrypoint at the image's `0755`, and a link
# whose target is absent.
#
# The walks are only reached by a create that is NOT converged. A first create
# has no store in the home yet, and a re-ingest of an unchanged source prints
# `converged` and returns before either walk -- which is why no suite saw a
# walk over a populated store, and why two real deployments broke first. The
# staged compose file gains a comment (the source hash covers the staged
# `.guarden/` and `compose.yaml`), and that change is what runs the walks over
# the store.

# machine: fresh

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GUARDEN_PREFIX=/

ensure_accounts
stage_config guarden.toml
stage_poke myapp 9f2c1ab
stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_exit 0

run weedr service ingest myapp-staging --from poke myapp@9f2c1ab
assert_exit 0
assert_stdout_has "created myapp-staging"
assert_stderr_empty

svc=myapp-staging
tree=/var/lib/guarden/services/$svc
home=$tree/home
store=$home/.local/share/containers
group=$(id -gn "$svc")

# --- the store, in the shape podman leaves it -------------------------------

layer=45187f4b9c1d4e07a2b6f8d3c5e1a7b4d9f2c6e8a1b3d5f7c9e2a4b6d8f1c3e5
diff=$store/storage/overlay/$layer/diff

mkdir -p "$diff/usr/bin" "$diff/usr/local/bin"
printf '#!/bin/sh\nexec postgres\n' >"$diff/usr/local/bin/docker-entrypoint.sh"
ln -s pinentry-curses "$diff/usr/bin/pinentry"
chmod 0755 "$diff/usr/local/bin/docker-entrypoint.sh"
chmod 0755 "$diff/usr"
chmod 0555 "$diff"
chown -R -h "$svc:$group" "$store"

# The same shape of link, in the tree and outside the store. A home carries
# whatever the service put in it, and a chown that follows a dangling link ends
# the create whether or not podman is what put it there. Root's to start with,
# so the walk owning it -- without following it -- is a fact about the walk
# rather than a restatement of the seed.
mkdir -p "$home/.local/bin"
ln -s pinentry-curses "$home/.local/bin/pinentry"

# --- snapper's subtree, the guard the walk already had ----------------------
#
# The EROFS case of 2026-10-12: a chown on a read-only snapshot subvolume
# raises `OSError: [Errno 30]` and ends the create, so `.snapshots` is skipped
# the way the store is. Planted rather than waited for, so the assertion does
# not depend on the distribution's timeline timer having fired (t110-previews
# plants a snapshot for the same reason, on the instance walk).
snap=$tree/state/data/.snapshots
mkdir -p "$snap/1/snapshot"
printf 'planted\n' >"$snap/1/snapshot/volume.txt"
chmod 0444 "$snap/1/snapshot/volume.txt"
chmod 0555 "$snap/1/snapshot"

# The premise, asserted BEFORE the ingest: every mode and owner below is what
# the seed put there, so an assertion after the ingest cannot pass because the
# seed never held the state the walk was supposed to disturb.
assert_mode "$diff" 555
assert_mode "$diff/usr" 755
assert_mode "$diff/usr/local/bin/docker-entrypoint.sh" 755
assert_owner "$diff" "$svc:$group"
assert_link "$diff/usr/bin/pinentry" pinentry-curses
assert_file_missing "$diff/usr/bin/pinentry-curses"
assert_owner "$home/.local/bin/pinentry" root:root
assert_mode "$snap/1/snapshot" 555
assert_owner "$snap/1/snapshot" root:root
assert_mode "$snap/1/snapshot/volume.txt" 444
assert_owner "$snap/1/snapshot/volume.txt" root:root

# --- the re-ingest that walks all of it -------------------------------------

say "$GUARDEN_PREFIX/var/lib/guarden/staging/myapp/9f2c1ab/compose.yaml" \
    '# a changed source, so this create is not a converged one'

run weedr service ingest myapp-staging --from poke myapp@9f2c1ab
assert_exit 0
# Not `converged`: that word means both walks returned before doing anything,
# and a suite green on that path would be green without looking.
assert_stdout_has "created myapp-staging"

# The store keeps podman's own modes -- `dr-xr-xr-x` on the diff directory and
# the image's `0755` on the entrypoint, never the walk's `drwx------`. This is
# the assertion that would have caught the defect earliest: a walk that
# re-modes the store is wrong whatever a container happens to do about it.
assert_mode "$diff" 555
assert_mode "$diff/usr" 755
assert_mode "$diff/usr/local/bin/docker-entrypoint.sh" 755
assert_owner "$diff" "$svc:$group"

# The links are still links, the create completed, and nothing was written
# through either one: the store's own link still points at a target the image
# does not ship, and the tree's link was owned rather than followed.
assert_link "$diff/usr/bin/pinentry" pinentry-curses
assert_file_missing "$diff/usr/bin/pinentry-curses"
assert_link "$home/.local/bin/pinentry" pinentry-curses
assert_owner "$home/.local/bin/pinentry" "$svc:$group"
assert_file_missing "$home/.local/bin/pinentry-curses"

# Snapper's subtree is untouched: still root's, still the modes it was planted
# with. The snapshot subvolume is read-only on a real host, and a walk that
# owned it is the EROFS create that ended.
assert_owner "$snap" root:root
assert_mode "$snap/1/snapshot" 555
assert_owner "$snap/1/snapshot" root:root
assert_mode "$snap/1/snapshot/volume.txt" 444
assert_owner "$snap/1/snapshot/volume.txt" root:root
