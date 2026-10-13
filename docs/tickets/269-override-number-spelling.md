# 269: quoted numbers in configuration — resolved as strict

**Status:** resolved 2026-10-13. The rule: **a number is a TOML number.** A quoted
`"0.20"` is a string — a different type — and is refused rather than coerced, in every reader,
by both the create path and the converge. TOML's types are distinct and its standard defines no
conversion between them; Rust's serde, the reference behaviour for typed configuration, refuses a
string where a number is required. guarden does the same.

The decision came from the operator, who was asked to choose between widening the override reader
and narrowing the row reader: *"align with toml standards. If toml has no standard, use rustlang
standards."* TOML has none to align with, so the Rust behaviour decided it — the strict side.

## What was wrong

`overrides.toml`'s `[retention] free_limit` was read by `overrides._float`, which refuses any value
that is not an `int` or a `float` — so `free_limit = "0.08"` was rejected by `weedr service ingest`
at the moment a service was created. A `[[environments]]` row's `free_limit` was read by
`config.float_value`, which **accepted** the quoted form, because the shipped template wrote
`"0.20"` on two of its three rows. One admin-facing file accepted two spellings of a number and
the other accepted one, and nothing stated which was right. The converge path
(`hostprep._retention_for`) read its values loosely besides — `int()`/`float()` on whatever the
file held — so a quoted value could pass the converge while the create path refused it.

## What was changed

- **The template and every fixture** spell `free_limit` as a TOML float; the quoted rows are gone
  tree-wide (sixteen files across `src/guarden/templates`, `fixtures/`, `docs/spec.md`, `README.md`
  and the suites).
- **`config.float_value` refuses a string** — `isinstance(value, (int, float))` or a named
  type error, no coercion branch. `config.int_value` (public now, the sibling for integer keys)
  does the same for `keep_last`, `weight`, the ladder buckets and `build.lanes`.
- **`hostprep._retention_for` reads through those strict readers** for the row and the override
  alike, so the converge and the create path cannot disagree about what a number is.
- **The refusal is pinned on both readers**: `t30-config.sh` stages `fixtures/guarden-badfree.toml`
  — the shipped table with staging's floor written as a string, the create path's refusal — and
  `t20-storage.sh` closes with the same row under a registered service for the converge path,
  `soil storage --check` exiting 1 and naming `free_limit`.
- **The spec states the rule** (§3.1's comment and §8.1's `FREE_LIMIT` row): a TOML number and
  only a number, refused rather than coerced, so the same value cannot be spelled two ways by two
  programs.

## The upgrade consequence

A host whose `guarden.toml` was seeded by the old template carries quoted staging and preview
rows. From this change on, `weedr service ingest` and `soil storage` refuse them with the key
named (exit 1) until the operator unquotes them — which is the decision working as designed, not
a regression: the quoted form was always a second spelling of the same number, and it is the
spelling the strict rule retires.

## The history

Found by the review of `c5f74b5` as an asymmetry, recorded here by `0d23f92`, its spec
self-contradiction fixed by `37bddc1`, and closed strict by the operator's TOML/Rust decision.
