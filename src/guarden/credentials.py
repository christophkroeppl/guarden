"""A credential's own half: one encrypted blob, and the podman secret it becomes.

ADR-0005, spec 6.2 and 6.9. A value is typed once at a terminal, encrypted into
`/etc/guarden/creds/<service>/<KEY>.cred` mode `0600`, and **never written
anywhere else in the clear**: the materialiser hands it to podman on a pipe, and
by the time a container asks for it podman is holding it in the service's own
store, which is inside the service's `0700` home. There is no plaintext file,
because a written-out one would be created under root's umask inside a directory
the service user owns, and its mode would be a decision nobody remembers.

**The key is stated once, here, and `auto` is not one of the choices.** Either
`--with-key=host`, against a host key at `/var/lib/systemd/credential.secret`, or
`--with-key=tpm2`, binding it to the machine's TPM. `auto` is refused because its
meaning varies with the hardware: it prefers a TPM2 key when it finds one, so a
box that happened to have a TPM would silently encrypt with a different key from
the one every document describes, and nothing at the time would say so. Which of
the two this host uses is a property of the box, and there is no configuration key
for it here because none of the documents names one — `ENCRYPT_WITH` is the one
place the answer is written.

**Reading a value back is what the gate needs and podman cannot do it.** `podman
secret ls` answers with names and no verb answers with a value, so a gate that
refuses a value still equal to its example has to read the blob root-side. That is
the same decryption the materialiser does, on the same `0700 root` directory, and
it is why the gate is a mutator verb rather than something an unprivileged program
evaluates. Nothing here ever returns a value to a caller: the caller is handed a
boolean, or the comparison it asked for.

`materialise` is the only place in guarden that decrypts a blob, and there is one
program for it: a path unit on `/etc/guarden/creds/` and one boot-time oneshot
(spec 6.9) rather than a pair of units per service.
"""

from __future__ import annotations

import os
import re
import sys
import termios
from pathlib import Path
from secrets import token_urlsafe

from guarden import conf, errors, paths, secretschema, tool

# spec 6.2: the encryption key is `host` or `tpm2` and never `auto`.
ENCRYPT_WITH = "host"
TPM2 = "tpm2"
AUTO_REFUSED = "auto"

CREDS_MODE = 0o700
BLOB_MODE = 0o600

# A key is a name, never a path: it comes from a project's own schema, and
# `weedr secret set` takes it from an operator's command line.
KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")

# The conventions the gate treats as "still an example" (SECURITY.md 2.4). They
# are conventions and not a specification: a schema whose `@example` follows
# neither is a schema the gate has nothing to say about.
EXAMPLE_PREFIX = "EXAMPLE-"
PLACEHOLDER = "changeme"

GENERATED_BYTES = 32


def validate_key(key: str) -> str:
    if not KEY_RE.match(key):
        raise errors.GuardenError(
            f"a credential key is a name and must match {KEY_RE.pattern}; {key!r} is not one"
        )
    return key


def keys(service: str) -> list[str]:
    """Every key with a blob, in name order."""
    directory = paths.creds(service)
    if not directory.is_dir():
        return []
    return sorted(path.stem for path in directory.glob("*.cred"))


def planted(service: str, key: str) -> bool:
    return paths.cred_blob(service, key).is_file()


def value(service: str, key: str) -> str | None:
    """The stored value, or `None` when nothing is planted.

    Root-side decryption of the blob, in memory only. A blob that will not
    decrypt is the host not being in the state the request assumed, which is `1`
    rather than a rejection: the key is an input, the blob is on the filesystem.

    **The materialiser unit hands us the decrypted blob and this prefers it.**
    `LoadCredentialEncrypted=credentials:` puts it at
    `$CREDENTIALS_DIRECTORY/credentials`, and re-running `systemd-creds decrypt`
    here would read the encrypted blob off disk a second time to produce a value
    systemd had already decrypted for us.
    """
    handed = os.environ.get("CREDENTIALS_DIRECTORY")
    if handed:
        staged = Path(handed) / "credentials"
        if staged.is_file():
            return staged.read_text().rstrip("\n")
    blob = paths.cred_blob(service, key)
    if not blob.is_file():
        return None
    result = tool.call(["systemd-creds", "decrypt", str(blob)])
    if not result.ok:
        detail = result.stderr.strip() or result.stdout.strip()
        raise errors.GuardenError(
            f"{blob} could not be decrypted: {detail}", errors.HOST_NOT_AS_ASSUMED
        )
    # `systemd-creds` reproduces what it was given, and what it was given is what
    # the terminal ended with; the newline is framing rather than part of the
    # value, so it is dropped once here rather than by every comparison.
    return result.stdout.rstrip("\n")


