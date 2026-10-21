#!/usr/bin/env bash
# TEMPORARY probe: the decisive measurement for ticket 303.
#
# The question the adversarial review raised: on a CONVERGED host, is root's
# name resolution broken, and what exactly is broken?
#
# The suite must NOT die on a failing command, so every command is run with
# `|| true` and its exit code printed.

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GUARDEN_PREFIX=/

ensure_accounts
stage_config guarden-nomodules.toml
stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_not_rejected

stage_poke shelf 9f2c1ab
run weedr service ingest shelf-staging --from poke shelf@9f2c1ab
assert_exit 0

deny_packets() {
    iptables-legacy -nvx -L guarden-svc 2>/dev/null \
        | awk '$3 == "DROP" && $NF ~ /^127\.0\.0\.0\/8/ {print $1; exit}'
}

# --- BEFORE the firewall: does this box have working DNS at all? ------------
echo "PROBE_BEFORE_FIREWALL"
getent hosts github.com >/dev/null 2>&1
echo "PROBE_BEFORE_ROOT_GETENT_EXIT=$?"
apt-get update -o Acquire::Retries=0 >/dev/null 2>&1
echo "PROBE_BEFORE_APT_EXIT=$?"

# --- the host converges, and the deny is in force ---------------------------
run soil firewall --apply
assert_not_rejected
run systemctl start guarden-firewall.service
assert_exit 0
wait_settled guarden-firewall.service

echo "PROBE_AFTER_FIREWALL"
before=$(deny_packets)
getent hosts github.com >/dev/null 2>&1
echo "PROBE_AFTER_ROOT_GETENT_EXIT=$?"
after=$(deny_packets)
echo "PROBE_AFTER_ROOT_DENY_COUNTER=$before->$after"

# apt-get update as root, on the converged host: the sharpest consequence.
apt-get update -o Acquire::Retries=0 >/dev/null 2>&1
echo "PROBE_AFTER_APT_EXIT=$?"
apt-get update -o Acquire::Retries=0 2>&1 | tail -4

# curl as root, to a NAME.
curl -s -o /dev/null --max-time 15 https://github.com >/dev/null 2>&1
echo "PROBE_AFTER_ROOT_CURL_EXIT=$?"

# resolvectl as root: D-Bus, not loopback.
resolvectl query github.com >/dev/null 2>&1
echo "PROBE_AFTER_ROOT_RESOLVECTL_EXIT=$?"

# The SERVICE uid, same name, same moment: the control.
svc_home=/var/lib/guarden/services/shelf-staging/home
before_svc=$(deny_packets)
run_in "$svc_home" setpriv --reuid=shelf-staging --regid=shelf-staging \
    --clear-groups env -u OLDPWD HOME="$svc_home" PWD="$svc_home" \
    getent hosts github.com >/dev/null 2>&1
echo "PROBE_AFTER_SERVICE_GETENT_EXIT=$?"
after_svc=$(deny_packets)
echo "PROBE_AFTER_SERVICE_DENY_COUNTER=$before_svc->$after_svc"

# --- WITH the uid-0 resolver accept added by hand: the other answer -------
echo "PROBE_WITH_ROOT_ACCEPT"
cp /etc/guarden/firewall/50-services.conf "$GUARDEN_FIXTURES/50.bak"
sed -i 's|^    mod owner uid-owner 0 daddr 127.0.0.1 proto tcp jump ACCEPT;$|&\n    mod owner uid-owner 0 daddr 127.0.0.53 proto udp dport 53 jump ACCEPT;\n    mod owner uid-owner 0 daddr 127.0.0.53 proto tcp dport 53 jump ACCEPT;|' \
    /etc/guarden/firewall/50-services.conf
run systemctl restart guarden-firewall.service
assert_exit 0
wait_settled guarden-firewall.service
before_acc=$(deny_packets)
getent hosts github.com >/dev/null 2>&1
echo "PROBE_WITH_ROOT_GETENT_EXIT=$?"
after_acc=$(deny_packets)
echo "PROBE_WITH_ROOT_DENY_COUNTER=$before_acc->$after_acc"
apt-get update -o Acquire::Retries=0 >/dev/null 2>&1
echo "PROBE_WITH_ROOT_APT_EXIT=$?"

cp "$GUARDEN_FIXTURES/50.bak" /etc/guarden/firewall/50-services.conf
run systemctl restart guarden-firewall.service
assert_exit 0
wait_settled guarden-firewall.service
echo "PROBE_DONE"
