"""Running the external tools, in one place.

Every call out of guarden goes through here, so the argv a program built is the
argv that ran and there is exactly one place to look when a fake's call log says
something unexpected.

The mutator runs these as root and the unprivileged programs run their own; a
non-zero exit is the host not being in the state the request assumed, so it is
exit `1` and the diagnostic names the tool. Nothing here is a shell: the tools
are invoked with an argv, never through a shell, and the only strings guarden
interpolates into a command are a system user's own name.

**`runuser_as` is here for the same reason: it is where a `runuser -u` command
is BUILT, and there is one of them.** Seven call sites ran a command as another
account, and each spelled the argv itself, so an environment a second site
forgot was invisible — a grep for `runuser` showed every site and none of them
said what environment the command would land in.
"""

from __future__ import annotations

import logging
import os
import pwd
import subprocess
from dataclasses import dataclass
from pathlib import Path

from guarden import errors, paths

log = logging.getLogger("guarden")


@dataclass(frozen=True)
class Result:
    argv: tuple[str, ...]
    returncode: int
    stdout: str
    stderr: str

    @property
    def ok(self) -> bool:
        return self.returncode == 0


def call(argv: list[str] | tuple[str, ...], stdin: str | None = None,
         cwd: str | Path | None = None) -> Result:
    log.debug("ran: %s", " ".join(argv))
    try:
        finished = subprocess.run(
            list(argv),
            input=stdin,
            capture_output=True,
            text=True,
            # The encoding is named rather than left to the environment: every
            # file guarden reads is read as UTF-8, and a tool's answer that
            # depends on the caller's locale is an answer that changes with it —
            # under `LANG=C` the same valid output would be refused as ASCII.
            encoding="utf-8",
            check=False,
            cwd=cwd,
        )
    except UnicodeDecodeError as exc:
        # A tool's answer is read as text, so bytes no codec accepts are an
        # answer this program cannot have: one line naming the tool, the same
        # refusal `unitsource.parse` makes for a unit file it cannot read, and
        # never a UnicodeDecodeError out of subprocess (spec 1.2).
        raise errors.GuardenError(
            f"{argv[0]} printed output that is not UTF-8: {errors.oneline(str(exc))}"
        ) from None
    return Result(tuple(argv), finished.returncode, finished.stdout, finished.stderr)


def run(argv: list[str] | tuple[str, ...], stdin: str | None = None,
        cwd: str | Path | None = None) -> Result:
    """Run a tool whose success the caller assumes. A failure is exit `1`.

    `stdin` is for the one tool that takes a value on a pipe rather than an
    argument: `systemd-creds encrypt` and `podman secret create`. It is not
    accepted as an argv element, so a value can never become a command-line
    argument that a process list would show.

    `cwd` is for the one call whose child must not inherit this process's working
    directory, and it is a directory the child's own uid can enter — see
    `credentials.materialise`, which is why it exists.
    """
    result = call(argv, stdin=stdin, cwd=cwd)
    if not result.ok:
        detail = result.stderr.strip() or result.stdout.strip()
        raise errors.GuardenError(
            f"{result.argv[0]} exited {result.returncode}" + (f": {detail}" if detail else ""),
            errors.HOST_NOT_AS_ASSUMED,
        )
    return result


def check(argv: list[str] | tuple[str, ...]) -> bool:
    """Run a tool and report whether it worked, for the feature-probe paths.

    `useradd --add-subuids-for-system` needs shadow-utils 4.11 or later, and
    "is this option supported" is answered by running it, not by parsing a
    version string out of a distribution's changelog.
    """
    return call(argv).ok


def lines(result: Result) -> list[str]:
    return [line for line in result.stdout.splitlines() if line.strip()]


def path_argument(value: Path) -> str:
    return str(value)


