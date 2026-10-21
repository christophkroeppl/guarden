# 332 — the `runuser` call sites inherit the caller's environment

Blockers: none. Found 2026-10-20 by the first of the ten security reviews
(`nous/longcat-2.5-preview-free`, F4) — and it is the SAME defect as ticket
321, found independently, so the two are one piece of work.

## What the review says

> **F4 — `runuser` sites that inherit the caller's environment (already ticket
> 321, still unapplied)**
> **LOW-MEDIUM — denial of service, not escalation.** Confirmed still present at
> every podman site the ticket lists.

The review's severity is LOWER than ticket 321's, and the reasoning is worth
keeping: a wrong `USER` gives a container FEWER privileges inside it, not
more, so the defect is a denial of service on the build path rather than a
privilege escalation. The ticket is not closed by that — a build that fails is
a build that fails — but the finding should not be described as an escalation.

## The seven call sites

```
credentials.py:224,227  runuser -u <name> -- podman secret create <key> -  ← unsanitised
edges.py:265            runuser -u <provider> -- podman <argv>             ← unsanitised
service.py:1578         runuser -u <name> -- env USER=… LOGNAME=… XDG_RUNTIME_DIR=… podman   ← THE ONE THAT SCRUBS
units.py:67             runuser -u guarden -- loom …                      ← unsanitised
weedr.py:880            runuser -u <service> -- podman …                   ← unsanitised
weedr.py:1467/1487      runuser -u guarden -- …                           ← unsanitised
```

`runuser -u` **inherits the caller's environment**, and the caller is root.
So every one of the six unsanitised sites inherits root's `XDG_RUNTIME_DIR`
and root's `XDG_DATA_HOME`, and podman's keep-id mapping reads the subid
files keyed by `$USER`.

## CORRECTION (2026-10-20): the premise above was MEASURED FALSE

**This ticket said `runuser -u` "swaps the uid and keeps the caller's
environment", and that every unsanitised site therefore "sees `USER=root`".
Both halves are wrong, and the wrongness was copied into four places in the
tree — this ticket, ticket 321, `service.py`'s docstring and `creator.py`'s.**

**Measured on a cut of the repo's own golden VM** (util-linux 2.41.3,
podman 5.7.0), caller root with `USER=root` and `HOME=/root`:

```
$ runuser -u probe-svc -- env | grep -E '^(HOME|USER|LOGNAME|XDG_RUNTIME_DIR)='
HOME=/var/lib/guarden/services/probe-svc/home
LOGNAME=probe-svc
USER=probe-svc

$ XDG_RUNTIME_DIR=/run/user/0 runuser -u probe-svc -- env
HOME=/var/lib/guarden/services/probe-svc/home
LOGNAME=probe-svc
USER=probe-svc
XDG_RUNTIME_DIR=/run/user/0        <-- INHERITED
```

**`runuser` SETS `HOME`, `USER`, `LOGNAME`, `SHELL` and `PATH` for a non-root
target. It does NOT inherit the caller's `USER`. It inherits everything ELSE
verbatim.** The measurement that produced the refuted claim was **`setpriv`,
not `runuser`** — `tests/t350-keepid.sh:148` actually uses
`setpriv --reuid=`, which genuinely keeps the caller's environment
(`setpriv --reuid=nobody --regid=nogroup --clear-groups env` answers
`HOME=/root` and `USER=root`, measured on the same machine). The comment named
both tools; only `setpriv` behaves the way it described.

**The MECHANISM claim is still right.** Podman's keep-id mapping reads the
subid files keyed by `$USER`, and forcing `USER=root` into podman answers
`cannot find UID/GID for user root: no subuid ranges found for user "root" in
/etc/subuid` — measured. What was wrong is only where the wrong `USER` came
from: it never reached podman through `runuser`.

**What IS genuinely inherited, and what it costs** (all measured, same
machine):

- `XDG_RUNTIME_DIR` = the caller's → `Failed to obtain podman configuration:
  lstat /run/user/0: no such file or directory`.
- `XDG_DATA_HOME` = elsewhere → **the whole podman store moves, INCLUDING the
  secret database** (`containers/storage/secrets/secrets.json` and
  `containers/storage/secrets/filedriver/secretsdata.json`, which hold the
  materialised credential values). The files stay `0600` to the service uid,
  but the DIRECTORY moves out of the service's `0700` home — and
  `credentials.py:190-195` names that `0700` home as the documented limit on
  that secret. **This is the sharpest consequence, and it is why
  `credentials.py:224` and `:227` are the two sites to fix first.**
- `XDG_CONFIG_HOME` / `XDG_CACHE_HOME` → podman reads them.
- `CONTAINERS_STORAGE_CONF` / `CONTAINERS_CONF` → podman fails on the file.
- `DBUS_SESSION_BUS_ADDRESS` → inherited verbatim.
- `PWD` / `OLDPWD` → `cannot chdir to /root: Permission denied` when the
  caller's cwd is unenterable.
- `PATH` → **NOT** a hijack: `runuser` RESETS it to a fixed system default
  (`/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`).

**Reachability, measured.** `sudo -u root` RESETS the environment
(`XDG_RUNTIME_DIR` arrives unset), and a systemd oneshot's environment is only
`PWD=/` and `USER=root` with no `XDG_*` at all — so the credential
materialiser (`guarden-creds-boot.service`, a `Type=oneshot`) is already
clean. **The reachable path is an operator's ROOT SHELL**: `weedr service
build`, and a hand-run `weedr secret materialise`.

## What to build

Give every one of them the account's own `HOME`, `USER`, `LOGNAME`,
`XDG_DATA_HOME` and `XDG_RUNTIME_DIR`, remove the variables that must not be
inherited (`XDG_CONFIG_HOME`, `XDG_CACHE_HOME`, `DBUS_SESSION_BUS_ADDRESS`,
`CONTAINERS_*`, `PWD`, `OLDPWD`), and make it the ONE place a `runuser -u`
command is built, so a second call site cannot miss it. The paths today are
the same shape written several times, and one of them had a partial fix.

**`XDG_DATA_HOME` is the XDG DATA DIRECTORY, not the home**, and podman puts
its store under `<XDG_DATA_HOME>/containers/storage` — measured on the golden
VM:

```
XDG_DATA_HOME unset   -> <home>/.local/share/containers/storage
XDG_DATA_HOME=<home>  -> <home>/containers/storage
XDG_DATA_HOME=<home>/.local/share
                       -> <home>/.local/share/containers/storage
XDG_DATA_HOME=/tmp/hostile
                       -> /tmp/hostile/containers/storage
```

**So the value that keeps the store where `paths.PODMAN_STORE` already says
it is — `<home>/.local/share/containers` — is `<home>/.local/share`.** Setting
it to the home itself would move the store to `<home>/containers`, which is
not the path `service.py`'s store walk names.

**The manager wait is a separate question and is NOT part of this ticket.**
`/run/user/<uid>` comes up asynchronously after the ingest, and a build that
lands before it dies in the window above. Whether the mutator waits for it,
retries, or names the cause in its own diagnostic is a decision this ticket
does not make.

## The test that would have caught it

A test that runs `weedr service build` and asserts the build container's
`/proc/self/uid_map` contains the service's subuid range. That test is **not
vacuous**: it measures the actual mapping, not the presence of a
configuration value.

**And the test that catches the part that is actually broken** — the
inherited `XDG_DATA_HOME` — asserts the STATE, not a configuration value:
with a hostile `XDG_DATA_HOME` in the caller's environment, the credential
path must still write the secret database inside the service's own `0700`
home, and podman's store must be under the service's home.
