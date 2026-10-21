# 340 — the btrfs conversion gives /tmp its own subvolume, and never a ladder

Blockers: none. Asked for by the operator 2026-10-21: "during btrfs conversion
also add @tmp for /tmp folder. Make sure it has no snapshot ladder. /tmp/ is
volatile data and not to be snapshotted."

## What the operator asked for

Three things, and they are separable:

1. **The conversion creates a third subvolume, `@tmp`, and mounts it at `/tmp`.**
2. **`@tmp` has NO snapper configuration at all** — so there is no `TIMELINE_LIMIT_*`
   ladder governing it, because a ladder is a per-configuration thing and a
   configuration that does not exist has none.
3. **`/tmp` is never snapshotted.** Not by the `root` configuration's snapshot of
   `/`, not by the apt hook, not by the nightly timer.

## What the host looks like today

Measured on the golden (`guarden-golden`, cut `base`, ubuntu 26.04), 2026-10-21:

```
$ cat /etc/fstab
LABEL=BOOT	/boot	ext4	defaults	0 2
LABEL=UEFI	/boot/efi	vfat	umask=0077	0 1
UUID=747687d9-… / btrfs subvol=@,noatime,compress=zstd 0 0 # guarden-storage
UUID=747687d9-… /var btrfs subvol=@var,noatime,compress=zstd 0 0 # guarden-storage
                                                    ← no /tmp line at all

$ findmnt -n -o FSTYPE,SOURCE,OPTIONS /tmp
tmpfs tmpfs rw,nosuid,nodev,size=4052648k,nr_inodes=1048576,inode64,usrquota /tmp

$ btrfs subvolume list / | grep -E 'path (@|@var)$'
ID 257 gen 876 top level 5 path @
ID 258 gen 880 top level 5 path @var

$ snapper list-configs
Config | Subvolume
-------+----------
root   | /
```

So `/tmp` is a **tmpfs**, mounted by the distribution's own unit
(`/usr/lib/systemd/system/tmp.mount`, pulled in by
`/usr/lib/systemd/system/local-fs.target.wants/tmp.mount`), and **not** by
`/etc/fstab`. `/tmp` is therefore already outside every snapshot — a tmpfs has
no btrfs subvolume and is not in the root snapshot's tree at all. The change
replaces that tmpfs with a btrfs subvolume, and everything below is what that
replacement costs and buys.

## What the change buys, and what it costs

**Buys.** `/tmp` becomes disk-backed rather than RAM-backed, so a large build
does not eat the box's memory; and `/tmp`'s contents are structurally outside
the root snapshot rather than outside it by accident of a mount unit.

**Costs, each measured, each a decision the implementer must make and justify:**

| what | measured today | measured with `@tmp` |
|---|---|---|
| `nosuid` on `/tmp` | **yes** (`nosuid,nodev` on the tmpfs) | **no** — the btrfs mount carries `rw,noatime,compress=zstd:3,discard=async,space_cache=v2,subvol=/@tmp` and nothing else |
| `nodev` on `/tmp` | **yes** | **no** |
| size cap | `size=4052648k` (tmpfs) | **none** — `/tmp` is bounded by the filesystem |
| inode cap | `nr_inodes=1048576` | none |
| survives a reboot | no | **yes** — a marker file written to `/tmp` was still there after a full reboot |
| snapshotted by `root` | no (tmpfs) | **no** (measured below) |

The `nosuid`/`nodev` loss is the one that matters and it is fixable: the
mount options are guarden's own choice (`MOUNT_OPTS`, `soil-storage-convert:43`),
and `nosuid,nodev` were honoured when I mounted a subvolume with them
(`rw,nosuid,nodev,relatime,compress=zstd:3,…`). **The `/tmp` fstab line must
carry `nosuid,nodev`** — the tmpfs it replaces had them and dropping them
silently is a security regression, not a simplification.

