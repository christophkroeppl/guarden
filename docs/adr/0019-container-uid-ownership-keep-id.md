# Container uid vs host ownership: map the image user onto the service identity, never chown

guarden's isolation boundary is one host uid per service and its 0700 tree, but a rootless
container's non-root image user maps into the service's subuid band, so image-uid writes are
denied on entry and, if allowed, would land on disk as subuid-aliased owners. We decided that
guarden probes the image's user at a start that has no probed answer yet — the first start of
a service, and every start after a build re-tags the image the answer was read from — and
renders `Userns=keep-id:uid=...,gid=...` into the unit itself — moving the process's mapping
onto the service identity — instead of ever chowning files. Operator decision locked
2026-10-18 after a measured option review; this ADR amends the spec's refusal of `Userns=` for
guarden-generated lines (repository-supplied `Userns` stays refused) — the spec was amended
alongside it (7bc9715), so it no longer refuses the directive at all.

## Status

accepted (2026-10-18, operator) — implemented on branch `feat/keep-id-uid` and merged into
`develop` as d9f48e0; amended by 3abc671 and 1fb02de, and amended again by the round-3
series 7156644…84209f0 — every finding of the third adversarial review closed: the 4242 pid-1
row re-measured on a container started under that pin, the two refuted prose claims out of the
tree, the owner keys refusing every other TOML scalar whole, the renderer answering per
image, a rebuild invalidating the pair it re-tags, and both handoff seams — and then by the
round-4 series, which closed the two findings that blocked the merge (a passwd row with a
uid and no gid was an `IndexError` out of the probe, and the exec-form `user:group` handoff
was skipped and the probe settled on root in silence) and corrected this document's four
overstatements of the tree. The tests are t350-keepid / t351-keepid-diagnostics /
t352-keepid-boundaries — the pid-1 readings that settle what a pin decides are asserted in
the last two and in t350. This file records the DECISION and what it costs; the commit
series is the history, and this Status names the series rather than counting the commits
in it.

**Amended 2026-10-19 (operator): the pin is a DROP-IN, not a line in the base unit.**
The line this ADR describes is now carried by
`/etc/containers/systemd/users/<uid>/<unit>.container.d/50-guarden-keepid.conf`, and the
base unit carries no `UserNS=` line at all. The three files and their three writers are
the model, and the reasons are measured (`probe-quadlet-dropins.md`, podman 5.7.0):

**Superseded in part by ADR-0026 (2026-10-22): the pin is the POD's.**
A container in a pod cannot carry a `UserNS=` of its own (podman refuses `--userns` with
`--pod`), so the file is now `<pod>.pod.d/50-guarden-keepid.conf` and there is exactly one
per pod. Everything below about the drop-in model — the base unit carrying no line, the
admin's `90-admin.conf` winning by name order, the generator reading the file as the
service user — is unchanged.

- **The base unit carries no line** because the renderer's own merge of the admin path
  and the generator's merge of the drop-in directory are two different merges — a base
  unit that carried the line would carry it twice over, and a key with two of them has
  two writers.
- **The pin is in the drop-in** because that directory is searched AFTER the home's own,
  so a regeneration of the unit cannot disturb the pin; and because drop-ins merge **in
  alphabetical order by filename** — not by mtime, not by directory of origin — so the
  alphabetically LAST file's value of a scalar key is the one in force. A drop-in in the
  system path IS picked up for a base unit in the home (probe row 8).
- **The admin's `90-admin.conf` is the human's file**, and it wins by that same order.
  Guarden writes exactly one file in that directory, never writes `90-admin.conf`, and
  never deletes it — not on a re-render, and not on a removal of the service, which takes
  guarden's own file and leaves the admin's where it is. The admin's slot BYPASSES the
  refusal of a repository's own `Userns=` (that refusal is about repository input), it is
  not the record and does not become one, and a change to it takes effect only after a
  daemon-reload.