def placeholder(key: secretschema.Key, stored: str) -> str | None:
    """Why this value is not a credential yet, in words, or `None`."""
    if not stored:
        return "is empty"
    if key.example and stored == key.example:
        return "is still the example"
    if stored.startswith(EXAMPLE_PREFIX):
        return f"is still the example ({EXAMPLE_PREFIX}...)"
    if stored.lower() == PLACEHOLDER:
        return f"is still {PLACEHOLDER}"
    return None


def generated_value() -> str:
    """A minted value. Nothing on an ungated track is worth stealing, and a poke
    must not be blocked on a human planting it (spec 5.3 step 9)."""
    return token_urlsafe(GENERATED_BYTES)


def plant(service: str, key: str, stored: str) -> Path:
    """Encrypt `stored` into the service's blob directory and return its path.

    The value goes in on a pipe and comes out as ciphertext; nothing in between
    is a file, and the blob is written with the write protocol like every other
    file more than one process reads.

**The password operand is empty and is passed anyway.** `systemd-creds
    encrypt` takes `CREDENTIALS [PASSWORD]`, and the password is not optional on
    this systemd — measured on 259: `encrypt --name=K --with-key=host -` answers
    `Too few arguments.` and exits 1, and every ingest of a service with a
    credential key died there. An empty password is the whole of what guarden
    means by "no passphrase": the key is the one stated once (spec 5.5,
    `--with-key=host` or `--with-key=tpm2`) and a second secret nobody holds would
    make the blob undecryptable rather than protected. The credential itself is
    the trailing `-`, read from the pipe.

    **The embedded name is the blob's own filename, suffix and all.**
    `systemd-creds` will not decrypt a blob whose embedded name is not the file
    it was handed — `Embedded credential name 'DB_PASSWORD' does not match
    filename 'DB_PASSWORD.cred', refusing.` — so `--name=` carries the suffix,
    because the blob is `/etc/guarden/creds/<service>/<KEY>.cred` in spec 2, ADR-0005
    and ticket 60 alike, and the suffix is what `systemd-creds` compares against.

    The podman secret is still the bare `<KEY>`, which is the name the renderer
    asks for with `Secret=<KEY>` and the one the application finds at
    `/run/secrets/<KEY>` (spec 6.3). **The suffix belongs to the file the value
    was encrypted into and to nothing else**, so the embedded name and the
    secret's name are two different names, and only one of them carries `.cred`.
    """
    validate_key(key)
    directory = paths.creds(service)
    directory.mkdir(parents=True, exist_ok=True)
    os.chmod(directory, CREDS_MODE)
    blob = paths.cred_blob(service, key)
    encrypted = tool.run(
        ["systemd-creds", "encrypt", f"--name={blob.name}", f"--with-key={ENCRYPT_WITH}", "", "-"],
        stdin=stored,
    )
    conf.write_file(blob, encrypted.stdout, BLOB_MODE)
    return blob


def materialise(service: str | None = None) -> list[str]:
    """Turn every blob into a podman secret in its own service's store.

    The one place in guarden that decrypts a blob. It runs as root because the
    key is, and it creates or replaces the secret in the *service's* store, which
    means the value ends up inside that service's `0700` home — the documented
    limit, not an accident, and the reason a backup of `/var/lib` carries every
    credential. Podman does not hold it in the clear: its `file` secret driver
    base64-encodes each value into one JSON file under that home, which is one
    `base64 -d` away and is not a boundary. The `0700` on the home is.
    """
    done: list[str] = []
    for name, key in _blobs(service):
        stored = value(name, key)
        if stored is None:
            continue
        where = _service_cwd(name)
        tool.call(
            ["runuser", "-u", name, "--", "podman", "secret", "rm", "-f", key], cwd=where
        )
        tool.run(
            ["runuser", "-u", name, "--", "podman", "secret", "create", key, "-"],
            stdin=stored,
            cwd=where,
        )
        done.append(f"{name} {key}")
    return done


def _service_cwd(service: str) -> str:
    """Where podman runs, and it is not the directory this program was started in.

    **A rootless container process inherits its caller's working directory, and
    podman enters it as the service's own uid.** So a `weedr secret materialise`
    run from a directory that uid cannot enter — an operator's home, or `/root`
    at `0700` — fails on the way in and the value never reaches the store, with a
    `cannot chdir to <the operator's directory>: Permission denied` that names
    nothing guarden owns. The service's own home is the one directory that uid
    holds `0700` on, and it is where podman's rootless store lives in any case.

    A blob whose service has no home is the host not being in the state the
    request assumed, so it is exit `1` with one line rather than the traceback
    `subprocess` raises for a working directory that is not there.
    """
    home = paths.service_home(service)
    if not home.is_dir():
        raise errors.GuardenError(
            f"{service} has no home at {home}, so no credential of it can be materialised",
            errors.HOST_NOT_AS_ASSUMED,
        )
    return str(home)


