#!/usr/bin/env bash
# The homepage module and `twig` (ticket 100, spec 3.6, 6.5, 6.9, 7.4).
#
# Real host, real uids, real `useradd`, and the machine's own tools, with
# `GUARDEN_PREFIX=/`: the module directory is guarden's own installation, a
# service is a system account, and a staged `/etc/passwd` reconciled with the
# real one reports a uid no account carries. This is `t50-module.sh`'s shape.
#
# **The dashboard binds no privileged port and holds no capability**, and both
# are asserted against the rendered unit rather than against the module's own
# file, because the unit is what podman reads.
#
# machine: fresh

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GUARDEN_PREFIX=/

# The marker that lets a gated-track service be removed. It is a file, not a
# service, so it is not in the purge's inventory -- and it is removed HERE,
# in the same `EXIT` trap that carries the teardown, because a second `trap
# ... EXIT` further down would REPLACE this one and the teardown would never
# run while the suite looked like it had one.
marker=/etc/guarden/allow-gated-drop

cleanup() {
    # **Every name this file creates, not most of them** (ticket 357). The list
    # is this suite's own inventory, read out of this file:
    #
    #   homepage-production  :64, :309  the dashboard, installed by
    #                                 `weedr module add homepage` and added
    #                                 AGAIN at the end, after the suite removes
    #                                 it at :286
    #   traefik-production   :137  the edge, installed by
    #                            `weedr module add gate-traefik`
    #   postgres-staging     :166  the provider the widget's project declares
    #                                 an edge on
    #   quadlet-app-staging  :176  the widget's own service
    #
    # A module installs a SERVICE, and a service is a tree, a registry entry, a
    # user and a credential -- so the module's services belong in this list as
    # much as the ingested ones do. `weedr module remove homepage` takes the
    # dashboard's service and its shared directory away, but the module is
    # added again at the end of this file, so the service is here twice over.
    local rc=0
    purge homepage-production traefik-production postgres-staging quadlet-app-staging \
        || rc=1
    # The dashboard's shared directory is the module's own (`weedr module
    # remove homepage` removes it), and the card `twig` wrote for the widget's
    # service goes with the service's own shared slice -- but the dashboard
    # directory itself holds the card tree, and a leftover card is a leftover
    # state in the same class as a leftover tree.
    rm -rf /var/lib/guarden/shared/dashboard
    # The marker is a file and not a service, so the purge does not carry it.
    rm -f "$marker"
    # **The machine is left as this suite found it.** The four directories are
    # where a service lives, and an entry left in one of them is a service the
    # next suite inherits -- which is the whole defect this teardown exists to
    # end.
    assert_no_service_left homepage-production traefik-production postgres-staging \
        quadlet-app-staging || rc=1
    return "$rc"
}
trap cleanup EXIT

# The pre-run call CLEARS and never reports: it removes what a previous run of
# THIS suite left behind, and a failure there is not this run's failure. The
# `|| true` is load-bearing -- under `set -e` a bare call would end the suite
# before its first assertion, for a leftover that is not this suite's.
cleanup || true

# The host configuration below names `operator` as `host.admin_user`, and the
# firewall renders the edge's API accept set with that account's uid. On a real
# host `soil install` records the invoking user, so the account is the fixture's
# own claim and it has to exist for the answer to be about the design rather
# than about a name nothing holds.
id -u operator >/dev/null 2>&1 || {
    getent group operator >/dev/null 2>&1 || groupadd --system operator
    useradd --system --no-create-home --gid operator --shell /usr/sbin/nologin operator
}
ensure_accounts
stage_config guarden-nomodules.toml

# `soil install` owns the `guarden` group and the `guarden` user, and it
# installs no service at all: a fresh host has no ingress and no dashboard until
# a module is added (spec 6.2).
stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_not_rejected

# The module ships, and `weedr module list` reads the directory plus
# `guarden.toml` and nothing else. `homepage` is available and not enabled.
assert_file_exists /usr/lib/guarden/modules/homepage/module.toml
assert_file_exists /usr/lib/guarden/modules/homepage/homepage-production/.guarden/service.yml
assert_file_exists /usr/lib/guarden/modules/homepage/homepage-production/.guarden/quadlet/homepage.container
run weedr module list --json
assert_exit 0
assert_json available.0 '"auth-authelia"'
assert_json available.1 '"cloudflared"'
assert_json available.2 '"gate-traefik"'
assert_json available.3 '"homepage"'
assert_json enabled '[]'
# The registry is a closed key set: the dashboard declares no forwarded port
# and no API, because it is reached through the edge by a route rather than by
# the kernel forwarding a public port at it.
assert_file_lacks /usr/lib/guarden/modules/homepage/module.toml "ingress"
assert_file_lacks /usr/lib/guarden/modules/homepage/module.toml "api ="
# ... and it names the renderer it switches on, which is `twig` and not `roots`:
# a module switches a program on, and the dashboard's renderer is its own.
assert_file_has /usr/lib/guarden/modules/homepage/module.toml 'program = "twig"'