The persistence across reboots is the "volatile" half of the contract: `/tmp`
is not snapshotted and is not rolled back by a restore, but it is also **not
wiped at boot** the way a tmpfs is. `systemd-tmpfiles`' `q /tmp 1777 root root
10d` (`/usr/lib/tmpfiles.d/tmp.conf:11`) still ages the contents out after ten
days; that is the mechanism that keeps it bounded now.

## The measurements that decide the design

All measured on a cut from the golden (`probe-tmpcheck`, since deleted).

### 1. `@tmp` MUST be created at the btrfs top level, never inside `@`

`btrfs subvolume create /@tmp` on a host whose `/` is mounted on `@` creates
`@/@tmp` — a **nested** subvolume:

```
$ btrfs subvolume create /@tmp
Create subvolume '//@tmp'
$ btrfs subvolume list / | grep @tmp
ID 264 gen 169 top level 257 path @/@tmp     ← inside @
```

and the fstab line `subvol=@tmp` then **fails to mount**, because `subvol=`
resolves against the filesystem's top level (subvolid 5), where no `@tmp`
exists:

```
Oct 21 05:17:35 probe-tmpcheck mount[974]: mount: /tmp: mount() failed: No such file or directory.
Oct 21 05:17:35 probe-tmpcheck systemd[1]: tmp.mount: Failed with result 'exit-code'.
```

`/tmp` then falls back to the tmpfs (`Directory /tmp to mount over is not
empty, mounting anyway`) — so the host **silently keeps the old behaviour** and
the layout looks wrong only to someone who checks. That is the whole shape of
this bug: it fails open.

Created at the top level, the same fstab line works, first try and after a
reboot:

```
$ TOP=$(mktemp -d); mount -o subvolid=5 /dev/sda1 "$TOP"
$ btrfs subvolume create "$TOP/@tmp"
Create subvolume '/var/tmp/tl.XXXX/@tmp'
$ btrfs subvolume list "$TOP" | grep @tmp
ID 289 gen 244 top level 5 path @tmp          ← top level 5, sibling of @ and @var
```

```
$ findmnt -n -o FSTYPE,SOURCE,OPTIONS /tmp
btrfs /dev/sda1[/@tmp] rw,noatime,compress=zstd:3,discard=async,space_cache=v2,subvolid=289,subvol=/@tmp
```

**The conversion's existing subvolume loop already does this correctly** —
`migrate_subvolumes` mounts the top level at `${TOP}` and creates
`${TOP}/${name}` (`soil-storage-convert:239-253`). `@tmp` joins that loop, and
the loop is the reason the hazard is survivable: **do not** create `@tmp` with
a plain `btrfs subvolume create /@tmp` from a script.

### 2. The `root` snapshot does NOT capture `/tmp` once `@tmp` is mounted

This is the operator's requirement, and it holds — but for a reason worth
stating, because it is btrfs's nesting rule and not a guarden mechanism.

```
$ echo volatile-marker > /tmp/marker-probe.txt
$ snapper -c root create --description probe --cleanup-algorithm timeline
$ ls /.snapshots/29/snapshot/tmp/
.ICE-unix  .X11-unix  .XIM-unix  .font-unix  snap-private-tmp
$ ls /.snapshots/29/snapshot/tmp/marker-probe.txt
ls: cannot access '/.snapshots/29/snapshot/tmp/marker-probe.txt': No such file or directory
```

The marker is in `@tmp`; the snapshot's `/tmp` is the **mountpoint directory**
inside `@`, which is empty of live data — btrfs excludes nested subvolumes from
a parent's snapshot entirely, and mounting `@tmp` over `@/tmp` leaves `@/tmp`
itself untouched. The live contents and the snapshot contents are different
trees.

The same rule means the **conversion must keep `/tmp` out of the rsync**, which
it already does: `--exclude=/tmp/` (`soil-storage-convert:53`), and
`mkdir -p` recreates the excluded directories on the receiver
(`soil-storage-convert:263`). So `@/tmp` in the snapshot is an empty
mountpoint directory. **Nothing volatile is copied into `@` and nothing volatile
is ever snapshotted.**

### 3. A snapper configuration CAN be created for `/tmp` — so "no configuration" is an active property

Nothing about a btrfs subvolume at `/tmp` prevents snapper from taking it:

```
$ snapper --config tmpprobe create-config -f btrfs /tmp
$ snapper list-configs
Config   | Subvolume
---------+----------
root     | /
tmpprobe | /tmp
```

So "no ladder for `/tmp`" is not a property of the filesystem. It is a property
of **guarden never creating that configuration**, and of nothing else creating
it either. The guarden-side rules already give it:

- `HOST_CONFIGURATIONS = {"root": "/"}` (`hostprep.py:212`) — the host's own
  configurations are `root` alone. `/tmp` must **not** be added here.
- `soil storage` creates a configuration only for a name in
  `HOST_CONFIGURATIONS` (`hostprep.py:1272-1279`) or for a service's `state`
  volume. `/tmp` is neither.
- `soil storage` converges the canonical ladder only into configurations it can
  see, and a configuration it did not create is **skipped with a warning**
  (spec §8.1, `hostprep.py:1288-1293`). So even an operator-made `/tmp`
  configuration is left alone rather than given a ladder by guarden.

The last point is the right outcome and it must stay true: guarden does not
hand a ladder to a configuration it does not own, and it does not create one for
`/tmp`. The `bulk` volume (`spec` §8.1) is the same rule at service scope —
**a subvolume with no snapper configuration** — and `@var` is the same rule at
host scope today: a top-level subvolume with no configuration and therefore no
ladder. `@tmp` is the third of that kind.

### 4. The fstab entry replaces the tmpfs unit, and a pre-existing `/tmp` line would win the wrong way

`systemd-fstab-generator` produces a `tmp.mount` from the new line, and the
**generated unit wins over the distribution's `/usr/lib/systemd/system/tmp.mount`**:

```
$ systemctl show tmp.mount -p FragmentPath -p What
FragmentPath=/run/systemd/generator/tmp.mount
What=/dev/disk/by-uuid/747687d9-…
```

No drop-in, no masking, no `systemctl disable` — the fstab entry is enough.

But the generator **keeps the FIRST entry** for a path and refuses the second:

```
$ systemd-fstab-generator …   # with both lines present
Failed to create unit file '…/tmp.mount', as it already exists. Duplicate entry in '…/fstab.dup'?
$ grep -E 'What|Where|Type' …/tmp.mount
What=/dev/disk/by-uuid/747687d9-…      ← the first entry won
```

The conversion's fstab rewrite (`soil-storage-convert:265-275`) drops the
`/` and `/var` lines with `awk '$2=="/" || $2=="/var" {next}'` and appends the
new ones. **A pre-existing `/tmp` line would survive that awk, and if it comes
first in the file the tmpfs wins and `@tmp` never mounts** — the same
fail-open shape as measurement 1. The rewrite must drop any `/tmp` line as
well, whatever it says.

The golden ships no `/tmp` line, so this is not broken today; it is broken on
any host whose `/etc/fstab` names `/tmp`, and the conversion is the code that
has to be right about it.

### 5. `systemd-tmpfiles` does not nest a subvolume inside `@tmp`

`/usr/lib/tmpfiles.d/tmp.conf:11` carries `q /tmp 1777 root root 10d`, and
`q` creates a **subvolume** when the path does not exist. After a reboot with
`@tmp` mounted, the subvolume list is unchanged — no nested subvolume inside
`@tmp`, and `@/tmp` is still a plain directory:

```
$ btrfs subvolume list "$TOP" | grep -vE '\.snapshots'
ID 257 … path @
ID 258 … path @var
ID 289 … path @tmp
$ btrfs subvolume show "$TOP/@/tmp"
ERROR: Not a Btrfs subvolume: Invalid argument
```

and with `/tmp` **unmounted**, `systemd-tmpfiles --create` still creates
nothing. The mode is also handled: the live `/tmp` reads `1777 root:root` after
the reboot, because tmpfiles applied it to the mounted subvolume. A freshly
created subvolume is `0755` (measured), so **the mode comes from tmpfiles, not
from `btrfs subvolume create`** — an implementation that creates `@tmp` and
never checks the mode would leave `/tmp` at `0755`, and that must be an
assertion.

## The decisions the implementer must make and justify

The operator's instruction settles the shape; these are the choices it leaves
open, and each one is a decision with a surface of its own.

**D1 — Does `/tmp` get `nosuid,nodev`?** The tmpfs it replaces had both, and
they are honoured on a btrfs subvolume (measured). Dropping them is a security
regression. **My recommendation: yes**, and the fstab line carries them. If
the implementer decides otherwise, the ticket has to say why, in writing.

**D2 — Is the size cap dropped, and is that intended?** The tmpfs capped `/tmp`
at 4 GiB; a btrfs subvolume caps it at the filesystem. A box whose `/tmp` fills
up now fills up the root filesystem. If the operator wants a bound, it is a
btrfs **qgroup limit** (`btrfs qgroup limit`), not a mount option — and the
ticket has to say which, because "the tmpfs had a limit and now it does not" is
a fact an operator needs to be told.

**D3 — Does `/tmp` keep ageing out, and does anything clear it at boot?**
`q /tmp 1777 root root 10d` still ages contents after ten days. But a tmpfs is
**empty at every boot** and a subvolume is not. If "volatile" means "gone at
boot", something has to do it, and the candidate is a `tmpfiles.d` entry of
guarden's own (the distribution's `q` does not remove contents on boot, only
age them). If "volatile" means "never snapshotted and never rolled back" — the
operator's own words — then nothing has to, and `/tmp` survives a reboot, which
is a change an operator must be told about. **This is the one decision that
changes the contract, and it needs an answer in the ticket before the code.**

**D4 — What happens to a host that already has the old layout?** The
conversion is a one-way door: a host already converted has `@` and `@var` and
no `@tmp`, and `soil storage` will not convert it again — the script's state
file says `done` and the layout verify is the only gate
(`soil-storage-convert:354-376`). Options: (a) `soil storage` grows a
migration for the missing `@tmp` on an already-converted host, (b) the change
applies only to hosts converted from now on and the operator is told, (c) the
phase refuses and names the repair. **(a) is the answer a converged host needs
and it is the most work; (b) is the cheapest and leaves hosts divergent.**
The ticket must state which, because the golden is already converted and the
harness cuts from it.

## What to build

### The conversion machinery (`src/guarden/templates/convert/soil-storage-convert`)

- **`TMP_MOUNT="/tmp"` and `TMP_SUBVOL="@tmp"`**, beside `ROOT_*` and `VAR_*`
  (`:39-44`).
- **Create `@tmp` at the top level**, in the existing loop at `:243-253` —
  `for name in "$ROOT_SUBVOL" "$VAR_SUBVOL" "$TMP_SUBVOL"`. **Do not** create
  it with a plain `btrfs subvolume create /@tmp`: that nests it inside `@` and
  the mount then fails open (measurement 1). The loop mounts the top level
  first, which is the whole reason this is safe.
- **Copy nothing into `@tmp`.** `/tmp` is volatile; the rsync already excludes
  it (`--exclude=/tmp/`, `:53`) and `@tmp` must start empty. A `rsync` of
  `/tmp` into `@tmp` would put volatile data on the disk the operator asked to
  keep clear of it.
- **Rewrite the fstab** (`:265-275`): drop the `/`, `/var` **and `/tmp`**
  lines — the awk's condition must include `$2=="/tmp"` (measurement 4) — and
  append the `/tmp` line. Its options are `subvol=@tmp` plus **`nosuid,nodev`**
  (D1) and whatever the answer to D2 is.
- **`verify_layout()`** (`:125-131`): check `/tmp` is a separate mountpoint on
  `@tmp`, beside the existing `/` and `/var` checks. The `--check` usage line
  (`:61`) says what `--check` proves, and it has to say it for three
  subvolumes.
- **`cleanup_backup()`** (`:319-336`) deletes the ext4 backup subvolumes; it
  has no `@tmp` business, and must not grow one.
- The header comment (`:2`, `:17-31`) and the dracut hook's comment
  (`guarden-convert-hook.sh:87-89`) say what the layout is; they have to say
  three subvolumes.

### The `storage` phase (`src/guarden/hostprep.py`)

- **`_btrfs_layout_holds()`** (`:901-903`): `"@" in layout and "@var" in layout`
  becomes the three-subvolume test.
- **The item's name** (`:1217`): "btrfs with the @ and @var subvolumes" →
  the three.
- **`HOST_CONFIGURATIONS` stays `{"root": "/"}`** (`:212`). **`@tmp` must NOT
  get a snapper configuration and therefore must not get a ladder.** If the
  implementer adds it, the ticket is wrong and the change must be reverted —
  this is the operator's explicit requirement and it is the one thing in this
  ticket that is not a matter of taste.
- **A check that `/tmp` has no configuration**, so the property is *verified*
  and not merely true by accident. `snapper list-configs` names every
  configuration and its subvolume; a configuration whose subvolume is `/tmp`
  must not exist. The existing helpers are `assert_no_snapper_config`
  (`tests/lib.sh:650-653`) and `snapper -c <name> get-config`.
- The layout comment at `:206-212` says what the layout is; it has to say three.

### The documents

- **`docs/spec.md` §6.1** (`:1521-1535`): "`storage` verifies btrfs with `@`
  and `@var` subvolumes" → three; and the `@`/`@var` migration sentence
  (`:1529`) → three. This is the contract and the code is written to it.
- **`docs/spec.md` §2.1's mode table** (`:252-286`): there is **no `/tmp` row
  today**. One is needed if the mode is guarden's to state — the measured mode
  is `1777 root:root`, owned by `systemd-tmpfiles`, so the table should say
  who owns it, exactly as the `/run/guarden/` row says "tmpfs and must be
  recreated every boot" (`:272-273`).
- **`docs/spec.md` §8.1** (`:2933-2940`, `:2944` says "one of the host's
  two"): the host's own configurations. **Note the discrepancy this ticket
  found** — §8.1 says the host's configurations are "`root` and `home`"
  (`:2933`, `:2940` says "two warnings"), and §6.1 repeats it (`:1524-1525`
  says "the host's own `root` and `home`" and "creates `root` and `home`
  where they are absent"), but the code has **one**: `HOST_CONFIGURATIONS =
  {"root": "/"}` (`hostprep.py:206-212` gives the reason — `/home` is a
  directory inside `@`, not a subvolume, so a snapper configuration for it
  could not be created on that layout at all). **The code is right and the
  spec is stale.** Fixing that is not this ticket's work, but this ticket is
  the place where the spec's own list of the host's configurations has to be
  touched, so the stale `home` must not be copied into the new text — and the
  new text must not say "`root`, `home` and `/tmp`".
- **`docs/sysadmin.md`** (`:47-50`, `:66`, `:198-203`) and **`README.md`**
  (`:108-117`): the `@`/`@var` layout in prose.

### The tests

- **`tests/lxc.sh`'s capability gate** (`:630-643`): it greps the subvolume
  list for `@var` (`:634-635`) and dies with "this instance has no btrfs root
  with @ and @var". A cut from a golden built before this change **has** `@var`
  and would pass the gate while failing the new layout check — so the gate has
  to name `@tmp` as well.
- **`tests/t20-storage.sh`** is the natural home. It already asserts the
  layout is the machine's own business rather than a stand-in's (`:11-16`).
  The new assertions, all on the machine's own state:
  - `/tmp` is a separate mountpoint on the `subvol=@tmp` mount
    (`findmnt -n -o FSTYPE,SOURCE,OPTIONS /tmp`);
  - `@tmp` is a **top-level** subvolume — `btrfs subvolume list /` shows
    `path @tmp` and **no** `@/@tmp` (measurement 1);
  - **no** subvolume is nested inside `@tmp`;
  - `/tmp` is `1777` (measurement 5);
  - **no snapper configuration exists for `/tmp`** — and no `TIMELINE_LIMIT_*`
    value governs it, because no configuration does;
  - **the volatile marker is not in a snapshot**: write a marker into `/tmp`,
    take a `root` snapshot, and assert the snapshot's `/tmp` does not contain
    it (measurement 2). This is the operator's requirement stated as a
    measurement.
  - `/tmp` carries `nosuid` (D1) — if the implementer decides D1 the other
    way, this assertion is replaced by one that says so.
- **The conversion itself is the real subject**, and the golden is already
  converted — a cut from it cannot exercise the conversion. See "The golden"
  below.

### The golden

**This change breaks every suite that assumes the golden is converged, until
the golden is rebuilt.** `soil storage --check` on the old golden will report
the layout as drift (D4), and `t20-storage.sh` asserts exit 0 for it
(`:182-187`). The golden is converted by the machinery itself
(`tests/lxc.sh:582-625`, `:753-754`), so the only honest way to test the
conversion is on a **fresh, unconverted** VM: `lxc init ubuntu:26.04 … --vm
--storage guarden-btrfs` with no user-data, push the checkout, and run
`soil storage --apply` and let the phase drive its own reboots — the path
`references/golden-vm-harness.md` already documents as "the scripts path".

**The golden is not to be rebuilt by this ticket.** It took an hour and every
other worker depends on it. The ticket's verification is the fresh-VM round,
and the golden rebuild is a **separate, explicitly scheduled act** — the
ticket has to say when it happens, because until it does, the whole suite
suite is red on the layout item.

**State this in the ticket, do not leave it implicit:** the suites that will go
red on an old golden are exactly the ones that assert a converged
`soil storage --check`, and the fix is a rebuild, not an assertion change.

## The scope, stated

**In:** the conversion machinery, the `storage` phase's layout predicate and
its item name, the fstab rewrite, the `/tmp` mount options, the documents
above, `tests/lxc.sh`'s capability gate, and `tests/t20-storage.sh`'s new
assertions.

**Out, deliberately:**

- **No snapper configuration for `/tmp`, and no ladder.** This is the
  operator's explicit requirement and the reason the ticket exists.
- **No change to the `bulk` volume's machinery.** `@tmp` is the same *rule* as
  a bulk volume (a subvolume with no configuration) at host scope; it is not
  the same *code*, and folding it into `volumes.py` would make a host-scoped
  subvolume look like a service-scoped one.
- **No service-scoped `/tmp`.** A service that wants a scratch directory
  declares a `bulk` volume (`spec` §8.1) and that is unchanged.
- **No change to the `root` configuration's own ladder.** `@`'s ladder is
  `soil storage`'s business and is untouched by this change.
- **No change to the dracut conversion hook's mechanics.** It converts the
  filesystem offline and patches `/`'s fstab line for the flat boot
  (`guarden-convert-hook.sh:87-100`); `@tmp` is a userspace-stage concern,
  created after the conversion, exactly as `@var` is.

## What "done" is

- A fresh, unconverted VM reaches `soil storage --check` exit 0 with `/`, `/var`
  **and `/tmp`** on `@`, `@var` and `@tmp`, the third at the btrfs **top level**.
- `/tmp` holds no snapper configuration and no ladder governs it.
- A `root` snapshot does not contain what was written to `/tmp` (measurement 2).
- The mount options on `/tmp` are the ones the ticket decided (D1, D2), and the
  mode is `1777`.
- The suite that measures these is **RED before the change and GREEN after** —
  and the RED is shown, because a suite that passes before the fix is not
  measuring the defect. Reverting the source change alone must turn it red
  again.
- The documents say what the code does, and the stale `root`/`home` claim in
  §8.1 is not copied into the new text.
- The golden rebuild is named as a separate act, with the suites it will unblock.