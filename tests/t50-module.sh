#!/usr/bin/env bash
# The gate module: `weedr module list`, `weedr module add gate`, and the state
# the add leaves behind (ticket 50, spec 3.6, 6.2, 7.4, 7.5, ADR-0008).
#
# There is no staged host here and that is the whole of what this file is about:
# a module's service is a real `useradd`, a real uid and a real delegated
# `/etc/subuid` range, and a staged `/etc/passwd` reconciled with the real one
# reports a uid no account carries. `GUARDEN_PREFIX=/` and the machine's own
# tools, the way `t30-create` and `t60-gate` already do.
#
# **The edge binds no privileged port, and there is no capability anywhere.**
# Both are asserted against the rendered unit rather than against the module's
# own file, because the unit is what podman reads.
#
# machine: fresh

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GUARDEN_PREFIX=/

# `soil install` owns the `guarden` group and the `guarden` user, and this file
# needs both: the registry is `root:guarden` and `loom` runs as `guarden`.
getent group guarden >/dev/null 2>&1 || groupadd --system guarden
id -u guarden >/dev/null 2>&1 || useradd --system --no-create-home --gid guarden guarden
# The host configuration below names `operator` as `host.admin_user`, and the
# firewall renders the edge's API accept set with that account's uid. On a real
# host `soil install` records the invoking user, so the account is the fixture's
# own claim and it has to exist for the answer to be about the design rather
# than about a name nothing holds.
id -u operator >/dev/null 2>&1 || {
    getent group operator >/dev/null 2>&1 || groupadd --system operator
    useradd --system --no-create-home --gid operator --shell /usr/sbin/nologin operator
}
mkdir -p /etc/guarden
stage_config guarden-nomodules.toml

# `soil install` is this suite's precondition and not its subject: the module
# directory is guarden's own installation, and a module added months later must
# not need the phase to run again.
run soil install --apply
assert_not_rejected
assert_file_exists /usr/lib/guarden/modules/gate/module.toml
assert_file_exists /usr/lib/guarden/modules/gate/traefik-production/.guarden/service.yml

# The registry: the directory plus `guarden.toml` and nothing else. The edge is
# not installed yet, so it is available and not enabled.
run weedr module list --json
assert_exit 0
assert_json available.0 '"gate"'
assert_json enabled '[]'
run weedr module list
assert_exit 0
assert_stdout_has "gate"
assert_stderr_empty

# A module that ships nothing is rejected input, and nothing was written.
run weedr module add nosuchmodule
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "nosuchmodule"
assert_file_lacks /etc/guarden/guarden.toml "nosuchmodule"

# The add itself. `soil install` ran above and is not run again: this is the
# claim that a module can be added without it.
run weedr module add gate
assert_exit 0
assert_file_has /etc/guarden/guarden.toml 'enabled = ["gate"]'

# The edge is a service, like any other: its own user, its own home, a uid the
# host's own user database allocated, and a distinct delegated range.
assert_passwd traefik-production
edge_uid=$(getent passwd traefik-production | cut -d: -f3)
assert_file_exists "/etc/containers/systemd/users/$edge_uid"
assert_file_has /var/lib/guarden/registry/traefik-production.toml \
    'installed_by = "gate"'
assert_file_has /var/lib/guarden/registry/traefik-production.toml "uid = $edge_uid"

# **`edge` belongs to this verb and to no other phase.** `soil install` creates
# the `guarden` group and no other, so this is the first time `edge` exists.
assert_group edge
assert_supplementary_group traefik-production edge
# ... and the edge's user is in `edge` and NOT in `guarden`: it is a service, and
# a service reads `/etc/guarden` and nothing of the unprivileged programs'.
assert_no_supplementary_group traefik-production guarden

