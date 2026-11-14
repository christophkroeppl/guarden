#!/usr/bin/env bash
# The alias: the pinned set it derives from, and the hop it promises.
#
# (ticket 130, spec 6.1, spec 1.2)
#
# `ingress.alias` is no longer measured. The container's default gateway is
# pinned in `[network] pasta_options` — `-g 10.0.2.2` — pasta maps that gateway
# onto the host's loopback in userspace, and `soil install` derives the alias
# from it, so the value is a fact about the table rather than about whichever
# route the host happened to have when a probe last ran. Three claims keep that
# honest, and this suite is all three:
#
#   1. a `pasta_options` set that does not pin the pieces the design depends on
#      (`--map-gw`, `--ipv4-only`, `-a`, `-n`, `-g`) is rejected input, refused
#      the way every pasta refusal is: exit 2, one `error:` line, naming the
#      piece that is missing;
#   2. with the pinned set staged, `soil install --apply` writes
#      `alias = "10.0.2.2"` — the `-g` value — and a `--check` on the converged
#      host is silent;
#   3. **the hop itself, measured on this machine.** An unprivileged `ubuntu`
#      container with the pinned options dials 10.0.2.2 and reaches a listener
#      bound to 127.0.0.1 on the host, with the host-side socket owned by uid
#      1000 and both of its ends 127.0.0.1 — the facts the retired probe
#      measured, now measured without an image this repository does not ship.
#
# **The hop is real and it is unprivileged, and that is the point.** root cannot
# run pasta (the subuid range belongs to `ubuntu`), and a suite that asked a
# stand-in for podman would be asserting its own fake; so the image is built
# from this machine's own `/bin/busybox` and run as `ubuntu` with the real
# podman. `tests/t130-hop.py` is the helper that holds both ends of the
# connection up long enough to read the kernel's socket table — a helper that
# reads machine state, not a fixture.
#
# machine: fresh
# The suite installs a package (`busybox-static`), imports an image into
# `ubuntu`'s own store and runs real containers, so it leaves package state and
# an image store behind: it gets a machine of its own.

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

export GUARDEN_PREFIX=/
config=/etc/guarden/guarden.toml

# The hop below needs two machine facts, asserted here so a machine without them
# fails with their names rather than with a hop that could not start: the
# unprivileged user's subuid range, because only it may map container-root into
# its own range, and pasta itself, which arrives as a podman Recommends and is
# what `pasta:` runs. Neither is a fixture; both are read from the machine.
run grep -c "^ubuntu:" /etc/subuid
assert_exit 0
assert_stdout_has "1"
run pasta --version
assert_exit 0

# The pinned set, once. The design states it as a constant — the gateway the
# alias is, the address the container holds, the subnet that puts the two
# on-link — and the configuration under test and the container below each name
# it in their own spelling.
pinned='--map-gw,--ipv4-only,-a,10.0.2.100,-n,24,-g,10.0.2.2'

# The shipped table pins the set; what is rewritten here is the one line under
# test, so the only defect the phase reads is the missing piece. `--ipv4-only`
# is the piece left out, and the diagnostic must name it: a refusal that says
# "the set is wrong" without saying which piece sends the operator to the wrong
# line. A refused input converges nothing, so the alias is still the
# unmeasured one afterwards.
stage_config guarden.toml
assert_file_has "$config" 'alias = ""'
sed -i 's/^pasta_options = .*/pasta_options = [ "--map-gw", "-a", "10.0.2.100", "-n", "24", "-g", "10.0.2.2" ]/' "$config"
run soil install --check
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "pasta_options"
assert_stderr_has "--ipv4-only"
assert_file_has "$config" 'alias = ""'

# The same table, whole again: the apply writes the `-g` value into
# `ingress.alias` — not a measurement, a derivation — and the `--check` that
# follows is what "already true" looks like from outside (spec 1.2). The
# fragments under it tie this staged table to the container below: the set the
# container runs is the one this file pins, piece for piece, so a template
# change the hop does not follow shows up as a fragment that moved. `-g` is
# tied by the alias assert, `--map-gw` by the hop succeeding at all, and the
# rest by their own fragments here.
stage_config guarden.toml
run soil install --apply
assert_exit 0
assert_stderr_empty
assert_file_has "$config" 'alias = "10.0.2.2"'
assert_file_has "$config" '"--ipv4-only"'
assert_file_has "$config" '"10.0.2.100"'
assert_file_has "$config" '"-n", "24"'
run soil install --check
assert_exit 0
assert_stderr_empty

