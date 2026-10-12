#!/usr/bin/env bash
# `weedr share`: a grant is an issuance, an issuance always expires, and the
# vendor's Access policy is a projection of guarden's record (ticket 220,
# ADR-0015, spec 6.2).
#
# Real host, real uids, real `useradd`: `GUARDEN_PREFIX=/` and the machine's own
# tools, as `t220-tendril` does. What is asserted is state — a record file with an
# absolute deadline, a rendered projection, a refused input — and never a record
# of what a program said it was about to do.
#
# **The vendor call cannot be exercised here**: it needs a real Cloudflare
# account, an account id, an application id and an API token, and the ticket marks
# the live path as an operator acceptance step. Nothing here fakes a vendor
# response (ADR-0014). What is assertable without one is the CLI seam, the local
# record and the projection logic, which is what this file is — and the projection
# is a **file**, so the union rule, the absolute deadline and the `session_duration`
# are read off bytes rather than off a call.
#
# machine: fresh

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GUARDEN_PREFIX=/

ensure_accounts

# The staging track's `expose` is `tunnel` (so its routes are tunnel routes and a
# grant may name them), production's is the default `edge` (so a grant against it
# is the refusal this file exists to assert), and `[share] max` is two days so an
# over-maximum `--until` is refused without waiting a week for it.
cat >"$GUARDEN_PREFIX/etc/guarden/guarden.toml" <<'TOML'
[host]
domain = "example.com"
interface = ""
admin_user = "operator"

[ingress]
alias = "192.0.2.1"
tunnel_domain = "tunnel.example.net"
publication_range = [20000, 32767]

[network]
backend = "pasta"
pasta_options = [ "--map-gw" ]

[build]
lanes = 1

[share]
max = "2d"
account = ""
app = ""

[modules]
enabled = []

[[environments]]
name = "production"
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
free_limit = "0.20"
keep_last = 0
kind = "slot"
fork_from = "production"
expose = "tunnel"

[[environments]]
name = "preview"
host_prefix = "preview."
gated = false
weight = 10
free_limit = "0.20"
keep_last = 0
kind = "instance"
fork_from = "staging"
cap = 3
TOML

stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_not_rejected
run soil storage --apply
assert_not_rejected

# The issuance store is guarden's, `root:guarden 0750` like the registry: it
# describes who may reach what and only the mutator writes it.
assert_mode /var/lib/guarden/share 0750
assert_owner /var/lib/guarden/share root:guarden

run weedr module add cloudflared
assert_exit 0
run weedr module add traefik
assert_exit 0

stage_poke routed 9f2c1ab
run weedr service ingest routed-staging --from poke routed@9f2c1ab
assert_exit 0
run weedr service ingest routed-production --from poke routed@9f2c1ab
assert_exit 0

store=/var/lib/guarden/share

# `--until` is **required**: there is no spelling of "never", because a grant
# that cannot be time-bounded is a grant whose expiry is somebody's memory.
run weedr share issue routed-staging alice@example.com
assert_exit 2
assert_stderr_has "--until"

# A value that is not a duration names the grammar, not a missing unit.
run weedr share issue routed-staging alice@example.com --until never
assert_exit 2
assert_stderr_has "not a duration"

# A value above the root-owned maximum is refused naming the maximum, so an
# operator is told which value to change rather than that a number was too big.
run weedr share issue routed-staging alice@example.com --until 3d
assert_exit 2
assert_stderr_has "48h"
assert_stderr_has "maximum"

# **A route whose destination is `edge` is refused, naming the route and its
# destination.** The edge is public already; a grant against it would be a second,
# invisible way in. There is no `--via tunnel` flag: which terminator carries a
# route is configuration, and a flag that chose it would be a second place.
run weedr share issue routed-production alice@example.com --until 1d
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "web"
assert_stderr_has "edge"

# An email that is not one is refused before anything is written.
run weedr share issue routed-staging not-an-address --until 1d
assert_exit 2
assert_stderr_has "email"

# A service with no registry entry is the host, not a rejected input.
run weedr share issue nosuch-production alice@example.com --until 1d
assert_exit 1

# Nothing above wrote a record: a grant that exists locally and not at the vendor
# is a grant an operator believes is closed and is not, so the refusals happen
# before the first byte.
[ "$(ls -A "$store" 2>/dev/null | grep -c '\.toml$' || true)" = 0 ] \
    || _fail "a refused share issue wrote a record"

run weedr share issue routed-staging alice@example.com --until 2d
assert_exit 0
assert_stdout_has "issued"
first=$(sed -n 's/^issued \([0-9a-f]*\) .*/\1/p' "$GUARDEN_STDOUT")
[ -n "$first" ] || _fail "the issue printed no id"
record="$store/$first.toml"
assert_file_exists "$record"

# **The stored value is an absolute deadline, not a duration.** A root-owned wall
# clock that can move backwards must not be able to extend a grant, so what is
# written is the moment it ends.
assert_file_has "$record" 'deadline = "'
assert_file_has "$record" 'email = "alice@example.com"'
assert_file_has "$record" 'hosts = ["staging.web"]'
assert_file_lacks "$record" "duration"
assert_file_lacks "$record" "never"

run weedr share list
assert_exit 0
assert_stdout_has "$first"
assert_stdout_has "live"
assert_stdout_has "alice@example.com"
run weedr share list --json
assert_exit 0
assert_stdout_lines 1
assert_json issuances.0.id "\"$first\""
assert_json issuances.0.state '"live"'
assert_json issuances.0.hosts.0 '"staging.web"'
assert_json issuances.0.revoked null

