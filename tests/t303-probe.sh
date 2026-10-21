#!/usr/bin/env bash
# TEMPORARY probe: dump the enforced guarden-svc chain. Deleted after use.

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GUARDEN_PREFIX=/

conf=/etc/guarden/firewall/50-services.conf

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

echo "PROBE_BEGIN_RENDERED"
cat "$conf"
echo "PROBE_END_RENDERED"
echo "PROBE_BEGIN_ENFORCED"
iptables-legacy -S guarden-svc
echo "PROBE_END_ENFORCED"
echo "PROBE_BEGIN_SS"
ss -lun | grep 53
echo "PROBE_END_SS"
echo "PROBE_DONE"
