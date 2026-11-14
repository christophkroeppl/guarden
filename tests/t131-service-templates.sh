#!/usr/bin/env bash
# The service templates are installed, so `weedr service create --template` can
# work at all.
#
# ticket 330. The templates lived in `examples/services/`, which the install
# phase does not copy — it copies `src/guarden/templates/` — so on a real host
# `/usr/lib/guarden/templates/services/` did not exist and the verb that
# creates a service from a template had an empty set to choose from.
#
# The defect is invisible from the source tree: the templates are RIGHT THERE,
# in the repository, and every path in the program resolves. It is only
# invisible from the HOST, which is where the verb runs. So this suite
# asserts the installed artefact, and it asserts the VERB, because "the file is
# installed" and "the verb can use it" are two different claims and only the
# second one is the capability.
#
# **The REAL host, not a scratch one.** A template-created service allocates a
# real uid and a real subuid range, and `useradd` writes the real
# `/etc/passwd` — while a scratch host reads `PREFIX/etc/passwd`, which
# `useradd` never touches. So this suite runs against the host itself, the way
# `t120-deploy` does, and it removes the service it created.

. "$(dirname "$0")/lib.sh"

# The pinned podlet release, staged the way `t120-deploy` stages it: without
# it `soil packages` has no record to install and refuses the input (exit 2),
# which is a rejection rather than a drift — so the suite would die before it
# asserted anything about templates.
stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_not_rejected

# --- the template set is installed -------------------------------------------
#
# **The set, not just the directory.** A directory that exists and is empty is
# the exact state this ticket found: `require_template` reads
# `templates/services/`, iterates it, and an empty iteration is a set with
# nothing in it — so the directory existing proves nothing.
templates=/usr/lib/guarden/templates/services
assert_file_exists "$templates"
echo "MEASURE: the installed template set: $(ls "$templates" 2>/dev/null | tr '\n' ' ')"

found=0
for name in postgres vaultwarden rustfs; do
    if [ -d "$templates/$name" ]; then
        found=$((found + 1))
        echo "MEASURE: the $name template is installed"
    else
        _fail "the $name template is not installed, so \`weedr service create --template $name\` cannot work"
    fi
done
[ "$found" -eq 3 ] || _fail "the installed template set holds $found of the three shipped templates"

# The template's own unit file — a template directory with no unit in it is a
# template that creates a service with no container.
for name in postgres vaultwarden rustfs; do
    if ls "$templates/$name"/*.container >/dev/null 2>&1; then
        echo "MEASURE: the $name template carries a unit: $(ls "$templates/$name"/*.container | xargs -n1 basename | tr '\n' ' ')"
    else
        _fail "the $name template directory holds no .container file"
    fi
done

# **The rustfs template is a PROVIDER of the `secret` kind**, and the kind is
# what a consumer's edge is checked against — so the template's own unit has
# to name the vendor's S3 port, which is the port a consumer dials. A template
# whose unit names no port gives the provider's edge nothing to land on.
if grep -q 'PublishPort=127.0.0.1:9000:9000' "$templates/rustfs"/*.container; then
    echo "MEASURE: the rustfs template publishes the S3 port a consumer dials"
else
    _fail "the rustfs template does not publish the S3 port, so a consumer's edge has nothing to land on"
fi

# **The vendor's credentials are ASKED for, never carried.** A template is a
# file in this repository, so an `Environment=<KEY>=<value>` line for the
# store's access key is a credential in git and a credential baked into every
# host that installs the template — and `weedr secret set` would then plant a
# value nothing reads. The keys arrive as environment variables from the
# service's own podman store instead, the shape the postgres template already
# takes, and a request nothing satisfies is named by the gate rather than by
# podman's `125 no such secret`.
for key in RUSTFS_ACCESS_KEY RUSTFS_SECRET_KEY; do
    if grep -qE "^Secret=$key(,|$)" "$templates/rustfs"/*.container; then
        echo "MEASURE: the rustfs template asks for $key as a credential"
    else
        _fail "the rustfs template does not ask for $key as a credential, so either the value is in the file or nothing can plant it"
    fi
    if grep -qE "^Environment=$key=" "$templates/rustfs"/*.container; then
        _fail "the rustfs template carries $key as a plaintext Environment= line, which is a credential in git"
    fi
done

# --- the verb can choose from the set ---------------------------------------
#
# The capability, not the artefact. `create` with a template name is refused
# when the installed set does not hold the name, and that refusal is what a
# host with no templates answers.
#
# `--env staging` because `create` defaults to `production` and APPENDS the
# environment to the name — so the service this makes is
# `tmplprobe-staging`, from the name `tmplprobe`. The name is
# `<workload>-<environment>`, and the environment segment is the track.
run weedr service create tmplprobe --env staging --template postgres
assert_exit 0
echo "MEASURE: create --env staging --template postgres: created"

# The service it made exists, and its unit is the template's.
if [ -d /var/lib/guarden/services/tmplprobe-staging ]; then
    echo "MEASURE: the service tree exists"
else
    _fail "create --template postgres reported success but made no service"
fi

units=$(find /var/lib/guarden/services/tmplprobe-staging -name '*.container' 2>/dev/null | wc -l)
echo "MEASURE: the units it installed: $units"
[ "$units" -ge 1 ] || _fail "create --template postgres installed no unit, so the template did not reach the service"

# The image is the template's own — the template is the service's source of
# truth, and a service that quietly lost the image would start a container
# with no image at all.
if grep -rq 'postgres:17' /var/lib/guarden/services/tmplprobe-staging 2>/dev/null; then
    echo "MEASURE: the template's image reached the service"
else
    _fail "the installed unit does not carry the template's image"
fi

# The service is taken away again, so the suite leaves the host as it found it.
run weedr service remove tmplprobe-staging
assert_exit 0
echo "MEASURE: the probe service is removed"

echo "ok   t131-service-templates.sh"