The re-render trigger moved with it: it reads the drop-in guarden owns, not the base unit,
because a base unit that holds no line would answer "no line" on every start and reinstall
the units for ever. The measured facts the probe produced are the ones the model rests on,
and they are recorded where the spec states the model (§6.3) and where the admin reads it
(docs/sysadmin.md).

## Considered Options

All options were evaluated against the standing constraints: do not change uid/gid inside
containers, keep the service uid + 0700 tree as the isolation boundary, no major platform
changes for a deployment. Measurements were taken on the live boxes (podman 5.7.0, kernel
6.9.3): default map is container 0 -> service uid, container 1..65536 -> subuid band
(aliases measured 306608 for uid 10001, 1017603 for uid 100); `keep-id:uid=70,gid=21`
delivered WRITE_OK into a 994-owned 0700 dir with files landing owned by the service user.

- **A1 manual namespace chown (rejected).** What the Q27 redeploy actually needed: 12 manual
  steps per stack, subuid arithmetic in the runbook, and a re-ingest re-chowns `state/*` back
  and re-breaks a working deployment.
- **A2 whole-volume automatic chown (rejected).** Automates A1's constant: still moves file
  ownership forever, one owner per volume cannot serve two image uids, and drift checks would
  chase it.
- **A3 subdir-scoped chown (kept as the fallback).** Chown only the manifest-declared writable
  subdir, skipping `.snapshots/` (ticket 273's rule). Smallest wound, still a wound; sanctioned
  for images whose entrypoint misbehaves under keep-id, together with a per-service owner
  override as the manual escape hatch.
- **B1 keep-id generated by guarden (DECIDED).** Probe the image's user at first start, render
  one quadlet line **per unit, from that unit's own image** (a service whose units name two
  images is probed twice and renders two lines), record the probed uid/gid in the registry. No
  file is ever touched, the
  image's USER is untouched, re-ingest has nothing to re-chown, and a shared volume works
  because each unit maps its own user onto the same service identity.
- **B2 User=0 (rejected).** The default map already makes container root the service user, but
  it overrides the image's declared uid — forbidden by constraint — and images that drop
  privileges fall back into the subuid band anyway.
- **B3 pin the service's uid to the image's uid (rejected).** Agreement by construction, but
  the uid must be known at user creation, images rebase across versions, and host uid
  allocation becomes image-dependent.
- **C1 idmapped mounts (ruled out 2026-10-18).** Cleanest in theory (kernel translates at the
  VFS boundary, nothing moves), but disqualified three ways: (a) LSM hooks do not receive
  mount idmaps (LWN 1092727, series only entering v7.4) and CVE-2026-64294 sits in exactly
  these ownership checks with stable fixes at 6.6.144+/6.12.95+ while this host runs EOL
  6.9.3; (b) our dedicated probe returned **UNSUPPORTED** — rootless podman accepts the
  `:idmap` syntax but never creates the idmapped mount (zero `mount_setattr` syscalls,
  byte-identical results with and without the flag); (c) two adversarial reviews reproduced
  it independently and podman's own docs say the option is "only supported in rootful mode"
  (kernel CAP_SYS_ADMIN rule). No kernel upgrade revives it; a rootful podman per service
  would abandon the service-uid model. Report: probe-idmap-capability.md; the probe-idmap VM
  is kept for any future re-run.
- **C2 POSIX ACLs (rejected as-is).** Keeps ownership at 994 and grants the alias
  entry-by-entry, but guarden has no ACL layer (create, drift, snapshot preservation, docs),
  `ls` hides the guest list, the tree's owner can always alter its own ACLs, and the
  ownership walk's `chmod 0700` flattens the ACL mask (measured) — new surface without new
  assurance. One capability note for the fallback design: ACLs are the only mechanism that
  can grant TWO image uids one shared volume, and btrfs snapshots preserve ACLs (measured).
- **C3 classic group permissions (rejected).** One group slot per door loses on shared
  volumes; the operator declined it.
- **D restructure writes to service-owned paths / tmpfs (rejected).** Per-application work
  that does not generalize.

