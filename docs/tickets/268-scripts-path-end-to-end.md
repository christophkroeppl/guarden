# 268: the scripts path, end to end on a fresh host

**What to build:** nothing new — this ticket is the record of running the README's "From the
scripts" flow on a **bare** `ubuntu:26.04` VM (no cloud-init user-data, no packages, no
`soil`) on 2026-10-12, the three defects the round measured, and what closed which.

## 1. The bootstrap order was wrong, and the README said so (closed)

`soil packages --apply` was the README's first command, and on a bare host it exits **2**:
*"a pinned artefact is not installable: the pinned podlet record is absent:
`/etc/guarden/podlet.release`, and `soil install` seeds it from the template"*. The refusal is
by design — `t130-packages.sh` asserts it — and the record item is the phase's **last**, so the
packages themselves installed and only the fetch stopped. `soil install --apply` works without
the record: it seeds it (and the programs, groups and files) before its own last item, the
alias probe. The README's block is reordered (install first, with every command's effect
annotated); the spec's phase list is unchanged — it describes the phases, not a bootstrap.

## 2. The conversion machinery existed only under `tests/` (closed)

`soil storage` on an ext4 root printed *"convert the root filesystem before running this phase
again"* and armed nothing: no marker, no dracut hook, `/var/lib/guarden/soil/` empty. Everything
four documents describe — the runbook's *"reboot only if `--check` asked for it"* and *"reports
the reboot marker and names it"*, spec 6.1's *"soil/ — the btrfs convert state and the reboot
marker"*, PRD item 1 (*"the dracut hook for the btrfs convert"*, Ubuntu-only), the README's
*"This reboots once"* — is implemented **once**, as `tests/lxc-btrfs-convert` and
`tests/dracut/99guarden-convert/`, a harness-only copy the golden's build drove directly.

Closed by wiring it in: the machinery moved to `src/guarden/templates/convert/` (installed by
`soil install`, whose templates walker was made recursive for it — it had only ever handled flat
files, so the new subdirectory needed `_templates_installed`/`_install_templates` to walk like
`_install_modules` does, or a host could report the templates converged while `convert/` was
absent), found from the source tree first in a checkout; `hostprep._conversion_step` runs it
from the btrfs-layout item, guards `/boot` first, and
translates `75` into a drift naming the marker; a new item —
*"no reboot is outstanding for the root filesystem conversion (reboot-required under
/var/lib/guarden/soil/)"* — carries the post-reboot cleanup and makes `--check` name the marker,
which is the runbook's
sentence made true. `tests/lxc.sh`'s `_convert` now drives `soil storage --apply` across the
reboots it asks for (the marker is the question — `soil` never exits 75), so every golden build
is evidence about the product again, and the harness copy is deleted: one file, one place.

## 3. The alias probe's image, and `soil --check` never being green without it (documented; ticket-worthy)

`soil install --apply` on any host exits 1 on `ingress.alias` until a `localhost/guarden-probe`
container image exists: the probe runs it, and the repository neither builds nor ships it
(`tests/t20-install.sh:50` says so and asserts the exit 1; `docs/tickets/265` recorded the
diagnostic). That is by design — guarden records no address it did not measure — and the README
now says it in the operator's terms. **The open decision**: build the image in-repo (a
`FROM scratch` + busybox-static Containerfile needs no registry pull) would make a fresh host
converge fully on the first run; it is deliberately not done here, because "the image is
external" is stated as design in three places and changing that is a decision for an ADR, not a
round.

> **Closed 2026-10-13 (ADR-0018):** the open decision is resolved — no image is built because
> there is no probe. `soil install` derives `ingress.alias` from the pinned `[network]
> pasta_options` (`-g 10.0.2.2`), so a fresh host converges fully on the first run and `soil
> --check` carries no alias item at all.

## What remains uncovered

- No suite can drive the conversion: every cut machine boots from the golden, whose root is
  already btrfs. The coverage is the golden build (`_convert`) and this manual round; a suite
  would need a deliberately unconverted machine, which no harness shape provides today.
