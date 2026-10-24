#!/usr/bin/env bash
# Config file injection, installed (ticket 289, spec 2, 4 and 6.3).
#
# The other half of `t40-configfiles.sh`, and the half that needs a real machine:
# `loom` renders the file, and `weedr service ingest` puts it in the service home
# at the target's own path. The claims here are about the home — the file is
# there, it is the service user's own rather than root's, and the directories its
# path needs are the service user's too — and about the convergence predicate,
# which has to see a changed template as a change rather than converge over it.
#
# The machine is this file's own: `ingest` writes a real user, a real home and
# real files, and nothing here reads a record of what guarden meant to do.

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

export GUARDEN_PREFIX=/
stage_config guarden.toml

stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_not_rejected

tree=/var/lib/guarden/staging/myapp/9f2c1ab
home=/var/lib/guarden/services/myapp-production/home
seed "$tree/.guarden/service.yml" "project: myapp" "units: .guarden/quadlet/" \
    "config_files:" "  - source: templates/odoo.conf.j2" "    target: /etc/odoo/odoo.conf"
seed "$tree/.guarden/quadlet/web.container" "[Unit]" "Description=the web container" \
    "" "[Container]" "Image=docker.io/library/nginx:1.27" \
    "Volume=$home/etc/odoo:/etc/odoo"
seed "$tree/templates/odoo.conf.j2" "[options]" "db_name = myapp"

run weedr service ingest myapp-production --from poke myapp@9f2c1ab
assert_exit 0
assert_stderr_empty

# The rendered file is in the home at the target's own path, and it is the
# service user's own: nothing root-owned lives inside a service's home (spec 2),
# and a config file the mutator left as root's would be the one thing that rule
# forbids. The directories the target needs are the service user's for the same
# reason — a directory the mutator made at `0755` would be one.
config=$home/etc/odoo/odoo.conf
assert_file_exists "$config"
assert_file_has "$config" "db_name = myapp"
assert_owner "$config" "myapp-production:$(id -gn myapp-production)"
assert_mode "$config" 640
assert_owner "$home/etc/odoo" "myapp-production:$(id -gn myapp-production)"
assert_mode "$home/etc/odoo" 700
assert_owner "$home/etc" "myapp-production:$(id -gn myapp-production)"
assert_mode "$home/etc" 700

# The unit source's own bind mount is what delivers it, and it is unchanged by
# this feature: the repository names `<home>/<target>:<target>`, and the file the
# renderer put at the home's end of it is what makes the mount non-empty.
assert_file_has "$home/.config/containers/systemd/web.container" \
    "Volume=$home/etc/odoo:/etc/odoo"

# The template travels with the service, which is what makes a re-render possible
# once the poke's staging tree is gone.
assert_file_has "$home/templates/odoo.conf.j2" "db_name = myapp"

seed "$tree/templates/odoo.conf.j2" "[options]" "db_name = myapp" "workers = 4"
run weedr service ingest myapp-production --from poke myapp@9f2c1ab
assert_exit 0
assert_file_has "$config" "workers = 4"

# An unchanged tree converges, and the file is left alone rather than rewritten.
run weedr service ingest myapp-production --from poke myapp@9f2c1ab
assert_exit 0
assert_stdout_has "converged"

seed "$tree/.guarden/service.yml" "project: myapp" "units: .guarden/quadlet/" \
    "config_files:" "  - source: templates/absent.j2" "    target: /etc/odoo/odoo.conf"
run weedr service ingest other-production --from poke myapp@9f2c1ab
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "absent.j2"
assert_no_passwd other-production
assert_file_missing /var/lib/guarden/services/other-production
