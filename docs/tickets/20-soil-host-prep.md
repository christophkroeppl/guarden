# 20: soil — host prep

**What to build:** A fresh Ubuntu becomes a host that can run rootless services and one edge
that publishes public HTTP. `soil <phase> --check` reports drift and changes nothing; `--apply`
converges and is idempotent. `soil` creates no service identity.

**Blocked by:** 10 (harness and program skeletons)

**Status:** ready-for-agent

- [ ] `soil packages` **disables the distribution's own apt timers — `apt-daily`,
      `apt-daily-upgrade` and `dpkg-db-backup` — and installs no replacement**, on the same
      rule and with the same "not enabled is enough" answer that `soil storage` applies to
      `snapper-cleanup.timer`: a packaging timer running on its own schedule is another writer
      of the index this phase refreshes, and `apt-get` does not queue for a lock it cannot take.
      `storage` installs a oneshot because it has daily work of its own; `packages` has none,
      because nothing in guarden installs packages on a schedule. `unattended-upgrades.service`
      stays enabled — it is an operator's security decision, not this phase's
- [ ] `soil packages` installs the distribution packages: btrfs-progs, snapper, ferm, fail2ban,
      podman, and `python3-yaml` and `python3-jinja2`. **`ufw` is not installed** — it was
      removed from the package list (see 2026-10-08 revision). `ferm` is the only firewall on
      the box and no `ufw` rule is ever written, read or reconciled.
- [ ] **`podlet` is the one fetch from outside a distribution repository.** Its version and
      SHA256 are recorded in the repository and verified on install. That is deliberate, it is
      the only third-party binary, and it is the only exception to "distribution packages only"
- [ ] `soil sysctl` sets `net.ipv4.conf.<ingress-if>.route_localnet=1` on the ingress interface
      and persists it, and nowhere else. Without it the kernel drops packets DNATed to
      `127.0.0.1` that arrived on a non-loopback interface as martians. It is scoped to that one
      interface, never to `conf.all`
- [ ] **`soil sysctl` sets `net.ipv4.ip_unprivileged_port_start=1024` and owns that key.** No
      unprivileged process on the host may bind a port below 1024, and no process gains a
      capability to do so. Raising the threshold to the kernel default is a tightening and is
      what makes the invariant a fact; *lowering* it grants every unprivileged uid a privileged
      port and is refused. An earlier revision said guarden must not set it, which conflated the
      two acts. The public ports belong to the kernel and are forwarded to the edge, so there is
      no privileged-port exception in the system
- [ ] `soil sysctl` **disables IPv6 by default** and persists that, so every firewall rule
      guarden writes is IPv4 only. There is no ip6tables set to keep in step, and an operator
      who re-enables IPv6 is outside what the golden VM proved
- [ ] **`soil sysctl --check` reports the two host invariants guarden depends on and cannot
      enforce**, and `weedr service list` reports the same two: that IPv6 has been re-enabled,
      and that `net.ipv4.ip_unprivileged_port_start` is not `1024`. **`soil sysctl` sets that key
      to `1024` and owns it** — the check is against the invariant, not against the distribution's
      default, because an image shipping `0` satisfies the default and breaks the invariant
      guarden not setting that port threshold is a convention, and reporting it is what turns
      the convention into a checked fact. Both are reported and neither is corrected — guarden
      does not undo a sysctl an operator set on purpose — and either one puts the box outside
      this design
- [ ] `soil firewall` installs ferm and fail2ban and
      `guarden-firewall.service`, writes `00-ssh.conf` — the SSH accept rule, root:root 0600, seed-once,
      its own `guarden-ssh` chain with the accept as the first rule, and the INPUT jump as the first
      rule after conntrack and lo — writes `10-framework.conf`, writes `30-admin.conf` (optional),
      and **writes `20-ingress-nat.conf` — the edge's three forwarding rules, from the enabled
      modules' declared ingress.** It owns the
      framework, the SSH accept, the admin drop-in and the edge's forwarding; the mutator owns
      `50-services.conf` and any service's own forwarding. The files are disjoint and each is
      written by exactly one program
- [ ] **No `nat POSTROUTING` rule is emitted, and that is the correct output rather than a
      missing one.** A `PREROUTING` DNAT to `127.0.0.1` makes the packet local, so it goes to
      `INPUT` and never reaches `POSTROUTING`, and conntrack rewrites the reply's source to the
      public address the client dialled. A masquerade written as `-d 127.0.0.1 --dport <pub>`
      matches no packet in either direction. `route_localnet` on the ingress interface is the
      whole requirement, and the golden-VM check asks for it explicitly
- [ ] **`soil firewall --apply` refuses (exit 1, installs nothing) unless all of:**
      `00-ssh.conf` exists, is 0600 root:root, its accept is first in `guarden-ssh`, and the
      INPUT jump to `guarden-ssh` is the first rule after conntrack and lo. This is the
      structural guarantee that replaces the dead-man timer: SSH access is guaranteed by the
      filesystem and rule order, not by a timer that opens the firewall
