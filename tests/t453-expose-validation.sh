#!/usr/bin/env bash
# t453-expose-validation.sh — ticket 293, the two halves of its "What to build"
# that the behaviour suite (t452) does not reach: the track field's own
# validation, and the shipped table's own posture.
#
# t452 measures the DERIVED DEFAULT: a track that says nothing, a module set
# that answers. It cannot measure two things that are about the field itself,
# because a suite that says nothing about `expose` never exercises the field's
# own rules:
#
#   1. **The value set.** `expose` is `loopback`, `tunnel` or `edge`, and
#      anything else is refused with the track named — the way a `kind`/`cap`
#      mistake is refused (spec 3.1). A field that accepted anything would make
#      "the track states a posture" a claim with no meaning, and a typo
#      (`exose = "edge"`) would resolve as a track that says nothing, which is
#      the fail-closed answer — a private service on a host the operator
#      believed was public. The refusal is what makes the typo loud.
#
#   2. **The shipped table.** A fresh host gets the shipped
#      `templates/guarden.toml`, and that file must not pin a posture: the
#      derived default is the posture (ticket 293), and a template that pinned
#      `edge` would put every new service on the internet on a box that never
#      asked for it. This is measured on a host where the file is ABSENT and
#      `soil install` seeds it — which is the shape a fresh host is, and the
#      only shape in which the template is the host's own table.
#
# The third case is the counter-example that keeps the first honest: a track
# that says `edge` is ACCEPTED, and its routes are rendered into the edge.
# A suite that only asserted refusals would be green against a field that
# refused everything.
#
# machine: fresh

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GUARDEN_PREFIX=/

ensure_accounts
stage_podlet_release
stage_poke routed 9f2c1ab
# The programs are installed before anything is deployed: a render is done by
# `loom`, and a suite that ingested before the install would be measuring a
# missing binary rather than a posture.
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_not_rejected

# --- 1. the value set ------------------------------------------------------
#
# A track whose `expose` is a word the field does not carry is refused, and
# the refusal names the TRACK — the same shape as the `kind`/`cap` refusal the
# spec states, and the shape an operator needs: a root-owned file with four
# tracks in it, and the line that says which one is wrong.
cat >"$GUARDEN_PREFIX/etc/guarden/guarden.toml" <<'TOML'
[host]
domain = "example.com"
interface = ""
admin_user = "operator"

[ingress]
alias = ""
publication_range = [20000, 32767]

[network]
backend = "pasta"
pasta_options = [ "--map-gw", "--ipv4-only", "-a", "10.0.2.100", "-n", "24", "-g", "10.0.2.2" ]

[build]
lanes = 1

[modules]
enabled = []

[[environments]]
name = "production"
expose = "public"
host_prefix = ""
gated = true
weight = 1000
free_limit = 0.10
keep_last = 7
kind = "slot"
fork_from = ""

[[environments]]
name = "staging"
host_prefix = "staging."
gated = false
weight = 100
free_limit = 0.20
keep_last = 0
kind = "slot"
fork_from = "production"
TOML
chmod 0640 "$GUARDEN_PREFIX/etc/guarden/guarden.toml"
chown root:guarden "$GUARDEN_PREFIX/etc/guarden/guarden.toml"

run weedr service ingest routed-staging --from poke routed@9f2c1ab
# A well-formed file that breaks a rule the document states is exit 2, and
# the track is named. **The track named is not the track being deployed:**
# `production` carries the bad value and the service is on `staging`, so the
# refusal is about the TABLE and not about one service's request — a table
# with a bad row in it is refused whole, because the next service to be
# created would resolve against it.
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "'production'"
assert_stderr_has "expose"
# The refusal names the three that ARE values, so the operator is not left
# guessing what the field takes.
assert_stderr_has "loopback"
assert_stderr_has "tunnel"
assert_stderr_has "edge"
# The refusal is about the TABLE, so nothing was created: no record, no
# system account. A host that refused a field must not be half configured.
assert_file_missing "$GUARDEN_PREFIX/var/lib/guarden/registry/routed-staging.toml"
assert_no_passwd routed-staging

# The bad row is taken out and a track that states a value the field DOES
# carry states it: `edge` publishes the route, which is the counter-example
# that keeps the refusal above honest. A field that refused everything would
# be green against the block above.
sed -i '/^expose = "public"$/d' "$GUARDEN_PREFIX/etc/guarden/guarden.toml"
sed -i '/^name = "staging"$/a expose = "edge"' "$GUARDEN_PREFIX/etc/guarden/guarden.toml"
run weedr service ingest routed-staging --from poke routed@9f2c1ab
assert_exit 0
edge_slice=$GUARDEN_PREFIX/var/lib/guarden/shared/routed-staging/routes.toml
edge_destination=$(sed -n 's/^destination = "\(.*\)"$/\1/p' "$edge_slice" | head -n 1)
[ "$edge_destination" = "edge" ] \
    || _fail "a track stating expose = edge rendered destination $edge_destination, not edge"

# The service comes away again, so the block below measures a fresh host's
# posture and not the posture of a service that already holds a record. The
# staging track is not gated, so the removal is not refused.
run weedr service remove routed-staging
assert_exit 0
assert_file_missing "$GUARDEN_PREFIX/var/lib/guarden/registry/routed-staging.toml"

# --- 2. the shipped table --------------------------------------------------
#
# A host with NO table is what a fresh host is, and `soil install` seeds the
# shipped one. The seeded file is the one the template holds, so the claim
# under test — "the shipped table states no posture" — is read off the file
# the host ended up with, not off the template in the checkout.
rm -f "$GUARDEN_PREFIX/etc/guarden/guarden.toml"
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_not_rejected
assert_file_exists "$GUARDEN_PREFIX/etc/guarden/guarden.toml"
# **No track states a posture.** The comment above the table says so in
# prose, and this says it in the file: an `expose` line on any of the three
# tracks is a posture pinned on every fresh host, which is the thing ticket
# 293 exists to remove.
assert_file_lacks "$GUARDEN_PREFIX/etc/guarden/guarden.toml" "expose ="
# The three tracks are still there — the table is not emptied to make the
# claim, it is the same table with one field left off.
for track in production staging preview; do
    assert_file_has "$GUARDEN_PREFIX/etc/guarden/guarden.toml" "name = \"$track\""
done

# And the host those three tracks describe resolves the DERIVED posture: with
# no `cloudflared` module in the table, a new service is loopback-only. The
# module set is the table's own `[modules] enabled`, and the shipped table
# carries `gate-traefik` and `homepage` and no tunnel.
assert_file_has "$GUARDEN_PREFIX/etc/guarden/guarden.toml" 'enabled = ["gate-traefik", "homepage"]'
stage_poke routed 9f2c1ab
run weedr service ingest routed-staging --from poke routed@9f2c1ab
assert_exit 0
slice=$GUARDEN_PREFIX/var/lib/guarden/shared/routed-staging/routes.toml
[ -f "$slice" ] || _fail "the new service rendered no route slice at all"
destination=$(sed -n 's/^destination = "\(.*\)"$/\1/p' "$slice" | head -n 1)
[ "$destination" = "loopback" ] \
    || _fail "the shipped table's own host resolved destination $destination, not loopback"
# The edge is not rendered for a loopback-only service, so the route is
# published nowhere outside the box.
run runuser -u guarden -- /usr/lib/guarden/bin/roots sync
assert_exit 0
assert_file_missing "$GUARDEN_PREFIX/var/lib/guarden/edge/dynamic/routed-staging.yml"