# `soil install` ran above and is not run again: this is the claim that a
# module can be added months later without it.
run weedr module add homepage
assert_exit 0
assert_file_has /etc/guarden/guarden.toml 'enabled = ["homepage"]'

# The dashboard is a service, like any other: its own user, its own home, its
# own uid, and a distinct delegated range.
assert_passwd homepage-production
dashboard_uid=$(getent passwd homepage-production | cut -d: -f3)
assert_file_has /var/lib/guarden/registry/homepage-production.toml 'installed_by = "homepage"'
assert_file_has /var/lib/guarden/registry/homepage-production.toml "uid = $dashboard_uid"
# It is a service and not the edge: it is in neither `edge` nor `guarden`, and
# `weedr module add gate-traefik` is the only thing that creates `edge`.
assert_no_supplementary_group homepage-production edge
assert_no_supplementary_group homepage-production guarden

# The dashboard's configuration directory, `guarden:guarden 0755`. World-
# readable is the point: the dashboard is a service in neither group and the
# design keeps two groups, so `2750 guarden:<reader-group>` is not available.
assert_file_exists /var/lib/guarden/shared/dashboard
assert_mode /var/lib/guarden/shared/dashboard 755
assert_owner /var/lib/guarden/shared/dashboard "guarden:guarden"
# `twig` runs as `guarden` and can write it; the dashboard reads it and cannot
# write it, and neither can write in the root-owned shared tree `twig` reads.
run runuser -u guarden -- touch /var/lib/guarden/shared/dashboard/.written-by-twig
assert_exit 0
assert_file_exists /var/lib/guarden/shared/dashboard/.written-by-twig
# **The dashboard's user must be able to REACH the directory, not merely be
# denied a write in it.** The bind mount's source resolves through every
# ancestor, and `shared/` at 0750 root:guarden denied the traverse to a user in
# neither group -- the 0755 on the directory was unreachable text and a
# homepage container could not start. The refusal below passes either way, so
# the grant needs its own positive assertion, the shape t110's `touch` uses.
run runuser -u homepage-production -- test -r /var/lib/guarden/shared/dashboard/.written-by-twig
assert_exit 0
run runuser -u homepage-production -- touch /var/lib/guarden/shared/dashboard/refused
assert_exit 1
assert_file_missing /var/lib/guarden/shared/dashboard/refused
run runuser -u guarden -- touch /var/lib/guarden/shared/homepage-production/refused
assert_exit 1
assert_file_missing /var/lib/guarden/shared/homepage-production/refused

# The publication is a loopback one from the declared range, allocated because
# the manifest declares a route, and the edge's route host is the label with the
# production track's own empty `host_prefix` in front of it.
registry=/var/lib/guarden/registry/homepage-production.toml
assert_file_has "$registry" "[publication]"
publication=$(sed -n 's/^homepage = \([0-9]*\)$/\1/p' "$registry")
[ -n "$publication" ] || _fail "the dashboard declares a route and no publication was allocated"
[ "$publication" -ge 20000 ] && [ "$publication" -le 32767 ] \
    || _fail "publication $publication is outside ingress.publication_range"
assert_file_has "$registry" 'homepage = "homepage"'

# The rendered dashboard unit: one loopback `PublishPort` in the range, no
# capability anywhere, and no port below 1024 and no non-loopback address.
unit=/var/lib/guarden/services/homepage-production/home/.config/containers/systemd/homepage.container
assert_file_exists "$unit"
assert_file_has "$unit" "Rendered by loom"
assert_file_has "$unit" "Network=pasta:--map-gw,--ipv4-only,-a,10.0.2.100,-n,24,-g,10.0.2.2"
assert_file_has "$unit" "PublishPort=127.0.0.1:$publication:3000"
assert_file_lacks "$unit" "AmbientCapabilities"
assert_file_lacks "$unit" "CapAdd"
assert_file_lacks "$unit" "Privileged"
assert_file_lacks "$unit" "0.0.0.0:$publication"
# The dashboard reads `twig`'s directory and writes nothing into it.
assert_file_has "$unit" "Volume=/var/lib/guarden/shared/dashboard:/app/config:ro"
# And the host path is in this service's own root-owned `[mounts] allow`, which
# is the only way a host path outside the service's volumes becomes bindable.
assert_file_has /etc/guarden/services/homepage-production/overrides.toml \
    "/var/lib/guarden/shared/dashboard"