# The unit `weedr secret set` asks to run, and the phase that installs it. spec
# 6.1 gives the credential materialiser to `install` and spec 6.9 names the pair,
# so the unit asked for here is one `soil install` writes — and on a box that has
# not been converged there is nothing to ask, which is the first branch below.
BOOT_UNIT = "guarden-creds-boot.service"
INSTALL_PHASE = "soil install"


def _load_state(unit: str) -> str:
    """What systemd says about a unit, asked of systemd rather than of a path.

    The load state answers "is there a unit file for this at all", and asking is
    better than reading one of the directories a unit may live in: that would be
    a second copy of the layout to keep true. An installed unit answers `loaded`
    — including one this query had not loaded yet, because the query loads it —
    and a unit nobody installed answers `not-found`.
    """
    result = tool.call(["systemctl", "show", "--property=LoadState", "--value", unit])
    return result.stdout.strip()


def ask_materialiser(service: str, key: str, blob: Path) -> None:
    """Ask the credential materialiser to carry a freshly written blob into the
    owning service's podman secret store (spec 6.2).

    **A unit that is not installed is a `warning:`, and a unit that is installed
    and fails is a failure.** Those are two different facts and only the second is
    a broken host. The first is a box `soil install` has not converged: the blob
    is written, which is the whole of what this verb was asked to do, and the
    value reaches the store as soon as the phase that owns the unit has run. The
    second is a materialiser that exists and could not carry the value, and
    reporting that as done is how a rotated credential stops arriving with nobody
    told — so it is exit `1`, naming the unit and the journal that says why.
    """
    if _load_state(BOOT_UNIT) in ("", "not-found"):
        sys.stderr.write(
            errors.warn(
                f"{BOOT_UNIT} is not installed, so {key} of {service} is in {blob} and not in "
                f"the service's podman secret store; `{INSTALL_PHASE} --apply` installs it"
            )
            + "\n"
        )
        return
    result = tool.call(["systemctl", "start", BOOT_UNIT])
    if result.ok:
        return
    detail = result.stderr.strip() or result.stdout.strip()
    raise errors.GuardenError(
        f"{BOOT_UNIT} did not materialise {key} of {service}"
        + (f": {detail}" if detail else "")
        + f"; the value is in {blob}, and `journalctl -u {BOOT_UNIT}` says why",
        errors.HOST_NOT_AS_ASSUMED,
    )


def _blobs(service: str | None) -> list[tuple[str, str]]:
    if service is not None:
        return [(service, key) for key in keys(service)]
    if not paths.CREDS.is_dir():
        return []
    return [
        (entry.name, key)
        for entry in sorted(paths.CREDS.iterdir())
        for key in keys(entry.name)
    ]


def prompt(label: str) -> str:
    """One line from the operator, with the terminal's echo off.

    Echo is turned off on `/dev/tty` when the caller has one, which is the case
    this verb is written for. When stdin is not a terminal — a pipe, a test — the
    line is read from stdin and there is nothing to turn off, because whatever
    produced the pipe already had the value in the clear.
    """
    if not sys.stdin.isatty():
        line = sys.stdin.readline()
        if not line:
            raise errors.GuardenError(
                "weedr secret set reads one value from the terminal; stdin closed before one came",
                errors.HOST_NOT_AS_ASSUMED,
            )
        return line.rstrip("\n")
    try:
        handle = os.open("/dev/tty", os.O_RDWR)
    except OSError as exc:
        raise errors.GuardenError(
            f"the terminal could not be opened to read the value: {exc.strerror}",
            errors.HOST_NOT_AS_ASSUMED,
        ) from exc
    try:
        original = termios.tcgetattr(handle)
        quiet = termios.tcgetattr(handle)
        quiet[3] &= ~termios.ECHO
        termios.tcsetattr(handle, termios.TCSADRAIN, quiet)
        os.write(handle, label.encode())
        os.write(handle, b": ")
        read = b""
        while not read.endswith(b"\n"):
            chunk = os.read(handle, 1)
            if not chunk:
                break
            read += chunk
        os.write(handle, b"\n")
    finally:
        termios.tcsetattr(handle, termios.TCSADRAIN, original)
        os.close(handle)
    return read.decode(errors="replace").rstrip("\n")