#!/usr/bin/env bash
# 00-ssh.conf: root-owned SSH accept rule, seed-once, verified at apply time.
# The operator has decided: SSH access must be guaranteed structurally,
# not by convention. A bad render now means you cannot fix it from outside,
# because fixing it requires the access it just removed.

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GUARDEN_PREFIX=/

# This test needs real identity and real iptables -- it runs against the machine
# because 00-ssh.conf is a structural guarantee that must be verified on a real host.
# machine: fresh

# Preconditions: the machine must have the guarden group and users, and the
# apt timers disabled (soil packages does this, but this suite drives firewall
# without the packages phase).
getent group guarden >/dev/null 2>&1 || groupadd --system guarden
id -u guarden >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin --gid guarden guarden
getent group operator >/dev/null 2>&1 || groupadd --system operator
id -u operator >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin --gid operator operator

for timer in apt-daily.timer apt-daily-upgrade.timer dpkg-db-backup.timer; do
    systemctl disable --now "$timer" >/dev/null 2>&1 || :
done
assert_not_enabled apt-daily.timer
assert_not_enabled apt-daily-upgrade.timer
assert_not_enabled dpkg-db-backup.timer

stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_not_rejected

                                                                                 
run soil firewall --check
assert_exit 1
assert_stderr_has "drift: 00-ssh.conf exists and is mode 0600 root:root"

                                                                               
run soil firewall --apply
assert_exit 0

                                                
assert_file_exists /etc/guarden/firewall/00-ssh.conf
assert_mode /etc/guarden/firewall/00-ssh.conf 0600
assert_owner /etc/guarden/firewall/00-ssh.conf root:root

# 00-ssh.conf content: guarden-ssh chain with proto tcp dport 22 jump ACCEPT as first rule
assert_file_has /etc/guarden/firewall/00-ssh.conf "chain guarden-ssh {"
assert_file_has /etc/guarden/firewall/00-ssh.conf "proto tcp dport 22 jump ACCEPT;"

# 10-framework.conf INPUT chain has 'jump guarden-ssh' as first rule after conntrack+lo
assert_file_has /etc/guarden/firewall/10-framework.conf "chain INPUT {"
# The first non-comment rule in INPUT should be conntrack, then lo, then jump guarden-ssh
input_rules=$(grep -vE '^[[:space:]]*(#|$)' /etc/guarden/firewall/10-framework.conf | sed -n '/chain INPUT {/,/^}/p' | grep -vE '^(chain INPUT {|})$')
# Check that the order is: conntrack, lo, guarden-ssh
echo "$input_rules" | head -1 | grep -q "mod conntrack ctstate" || _fail "first rule in INPUT is not conntrack"
echo "$input_rules" | sed -n '2p' | grep -q "if lo" || _fail "second rule in INPUT is not 'if lo'"
echo "$input_rules" | sed -n '3p' | grep -q "jump guarden-ssh;" || _fail "third rule in INPUT is not 'jump guarden-ssh;'"

                                                       
ssh_rules=$(grep -vE '^[[:space:]]*(#|$)' /etc/guarden/firewall/00-ssh.conf | sed -n '/chain guarden-ssh {/,/^}/p' | grep -vE '^(chain guarden-ssh {|})$')
first_ssh_rule=$(echo "$ssh_rules" | head -1 | xargs)
[ "$first_ssh_rule" = "proto tcp dport 22 jump ACCEPT;" ] || _fail "first rule in guarden-ssh is '$first_ssh_rule', expected 'proto tcp dport 22 jump ACCEPT;'"

                                                                               
                                                                   
sed -i 's/proto tcp dport 22 jump/proto tcp dport 2222 jump/' /etc/guarden/firewall/00-ssh.conf
cat /etc/guarden/firewall/00-ssh.conf
assert_file_has /etc/guarden/firewall/00-ssh.conf "dport 2222"
                                                                                                   
grep -vE '^[[:space:]]*(#|;)' /etc/guarden/firewall/00-ssh.conf | grep -q "proto tcp dport 22 jump" && _fail "/etc/guarden/firewall/00-ssh.conf names dport 22 and should not"

# Re-run soil install --apply (which runs firewall phase)
run soil firewall --apply
assert_exit 0

# The edit must survive
assert_file_has /etc/guarden/firewall/00-ssh.conf "dport 2222"
                                                             
