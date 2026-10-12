#!/usr/bin/env bash
# The structural SSH guarantee still holds, and a tunnel grant cannot disable it.
#
# This test verifies that after `weedr share issue` grants a customer a time-bounded
# tunnel route, the SSH guarantee remains intact:
# 1. 00-ssh.conf is still 0600 root:root — unchanged.
# 2. The accept is still the first rule of guarden-ssh, and the INPUT jump is still first.
# 3. soil firewall --apply --check still reports no drift on the SSH items.
# 4. The tunnel's own effect is the share projection, not a firewall rule: `weedr share
#    reconcile` writes /var/lib/guarden/share/projection.json and touches no firewall file
#    (measured: `grep -c firewall src/guarden/share.py` is 0). So what is asserted is that
#    the grant appears in that projection and the revoke takes it away, while the SSH chain
#    is left exactly as it was.
#
# Real host, real uids, real `useradd`: GUARDEN_PREFIX=/ and the machine's own
# tools. What is asserted is state — a file, a rule position, an unchanged file —
# and never a record of what a program said it was about to do.
#
# machine: fresh

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GUARDEN_PREFIX=/

ensure_accounts

# Configuration with the tunnel module enabled and share.max set
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
enabled = ["cloudflared", "gate-traefik"]

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

run weedr module add cloudflared
assert_exit 0
run weedr module add gate-traefik
assert_exit 0

# Ingest a service with a tunnel route (staging track has expose=tunnel)
stage_poke routed 9f2c1ab
run weedr service ingest routed-staging --from poke routed@9f2c1ab
assert_exit 0

# Converge the firewall to create 00-ssh.conf and verify the structural guarantee
run soil firewall --apply
assert_exit 0

# The SSH guarantee is already verified by t150-ssh-accept.sh:
# - 00-ssh.conf exists, is 0600 root:root
# - Its accept is first in guarden-ssh chain
# - INPUT's first rule after conntrack+lo is jump guarden-ssh
# - soil firewall --apply refuses unless all hold

# Verify the pre-grant state (the structural guarantee holds)
ssh_conf="/etc/guarden/firewall/00-ssh.conf"
assert_file_exists "$ssh_conf"
assert_mode "$ssh_conf" 0600
assert_owner "$ssh_conf" root:root

ssh_rules=$(grep -vE '^[[:space:]]*(#|;)' "$ssh_conf" | sed -n '/chain guarden-ssh {/,/^}/p' | grep -vE '^(chain guarden-ssh {|})$')
first_ssh_rule=$(echo "$ssh_rules" | head -1 | xargs)
[ "$first_ssh_rule" = "proto tcp dport 22 jump ACCEPT;" ] || _fail "first rule in guarden-ssh is '$first_ssh_rule', expected 'proto tcp dport 22 jump ACCEPT;'"

framework="/etc/guarden/firewall/10-framework.conf"
input_rules=$(grep -vE '^[[:space:]]*(#|$)' "$framework" | sed -n '/chain INPUT {/,/^}/p' | grep -vE '^(chain INPUT {|})$')
echo "$input_rules" | head -1 | grep -q "mod conntrack ctstate" || _fail "first rule in INPUT is not conntrack"
echo "$input_rules" | sed -n '2p' | grep -q "if lo" || _fail "second rule in INPUT is not 'if lo'"
echo "$input_rules" | sed -n '3p' | grep -q "jump guarden-ssh;" || _fail "third rule in INPUT is not 'jump guarden-ssh;'"

# soil firewall --check must report no drift on SSH items
run soil firewall --check
assert_exit 0

# Now issue a tunnel grant (share)
# This creates a record in /var/lib/guarden/share/ and triggers the reconciler
run weedr share issue routed-staging alice@example.com --until 2d
assert_exit 0
assert_stdout_has "issued"
first=$(sed -n 's/^issued \([0-9a-f]*\) .*/\1/p' "$GUARDEN_STDOUT")
[ -n "$first" ] || _fail "the issue printed no id"

# Wait for the reconciler timer to fire (or run it manually to assert the state change)
# The share reconciler timer runs every 10 minutes; we run it manually to observe the state
run weedr share reconcile
assert_exit 0