# A second email on the same hostname. The union of the live issuances is one
# `Allow` policy per hostname, so the projection holds both and the hostname
# appears once.
run weedr share issue routed-staging bob@example.com --until 2d
assert_exit 0
second=$(sed -n 's/^issued \([0-9a-f]*\) .*/\1/p' "$GUARDEN_STDOUT")
[ -n "$second" ] || _fail "the second issue printed no id"

# With no account and no token the vendor call cannot happen, and the reconciler
# says so and **changes nothing local**: the projection is written, the applied
# digest is not, and a `warning:` names the missing account.
run weedr share reconcile
assert_exit 0
assert_stderr_has "warning:"
assert_stderr_has "share.account"
projection="$store/projection.json"
assert_file_exists "$projection"
run cat "$projection"
assert_exit 0
assert_json policies.0.hostname '"staging.web"'
assert_json policies.0.decision '"allow"'
assert_json policies.0.include_emails.0 '"alice@example.com"'
assert_json policies.0.include_emails.1 '"bob@example.com"'
assert_json policies.0.require_login_methods.0 '"one_time_pin"'
# `session_duration` is the root-owned maximum in the vendor's Go syntax: two
# days is `48h`, never `2d`, because the vendor has no `d`.
assert_json policies.0.session_duration '"48h"'

# The projection is a function of the record and the clock is not an input to it,
# so rendering the same record twice gives the same bytes — which is what makes
# the vendor call skippable once a token is present, and what "idempotent" means
# for a reconciler whose desired state is a document.
cp "$projection" "$GUARDEN_FIXTURES/projection-first.json"
run weedr share reconcile
assert_exit 0
run cmp -s "$projection" "$GUARDEN_FIXTURES/projection-first.json"
assert_exit 0

# **An unreadable record is exit `1` and the projection is left exactly where it
# was.** A reconciler that cannot read its own state must never render an empty
# projection, because an empty projection is what removes every address. The
# record is emptied — the shape a hand edit leaves — and the projection on disk
# must be byte-identical afterwards.
cp "$projection" "$GUARDEN_FIXTURES/projection-before.json"
: >"$record"
run weedr share reconcile
assert_exit 1
assert_stderr_has "issuance record"
run cmp -s "$projection" "$GUARDEN_FIXTURES/projection-before.json"
assert_exit 0

# The store is emptied first, so what the projection holds below is a function of
# the two issuances this phase makes and of nothing an earlier phase left behind.
rm -f "$store"/*.toml
run weedr share issue routed-staging alice@example.com --until 2d
assert_exit 0
third=$(sed -n 's/^issued \([0-9a-f]*\) .*/\1/p' "$GUARDEN_STDOUT")
run weedr share issue routed-staging bob@example.com --until 2d
assert_exit 0

run weedr share revoke "$third"
assert_exit 0
assert_stdout_has "revoked"
run weedr share list
assert_exit 0
assert_stdout_has "$third"
assert_stdout_has "revoked"
# The deadline is not rewritten by a revoke: a revoke ends a grant, it does not
# change when it would have ended, and the record keeps both facts.
assert_file_has "$store/$third.toml" 'revoked = "'
assert_file_has "$store/$third.toml" 'deadline = "'

# A second revoke of the same id is already true, and exit 0: a script that
# revokes defensively must not read that as having found something.
run weedr share revoke "$third"
assert_exit 0
assert_stdout_has "already revoked"

# An id that names no issuance is the host not being in the assumed state.
run weedr share revoke deadbeefdeadbeef
assert_exit 1

# **A revoked issuance is not in the projection**, and the other live one still
# is: the record keeps the revoked one so "who could see this" is answerable, and
# the projection is a function of who can reach it now.
run weedr share reconcile
assert_exit 0
run cat "$projection"
assert_exit 0
assert_json policies.0.include_emails.0 '"bob@example.com"'
assert_json_missing policies.0.include_emails.1

# A one-second grant is the only way to observe an expiry without a fake clock:
# it is a real issuance with a real absolute deadline, and after it passes the
# reconciler must drop the address from the projection.
run weedr share issue routed-staging carol@example.com --until 1s
assert_exit 0
sleep 2
run weedr share list
assert_exit 0
assert_stdout_has "carol@example.com"
assert_stdout_has "expired"
run weedr share reconcile
assert_exit 0
run cat "$projection"
assert_exit 0
assert_stdout_lacks "carol@example.com"
assert_stdout_has "bob@example.com"

# The reconciler is what enforces an expiry, so it runs on a root-owned timer —
# and only on a host that has the tunnel module, because a grant names a tunnel
# route and a host with no tunnel has no such route. The units are installed by
# the `units` phase, which is where the file appears.
run soil units --apply
assert_not_rejected
assert_file_exists /etc/systemd/system/guarden-share-reconcile.service
assert_file_has /etc/systemd/system/guarden-share-reconcile.service \
    "ExecStart=/usr/lib/guarden/bin/weedr share reconcile"
assert_enabled guarden-share-reconcile.timer

# The sudoers rule is unchanged by this ticket, and that is the whole reason a
# customer-facing grant is safe to have: a poke can deploy to a preview and
# cannot mint, extend or revoke access to one. `hose` names no share verb at all,
# and its only route to the mutator is through `furrow`.
run hose --help
assert_exit 0
assert_stdout_lacks "share"
run weedr --help
assert_exit 0
assert_stdout_has "weedr share"
assert_stdout_has "every \`weedr share\`"