## Consequences

- The unit gains a guarden-generated keep-id line rendered after the first probe — quadlet
  documents the key as `UserNS=`, guarden emits that spelling, the repository-input refusal
  accepts both spellings, and this prose keeps `Userns=` — one directive. The probe is
  entrypoint-aware by **one table**, and every `Config.User` shape takes exactly one row of
  it: empty, `0` and `root` are one declaration (container root) and are answered by the
  image's gosu/su-exec handoff target when the entrypoint names one (asked of every word of
  `Entrypoint`/`Cmd` — a bare `gosu`/`su-exec` element takes the word after it, exec form
  included, and the word may carry a `user:group` spec, which is the spelling the stock
  postgres image uses — and of every `.sh` script any of those words names, at whatever
  position it sits; a word naming a script that does not end in `.sh` is not read), and
  by nothing — **no line**, the default mapping — when it does not; a non-root number or
  name is resolved
  against the image's own `/etc/passwd` and `/etc/group`, where a field that is not a
  decimal number — or a field the row does not carry at all — is refused the way a user
  the image does not carry is (spec 1.2: one line, exit `2`). The
  table decides the RECORD; what each of the three root spellings then RUNS as under the line
  is measured per spelling below, and they do not all run the same way. An
  image that reaches no user at all is the no-self-heal class, a documented gap left to the
  A3 fallback or a future manifest runtime-uid field — not invented here. The table names
  `gosu` and `su-exec` and no other privilege-dropping tool: a wrapper that drops
  privileges with `setpriv`, `runuser` or `chroot --userspec` reaches no user here, and
  is the same no-self-heal class.
- The registry records `owner_uid`/`owner_gid` (ticket 277's drift anchor) plus `owner_image`,
  the image that pair was read from — and, **for a service whose units name more than one
  image, a per-unit `owner_units` map** of image/uid/gid. A single-image service's document
  keeps the shape it always had: the scalar pair and no table. **The table grows when the
  units name more than one image** — two units on one image never grow it, and two units on
  two images grow it whether or not the two images declare the same user — and the renderer
  answers **each unit from its own entry**, so each unit
  maps its own image's user onto the same service identity and no image's uid is ever taken up
  by another container (each unit runs what its own image puts on pid 1 — or, where the image
  names no user, its own pin — and either way the pin decides where that uid
  lands — measured, t350/t351/t352). A unit the
  record does not answer renders no line and is the probe's condition again at the next start,
  never another unit's pin — except for a record that carries no `owner_image` at all, the
  shape written before that field existed, which answers every unit with its one pair, because
  there is no image to disagree with — and the renderer asks that per unit AND per image, the
  reference the unit names resolved the way the probe resolves it, so a deploy that renders
  a unit whose `Image=` changed writes no line rather than the pair read from another image
  (round 3, measured t350). Re-ingest can no longer break ownership because nothing chowns.
- **A rebuild invalidates the pair.** `owner_image` records the REFERENCE and `weedr service
  build` re-tags it, so the reference is not an anchor: after a successful build the
  record's answer for that reference is cleared — the scalar anchor whole (uid, gid and
  `owner_image` are one answer), a per-unit entry only for the image it names — under the
  registry lock, and the next start probes what the units name (measured, t350: the rebuilt
  fixture declares `USER 10002` and the record and the unit come back as 10002). Before
  this, a rebuilt Containerfile that changed `USER` kept the old pin: the container ran the
  new image user, the line mapped the old pair, and those writes landed in the subuid band
  with the record and this ADR's "an image that changed is the probe's condition again" both
  claiming otherwise. **The invalidation is one-sided: it clears the RECORD, not the
  installed pin.** The drop-in guarden owns keeps the line it was written with until
  something re-writes it, and what re-writes it is `weedr service start` — the start path
  re-renders whenever that file does not hold exactly what the record renders for the
  unit. A unit started by anything else — a systemd `Restart=`, an operator's own
  `systemctl --user start` — comes up under the OLD pin with the NEW image, and nothing
  says so, because the record holds no answer and nothing contradicts the pin.
  `weedr service start` is the supported
  way to start a service and it re-renders first; the gap is between a rebuild and a start
  through any other door, and it is stated here rather than closed, because closing it
  means the build verb writing into the drop-in directory, which is root-owned and would
  need a lock the build does not hold. What this does NOT
  cover is an image replaced outside that verb — a hand `podman pull` under the same tag,
  a hand `podman build --tag` under it, or a per-container `Containerfile` layout the build
  verb does not read at all (it looks only at the home's own `Containerfile`/`Dockerfile`,
  so a tree with `.guarden/images/<container>/Containerfile` is never built and its image
  is never invalidated) — which a reference anchor cannot see and an image-ID anchor would:
  the deliberate trade, recorded here rather than in a comment.
