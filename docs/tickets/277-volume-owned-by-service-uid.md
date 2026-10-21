# 277 — a volume is owned by the service uid, but the container may run as another

Blockers: none. Found 2026-10-14 deploying RustFS.

**Status: SUPERSEDED by ADR-0019 (2026-10-18), and the residue it left behind
is fixed here.** The ticket's premise was right and its two remedies are both
wrong under the decision that replaced them. What this ticket now carries is the
record of that, and the three defects the superseded rule left in the tree.

## What happens

guarden creates a service's volumes owned by the **service user** (uid 992 for
`rustfs-production`). A container that runs as **its own non-root uid** cannot
write them, and the failure is a bare `Permission denied (os error 13)` from the
application, which names nothing.

Measured with `docker.io/rustfs/rustfs:latest`, which runs as **uid 10001**:

```
$ podman run -v .../state/data:/data rustfs/rustfs
[FATAL] Server runtime failed: Io error: Permission denied (os error 13)
```

The host directory is `drwx------ 992 992`; inside the container's user namespace
that is `65534 65534` (nobody), so uid 10001 cannot touch it.

## Why the obvious fix is wrong

`chown 10001:10001` on the host does **not** work: the service's subuid range is
`/etc/subuid:rustfs-production:296608:65536`, so container uid 10001 is host uid
`296608 + 10001 - 1 = 306608`. A host-level `chown 10001` maps to *nobody* in the
container — measured: the container then saw `/data` as `65534` and still could
not write. The ownership has to be set through the namespace:

```
podman unshare chown -R 10001:10001 <volume>     # run as the service user
```

after which the container sees `10001 10001` and writes both `/data` and `/logs`.

## Why BOTH remedies are now wrong — ADR-0019

ADR-0019 (`docs/adr/0019-container-uid-ownership-keep-id.md`, accepted
2026-10-18, merged `d9f48e0`) decided the **opposite** of what this ticket
proposed, and it is the binding decision:

> guarden probes the image's user at first start and renders
> `UserNS=keep-id:uid=<image uid>,gid=<image gid>`, which **maps the image's uid
> ONTO THE SERVICE IDENTITY**.

Under that pin the container's uid 10001 **is** the service user on the host
filesystem. The 0700 service-owned volume is writable — with the volume owned by
the service uid, exactly as the create path already does it, and with no chown
anywhere. `tests/t350-keepid.sh` measures this end to end, and says in its own
header: *"Ticket 277's `Permission denied` is the failure this replaces."*

**So the create path must NOT change**, and neither remedy below may be
implemented:

- **The namespace chown** (`podman unshare chown -R <image uid>:<image uid>
  <volume>`) moves the tree onto a uid the container does not own under the pin
  — the image's uid lands in the service's **subuid band** — and the container
  loses the write it had. On a `state` volume it is worse: the walk reaches
  snapper's root-owned `.snapshots` and fails, **having already moved the
  volume's own owner**, so a command that reports failure leaves a broken
  deployment behind it. Measured, below.
- **A manifest field** (`owner: 10001`) and **reading `Config.User` at ingest**
  would put the volume's owner on a uid the pin maps into the subuid band, which
  is the same defect by another route — and the first of them would also be a
  repository naming a host uid, which is the request/grant split the spec
  refuses (§7.7).

The escape hatch for a volume genuinely shared by two image uids is **ADR-0021**:
`overrides.toml` gains `[ownership] volumes = { "<vol>" = <uid> }` as an ADMIN
grant. That is decided and **not yet implemented** (ticket 308's item 2), and
the spec's §3.3 now says so where an operator reads it.

## The residue, and what was fixed

The superseded rule was still in the tree in three places, and each is a defect
in its own right:

1. **`docs/sysadmin.md` told the operator to run the destructive step.** It is
   now a "do not chown a volume to the image's uid" note that names the hazard
   and points at the pin instead.
2. **`docs/spec.md` §3.3 documented `[ownership]` as a present table.** The
   program has no such table and `overrides.load()` refuses the key by name, so
   a file carrying the table the spec documents was **refused with exit 1**. The
   spec now says the table is decided-and-unimplemented and that the answer to
   "a volume is owned by the service uid and the container runs as another" is
   the pin — and the table is **out of the copy-paste sample**, because a sample
   an operator copies is not the place for a table the program refuses. The
   refusal itself is measured by the suite rather than asserted.
3. **`src/guarden/overrides.py` said "Five tables and nothing else" and "not
   one of the eight"** — there are six (`[expose]` is the sixth). The same count
   was off by one in ADR-0021, which called `[ownership]` "a sixth table" two
   paragraphs after stating that six already exist; it is the seventh.

## The measurement

`tests/t277-volume-owner.sh`, on a real cut with a real `useradd`, a real
subuid range, real rootless podman and real systemd. Four claims:

- **the create path's owner** (the decision lock): both volumes are owned by the
  **service uid** before the start and after it, the container writes into the
  `state` volume with no chown anywhere in the file, and the file lands on the
  host owned by the service uid. **The volume's owner must NOT become the
  image's uid** — a later implementer must not "fix" this ticket by doing that.
- **what the runbook's step costs**, on both kinds of volume: on a `bulk` volume
  the chown completes, the tree ends up owned by the **subuid-aliased** host uid
  (`subuid_base + image_uid - 1`, read from the host's own `/etc/subuid`), and
  the container's write is **refused**; on a `state` volume the chown **fails**
  on `.snapshots` and the volume's own owner has **already moved**.
- **the tree does not prescribe it any more**: a grep over the standing
  documents and the programs for the step, the same shape as t350's
  refuted-claims block.
- **the spec's `[ownership]` sentence is true of the program**: a file carrying
  the table §3.3 records is written, and `weedr expose set` — the cheapest
  reader of `overrides.toml` — refuses it by name with exit `1`. The day ticket
  308's item 2 lands, that section fails "expected exit 1, got 0" and says both
  documents have to stop calling the table unimplemented in the same change.

## The same class, third instance

This is the third face of one problem in this deploy (272's siblings 273 and
274): a container's *runtime* assumptions about a path guarden provides
(ownership, a writable subdirectory, a mounted subdir rather than the volume
root) are not modelled, and each one surfaces as an application-level error.
`/data` and `/logs` both had to be pre-created and owned; the image expects both
to exist.

**Ownership was the face ADR-0019 closed; the other two are 273 (ADR-0020, the
`.snapshots` subtree) and 325 (the image's own data-directory convention).**

## Found while verifying this ticket — and filed, not fixed here

`tests/t480-doc-claims.sh:96` forbids the phase order that `docs/sysadmin.md`
has stated since 2026-09-29, and the suite's own comment says that order is the
right one; it is a stale assertion left behind by ticket 310's correction. It
has never been caught because `assert_file_lacks` in `tests/lib.sh` **cannot
fail on a large file**: it pipes `printf` into `grep -q` under `pipefail`, and
`grep -q`'s early exit kills the producer with SIGPIPE, so the pipeline answers
`141` and the assertion silently passes. Measured in this session: the same
assertion is `FAIL` on this branch and `ok` twice on `develop`, and a copy of
`develop` carrying a diagnostic printed the matching line *and* the `ok`.

That is a gate-integrity defect, not this ticket's subject — it is filed on the
board (card `t_1732cca7`) with the reproduction, because fixing the helper is a
*tightening* that may turn other suites red for reasons nobody has measured and
needs its own gate. **Nothing in this ticket's tree rests on it**: the suite's
one `assert_file_lacks` is over a small unit file that fits the pipe buffer.

