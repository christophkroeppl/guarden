# Ferm firewall rules

[Ferm](https://ferm.foo-projects.org/) (Firewall Easy Rule Maker) is a tool that reads a config file and generates iptables/nftables rules. We use it to manage the host firewall on the Ubuntu VPS so that:

- Incoming traffic is restricted by default (DROP).
- Only SSH, ICMP, and specific Docker-published ports are allowed.
- Docker’s own chains are preserved; we only add rules in `DOCKER-USER`.

## How it works

1. **ferm.conf** – Main entry. Sets default policies (INPUT DROP, OUTPUT ACCEPT), allows loopback and established connections, and includes all files under `ferm.d/`.
2. **ferm.d/** – Rule files are loaded in lexicographic order. We use numbered prefixes so the order is clear.

When you run `ferm /etc/ferm/ferm.conf`, ferm rewrites the firewall from scratch according to these files. Anything not mentioned (and not preserved) is removed.

## Our rule files

| File | Purpose |
|------|--------|
| **00-docker.ferm** | Preserve Docker’s filter/nat chains and the fail2ban chain `f2b-sshd`. We don’t manage those ourselves. |
| **10-in.ssh.ferm** | INPUT: send SSH to fail2ban’s chain (banned IPs dropped), then accept SSH. |
| **30-in.docker.public-ports.ferm** | DOCKER-USER: allow new connections from WAN (venet0) to the edge network on ports 80 and 443 (Traefik). |
| **50-in.docker.bitcoin-public-ports.ferm** | DOCKER-USER: allow Bitcoin ports 8332 and 8333 to the edge network. |
| **99-docker.ferm** | DOCKER-USER: for venet0 → docker_edge, allow established/related, drop all other new traffic. |

## Interfaces and networks

- **venet0** – WAN interface (incoming internet). On some hosts this may be `eth0`; the install script replaces `venet0` with `eth0` in the rules if `eth0` exists.
- **docker_edge** – Bridge for the “edge” Docker network. Traffic to Traefik and the Bitcoin node is forwarded to this interface.

Traffic path: internet → venet0 → (ferm allows 80/443 and 8332/8333 to docker_edge) → Docker forwards to the container.

## Fail2ban

Host fail2ban (sshd jail) adds and removes rules in the `f2b-sshd` chain. We preserve that chain in 00-docker.ferm and jump to it from INPUT in 10-in.ssh.ferm so SSH is checked before being accepted. Do not remove the preserve or the jump, or fail2ban bans will stop working after the next ferm reload.

## Deployment

The install script copies only `ferm.conf` and `ferm.d/` to `/etc/ferm/` (this README is not installed). After editing, reload with:

```bash
sudo ferm /etc/ferm/ferm.conf
```

Test without applying:

```bash
sudo ferm --noexec /etc/ferm/ferm.conf
```
