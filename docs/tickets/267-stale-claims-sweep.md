# 267: the stale-claim sweep

**Blocked by:** nothing. **Blocks:** nothing.

Three read-only audits on 2026-10-12 walked `tests/`, `src/guarden/` and
`modules/` for comments, docstrings and headers that assert what the code, a
later commit or the spec contradicts. Each finding below was checked against
the tree and the git history. The fix is in every case a rewrite of the claim
— and in one case the assertion the claim was standing in for. One finding
(the `tests/t50-slice.sh` "cause is NOT measured" block) is corrected with the
edge-group work in `t-263` (`ab2082e`), not here.

## tests/

- `t120-queue.sh:110–118` — "The request was carried out, so it is not on
  disk … with guarden installed the deploy succeeds" contradicts the run
  twelve lines below (`assert_exit 1`, `assert_file_exists`, 124–127) and
  every other production deploy in the file (87, 124, 175 all refuse). Two
  adjacent comment blocks currently claim opposite outcomes for the same
  run; rewrite as one comment for the refusal case.
- `t20-firewall.sh:2–3` — the header sells "the timer that gets an operator
  back in"; the timer is gone (545f7ed, "The dead-man timer is gone") and the
  body asserts its absence (`160–161`). Header sentence to be deleted.
- `t80-edges.sh:193–197` and the fail message at `209` — "KNOWN DIVERGENCE …
  spec 7.6 puts `-o lo` on every accept" is stale: the spec was rewritten
  (028c4db; spec.md:2171–2177) to say there is no interface match and there
  never was. The assertion is right; its label and fail message still present
  the divergence as unreconciled.
- `t160-grants.sh:288–291` — a comment justifying a missing assertion with
  "relay-staging still holds 8333/tcp", a premise the file refutes at 235–240
  (`assert_exit 1`, `assert_file_lacks 8333/tcp`) and contradicts at 232–234.
- `t90-gitops.sh:346–347` — "Both halves of the mode claim … are asserted …
  below" — the only surviving-tree mode assertion is above it (326) and no
  `0644` assertion exists anywhere in the file. 0064c9a's own message says
  the `0644` half was asserted nowhere at all.
- `t70-snapshot.sh:220–223` — "`--all` has run twice since the count of
  three" — the run at 175 is a refused plain `snapshot`; the figures below
  (4/2) need exactly one effective `--all` since 164. Miswritten at birth
  (319ee2f); rewrite to name the one run.

## src/guarden/

- `lineage.py:410` — the `_swap` docstring "…clone, record, start — and put
  it all back on error" is stale since 1dd6a03 removed the `start_units` call
  from `_swap`; only `_undo` starts. Same at `:654` ("A stop, a swap and a
  start") for `rollback`, which runs through `_swap`.
- `report.py:4–6` — "every one of the fourteen fields" — the object carries
  sixteen since `route_hosts` (6d36a00) and `route_destinations` (120a9e6),
  neither in the closed table the sentence defends (spec.md:73–79).
- `hostprep.py:1485` — "Nothing else reads it" — `firewall.installed()` reads
  every root-owned `*.conf` including it (firewall.py:448–469), added by the
  same commit (8c78126) that wrote the claim.
- `hostprep.py:1487` — "(which are root:guarden 0644)" — the convention is
  `0640` since 8c78126 (`hosttool.py:40`; spec.md:248).
- `zram.py:456–459` — the hot-remove comment describes the pre-caa414d world:
  `_gone()` is `not present()` and `present()` is `disksize() > 0` by design,
  so a refused hot-remove does not "stay drift".
- `firewall.py:346–347` — "the three files are disjoint and each has exactly
  one writer" — the directory holds five by design since 8c78126
  (`00-ssh.conf`, seed-once; `30-admin.conf`, admin-edited). True of the
  three it names; reads as un-updated.
- `credentials.py:29` (repeated `:184`, `weedr.py:80`) — "the only place in
  guarden that decrypts a blob" — `credentials.value()` decrypts too
  (`:86–116`) and is called by the gate (gate.py:59) and edges (edges.py:197).

## modules/

- `tendril/tendril-production/.guarden/service.yml:18` — **not a comment
  defect**: `schema: .env.schema` resolves under the service root instead of
  `.guarden/` (render.py:810 joins against the module dir), the file is not
  there, `secretschema.read` returns an empty schema for a missing file — and
  the container's `Secret=` is an owned key, stripped and re-emitted only from
  the schema (render.py:78), so the rendered unit requests no credential at
  all. Every other manifest spells `.guarden/.env.schema`. Fix with the
  credential item in ticket 220; an assertion on the rendered unit's
  `Secret=` belongs with it.
- `tendril/tendril-production/.guarden/.env.schema:9–13` — the key and its
  annotations are plain lines; `secretschema` reads comment lines only
  (`:108–111`), so the schema declares nothing even once the path is fixed.
  Comment-prefix them, per `fixtures/projects/quadlet-app/.guarden/.env.schema`.
- `tendril/module.toml:15–16` — "touches no other module" — `_install_module`
  runs `_edge_group` and `_edge_directory` for every module (weedr.py:837–843,
  963–981); spec §7.5 and ADR-0008 attribute both to the gate module alone.
- `auth/auth-production/.guarden/quadlet/auth.container:12–15` — "it is the
  same string `roots` puts in the middleware definition" — the strings differ
  by design; t150 asserts the middleware address and asserts the file lacks
  `127.0.0.1` (tests/t150-auth.sh:140–141), while the container's own address
  is `http://127.0.0.1:9000/verify`.
- `auth/auth-production/.guarden/service.yml:13–14` — "the renderer refuses
  the rule on the provider's own route whatever the manifest says" — nothing
  refuses; the slice keeps `auth = true` (render.py:1160) and `roots`
  withholds the middleware (`roots.py:94–95`).
- `auth/module.toml:6–7` — "in a gated track because its credentials are the
  ones worth gating" — the module ships no credentials and the gate blocks
  only on declared keys; ticket 150 carries the item open. Rewrite the
  rationale or wait for 150.
- `homepage/module.toml:18` — "`api = false`" — the file has no `api` key
  (absence is the value; tests/t100-homepage.sh:56 asserts the key's
  absence).

## Checked clean

`lib.sh:372`'s line reference, the t40-untrusted / t20-firewall /
t150-ssh-accept / t170-zram / t60-gate / t130-alias historical notes, the gate
unit's lowercase-entrypoints block, and the shipped `[modules] enabled`
claims all verified against current code and history. The audit was not
exhaustive: `t30`, `t100`, `t110`, `t20-podlet`, `t210`, `t221`, `t90-projects`
were grepped for the target patterns but not fully read.