# The grant's own effect, which the header used to describe as a firewall rule and
# is not one: the tunnel reads a projection, so that is what is asserted.
projection=/var/lib/guarden/share/projection.json
assert_file_exists "$projection"
assert_file_has "$projection" "alice@example.com"

# MUTATION TEST: break the SSH chain by inserting a rule before the accept
# This simulates what would happen if a grant path wrote to 00-ssh.conf
# Uncomment the next 4 lines to make the test fail (red):
# sed -i '/chain guarden-ssh {/a\    proto tcp dport 80 jump DROP;' "$ssh_conf"
# run soil firewall --apply
# assert_exit 1
# assert_stderr_has "apply-time verification failed"

# --- Assertion 1: 00-ssh.conf is still 0600 root:root ---
assert_mode "$ssh_conf" 0600
assert_owner "$ssh_conf" root:root

                                                                                              
ssh_rules=$(grep -vE '^[[:space:]]*(#|;)' "$ssh_conf" | sed -n '/chain guarden-ssh {/,/^}/p' | grep -vE '^(chain guarden-ssh {|})$')
first_ssh_rule=$(echo "$ssh_rules" | head -1 | xargs)
[ "$first_ssh_rule" = "proto tcp dport 22 jump ACCEPT;" ] || _fail "after grant: first rule in guarden-ssh is '$first_ssh_rule', expected 'proto tcp dport 22 jump ACCEPT;'"

input_rules=$(grep -vE '^[[:space:]]*(#|$)' "$framework" | sed -n '/chain INPUT {/,/^}/p' | grep -vE '^(chain INPUT {|})$')
echo "$input_rules" | head -1 | grep -q "mod conntrack ctstate" || _fail "after grant: first rule in INPUT is not conntrack"
echo "$input_rules" | sed -n '2p' | grep -q "if lo" || _fail "after grant: second rule in INPUT is not 'if lo'"
echo "$input_rules" | sed -n '3p' | grep -q "jump guarden-ssh;" || _fail "after grant: third rule in INPUT is not 'jump guarden-ssh;'"

                                                                                
run soil firewall --check
assert_exit 0
assert_stderr_lacks "00-ssh.conf"

                                                                                 
run weedr share revoke "$first"
assert_exit 0
assert_stdout_has "revoked"

# Run reconcile again to update the vendor policy
run weedr share reconcile
assert_exit 0

# And the revoke takes it out of the projection, which is the half the header
# claimed and nothing checked: without this the suite passes whether or not the
# revoke reached the projection at all.
assert_file_lacks "$projection" "alice@example.com"

# SSH guarantee must still hold exactly as before
assert_mode "$ssh_conf" 0600
assert_owner "$ssh_conf" root:root

ssh_rules=$(grep -vE '^[[:space:]]*(#|;)' "$ssh_conf" | sed -n '/chain guarden-ssh {/,/^}/p' | grep -vE '^(chain guarden-ssh {|})$')
first_ssh_rule=$(echo "$ssh_rules" | head -1 | xargs)
[ "$first_ssh_rule" = "proto tcp dport 22 jump ACCEPT;" ] || _fail "after revoke: first rule in guarden-ssh is '$first_ssh_rule', expected 'proto tcp dport 22 jump ACCEPT;'"

input_rules=$(grep -vE '^[[:space:]]*(#|$)' "$framework" | sed -n '/chain INPUT {/,/^}/p' | grep -vE '^(chain INPUT {|})$')
echo "$input_rules" | head -1 | grep -q "mod conntrack ctstate" || _fail "after revoke: first rule in INPUT is not conntrack"
echo "$input_rules" | sed -n '2p' | grep -q "if lo" || _fail "after revoke: second rule in INPUT is not 'if lo'"
echo "$input_rules" | sed -n '3p' | grep -q "jump guarden-ssh;" || _fail "after revoke: third rule in INPUT is not 'jump guarden-ssh;'"

run soil firewall --check
assert_exit 0
assert_stderr_lacks "00-ssh.conf"

# The machine is left converged: SSH guarantee intact, grant revoked, no drift.