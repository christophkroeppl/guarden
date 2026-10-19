#!/usr/bin/env bash
# `weedr service add` applies an edited source, and is the reconcile command
# spec 5.3 says it is (ticket 297).
#
# spec 5.3: "`ingest` requires its two arguments. `add` requires `--from`, and
# is also the reconcile command: run either again to apply an edited manifest",
# beside "Every step is idempotent. A second `ingest` or `add` of a converged
# service exits `0`, says it converged, and changes nothing." What made an edit
# visible to that check was `source_hash`, computed for `kind == "poke"` only,
# so `add` answered `converged` after the tree it copies had been edited and
# installed nothing — while docs/sysadmin.md said the reconcile note "holds for
# this case exactly as it holds for a poke". The spec is the contract and the
# code was the side that was wrong (AGENTS.md), so `add` hashes its source too.
#
# The source for `add --from <service>` is that service's own home, which is
# where the manifest lives (spec 6.6) and where the operator edits — so this is
# t30-create.sh's convergence block in `add`'s vocabulary.
#
# machine: fresh
# `GUARDEN_PREFIX=/` and every claim below is a question to the machine: a
# system user, a passwd entry, btrfs subvolumes, a snapper configuration, and
# the unit files the re-deploy installs.

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

# The source service, from a poke. Its home is the tree every `add --from
# myapp-production` copies.
run weedr service ingest myapp-production --from poke myapp@9f2c1ab
assert_exit 0
assert_stdout_has "myapp-production"
assert_stderr_empty
assert_file_has /var/lib/guarden/services/myapp-production/home/.guarden/service.yml \
    "project: myapp"

# The first `add` creates the service from that tree and records what the tree
# was, so the next one has something to compare against.
run weedr service add myapp-staging --from myapp-production
assert_exit 0
assert_stdout_has "myapp-staging"
assert_file_has /var/lib/guarden/services/myapp-staging/home/compose.yaml "nginx:1.27"

# Nothing edited: converged, and nothing changes. This is the other half of the
# same spec sentence — a second `add` of a converged service exits `0` and says
# so — and it is what keeps the assertion below about the edit alone.
run weedr service add myapp-staging --from myapp-production
assert_exit 0
assert_stdout_has "converged"

# The edit, in the tree `add` copies rather than in a replacement file: a stub
# that mounted nothing would earn the render's own refusal about the manifest
# instead of a different hash.
sed -i 's|nginx:1.27|nginx:1.28|' /var/lib/guarden/services/myapp-production/home/compose.yaml

# The reconcile: `add` again, and the edit is applied — not converged, and the
# copy the redeploy makes and the unit it installs both carry the new image.
run weedr service add myapp-staging --from myapp-production
assert_exit 0
assert_stdout_lacks "converged"
assert_stdout_has "myapp-staging"
assert_file_has /var/lib/guarden/services/myapp-staging/home/compose.yaml "nginx:1.28"
assert_file_has \
    /var/lib/guarden/services/myapp-staging/home/.config/containers/systemd/web.container \
    "nginx:1.28"

# And the service is converged again straight afterwards: an edit re-deploys
# once, and the redeploy is not a state the next run keeps working from.
run weedr service add myapp-staging --from myapp-production
assert_exit 0
assert_stdout_has "converged"
