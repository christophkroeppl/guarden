#!/usr/bin/env bash
# TEMPORARY probe: the decisive measurement for ticket 303.
#
# Every command's exit code is captured with `rc=0; cmd || rc=$?` — the house
# idiom from tests/lib.sh's `_capture` — because `set -e` kills the suite on a
# failing command and a suite that dies on the first failure measures nothing.

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

probe() {
    local label=$1
    shift
    local rc=0
    "$@" >/dev/null 2>&1 || rc=$?
    printf 'PROBE %s exit=%s\n' "$label" "$rc"
}

echo "PROBE_BEFORE_FIREWALL"
probe BEFORE_ROOT_GETENT getent hosts github.com
probe BEFORE_APT_UPDATE apt-get update -o Acquire::Retries=0
probe BEFORE_ROOT_CURL curl -s -o /dev/null --max-time 20 https://github.com

run soil firewall --apply
assert_not_rejected
run systemctl start guarden-firewall.service
assert_exit 0
wait_settled guarden-firewall.service

echo "PROBE_AFTER_FIREWALL"
before=$(deny_packets)
probe AFTER_ROOT_GETENT getent hosts github.com
after=$(deny_packets)
echo "PROBE AFTER_ROOT_DENY_COUNTER=$before->$after"

probe AFTER_APT_UPDATE apt-get update -o Acquire::Retries=0
probe AFTER_ROOT_CURL curl -s -o /dev/null --max-time 20 https://github.com
probe AFTER_ROOT_RESOLVECTL resolvectl query github.com

echo "PROBE_APT_OUTPUT"
apt-get update -o Acquire::Retries=0 2>&1 | tail -3

svc_home=/var/lib/guarden/services/shelf-staging/home
before_svc=$(deny_packets)
rc=0
run_in "$svc_home" setpriv --reuid=shelf-staging --regid=shelf-staging \
    --clear-groups env -u OLDPWD HOME="$svc_home" PWD="$svc_home" \
    getent hosts github.com >/dev/null 2>&1 || rc=$?
echo "PROBE AFTER_SERVICE_GETENT exit=$rc"
after_svc=$(deny_packets)
echo "PROBE AFTER_SERVICE_DENY_COUNTER=$before_svc->$after_svc"

echo "PROBE_WITH_ROOT_ACCEPT"
cp /etc/guarden/firewall/50-services.conf "$GUARDEN_FIXTURES/50.bak"
sed -i 's|^    mod owner uid-owner 0 daddr 127.0.0.1 proto tcp jump ACCEPT;$|&\n    mod owner uid-owner 0 daddr 127.0.0.53 proto udp dport 53 jump ACCEPT;\n    mod owner uid-owner 0 daddr 127.0.0.53 proto tcp dport 53 jump ACCEPT;|' \
    /etc/guarden/firewall/50-services.conf
run systemctl restart guarden-firewall.service
assert_exit 0
wait_settled guarden-firewall.service
before_acc=$(deny_packets)
probe WITH_ROOT_GETENT getent hosts github.com
after_acc=$(deny_packets)
echo "PROBE WITH_ROOT_DENY_COUNTER=$before_acc->$after_acc"
probe WITH_APT_UPDATE apt-get update -o Acquire::Retries=0

cp "$GUARDEN_FIXTURES/50.bak" /etc/guarden/firewall/50-services.conf
run systemctl restart guarden-firewall.service
assert_exit 0
wait_settled guarden-firewall.service
echo "PROBE_DONE"