# The container's gateway is pinned, but a pinned option is a promise about a
# container's routing, and only a container can keep it. So the promise is
# measured the way the retired probe measured it — one real rootless container
# under `ubuntu`, one listener on the host's loopback — and the facts are the
# ones a mapping fault can change: the default route names the gateway, the
# gateway reaches the host, and the connection's host-side ends are both the
# loopback. The uid the connection is owned by is recorded too, but it is the
# state rather than a mutation-catcher: pasta's mirrored pair of sockets shares
# it, so a broken mapping could not change it.
apt_waits install -y busybox-static
assert_executable /bin/busybox

hop=/tmp/guarden-t130-hop
hop_tar=/tmp/guarden-t130-hop.tar
hop_helper=/tmp/guarden-t130-hop.py
hop_report=/tmp/guarden-t130-hop.report
hop_port=27813

# The image is this machine's own busybox, packed by the machine's own tar: a
# payload built inside the VM from a file the machine already has. Nothing is
# fetched — a fetch is a phase and the phase runs on a machine — and nothing is
# a stand-in: the client below is the real busybox from the real package.
mkdir -p "$hop/bin"
cp /bin/busybox "$hop/bin/busybox"
tar -C "$hop" -cf "$hop_tar" .
chmod 644 "$hop_tar"
# The helper is read by `ubuntu` and the checkout is not, so it is copied to a
# readable path, where the listener and the report live too.
cp "$GUARDEN_ROOT/tests/t130-hop.py" "$hop_helper"
chmod 644 "$hop_helper"

# The import is the unprivileged user's, because the image store is: the subuid
# range belongs to `ubuntu` and only it may map container-root into it.
run runuser -u ubuntu -- env -C /tmp podman import --change 'CMD ["/bin/busybox","sleep","3600"]' "$hop_tar" localhost/probe-bb:latest
assert_exit 0

# The container's default route names the pinned gateway, which is the value the
# alias is; and its own address is the pinned one, so `-a` and `-g` are the
# addresses this run is about.
run runuser -u ubuntu -- env -C /tmp podman run --rm --log-level=error --network "pasta:$pinned" localhost/probe-bb /bin/busybox ip -4 route show default
assert_exit 0
assert_stdout_has "default via 10.0.2.2"
run runuser -u ubuntu -- env -C /tmp podman run --rm --log-level=error --network "pasta:$pinned" localhost/probe-bb /bin/busybox ip addr show
assert_exit 0
assert_stdout_has "10.0.2.100"

# The hop itself. The helper binds 127.0.0.1:$hop_port, starts one container as
# the client dialling the pinned gateway at that port, and reads the kernel's
# socket table while both ends are up — the sample a suite cannot take, because
# the connection exists only for the life of the container.
run runuser -u ubuntu -- env -C /tmp python3 "$hop_helper" "$hop_port" "pasta:$pinned" localhost/probe-bb:latest "$hop_report"
assert_exit 0
# The connection arrived and carried the container's payload ...
assert_file_has "$hop_report" "peer=127.0.0.1"
assert_file_has "$hop_report" "received=hop"
# ... the host-side socket is owned by the unprivileged user's uid (recorded
# rather than relied on: both sockets of pasta's mirrored pair are the same
# uid, so this is the state, not a mutation-catcher) ...
assert_file_has "$hop_report" "uid=1000"
# ... and both of its ends are the loopback, which is what the OUTPUT accept
# rules are written to match. `ss` says it in its own words, and the kernel's
# table says it in its own: two readers, one answer.
assert_file_has "$hop_report" "ss_local=127.0.0.1:$hop_port"
assert_file_has "$hop_report" "ss_peer=127.0.0.1:"
assert_file_has "$hop_report" "proc_local=127.0.0.1"
assert_file_has "$hop_report" "proc_remote=127.0.0.1"

# DNS still resolves inside the container: pasta forwards it, and the loopback
# mapping the alias relies on does not swallow it. This is evidence about
# pasta's forwarder and not about the loopback deny — the firewall phase does
# not run on a cut, so nothing here renders or reads a rule.
run runuser -u ubuntu -- env -C /tmp podman run --rm --log-level=error --network "pasta:$pinned" localhost/probe-bb /bin/busybox nslookup example.com
assert_exit 0
assert_stdout_has "example.com"

# The host's route table gains nothing: the pinned subnet lives in the
# container's own network namespace, and pasta's mapping is userspace. The
# report carries the table as it was read during the hop, and the check below
# reads it again after — a route that only appeared while a container ran would
# be missed by the second one and is not missed by the first.
assert_file_lacks "$hop_report" "10.0.2.0/24"
run ip -4 route show
assert_exit 0
assert_stdout_lacks "10.0.2.0/24"

# Clean up: the image is `ubuntu`'s, and the payload, the helper and the report
# are this suite's own scratch.
run runuser -u ubuntu -- env -C /tmp podman rmi localhost/probe-bb:latest
assert_exit 0
rm -rf "$hop" "$hop_tar" "$hop_helper" "$hop_report"
