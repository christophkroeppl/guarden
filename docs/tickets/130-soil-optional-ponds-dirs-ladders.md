# 130: soil: optional ponds, fixed dir schema, ladder ownership

**What to build:** Default host prep creates no ponds and no pond hyphae: `soil storage --apply` lays down the fixed directory schema only (`/var/lib/guarden/beds/<bed>/` with nested preview `<ref>/` instance dirs, `/var/lib/guarden/ponds/<pond>/`), and pond instances appear only when a pond is dug or when tests create them. Ladder (snapper) config is owned by the subvolume it protects — a pond subvolume's ladder lives with the pond, a bed subvolume's ladder lives with the bed — instead of being baked into soil, and `stakes` can list the ladders as well as query pins. Production- and staging-named ponds exist only in tests as the reference use-case.

**Blocked by:** T40 (soil: btrfs convert + snapper ladders)

**Status:** ready-for-agent

- [ ] `soil storage --apply` on a fresh host creates `/var/lib/guarden/beds/` and `/var/lib/guarden/ponds/` but creates no pond instance, no pond data subvolume, and no pond hyphae names; the call log contains no pond-creation calls
- [ ] A following `soil storage --check` exits 0 (no drift), and a second `--apply` is idempotent
- [ ] The bed directory schema is fixed: `/var/lib/guarden/beds/<bed>/`, with nested `<ref>/` instance directories for preview beds created on demand and removed with the ref
- [ ] A ladder config for a pond subvolume is created by the pond's owner and a ladder config for a bed subvolume by the bed's owner; soil's ladder scope stays root and home
- [ ] `stakes ladders` lists the ladders known to the registry, and a ladder created by a pond or bed owner appears in the list
- [ ] A default host has no pond whose name matches the production- or staging-named reference ponds; those names appear only in golden-VM test fixtures
- [ ] `--check` / `--apply` semantics are unchanged: `--check` exits 1 with the word `drift` when not converged
- [ ] The fast harness asserts on files and the call log; the golden VM exercises the reference ponds as test fixtures and captures an evidence tarball
