#!/usr/bin/env bash
# An instance's deploy leaves the service's own record fields alone, so the
# next `add` of the service is still the idempotent reconcile command spec 5.3
# makes it (adversarial review finding 1).
#
# spec 5.3: "Every step is idempotent. A second `ingest` or `add` of a
# converged service exits `0`, says it converged, and changes nothing." The
# registry is one file per SERVICE — `names.resolve` returns the name without
# the ref, so an instance's `create()` loads and writes the service's record —
# and two of its fields were values a service deploy and an instance deploy
# took turns writing:
#
#   * `source_hash`: one hash for the service AND every instance. Ticket 297
#     made `add` a second writer, so an instance ingest overwrote the hash the
#     service's own `add` had recorded with the hash of a DIFFERENT tree, and
#     the next `add` of an unchanged service found the hashes apart.
#   * the state volumes' snapper `config`: an instance deploy recorded `None`
#     over the service's `<service>-<volume>` name, and the convergence check
#     compares the service's volumes against `<service>-<volume>` — never
#     equal to `None`, so every service-level `add` after any instance deploy
#     re-deployed in full.
#
# The sequence is the review's, all ordinary verbs:
#
#   add myapp-preview --from myapp-production      record carries H(prod home)
#   ingest myapp-preview/feature-a --from poke …   same record, H(staging tree)
#   add myapp-preview --from myapp-production      nothing changed: converged
#
# The third line redeployed a service nothing had changed, which is what the
# spec sentence forbids. Each field is now the deploy's own: the hash lives
# under the instance's ref, and an instance deploy records no snapper
# configuration over the service's.
#
# machine: fresh
# `GUARDEN_PREFIX=/` and every claim below is a question to the machine: real
# system users, btrfs subvolumes, snapper configurations, and the registry
# file whose two `source_hash` values and volume configs are read back with
# `tomllib` rather than grepped off stdout.

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GUARDEN_PREFIX=/

stage_config guarden.toml
stage_poke myapp 9f2c1ab

stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_not_rejected
run weedr project add myapp --repository https://example.invalid/myapp.git
assert_exit 0

# The source service, from a poke: its home is the tree `add --from
# myapp-production` copies, and its hash is what the service's own deploys
# compare against.
run weedr service ingest myapp-production --from poke myapp@9f2c1ab
assert_exit 0
assert_stdout_has "myapp-production"

# The fork source the preview track names, so the instance below forks the
# ordinary way rather than starting empty.
run weedr service ingest myapp-staging --from poke myapp@9f2c1ab
assert_exit 0
assert_stdout_has "myapp-staging"

# The service whose record the instance will share.
run weedr service add myapp-preview --from myapp-production
assert_exit 0
assert_stdout_has "myapp-preview"
assert_file_has /var/lib/guarden/services/myapp-preview/home/compose.yaml "nginx:1.27"

# Nothing has moved: converged. This is the row the sequence below has to keep
# holding, and it is what makes the third `add` mean something.
run weedr service add myapp-preview --from myapp-production
assert_exit 0
assert_stdout_has "converged"

# The poke's tree edited, so the instance's deploy carries a tree whose hash
# differs from the one the service's home holds — the two trees the shared
# fields took turns recording.
sed -i 's|nginx:1.27|nginx:1.28|' \
    "$GUARDEN_PREFIX/var/lib/guarden/staging/myapp/9f2c1ab/compose.yaml"

run weedr service ingest myapp-preview/feature-a --from poke myapp@9f2c1ab
assert_exit 0
assert_stdout_has "forked myapp-preview/feature-a from myapp-staging"

# The review's third line, and the whole subject: the service's own tree has
# not changed, so this `add` is the idempotent one — exit 0, "converged", and
# nothing redeployed. Before the fix it answered a full `created` pass over a
# tree nothing had touched.
run weedr service add myapp-preview --from myapp-production
assert_exit 0
assert_stdout_has "converged"

# And the record says why both halves hold: the service's own hash is the tree
# `add` copies, the instance's hash is the tree its poke carried (they differ,
# because the two trees differ), and the state volumes still name the
# SERVICE's snapper configurations — an instance's is derived from its ref
# wherever it is needed and is recorded nowhere over the service's.
preview_registry=/var/lib/guarden/registry/myapp-preview.toml
run python3 -c '
import sys, tomllib

document = tomllib.load(open(sys.argv[1], "rb"))
service_hash = document.get("source_hash") or ""
instance = document.get("instances", {}).get("feature\\x2da", {})
instance_hash = instance.get("source_hash") or ""
volumes = document.get("state", {})
assert service_hash, "the service records no source_hash"
assert instance_hash, "the instance records no source_hash"
assert service_hash != instance_hash, "one hash is shared by both deploys"
assert volumes and all(entry.get("config") for entry in volumes.values()), \
    f"the state volumes carry no snapper configuration: {volumes}"
assert all("-feature\\x2da-" not in entry["config"] for entry in volumes.values()), \
    f"an instance configuration landed on the service volumes: {volumes}"
' "$preview_registry"
assert_exit 0

# The instance's own convergence is not this file's subject — its volumes are
# its own and a re-ingest re-deploys them — but the cap's arithmetic still
# counts one instance and nothing was evicted by any of the three verbs above.
held=$(ls -1 /var/lib/guarden/services/myapp-preview/instances | wc -l)
[ "$held" = 1 ] || _fail "myapp-preview holds $held instances after the sequence, expected 1"
