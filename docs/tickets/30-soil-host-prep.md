# 30: soil: host prep (users, firewall, sysctl)

**What to build:** A fresh Ubuntu becomes a host that can run rootless beds and a fence proxy. An operator runs `soil <phase> --check` to see drift and `soil <phase> --apply` to converge users, firewall, and sysctl; the same commands run on the golden VM with real tools.

**Blocked by:** T10 (Skeleton + CLI seam harness)

**Status:** ready-for-agent

- [ ] `soil users --check` / `--apply` converges the shared-tier users and groups (`roots`, `stakes`, `twig`, `hose`) and the `fence` group; `traefik` is the fence bed `bed-fence-traefik`, created later (ticket 120), not a shared-tier user
- [x] `soil users` creates no shared `pond` user — pond users are created by `weedr pond dig` (ADR-0002)
- [x] `soil firewall --check` / `--apply` disables the preinstalled firewall (ufw) and installs and configures ferm + fail2ban
- [x] `soil sysctl --check` / `--apply` sets `net.ipv4.ip_unprivileged_port_start=0` so Traefik can bind :80/:443 without root
- [x] `--check` reports drift without changing the host and exits non-zero when drift exists
- [x] `--apply` is idempotent: a second `--apply` reports no drift
- [x] Anything root executes is installed root-owned so root never runs deploy-writable code
- [ ] The fast harness verifies these phases against fakes; the golden VM runs them with real tools
- [x] A lockout drill exists: a dead-man timer restores firewall access if the operator is cut off
