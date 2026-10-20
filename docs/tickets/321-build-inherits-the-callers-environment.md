# 321 — `weedr service build` runs podman with the caller's environment, not the service's

Blockers: none. Found 2026-10-19 while implementing ADR-0019's drop-in model
(t353-dropin-overrides), where a build of a SECOND service in one suite failed
in a way the first service's build did not.

## What happens

`weedr service build` runs the build as the service user:

```python
podman = ["runuser", "-u", resolved.name, "--", "podman", "build", ...]
result = tool.call(podman, cwd=home)
```

`runuser -u` **inherits the caller's environment**, and the caller is root. So
the build's podman sees root's `XDG_RUNTIME_DIR` and root's `XDG_DATA_HOME`,
and the build's containers are placed in the sandbox cgroup of the wrong
session.

The probe path in `service.py` had a partial scrub of its own, and its
docstring gave the reason:

> `runuser -u` swaps the uid but keeps the caller's environment, and the
> caller is root — so podman saw `USER=root`, and its keep-id mapping reads
> the subid files keyed by that name

and it therefore scrubbed:

```python
env = ["env", f"USER={name}", f"LOGNAME={name}"]
if runtime.is_dir():
    env.append(f"XDG_RUNTIME_DIR={runtime}")
```

**That docstring's REASON was wrong — see the correction below — but its
scrub was right, and it was the only one of the seven.** It is corrected in
the same change this ticket lands in, so the copy above is what the tree said
when this ticket was written and the correction section says what it says
now.

**The build verb was never given that scrub.** Two consequences were
observed:

- **A `UserNS`-style mapping built from the wrong key.** The same defect the
  probe's docstring describes, one path over: podman's keep-id mapping reads
  the subid files keyed by `USER`, and a build that inherits `USER=root`
  finds none.
- **A build that dies in the sd-bus/sandbox-cgroup window.** Measured
  verbatim on a cut:

  ```
  error running container: from /usr/bin/crun creating container for
  [/bin/sh -c adduser -D -u 10001 dropuser]: sd-bus call: Access denied as
  the requested operation requires interactive authentication. However,
  interactive authentication has not been enabled by the calling program.:
  Permission denied : exit status 1
  Failed to add pause process to systemd sandbox cgroup: dial unix
  /run/user/994/bus: connect: connection refused
  ```

  The second line names the cause: the build asked the service user's own
  manager for a cgroup and the manager's bus was not there. The build's
  podman was pointed at `/run/user/<uid>` — the right uid — but the manager
  is up only asynchronously after the ingest, so the build can land in the
  window before it is.

**How far this reaches: MEASURED 2026-10-19.** `grep -n "runuser"
src/guarden/*.py` is the inventory, and there are SEVEN real call sites. Only
ONE of them scrubs the environment (service.py:1578, the probe):

```
credentials.py:224  runuser -u <name> -- podman secret rm <key>      ← unsanitised
credentials.py:227  runuser -u <name> -- podman secret create <key> -  ← unsanitised
edges.py:265        runuser -u <provider> -- podman <argv>             ← unsanitised
service.py:1578     runuser -u <name> -- env USER=… LOGNAME=… XDG_RUNTIME_DIR=… podman   ← THE ONE THAT SCRUBS
units.py:67         runuser -u guarden -- loom …                      ← unsanitised
weedr.py:880        runuser -u <service> -- podman …                   ← unsanitised
weedr.py:1467/1487  runuser -u guarden -- …                           ← unsanitised
```

`podman secret create/rm` under the wrong XDG_DATA_HOME reads and writes the
wrong store; `podman` under the wrong XDG_RUNTIME_DIR asks the wrong session's
manager for a cgroup. The build was the one that showed it because a build
actually RUNS a container; the others fail more quietly.

## CORRECTION (2026-10-20): the premise above was MEASURED FALSE

**The ticket said `runuser -u` "swaps the uid and keeps the caller's
environment", and that podman therefore saw `USER=root`. Both halves of that
are wrong, and the wrongness was copied into four places in the tree — this
ticket, ticket 332, `service.py`'s docstring and `creator.py`'s.**

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

## Independently confirmed by an adversarial security review

**`deepseek-v4.1-flash-free` found this on its own**, in the first of the ten
security reviews (prompt: the whole platform, one bounded question). Its F1
is this ticket, stated independently:

> **F1 — MEDIUM: `USER`/`LOGNAME` not set at five `runuser` call sites**
> The other six call sites do **not** set `USER` or `LOGNAME`. They inherit
> root's environment. […] **This is a functional bug, not a direct security
> exploit.** The container still runs as the service user's uid […] A wrong
> subuid mapping means *fewer* privileges inside the container, not more.
> […] **Fix.** Set `USER` and `LOGNAME` at every `runuser` call site that runs
> podman, matching the `_podman` function's pattern.

The review's own severity assessment is **lower than this ticket's**, and the
reasoning is worth keeping: a wrong `USER` gives a container FEWER privileges,
not more, so the defect is a denial of service on the build path rather than
an escalation. The ticket is not closed by that — a build that fails is a
build that fails — but the finding is **not** a privilege escalation and should
not be described as one.

The review also checked the other three properties it was asked about and
found **no critical exploitable vulnerability**: the per-service uid, the
`0700` tree, the subuid band, the capability set, the firewall's default
deny, the credential blob's `0600 root:root`, the request/grant split, and the
`hose` path-traversal guard all hold against the threat model.

## What to build

Give the build the same scrub the probe has — the service's own `HOME`,
`USER`, `LOGNAME`, `XDG_DATA_HOME` and `XDG_RUNTIME_DIR`, and the removal of
the variables that must not be inherited (`XDG_CONFIG_HOME`,
`XDG_CACHE_HOME`, `DBUS_SESSION_BUS_ADDRESS`, `CONTAINERS_*`, `PWD`,
`OLDPWD`) — and make it the ONE place a `runuser -u <service>` command is
built, so a second call site cannot miss it. The paths today are the same
shape written several times, and one of them had a partial fix.

**The manager wait is a separate question and is NOT part of this ticket.**
`/run/user/<uid>` comes up asynchronously after the ingest, and a build that
lands before it dies in the window above. Whether the mutator waits for it,
retries, or names the cause in its own diagnostic is a decision this ticket
does not make — and it is the same premise the keep-id suites already wait
for before their probe (`t350-keepid.sh` waits for `/run/user/<uid>` before
the first container run). What this ticket settles is the ENVIRONMENT.
