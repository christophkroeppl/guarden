#!/usr/bin/env bash
# TEMPORARY probe: does root resolve names on a CONVERGED host?
# The decisive measurement for ticket 303. Deleted after use.

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

run soil firewall --apply
assert_not_rejected
run systemctl start guarden-firewall.service
assert_exit 0
wait_settled guarden-firewall.service

echo "PROBE_BEGIN_RESOLVCONF"
cat /etc/resolv.conf
echo "PROBE_END_RESOLVCONF"
echo "PROBE_BEGIN_STUBRESOLV"
cat /run/systemd/resolve/stub-resolv.conf 2>&1
echo "PROBE_END_STUBRESOLV"

echo "PROBE_BEGIN_ROOT_GETENT"
getent hosts github.com
echo "PROBE_ROOT_GETENT_EXIT=$?"
echo "PROBE_END_ROOT_GETENT"

echo "PROBE_BEGIN_ROOT_CURL"
curl -s -o /dev/null -w 'HTTP=%{http_code}\n' --max-time 20 https://github.com
echo "PROBE_ROOT_CURL_EXIT=$?"
echo "PROBE_END_ROOT_CURL"

echo "PROBE_BEGIN_ROOT_APT_UPDATE"
apt-get update -o Acquire::Retries=0
echo "PROBE_ROOT_APT_EXIT=$?"
echo "PROBE_END_ROOT_APT_UPDATE"

echo "PROBE_BEGIN_ROOT_RESOLVECTL"
resolvectl query github.com 2>&1 | head -5
echo "PROBE_ROOT_RESOLVECTL_EXIT=$?"
echo "PROBE_END_ROOT_RESOLVECTL"

echo "PROBE_BEGIN_SERVICE_GETENT"
svc_home=/var/lib/guarden/services/shelf-staging/home
run_in "$svc_home" setpriv --reuid=shelf-staging --regid=shelf-staging \
    --clear-groups env -u OLDPWD HOME="$svc_home" PWD="$svc_home" \
    getent hosts github.com
echo "PROBE_SERVICE_GETENT_EXIT=$?"
echo "PROBE_END_SERVICE_GETENT"

echo "PROBE_BEGIN_DNSMASQ"
grep -E '^nameserver' /etc/resolv.conf
echo "PROBE_END_DNSMASQ"
echo "PROBE_DONE"