# The edge's configuration directory, written by `roots` as `guarden` and read by
# the edge: `guarden:edge 2750`, so neither can write where the other writes.
assert_file_exists /var/lib/guarden/edge/dynamic
assert_mode /var/lib/guarden/edge/dynamic 2750
assert_owner /var/lib/guarden/edge/dynamic "guarden:edge"
# `roots` can write it and the edge cannot; the edge can read it and `roots` has
# no business in the edge's own tree, which is `0700` to the edge. Every write
# goes through `run`, or the exit code asserted below is the previous command's.
run runuser -u guarden -- touch /var/lib/guarden/edge/dynamic/.written-by-roots
assert_exit 0
assert_file_exists /var/lib/guarden/edge/dynamic/.written-by-roots
run runuser -u traefik-production -- touch /var/lib/guarden/edge/dynamic/refused
assert_exit 1
assert_file_missing /var/lib/guarden/edge/dynamic/refused
run runuser -u guarden -- touch /var/lib/guarden/services/traefik-production/home/refused
assert_exit 1
assert_file_missing /var/lib/guarden/services/traefik-production/home/refused

# The publications: one per entrypoint the module declares and one for the API,
# every one of them inside `ingress.publication_range` and every one different.
# They are loopback publications, not ports the edge binds on a public address.
registry=/var/lib/guarden/registry/traefik-production.toml
assert_file_has "$registry" "[publication]"
web_publication=$(sed -n 's/^web = \([0-9]*\)$/\1/p' "$registry")
tls_publication=$(sed -n 's/^websecure = \([0-9]*\)$/\1/p' "$registry")
api_publication=$(sed -n 's/^api = \([0-9]*\)$/\1/p' "$registry")
[ -n "$web_publication" ] || _fail "the edge's redirect publication was never allocated"
[ -n "$tls_publication" ] || _fail "the edge's TLS publication was never allocated"
[ -n "$api_publication" ] || _fail "the module declares api = true and no API publication exists"
[ "$web_publication" != "$tls_publication" ] \
    || _fail "the redirect and TLS entrypoints share one publication"
[ "$api_publication" != "$web_publication" ] \
    || _fail "the API shares a publication with an ingress entrypoint"
for publication in "$web_publication" "$tls_publication" "$api_publication"; do
    [ "$publication" -ge 20000 ] && [ "$publication" -le 32767 ] \
        || _fail "publication $publication is outside ingress.publication_range"
done

# `weedr service list` reports the numbers, and `weedr port list` shows the API
# on its own line — it is a control surface, not a requested public port.
run weedr service list
assert_exit 0
assert_stdout_has "web=$web_publication"
assert_stdout_has "websecure=$tls_publication"
run weedr port list
assert_exit 0
assert_stdout_has "api $api_publication"
assert_stdout_has "never forwarded"

# The rendered edge unit: every `PublishPort` is a loopback publication in the
# range, and there is no capability, no privileged port and no non-loopback
# address anywhere in it.
unit=/var/lib/guarden/services/traefik-production/home/.config/containers/systemd/traefik.container
assert_file_exists "$unit"
assert_file_has "$unit" "Rendered by loom"
assert_file_has "$unit" "Network=pasta:"
assert_file_has "$unit" "PublishPort=127.0.0.1:$web_publication:80"
assert_file_has "$unit" "PublishPort=127.0.0.1:$tls_publication:443"
# The API publication is bound too. `api = true` allocates it and the firewall
# admits it for `host.admin_user`, so leaving it unbound would be a port the
# host accepts on and the edge answers nothing on. The container port comes from
# the entrypoint the edge's own source serves the API on.
assert_file_has "$unit" "PublishPort=127.0.0.1:$api_publication:8080"
assert_file_lacks "$unit" "AmbientCapabilities"
assert_file_lacks "$unit" "CapAdd"
assert_file_lacks "$unit" "Privileged"
assert_file_lacks "$unit" "0.0.0.0:$web_publication"
assert_file_lacks "$unit" "$web_publication:$web_publication"
# The edge reads the shared directory read-only, which is the only direction it
# has any business writing it in.
assert_file_has "$unit" "Volume=/var/lib/guarden/edge/dynamic:/etc/guarden/edge:ro"

# One job each: `web` redirects, `websecure` terminates TLS, `api` serves the
# control surface. An entrypoint doing both the redirect and TLS is refused, and
# the refusal is exit 2 naming it.
assert_file_has "$unit" "--entryPoints.web.http.redirections.entrypoint.to=https"
assert_file_has "$unit" "--entryPoints.websecure.http3"
assert_file_has "$unit" "--entryPoints.api.http.api.insecure=true"