- While a pin renders, a repository-supplied `User=` is refused (it would run the container
  outside the mapping the line exists to create: the line puts exactly the pinned pair on the
  service identity, and a `User=` that names anything else runs where it maps nothing — spec
  §6.3's own words, and the refusal's whole rationale, which stands whether or not the pin
  also picks pid 1: it does where the image names no `USER` (t351) and it does not where the
  image names one (t352)); `UserNS=`/`Userns=` from repositories stay refused. Spec
  §6.3/§6.6 amended
  (7bc9715). AGENTS.md's copy of the refusal list is brought up to the spec's — it had
  gained `Userns=`/`UserNS=` in the spec and not here, and AGENTS.md's own rule ("one
  canonical statement per rule … grep for it") is the rule that applies; there is no rule in
  this repository that protects AGENTS.md from an edit, and the file has been edited on this
  lineage (130db5f).
- The root-then-drop class is now MEASURED **per spelling**, not open, and the spellings do not
  all behave the same at run time. Who pid 1 is, read off `/proc/1/status` under the rendered
  line on podman 5.7.0, and every row of this list asserted:
  an image that names a `USER` runs it — `USER root` → pid 1 = 0 under
  `keep-id:uid=3000,gid=3000` (t352), `USER 0` → pid 1 = 0 under the same pin (t352), and
  `USER 10001` → pid 1 = 10001 while the record pins 4242 (t350: read after a stop and a
  start under that pin, with the container's own uid_map row `4242 0 1` asserted live
  first — a start on an already-active unit does not restart, which is how this row was
  measuring the FIRST pin until round 3 found it) — and an image with **no**
  `USER` line runs the **pinned pair**: pid 1 = 2000 under `keep-id:uid=2000` (t351), the
  discriminating measurement the round-2 review asked for, because every other fixture's image
  user and pinned pair are the same number by construction and cannot tell the two readings
  apart. So the blanket "a pin decides where a uid lands, not who starts" holds for an image
  that names its user and does not hold for one that does not; what holds either way is the
  landing — each uid's host mapping is the pin's, and an image's `USER` is never rewritten.
  The probe's table is untouched: all three spellings still answer the same RECORD question
  (container root, asked of the entrypoint's handoff) — what they do not do is all run the
  same way. Consequences by row: for an image whose declared user is the pair the probe pins
  (t350's shape), init is on that pair and there is no root-start phase: container uid 0 sits
  on the service's first-subuid band, and a second process appending after stop/start writes
  files owned by the service uid (t350). For `USER root` and `USER 0` the entrypoint starts as
  container root and the HANDOFF is what the pinned pair moves onto the service identity;
  anything written before that handoff is the root-start phase, and A3 remains the fallback
  for it. For the empty spelling the pinned pair — which the probe took from that very
  handoff — IS pid 1, so the entrypoint begins after the handoff would have happened, and the
  root-start phase does not exist there.
- Fallback stack: A3 subdir chown with `.snapshots/` skipped, plus a per-service owner
  override for volumes shared by two images — both deferred to the A3 follow-up (the
  overrides contract deliberately has no `[volumes] owner` key: "five tables and nothing
  else").