grep -vE '^[[:space:]]*(#|;)' /etc/guarden/firewall/00-ssh.conf | grep -q "proto tcp dport 22 jump" && _fail "/etc/guarden/firewall/00-ssh.conf names dport 22 and should not"

# Change it back for the negative tests
sed -i 's/proto tcp dport 2222 jump/proto tcp dport 22 jump/' /etc/guarden/firewall/00-ssh.conf

                                                                               
                                                                    
cat > /etc/guarden/firewall/00-ssh.conf <<'EOF'
# Written by soil firewall. The SSH accept chain, separate from the
# framework so the operator can edit the port without it being overwritten.
#
# This file is SEED-ONCE: soil install writes it only if absent. It must
# NEVER overwrite an existing file, because the operator may have edited
# the port to a non-standard one. Re-running soil install must not wipe
# that edit.
#
# Mode 0600, owner root:root. ferm loads it as root, and
# firewall.installed() reads every root-owned *.conf, this one included
# (8c78126). It is deliberately tighter than every other config file in
# the tree (which are root:guarden 0640). 0600 is an existing convention
# here -- see credentials.py BLOB_MODE.

table filter
chain guarden-ssh {
    # A DROP rule before the accept - this should make verification fail
    proto tcp dport 80 jump DROP;
    proto tcp dport 22 jump ACCEPT;
}
EOF
chmod 0600 /etc/guarden/firewall/00-ssh.conf
chown root:root /etc/guarden/firewall/00-ssh.conf

                                   
run soil firewall --apply
assert_exit 1
assert_stderr_has "apply-time verification failed"

# Nothing should have been installed (the old ruleset should remain)
# Check that 10-framework.conf wasn't updated
assert_file_has /etc/guarden/firewall/10-framework.conf "jump guarden-ssh;"

                             
cat > /etc/guarden/firewall/00-ssh.conf <<'EOF'
# Written by soil firewall. The SSH accept chain, separate from the
# framework so the operator can edit the port without it being overwritten.
#
# This file is SEED-ONCE: soil install writes it only if absent. It must
# NEVER overwrite an existing file, because the operator may have edited
# the port to a non-standard one. Re-running soil install must not wipe
# that edit.
#
# Mode 0600, owner root:root. ferm loads it as root, and
# firewall.installed() reads every root-owned *.conf, this one included
# (8c78126). It is deliberately tighter than every other config file in
# the tree (which are root:guarden 0640). 0600 is an existing convention
# here -- see credentials.py BLOB_MODE.

table filter
chain guarden-ssh {
    proto tcp dport 22 jump ACCEPT;
}
EOF
chmod 0600 /etc/guarden/firewall/00-ssh.conf
chown root:root /etc/guarden/firewall/00-ssh.conf

run soil firewall --apply
assert_exit 0

                                                                               
chown operator:operator /etc/guarden/firewall/00-ssh.conf

run soil firewall --apply
assert_exit 1
assert_stderr_has "apply-time verification failed"

# Restore ownership
chown root:root /etc/guarden/firewall/00-ssh.conf

run soil firewall --apply
assert_exit 0

                                                                               
chmod 0644 /etc/guarden/firewall/00-ssh.conf

run soil firewall --apply
assert_exit 1
assert_stderr_has "apply-time verification failed"

# Restore mode
chmod 0600 /etc/guarden/firewall/00-ssh.conf

run soil firewall --apply
assert_exit 0

                                                                               
rm -f /etc/guarden/firewall/00-ssh.conf

run soil firewall --apply
assert_exit 1
assert_stderr_has "apply-time verification failed"

                                                                               
                            
assert_active guarden-firewall.service

                                                   
run iptables-legacy -S guarden-ssh
assert_exit 0
assert_stdout_has "22"
assert_stdout_has "ACCEPT"

run iptables-legacy -S INPUT
assert_exit 0
# The first rule after conntrack+lo should be guarden-ssh
# We can't easily check order in iptables output, but we verified the file

# --- the machine is left converged -------------------------------------------
# files in place, and no lockout failsafe to stop because there is none --
# the SSH chain is the protection and it is structural.
assert_file_missing /etc/systemd/system/guarden-firewall-deadman.timer
assert_file_missing /etc/systemd/system/guarden-firewall-deadman.service