# --- the `runuser -u` command, and the environment it runs in ----------------
#
# **What `runuser` does to the environment, MEASURED on a cut of the golden VM
# (util-linux 2.41.3, podman 5.7.0), caller root with `USER=root`,
# `HOME=/root`:**
#
# ```
# $ runuser -u probe-svc -- env | grep -E '^(HOME|USER|LOGNAME|SHELL)='
# HOME=/var/lib/guarden/services/probe-svc/home
# LOGNAME=probe-svc
# SHELL=/bin/sh
# USER=probe-svc
#
# $ XDG_RUNTIME_DIR=/run/user/0 runuser -u probe-svc -- env
# ... the four above, unchanged ...
# XDG_RUNTIME_DIR=/run/user/0        <-- INHERITED VERBATIM
# ```
#
# **So `runuser` SETS `HOME`, `USER`, `LOGNAME`, `SHELL` and `PATH` for a
# non-root target, and inherits everything ELSE verbatim.** The repository
# claimed the opposite — "swaps the uid but keeps the caller's environment, and
# the caller is root — so podman saw `USER=root`" — and that claim was copied
# into four places. It was refuted by measurement, and the refutation is
# recorded in `service.py`'s docstring, in `creator.py`'s, in
# `tests/t350-keepid.sh` and in tickets 321 and 332 so that it stops being
# copied.
#
# **The measurement that produced the refuted claim was `setpriv`, not
# `runuser`.** `tests/t350-keepid.sh` scrubs with
# `setpriv --reuid=<svc> --regid=<svc> --clear-groups env …`, and `setpriv`
# genuinely keeps the caller's environment — measured on the same machine:
# `setpriv --reuid=nobody --regid=nogroup --clear-groups env` answers
# `HOME=/root` and `USER=root`. The comment named both tools; only the second
# behaves the way the comment describes.
#
# **The mechanism is still right.** Podman's keep-id mapping reads `/etc/subuid`
# keyed by `$USER`, and forcing `USER=root` into podman answers `cannot find
# UID/GID for user root: no subuid ranges found for user "root" in /etc/subuid`
# — measured. So `USER` is set here, but as defence in depth against a caller
# that reaches podman by another route, NOT as the fix for an inherited
# `USER=root`.
#
# **What is genuinely inherited is what this helper removes.** Measured costs
# of each, same machine:
#
#   * `XDG_RUNTIME_DIR` — the caller's own. Podman answers `Failed to obtain
#     podman configuration: lstat /run/user/0: no such file or directory`.
#   * `XDG_DATA_HOME` — the caller's own. **The podman STORE moves, and with it
#     the secret database**: `containers/storage/secrets/secrets.json` and
#     `containers/storage/secrets/filedriver/secretsdata.json` hold the
#     materialised credential values. The files stay `0600` to the service uid,
#     but the DIRECTORY leaves the service's `0700` home — and
#     `credentials.materialise` names that home as the documented limit on
#     that secret. This is the sharpest consequence, and it is why the two
#     `podman secret` sites are the first to fix.
#   * `XDG_CONFIG_HOME` and `XDG_CACHE_HOME` — podman reads them.
#   * `CONTAINERS_*` — podman fails on the file they name.
#   * `DBUS_SESSION_BUS_ADDRESS` — inherited verbatim, and it points podman at
#     the caller's session bus rather than the service's own manager.
#   * `PWD` and `OLDPWD` — the caller's directory, which a service uid may not
#     be able to enter: `cannot chdir to /root: Permission denied`.
#
# **`PATH` is NOT scrubbed, because `runuser` resets it** to a fixed system
# default (`/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`),
# measured — so there is no `PATH` hijack through this path and pretending
# otherwise would be a claim nobody measured.
#
# **Reachability, measured.** `sudo -u root` RESETS the environment
# (`XDG_RUNTIME_DIR` arrives unset), and a systemd oneshot's environment is
# only `PWD=/` and `USER=root` with no `XDG_*` at all — so the credential
# materialiser (`guarden-creds-boot.service`, a `Type=oneshot`) is already
# clean. **The reachable path is an operator's ROOT SHELL**: `weedr service
# build` and a hand-run `weedr secret materialise`.

# The variables that must be the TARGET's own, and the ones that must not be
# inherited at all. A name in the first set is SET; a name in the second is
# REMOVED. The two sets do not overlap, and a name in neither is left alone —
# which is deliberate: the environment carries more than guarden knows about
# (a locale, a proxy), and a scrub that removed everything would be a policy
# this module has no standing to set.
SCRUB_REMOVE = (
    "XDG_CONFIG_HOME",
    "XDG_CACHE_HOME",
    "DBUS_SESSION_BUS_ADDRESS",
    "CONTAINERS_STORAGE_CONF",
    "CONTAINERS_CONF",
    "CONTAINERS_REGISTRIES_CONF",
    "CONTAINERS_POLICY_JSON",
    "PWD",
    "OLDPWD",
)


def _home_for(account: str) -> Path:
    """The home an account's commands run in.

    **A service's home is its own tree**, `/var/lib/guarden/services/<name>/home`
    (`paths.service_home`), and it is where podman's rootless store lives — the
    `0700` that `credentials.materialise` names as the limit on the
    materialised secret.

    **The `guarden` account is not a service** and has no home under
    `/var/lib/guarden/services`: it is one of the two program users `soil
    install` creates, and `useradd --system --no-create-home` gives it the
    passwd home `/home/guarden` — which `useradd` does NOT create, because
    `--no-create-home` says so. So the `guarden` commands run in the passwd
    home, read out of the machine's own `/etc/passwd`, and that is what this
    returns for it. It is the honest answer rather than a made-up one: the
    account's home is where the account's own files are, and nothing in
    guarden's own tree is that account's home.
    """
    if account == "guarden":
        return Path(_passwd_home(account))
    return paths.service_home(account)


