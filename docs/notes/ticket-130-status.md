# Ticket 130 — status: partial, three defects known

`feat(130): the portable install` (`fb54c8f`). The fast suite is green — 34
suites, 0 failures — and **the fast suite cannot see any of the defects below**,
because none is reachable without installing onto a real host.

They were found by running against the golden VM. That is the whole argument
for having one.

## The golden VM

`infra-test-golden` — Ubuntu 26.04.1, LXD, **podman 5.7.0 with `pasta` present**.
Podman 5.0 made pasta the default rootless network, which is why the eleven
networking claims of ticket 15 are answerable here and were not on the
development host (podman 3.4.4, 2021).

```bash
lxc list                                   # infra-test-golden, STOPPED
lxc start infra-test-golden
lxc list                                    # grab the IP
tools/golden-vm --target <ip>               # re-renders, boots, converges
```

## The three defects

### 1. An installed program cannot import the package

`hostprep._install_programs` installs each program's `.py` into `bin/` and
copies **only `cli.py`** into `lib/`. So:

```
/usr/lib/guarden/bin/soil  →  ModuleNotFoundError: No module named 'guarden'
```

`soil.py`'s siblings — `conf`, `hostprep`, `loom`, `render` — are never
installed. The `/usr/bin` symlinks spec §2 requires are therefore present and
**non-functional**.

Needs a decision, not just a patch: a `PYTHONPATH` in the installed wrapper, or
installing the package as a package. The second is cleaner and is what a real
install should look like.

### 2. `/var/lib/guarden` is `root:root 755`

`soil storage` creates it before `soil install` creates the program group. The
**install** phase was reordered so the group leads the directories and users
(`hostprep.py:1006` groupadd, `:1061` useradd, with the ordering comment at
`:1055`). **`storage` has the same defect and was not reordered.**

### 3. The alias probe cannot succeed on any host

`hosttool.PROBE_IMAGE = "localhost/guarden-probe"` (`hosttool.py:36`) and **no
such image is built, referenced or shipped anywhere in the repo**.

So `soil install --check` will always report alias drift, on every host, forever.
This is the ticket's own load-bearing claim — the measured alias is what the
whole ingress design rests on (ticket 15's claims A, B, C, F, G, M all depend on
it) — so it is the important one of the three.

The image is what measures the container's default gateway and proves pasta maps
the alias. It has to exist before any of ticket 15's networking checks mean
anything.

## Not proven

**A boot from cloud-init reaching converged state.** The golden VM's root is
**ext4**, not btrfs with `@`/`@var`. `soil storage` *verifies* that layout and
errors otherwise; converting it needs a reboot and a dracut hook, which is one
of the four documented Ubuntu-only items. So `soil storage --check` cannot exit
0 on that machine, and the full-boot claim is untested.

```bash
lxc start infra-test-golden && tools/golden-vm --target <ip-of-infra-test-golden>
```

## What IS verified on the VM

- the family probe resolves `debian` from `/etc/os-release`
- `packages/packages.toml` reads correctly, one list, no second copy
- the rendered user-data passes `cloud-init schema --config-file` — **Valid schema**
- the render is **byte-identical** to the committed file
- all 7 substrate packages plus `passt` install via the list's own `apt-get` argv
- `soil packages --check` then reports only the operator-filled podlet pin

`tools/golden-vm` re-renders before booting and **refuses a committed document
that has drifted from the list**, so the file a reviewer reads is the file the
machine boots.

## Also landed

`[modules] enabled` is seeded under the modules lock and re-read under it.
`holds()` is a **subset** test, so a later `weedr module add` append is not
mistaken for drift — that is the claim the lock exists for: two writers, one
key, and the later one does not silently drop the earlier one.

## The PATH trap, hit again

Working in this repo, a sourced `tests/lib.sh` puts `fixtures/bin/git` first on
`PATH`. That fake silently no-ops on `git status`, `git rev-parse` and even
`git --version` — empty output, exit 0. It reads exactly like a corrupted
repository. It is ticket 35's subject, and it has now cost real time twice.
**Pin `PATH=/usr/bin:/bin` in any shell not deliberately running a guarden
test.**
