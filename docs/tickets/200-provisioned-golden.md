# 200: provision the golden, so a cut machine boots without installing anything

**What was wrong:** the golden every suite is cut from carried a cloud-init
document with `package_update: true` and twenty-three packages. A copy of the
golden is a new instance to cloud-init, so **every cut re-ran it**: an
`apt-get update` over the network plus an install of packages the image already
had, with apt's locks held while the suite cut for it waited.

Measured on 2026-10-22 on two cuts of the old `guarden-golden/base`, sampling the
guest once a second from the copy:

| | cut 1 | cut 2 |
|---|---|---|
| first answer from the guest | 16.3 s of uptime | 21.6 s of uptime |
| cloud-init's `apt-get update` | 18.5 s by cloud-init's own clock | — |
| apt's locks held | ~22 s → ~38 s of uptime | ~26 s → ~40 s of uptime |
| cloud-init done | 40.6 s of uptime | 45.6 s of uptime |
| steady: cloud-init done, no apt process, locks free | 62.3 s after the copy | 71.1 s after the copy |

## What was done

- [x] **`tests/lxc.sh provision` installs the golden's packages during the build.**
      It pushes the checkout, asks the machine to read the one list, and installs
      its output. `apt-get update` now runs once per build instead of once per
      cut, and nothing races it: the install is the only writer.
- [x] **The document the golden carries installs nothing** — no `package_update`,
      no `packages:` block — and it says so in its own text
      (`_provisioned_user_data` in `tests/lxc.sh`). It is also the ONLY document
      the golden has: the build document the earlier plan would have swapped out
      after the build does not exist.
- [x] **One package list, not two.** `packages/packages.toml` is authoritative.
      The heredoc in `tests/lxc.sh` was a second copy: the substrate plus six
      packages no list declared (`passwd`, `uidmap`, `sudo`, `util-linux`,
      `kmod`, `procps`). Those six are now the new `golden` role beside the
      substrate, together with `python3`, `iproute2`, `iptables`, `curl`,
      `ca-certificates`, `rsync`, `psmisc` and `passt`;
      `tests/packagelist.py` composes the substrate and that role in the
      machine, and `provision` installs the result.
      *Which is authoritative, and why:* `packages.toml`, because spec §6.1 makes
      it the contract and it is the file the product itself reads; the runner's
      copy was a subset plus six undeclared extras, and the two could disagree
      with nothing noticing (`passt` was on the image only because podman's
      Recommends pulled it in, while `t130-packages.sh` asserts pasta). The role
      is not `harness`, because that one carries `nginx` and a Postgres client,
      and a golden that booted with port 80 taken would break every suite that
      binds it.
- [x] **`tools/golden-vm` and the `vps` profile are unchanged**: a real host still
      installs its substrate on first boot.
- [x] **`just provision` still builds a golden from scratch** — the image these
      numbers were taken from was built by it, on a machine whose cloud-init
      installs nothing at all.
- [x] **The inventory suite is re-derived, not deleted.** `t15-cutlist.sh`
      becomes `t15-golden-list.sh`: it asks the machine for its own `dpkg` state
      for every name the one list prints, and it asserts that the document this
      cut re-ran installs nothing. `t322-psmisc.sh` holds the `golden` role to
      `psmisc` the same way it held the old heredoc.

## Measured after

Three cuts of the rebuilt `guarden-golden-t200/base`, same sampling:

| | cut 1 | cut 2 | cut 3 |
|---|---|---|---|
| first answer from the guest | 9.7 s of uptime | 7.7 s | 10.5 s |
| apt process seen at boot | none | none | none |
| apt's locks held at boot | never | never | never |
| cloud-init done | 14.6 s of uptime | 10.0 s | 13.0 s |
| steady | 21.0 s after the copy | 21.5 s | 21.4 s |

**The cut reaches steady state 41–50 s sooner** (62.3 / 71.1 s → 21.0 / 21.5 /
21.4 s), and no package transaction runs at all: the boot journal for a cut has
no `apt-get` or `dpkg` line, and `/var/lib/apt/lists` still carries the build's
mtime, so the index was not refreshed either.

Suites run green against the rebuilt golden, `--no-cache`, one machine each:
`t15-golden-list` 25 s, `t322-psmisc` 33 s, `t130-packages` 1 m 39 s,
`t10-golden-vm` 42 s, `t20-packages` 1 m 37 s, `t60-secrets` 40 s.

## The full-suite wall clock

| | suites | wall clock |
|---|---|---|
| before — `guarden-run-t358gate`, the last gate on the same golden | 134 | 2 h 14 m 35 s |
| after | 134 | recorded below when the gate lands |

## The two limits, stated

- **The first install on a real host is unchanged.** A host that is not a golden
  still needs `soil packages --apply`, and still needs its index refreshed
  (spec §6.1). This is about the machine the harness cuts.
- **It does not remove the need to wait for a machine to be ready.** Boot is
  boot. What it removes is the package transaction inside it — the part that
  also lost seven suites an apt-lock race on 2026-10-01.
