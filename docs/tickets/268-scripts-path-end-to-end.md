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
`soil install` like every template, found from the source tree first in a checkout);
`hostprep._conversion_step` runs it from the btrfs-layout item, guards `/boot` first, and
translates `75` into a drift naming the marker; a new item —
*"no reboot is outstanding for the root filesystem conversion (`…/reboot-required` is absent)"* —
carries the post-reboot cleanup and makes `--check` name the marker, which is the runbook's
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

## What remains uncovered

- No suite can drive the conversion: every cut machine boots from the golden, whose root is
  already btrfs. The coverage is the golden build (`_convert`) and this manual round; a suite
  would need a deliberately unconverted machine, which no harness shape provides today.
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
