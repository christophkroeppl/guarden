#!/usr/bin/env bash
# Record which iptables table the firewall rules go in, before any phase runs.
#
# Tracked here and inlined into the cloud-init document by the renderer.
#
# `soil firewall` converges the variant the package list names and refuses to
# report a converged firewall whose rules the host's own `iptables` cannot read,
# but a machine booting into the two halves disagreeing should say so here, where
# nothing has been converged on top of it yet.
#
# Both halves are recorded, and separately on purpose: `update-alternatives`
# records which variant `/usr/sbin/iptables` NAMES, while ferm resolves its own
# binary when loading a policy and prefers the `-legacy` names. The two can
# disagree on a healthy host, and on the golden they did — which is the whole of
# docs/notes/iptables-variant-must-be-stated.md.
set -eu

vf=/var/lib/guarden-evidence
echo "iptables name:   $(iptables --version 2>/dev/null || echo MISSING)" >>"$vf/substrate.txt"
ferm --shell /dev/null >"$vf/.ferm-sh" 2>&1 || true
echo "ferm would load: $(head -1 "$vf/.ferm-sh" | cut -d' ' -f1)" >>"$vf/substrate.txt"
echo "alternatives:    $(iptables --version | sed 's/.*(//;s/)//')" >>"$vf/substrate.txt"
iptables-legacy-save -t filter >"$vf/.legacy" 2>/dev/null || true
echo "legacy chains:   $(grep -c '^-N' "$vf/.legacy")" >>"$vf/substrate.txt"
nft list tables >"$vf/.nft" 2>/dev/null || true
echo "nft tables:      $(wc -w <"$vf/.nft")" >>"$vf/substrate.txt"
rm -f "$vf/.ferm-sh" "$vf/.legacy" "$vf/.nft"
tail -5 "$vf/substrate.txt"