# **The dashboard declares no ingress and no API, so the edge's three forwarding
# rules are the only ones on the box.** A module that declared its own would add
# nat rules the design does not have, and this is the count that would show it.
run weedr module add gate-traefik
assert_exit 0
nat=/etc/guarden/firewall/20-ingress-nat.conf
run soil firewall --apply
assert_not_rejected
assert_rule_count "$nat" 3
assert_file_has "$nat" "proto tcp dport 80 DNAT to 127.0.0.1:"
assert_file_lacks "$nat" "MASQUERADE"
assert_file_lacks "$nat" "chain POSTROUTING"
assert_file_lacks "$nat" "REDIRECT"

# The dashboard is reachable through the edge by a route, and the edge resolves
# its name through an `AddHost=` entry in the edge's own units.
#
# `roots sync` is a precondition here, not the subject: it is the verb that turns
# the installed slices into the edge's file-provider entries, and nothing else
# writes that directory. This module switches on `twig`, which writes the
# dashboard cards — both run, and only one of them produces this file.
run runuser -u guarden -- /usr/lib/guarden/bin/roots sync
assert_exit 0
assert_file_has /var/lib/guarden/edge/dynamic/homepage-production.yml 'Host(`homepage`)'
edge_unit=/var/lib/guarden/services/traefik-production/home/.config/containers/systemd/traefik.container
assert_file_has "$edge_unit" "AddHost=homepage-production:"

# The provider the project below declares an edge on, staged and ingested first.
# Its registry entry is what the renderer's edge check reads, so without this the
# ingest below would be refused for a reason that has nothing to do with widgets
# (`t120-deploy.sh` stages the same provider, and for the same reason).
stage_poke pgprov 9f2c1ab
run weedr service ingest postgres-staging --from poke pgprov@9f2c1ab
assert_exit 0
assert_file_has /var/lib/guarden/registry/postgres-staging.toml 'kinds = ["db", "secret"]'

# A poke's staged tree, where guarden itself puts it, with a `widgets:` entry
# and its file. `staging` because its `host_prefix` is `staging.`, so the card
# and the link carry a name the repository could not have chosen.
staged=$GUARDEN_PREFIX/var/lib/guarden/staging/quadlet-app/9f2c1ab
mkdir -p "$staged/.guarden/widgets"
cp -r "$GUARDEN_ROOT/fixtures/projects/quadlet-app/." "$staged/"
run weedr service ingest quadlet-app-staging --from poke quadlet-app@9f2c1ab
assert_exit 0

# The rendered widget slice is what `twig` validates against, and it carries the
# container set because `twig` runs as `guarden` and cannot read the unit source.
slice=/var/lib/guarden/shared/quadlet-app-staging/widgets.toml
assert_file_exists "$slice"
assert_file_has "$slice" 'service = "quadlet-app-staging"'
assert_file_has "$slice" 'container = "web"'
assert_file_has "$slice" 'file = "web.yml"'
assert_file_exists /var/lib/guarden/shared/quadlet-app-staging/widgets/web.yml

# `twig sync` copies the file through **unparsed**, byte for byte, and generates
# the grouping and the per-project links beside it. The installed path, not
# `PATH`: a venv on the suite's PATH would answer for the program it means.
run runuser -u guarden -- /usr/lib/guarden/bin/twig sync
assert_exit 0
card=/var/lib/guarden/shared/dashboard/widgets/quadlet-app-staging/web.yml
assert_file_exists "$card"
# The copy is the repository's bytes, not a reformatting of them.
run cmp -s /var/lib/guarden/shared/quadlet-app-staging/widgets/web.yml "$card"
assert_exit 0
assert_file_has "$card" "name: quadlet-app web"
assert_file_has "$card" "stat: uptime"
# The grouping is generated and names the service that has a card, and the
# dashboard's own service — which declares no `widgets:` — has none.
assert_file_has /var/lib/guarden/shared/dashboard/layout.yml 'name: quadlet-app-staging'
# The dashboard's own service declares no `widgets:` and gets no group: a group
# with nothing in it is an empty heading rather than a card.
assert_file_lacks /var/lib/guarden/shared/dashboard/layout.yml "homepage-production"
# A project with no `projects.toml` entry gets no link and no error: the
# allowlist is for dispatch, and a card with no link is still a card.
assert_file_exists /var/lib/guarden/shared/dashboard/links.yml

# A sync that finds the same slices writes the same bytes, so nothing is
# reloaded for nothing and the dashboard is not disturbed by a no-op.
cp /var/lib/guarden/shared/dashboard/layout.yml "$GUARDEN_FIXTURES/first-layout.yml"
run runuser -u guarden -- /usr/lib/guarden/bin/twig sync
assert_exit 0
run cmp -s /var/lib/guarden/shared/dashboard/layout.yml "$GUARDEN_FIXTURES/first-layout.yml"
assert_exit 0