- **`/etc/guarden`'s directory modes.** Resolved in `b9356be`: the write protocol's
  `mkdir(parents=True)` is `0777 & ~umask`, so an `027` umask would have silently produced the
  `0750` that locks `hose` out — the same traverse class `/var/lib/guarden` had (`df0b268`).
  The modes are stated in `INSTALL_DIRECTORIES` now (`0751` parent, `services` and
  `projects.d` `0755`, `creds` `0700`) and spec 2.1's single row is split to match.
- **Two lock implementations for one spec 3.5 set.** `conf.lock` (with the order ranks) and
  `hosttool.lock` (what `hostprep`'s six sites import) both exist, and they had drifted:
  `hosttool.lock` re-chmodded `/run/guarden/locks` to the old `0770` on every acquisition, so
  the first lock-taking item undid the directory item's `2770` in the same apply — found by
  `t20-install` after `5a28a7a`, fixed in `0fa2937`. Both now state `2770` and `0664`, which
  is two copies of one rule; collapsing the pair is a follow-up worth doing before a third
  caller appears. **The pair is five copies in total** — `hosttool.MODE_DIR_LOCKS`/`LOCK_GROUP`,
  `hostprep`'s locks row, the tmpfiles template (plain text; its header names the constants),
  spec 2.1's row and sysadmin's row — held in step by hand and pinned end-to-end by
  `t20-install`'s mode and owner assertions on the live host. A constant the template could
  render from would be the honest single source; today the suites are what make the copies safe.
- The machinery is bash (its dracut half is shell by necessity — it runs in the initramfs). Its
  Python-driver half is a possible follow-up if the state dispatch ever needs more than
  `state_get`/`state_set`.

## The round's evidence

Bare VM, no user-data, in order: `soil packages --apply` → exit 2 (record absent) →
`soil install --apply` → exit 1, seeds everything including `podlet.release`, probe item last →
`soil packages --apply` → exit 0 (fetch included) → `soil storage --apply` → exit 1, three
drifts, no arming (the defect above) → conversion driven manually via the then-`tests/` script:
two reboots, `state` `none → converting → migrated → done` → `soil storage --apply` → the rest
converged, then `soil sysctl`/`firewall`/`units` → `soil --check` → only the alias drift. The
wired tree re-runs this round from a fresh machine, with `storage` doing the conversion itself.

## The review round (2026-10-12, adversarial)

Two real defects the round itself could not see, plus four smaller items, all closed in the
same branch:

1. **`dracut` was undeclared.** The machinery refuses a conversion without it (`automated
   conversion needs dracut`), and it was in no family of `packages.toml` — it existed on the
   golden only because `tests/lxc.sh`'s own user-data list installs `dracut-core`. The round's
   bare machine happened to have it (the image ships it or a package pulled it), which is
   exactly why the round passed and the dependency stayed invisible. Now declared per family
   (`dracut-core` on Debian, `dracut` on Fedora and Arch) and named in spec 6.1's package
   sentence; a host on a family without it still refuses explicitly, which is the documented
   fallback.
2. **The templates walkers could not handle a directory.** `convert/` is the first
   subdirectory `templates/` has ever had: `_templates_installed` skipped it (a host could
   report converged while the machinery was stale or absent) and `_install_templates` ran
   `install -m 0644 <dir>` on it, which exits 1 — so a host needing a template re-install
   would have failed at apply time. Both now walk recursively, the shape `_install_modules`
   already had.
3. `_finish_conversion` discarded the script's result (a failed cleanup was silent); it now
   reports the script's first stderr line the way `_conversion_step` does.
4. The marker item's description read *"(… is absent)"* — a claim the drift line then
   contradicts while the marker is present. It reads *"(reboot-required under
   /var/lib/guarden/soil/)"* now: a locator, not an assertion.
5. `docs/sysadmin.md` still said "exactly one reboot"; it now states the two, matching the
   spec's clause (AGENTS.md's one-canonical-statement rule).
6. The stale pre-rewrite comment above `_convert`, the script's dangling "NOTES section"
   reference, and the script's missing trailing newline — all three gone.

One ordering note recorded rather than changed: `_conversion_step` runs before
`/etc/apt/apt.conf.d/80guarden-snapper` is installed, so the conversion's own `apt-get install
btrfs-progs` runs without a pre-transaction snapshot — correct (there is no configuration to
snapshot before the conversion converges) and worth knowing.