# The shared slice `roots` reads is installed, and the order target is in the
# system path podman's generator looks in.
assert_file_exists /var/lib/guarden/shared/traefik-production/routes.toml
assert_file_exists /etc/systemd/system/guarden-order.target

# `20-ingress-nat.conf`: three rules, one per forwarded port, each a DNAT onto
# the publication of the entrypoint that answers it. `443/udp` shares the TLS
# publication because it is served from the same entrypoint.
nat=/etc/guarden/firewall/20-ingress-nat.conf
run soil firewall --apply
assert_not_rejected
assert_file_has "$nat" \
    "proto tcp dport 80 DNAT to 127.0.0.1:$web_publication"
assert_file_has "$nat" \
    "proto tcp dport 443 DNAT to 127.0.0.1:$tls_publication"
assert_file_has "$nat" \
    "proto udp dport 443 DNAT to 127.0.0.1:$tls_publication"
assert_rule_count "$nat" 3
# Bare target words: the `-j` spelling ferm never emits asserted nothing.
assert_file_lacks "$nat" "MASQUERADE"
assert_file_lacks "$nat" "POSTROUTING"
assert_file_lacks "$nat" "REDIRECT"
assert_file_lacks "$nat" "SNAT"
assert_file_lacks "$nat" "jump DNAT"

# The intra-host rule set: accepts above one drop, and the drop carries no uid.
services=/etc/guarden/firewall/30-services.conf
assert_file_exists "$services"
assert_file_has "$services" "chain guarden-svc"
assert_file_has "$services" \
    "mod owner uid-owner $edge_uid daddr 127.0.0.1 proto tcp dport $web_publication jump ACCEPT;"
assert_file_has "$services" \
    "mod owner uid-owner $edge_uid daddr 127.0.0.1 proto tcp dport $tls_publication jump ACCEPT;"
assert_file_lacks "$services" "192.0.2.1"
# The API's accept set is `host.admin_user` and nobody else.
admin_uid=$(getent passwd operator | cut -d: -f3)
assert_file_has "$services" \
    "mod owner uid-owner $admin_uid daddr 127.0.0.1 proto tcp dport $api_publication jump ACCEPT;"
# The drop is the last rule and names no uid: a default deny that enumerates who
# it applies to leaves every other uid with the box's own default policy.
# Rule lines only, so the provenance comments cannot move the numbers.
drop_line=$(grep -vE '^[[:space:]]*(#|$)' "$services" | grep -n 'jump DROP;' | tail -1 | cut -d: -f1)
accept_line=$(grep -vE '^[[:space:]]*(#|$)' "$services" | grep -n 'jump ACCEPT;' | tail -1 | cut -d: -f1)
[ "$drop_line" -gt "$accept_line" ] \
    || _fail "the loopback drop is not the last rule in 30-services.conf"
run grep 'jump DROP;' "$services"
assert_exit 0
assert_stdout_lacks "uid-owner"
assert_stdout_has "daddr 127.0.0.0/8"
# KNOWN DIVERGENCE, asserted not deleted: spec 7.6 puts `-o lo` on this deny and
# on every accept; firewall.py emits no interface match at all. Fails until reconciled.
case "$GUARDEN_STDOUT" in
    *"if lo"*|*"o lo"*) ;;
    *) _fail "30-services.conf's deny carries no interface match; spec 7.6 shows -o lo and firewall.py emits none" ;;
esac

# A second add is a no-op: the service converges, the list does not grow a
# second copy, and the ingress is still three rules.
run weedr module add gate
assert_exit 0
run soil firewall --apply
assert_not_rejected
assert_rule_count "$nat" 3
assert_file_has /etc/guarden/guarden.toml 'enabled = ["gate"]'

# `weedr module list` after the add reports both halves.
run weedr module list --json
assert_exit 0
assert_json enabled.0 '"gate"'
assert_json available.0 '"gate"'