# The per-project links, from `projects.toml`. The project is pushed by the poke
# above, so the card's project is in the root-owned allowlist, and the host in
# the link is the one the mutator allocated.
seed /etc/guarden/projects.toml '[projects.quadlet-app]' \
    'repository = "git@github.com:you/quadlet-app.git"' \
    'environments = { "main" = ["production"] }'
run runuser -u guarden -- /usr/lib/guarden/bin/twig sync
assert_exit 0
assert_file_has /var/lib/guarden/shared/dashboard/links.yml "quadlet-app:"
assert_file_has /var/lib/guarden/shared/dashboard/links.yml \
    "git@github.com:you/quadlet-app.git"
assert_file_has /var/lib/guarden/shared/dashboard/links.yml "staging.web"

# **A card disappears when its service does, with no manual step.** The removal
# is `weedr service remove`, which drops the shared slice and then calls
# `twig sync`; the sweep removes the card because nothing installed it.
run weedr service remove quadlet-app-staging
assert_exit 0
assert_file_missing /var/lib/guarden/shared/quadlet-app-staging/widgets.toml
assert_file_missing /var/lib/guarden/shared/dashboard/widgets/quadlet-app-staging
assert_file_lacks /var/lib/guarden/shared/dashboard/layout.yml "quadlet-app-staging"

# A widget naming a container the unit source does not define is exit 2, and
# the diagnostic names the file and the key. `loom` refuses it at render time;
# this is a slice installed from an older render, which is what a hand edit
# looks like from here.
rejected=$GUARDEN_PREFIX/var/lib/guarden/shared/wrong-staging
mkdir -p "$rejected/widgets"
seed "$rejected/widgets.toml" 'service = "wrong-staging"' 'containers = ["web"]' \
    '[[widgets]]' 'container = "api"' 'file = "api.yml"'
seed "$rejected/widgets/api.yml" 'name: wrong api'
run runuser -u guarden -- /usr/lib/guarden/bin/twig sync
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "api"
assert_stderr_has "widgets.toml"

# A widget entry keyed `service:` rather than `container:` is exit 2 naming the
# block: a widget names a container in the same service, and only `needs` names
# another service. `loom` refuses it at render time; the same rule is checked
# here because the slice is what `twig` reads.
seed "$rejected/widgets.toml" 'service = "wrong-staging"' 'containers = ["web"]' \
    '[[widgets]]' 'service = "other-production"' 'file = "api.yml"'
run runuser -u guarden -- /usr/lib/guarden/bin/twig sync
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "service"

# Two widgets for one container is exit 2: one card is one container, and which
# of the two would win is a question the repository should not answer by
# accident.
seed "$rejected/widgets.toml" 'service = "wrong-staging"' 'containers = ["web"]' \
    '[[widgets]]' 'container = "web"' 'file = "api.yml"' \
    '[[widgets]]' 'container = "web"' 'file = "web.yml"'
seed "$rejected/widgets/web.yml" 'name: wrong web'
run runuser -u guarden -- /usr/lib/guarden/bin/twig sync
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "web"

rm -rf "$rejected"

# `weedr module remove homepage` reverses the add without touching `gate-traefik`: the
# edge keeps its account, its units, its publications and its forwarding rules,
# and the dashboard goes. The marker is the one above: it is what lets a
# service on the gated production track be removed, and the teardown takes it
# away again when the suite is done.
touch "$marker"
run weedr module remove homepage
assert_exit 0
assert_file_lacks /etc/guarden/guarden.toml '"homepage"'
assert_file_has /etc/guarden/guarden.toml 'enabled = ["gate-traefik"]'
assert_no_passwd homepage-production
assert_file_missing /var/lib/guarden/registry/homepage-production.toml
assert_file_missing /var/lib/guarden/shared/dashboard
assert_file_missing /var/lib/guarden/shared/homepage-production
# `gate-traefik` is untouched: its user, its unit and all three of its nat rules.
assert_passwd traefik-production
assert_file_exists /var/lib/guarden/services/traefik-production/home/.config/containers/systemd/traefik.container
run soil firewall --apply
assert_not_rejected
assert_rule_count "$nat" 3
assert_group edge
run weedr module list --json
assert_exit 0
assert_json enabled.0 '"gate-traefik"'
assert_json_missing enabled.1

# And the dashboard module can be added again afterwards: a removal is
# reversible with `weedr module add`, which is the claim spec 6.2 step 2 makes
# about volumes moved aside rather than deleted.
run weedr module add homepage
assert_exit 0
assert_passwd homepage-production
assert_file_exists /var/lib/guarden/shared/dashboard
assert_mode /var/lib/guarden/shared/dashboard 755
run weedr module list --json
assert_exit 0
assert_json enabled.1 '"homepage"'