- [ ] `soil install` copies guarden's programs, templates and systemd units into
      `/usr/lib/guarden` root-owned, **creates the `guarden` and `hose` users**, **creates the
      `guarden` group** so every `root:guarden` path — the registry, every `overrides.toml` and
      all of `/etc/guarden` — is readable by the unprivileged programs that need it, records
      `host.admin_user` if it is empty, **measures `ingress.alias` and writes the result into
      `guarden.toml`**, and installs the credential materialiser units. There is no `soil users`
      phase, and `install` creates no group beyond `guarden` and never an `edge`:
      `weedr module add gate` does
- [ ] **`soil install` refuses to start the edge without `ingress.alias`**, naming the key. A
      container that cannot reach the host loopback answers every route with a cause-less 502
- [ ] `soil storage` verifies btrfs with `@` and `@var`, creates the `root` and `home` snapper
      configurations, keeps `/boot` on ext4, installs
      `/etc/apt/apt.conf.d/80guarden-snapper` with the `DPkg::Pre-Invoke` that snapshots `root`
      before every package transaction, and installs `/var/lib/guarden/soil/` for the convert
      state and the reboot marker
- [ ] **`soil storage` converges one fixed set of canonical values into every snapper
      configuration it can see, a service's state volumes as much as the host's own, and rewrites
      nothing else in them.** No manifest key and no repository sets any of them, and
      `soil storage --check` reports drift when any differs
- [ ] **Every state volume's configuration carries `EMPTY_PRE_POST_CLEANUP=no`.** guarden only
      ever creates `single` snapshots and never a pre/post pair, so switching the empty-pair
      cleaner off costs nothing. How that cleaner treats the cleanup tag and the `important` mark
      is not something this ticket can establish, and nothing in the design depends on the
      answer; the distribution's own default template enables it
- [ ] **Every state volume's configuration sets `NUMBER_MIN_AGE=3600`**, so a brand-new snapshot
      cannot be reaped before the reconciler has had a chance to see it and mark it
- [ ] **Every state volume's configuration sets `NUMBER_CLEANUP=yes`, `TIMELINE_CLEANUP=yes`,
      `NUMBER_LIMIT=2-10` and `NUMBER_LIMIT_IMPORTANT=8-12`.** The last is the floor the
      free-space pass keeps to under pressure, it is one number `soil` owns, and no manifest key
      and no `keep_last` value changes it. `FREE_LIMIT` comes from the track or the service's
      overrides
- [ ] **`TIMELINE_LIMIT_DAILY` is `0-<keep_last>`, and that row is the volume's ladder.** A daily
      cadence fills the daily bucket and snapper ages those snapshots up into the weekly,
      monthly and quarterly buckets, so one nightly timer produces a bounded, spread-out history
      rather than a flat window of the newest few. The weekly, monthly and quarterly limits are
      `0-4`, `0-6` and `0-2`; the hourly limit is `0` and the yearly limit is `0`
- [ ] `soil storage` **disables the distribution's packaged snapper cleanup timer and installs
      guarden's own oneshot, and both take `/run/guarden/locks/snapshots.lock`.** The reason is
      that snapper takes no lock `snapper modify` participates in — the per-config lock lives in
      the daemon, is advisory, and is released when a client disconnects — and the cleaner reuses
      one reference to the snapshot list across all three passes, so a mark written during a
      running cleanup is silently lost with no error anywhere. A packaging timer on its own
      schedule is that same overlap by another name
- [ ] **`snapper list` holds the configuration lock for its whole duration**, so a program that
      lists in a loop can stall cleanup. A loop is a defect, not a tuning choice
- [ ] `soil storage` **creates no service volume**, and a snapper configuration belonging to a service is created
      by the mutator and never recreated here
- [ ] `soil --check` exits 0 when converged and 1 with the word `drift` when not
- [ ] **Every drift line carries the requirement and the fact**: `error: drift: the ferm
      package is installed — does not hold on this host`, never the bare sentence. An item
      describes the converged state and one of them names a state that is itself a negative,
      so a bare `drift: <sentence>` reads as a claim about the present and cannot be acted on.
      Both modes produce the identical line, and every line a run emits carries the clause
- [ ] A second `--apply` exits 0 and changes nothing
- [ ] `getent passwd` and `getent group` show that `soil install` created only the `guarden` and
      `hose` users and the `guarden` group — no service user, no service directory, no state
      volume, no snapper configuration for anything guarden does not own
- [ ] The structural verification exists: `soil firewall --check` reports drift against the
      SSH guarantee, and `soil firewall --apply` refuses to install a ruleset that breaks it
- [ ] On the golden VM: `net.ipv4.ip_unprivileged_port_start` reads `1024` after
      `soil sysctl --apply`, and an unprivileged process fails to bind a port below 1024. Set it
      to `0` first and confirm `--check` reports the drift, because a host that ships `0` is the
      case the check exists for
- [ ] **The VM verifies the phases with the real tools and captures an evidence tarball.** There
      is no fast tier: this ticket's own suites override `PATH` to reach the real `getent`,
      `dpkg-query`, `systemctl`, `snapper`, `sysctl` and `install`, and they are the reason the
      fake tier could be deleted (ADR-0014)