def _data_home(account: str) -> Path:
    """Where podman's store — and the secret database inside it — belongs.

    **`XDG_DATA_HOME` is the XDG DATA DIRECTORY, not the home**, and podman
    puts its store under `<XDG_DATA_HOME>/containers/storage`. Measured on the
    golden VM, with the service's home as the only variable:

    ```
    XDG_DATA_HOME unset   -> <home>/.local/share/containers/storage
    XDG_DATA_HOME=<home>  -> <home>/containers/storage
    XDG_DATA_HOME=<home>/.local/share
                           -> <home>/.local/share/containers/storage
    XDG_DATA_HOME=/tmp/hostile
                           -> /tmp/hostile/containers/storage
    ```

    **So the value that keeps the store where the repository already says it
    is — `paths.PODMAN_STORE`, `<home>/.local/share/containers` — is
    `<home>/.local/share`, and that is what this returns.** Setting it to the
    home itself would move the store to `<home>/containers`, which is not the
    path `service.py`'s store walk and `paths.PODMAN_STORE` name, and every
    assertion about the store would then be about a tree that is not there.

    **And the hostile case is the one this exists for**: with the caller's own
    `XDG_DATA_HOME` inherited, the whole store — and with it
    `containers/storage/secrets/secrets.json` and
    `containers/storage/secrets/filedriver/secretsdata.json`, which hold the
    materialised credential values — lands OUTSIDE the service's `0700` home.
    The files stay `0600` to the service uid; the DIRECTORY is what leaves.
    """
    return _home_for(account) / ".local" / "share"


def _passwd_home(account: str) -> str:
    """The home directory the machine's passwd database gives an account.

    Read from `pwd` rather than from a file guarden stages: `GUARDEN_PREFIX`
    relocates guarden's own tree and not the host's identity databases, and
    `useradd` writes the machine's `/etc/passwd` — so a staged copy would be
    reading a different database than the one the account was created in.
    """
    try:
        entry = pwd.getpwnam(account)
    except KeyError:
        return "/"
    return entry.pw_dir


def _runtime_dir(account: str) -> Path:
    """The service's own `/run/user/<uid>`, when the manager has made it.

    The user manager comes up asynchronously after an ingest, so the directory
    is not always there. `service.py`'s probe has always set
    `XDG_RUNTIME_DIR` only when it exists, and that condition is kept: a
    `XDG_RUNTIME_DIR` naming a directory that is not there is worse than none,
    because podman fails on the missing path rather than falling back.
    """
    try:
        uid = pwd.getpwnam(account).pw_uid
    except KeyError:
        return Path(f"/run/user/{os.getuid()}")
    return Path(f"/run/user/{uid}")


def runuser_as(account: str, *argv: str, cwd: str | Path | None = None) -> list[str]:
    """The argv that runs a command as another account, in a scrubbed environment.

    **`runuser -u <account> --` plus an `env` that sets the account's own
    variables and removes the ones that must not be inherited.** The `env` is
    INSIDE the `runuser`, so it is the environment of the command that runs as
    the account and not of the caller's.

    **The variables that are SET are the account's own**, and every one of them
    is set whether or not the caller had it:

      * `HOME` — the account's home (`_home_for`).
      * `XDG_DATA_HOME` — the account's XDG data directory (`_data_home`), so
        podman's store and the secret database inside it land inside the
        service's `0700` home rather than wherever the caller's pointed. This
        is the one that matters: without it the materialised credential leaves
        the home that is its documented limit.
      * `XDG_RUNTIME_DIR` — the account's own `/run/user/<uid>`, **only when
        that directory exists** (see `_runtime_dir`).
      * `USER` and `LOGNAME` — the account's name.

    **The variables that are REMOVED are the ones the caller must not pass
    on**: `XDG_CONFIG_HOME`, `XDG_CACHE_HOME`, `DBUS_SESSION_BUS_ADDRESS`,
    every `CONTAINERS_*` this module names, `PWD` and `OLDPWD`.

    **`USER` and `LOGNAME` are set although `runuser` already sets them.** That
    is defence in depth and not a measured fix: `runuser` sets both for a
    non-root target (measured above), so setting them costs nothing and the
    decision was to set them. What the measurement DID find is that `USER` is
    what podman's keep-id mapping is keyed by, so a caller that reaches podman
    by another route must not be able to put `USER=root` into it.

    **A service's own home is not a directory every account can enter**, so the
    caller passes `cwd` and the suite's own tree is never the working
    directory: a rootless podman enters the working directory as the service's
    uid and is refused before it does any work.
    """
    home = _home_for(account)
    runtime = _runtime_dir(account)
    env = [
        "env",
        *[["-u", name] for name in SCRUB_REMOVE],
        "--",
        f"HOME={home}",
        f"USER={account}",
        f"LOGNAME={account}",
        f"XDG_DATA_HOME={_data_home(account)}",
    ]
    if runtime.is_dir():
        env.append(f"XDG_RUNTIME_DIR={runtime}")
    return ["runuser", "-u", account, "--", *env, *argv]
