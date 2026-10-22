# 359 — `ensure_accounts` asserts no post-condition, so a half-created account dies as a bare `useradd` exit code

**Found by** the rebase verification of ticket 307f. `tests/t457-tunnel-edge-host.sh` died on
its **first line**:

    useradd: user 'guarden' already exists
    error: failed at line 568: useradd --system --no-create-home --shell /usr/sbin/nologin --gid guarden guarden (exit 9)

`tests/lib.sh` guards each `useradd` with `id -u`, so the add ran only because `id` said the
account was absent — while `useradd` said the name was taken. The suite was not at fault, and
neither was the branch it ran on: **the helper reported a machine's inconsistency as a bare exit
code from the account tool**, which reads as a defect in whatever ran next.

It is also the only helper in `lib.sh` that asserts nothing. `purge`, two hundred lines up, checks
every promise it makes — each name in each place a service of that name lives — and this one
checked none of its two.

## Measured

On a cut from `guarden-golden/base`, as root, `tests/lib.sh` sourced in the same shell (a command
substitution is a subshell and loses the functions — measured: `rc=127`, `_ensure_account: command
not found`).

The inconsistent state was reproduced with a `PATH` shim: `id` failing for `guarden`, `useradd`
exiting 9 with the real message.

| | accounts made | code | what it said |
| --- | --- | --- | --- |
| **A** healthy machine, `develop` @ `ba08b5b` | `guarden` uid 999 `nologin`, `operator` uid 1001 `bash` | 0 | — |
| **A** second call (idempotent) | unchanged | 0 | — |
| **B** name taken, `id` blind — **this branch** | none | **1** | `error: ensure_accounts: cannot create the 'guarden' account — its name is taken but 'id -u guarden' cannot resolve it` |
| **C** same state, **old code** | none | **9** | `useradd: user 'guarden' already exists` |

C is the shape the ticket is about: the exit code is the tool's, the message names no helper and no
account, and a suite that dies there looks like a suite with a bug. B cannot fix a machine whose
account is half-created — nothing here can — but it says which account, in which helper, and what
the machine did, at the line where it happened.

## Why it is not 307f's defect

Four things were ruled out before this ticket was written:

- a fresh cut from `base` has the **group** `guarden` (gid 986) and **no user**, and the exact
  guard-then-add sequence returns **0** there;
- after a successful add `id -u` returns 999 and a second `useradd` returns 9 — so NSS on a cut is
  sound and the guard does work;
- `purge()`, which `t457` runs one line before `ensure_accounts`, deletes only the two service
  users and never `guarden`;
- re-running `t457` alone on a fresh runner was **green**, with its measurements printed
  (`SERVICE_UID_LOOKUP DENY=0->0 ACCEPT=0->2`, `NON_SERVICE_UID_LOOKUP DENY=0->4`).

So the run met a machine in an inconsistent state. What this ticket changes is that the next such
meeting is diagnosable.

## The change

`_ensure_account <name> <group> [useradd args]` — one helper for both accounts, which:

1. creates the group if absent, as before;
2. returns immediately if `id -u` resolves the account;
3. runs `useradd` with **the caller's** flags — `guarden` is a system account with no home,
   `operator` is a login account with one, and a helper that decided either would be wrong about
   the other (a first draft of this patch hardcoded `--system --no-create-home` for both and
   would have made `operator` a system account with no home);
4. if `useradd` fails, checks `id -u` once more and, if the account is still not there, prints the
   named failure above and returns 1.

`ensure_accounts` keeps both accounts in the same order and with the same flags as before.

## What this does not do

It does not repair a machine. An account whose name is taken and whose passwd entry `id` cannot
resolve is a broken machine, and a test helper that quietly rebuilt one could hide a contaminating
suite. It names the state and stops.
