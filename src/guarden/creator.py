"""The guided service creator: the questions, the tree, the pull, the checks.

Ticket 328. `weedr service create` grows a guided mode that asks the operator
what a service is and writes the tree a `weedr service add --from <tree>` would
have had to be hand-written.

**The questions are asked by the UNPRIVILEGED process, before root is asked
for.** That is the whole of the security argument, and it is why this module
holds no privilege of its own: the answers are gathered and validated here, at
the operator's terminal, and the answers travel with the re-exec as arguments
(`weedr.py:_become_root`). The root half receives a request that is already
well-formed, which is the same shape every other verb keeps.

**What the creator records is what the service ASKS for.** A manifest asks for
a public port and for a firewall rule; it does not grant either. `weedr port
open` and `weedr firewall open` are root and on no sudoers rule, so nothing
that answers a push can reach them. The creator therefore **prints** the
commands the operator has to run and **never runs them** — the request/grant
split survives, and the creator cannot collapse it.

**A secret is read at a terminal, with the echo off, through the existing
`credentials.prompt()`.** The value is never taken from a command line, a flag
or a file, and it is never written into the tree: a tree is a repository, and a
repository is a thing other people read.

**The network is not asked.** The renderer owns `Network=` outright
(`render.py:OWNED_KEYS`), refuses anything that does not start with `pasta:`
and writes the value from the host's `[network]` table. There is exactly one
legal answer, so the question would offer a choice that does not exist. The
creator *states* the network instead.

**The pull starts in the background as soon as the image and the tag are
known**, and it is aborted on exit. The honest limits, which the docs carry:
the abort cannot be guaranteed against a SIGKILL (a killed CLI cannot abort a
process it no longer controls), "delete the partial image" is not a podman
operation (a half-pulled image is never committed, so `podman rmi` does not
find it — the layers are unreferenced blobs), and "a later start would find it
and use it" is false. **The real cost of an uncleaned pull is DISK.**
"""

from __future__ import annotations

import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

from guarden import credentials, errors, names, paths, service, tool
from guarden import manifest as manifest_mod

# --- the vocabulary ----------------------------------------------------------

# The name a service carries: `^[a-z0-9][a-z0-9._-]*$` and no `..` (names.py).
NAME_RE = names.NAME_RE
# A volume's own name (manifest.py:VOLUME_RE).
VOLUME_RE = manifest_mod.VOLUME_RE
# A credential key (credentials.py:KEY_RE).
KEY_RE = credentials.KEY_RE
# A container's own name inside the service: a unit file's stem, so the same
# shape as a name and no `..` in it either.
CONTAINER_RE = re.compile(r"^[a-z0-9][a-z0-9._-]*$")
# An image reference is podman's to validate. What this module checks is the
# shape that keeps it an ARGUMENT and never a path: no whitespace, no shell
# metacharacter, no leading `-` (which would make it an option), and no `/`
# at the start (which would make it a path).
IMAGE_RE = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9._/:@-]*$")
# A tag: what follows the last `:` of a reference, and what a moving `latest`
# is not — but the creator accepts `latest` because the operator may want it
# and the renderer already warns about a moving tag.
TAG_RE = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9._-]*$")

PORT_MIN = manifest_mod.PORT_MIN
PORT_MAX = manifest_mod.PORT_MAX

# The kinds a provider may `provide:` (manifest.py:PROVIDES_KINDS).
PROVIDES_KINDS = manifest_mod.PROVIDES_KINDS

# The network the renderer will write, and the only one it accepts. Stated,
# never asked (see the module docstring).
NETWORK_BACKEND = "pasta"

# The tree's own layout, relative to the tree's root.
MANIFEST_REL = manifest_mod.MANIFEST_REL
QUADLET_REL = manifest_mod.MANIFEST_REL.parent / "quadlet"
# The schema's path in the manifest is relative to the TREE's root, not to
# `.guarden/` — the manifest is read from the tree's root and the schema is
# read from the same place (`render.py:build` reads `directory / schema`).
# The fixture says `.guarden/.env.schema` and so does this.
SCHEMA_REL = manifest_mod.MANIFEST_REL.parent / ".env.schema"
SCHEMA_MAML_REL = SCHEMA_REL.as_posix()


# --- the answers -------------------------------------------------------------


@dataclass
class Port:
    """One requested port: the container's own port AND the public port asked
    for it — ONE number, two meanings (ticket 328, review F1)."""

    container: str
    port: int


@dataclass
class Secret:
    """One credential key the operator wants planted, and nothing else.

    **No value is ever carried here.** A value is read at the terminal, at the
    moment it is planted, and it never reaches the tree and never reaches this
    object (see `plant_secret`).
    """

    key: str


@dataclass
class Answers:
    """Everything the operator answered, validated."""

    name: str
    environment: str
    image: str
    tag: str
    provides: list[str] = field(default_factory=list)
    ports: list[Port] = field(default_factory=list)
    volumes: dict[str, str] = field(default_factory=dict)
    firewall: list[dict] = field(default_factory=list)
    secrets: list[Secret] = field(default_factory=list)
    start: bool = False

    @property
    def reference(self) -> str:
        """The image reference the pull and the unit both name."""
        return f"{self.image}:{self.tag}"


@dataclass
class Pull:
    """A background pull, and the handle the abort takes."""

    process: subprocess.Popen
    reference: str
    aborted: bool = False


# --- the validation ----------------------------------------------------------


def validate_name(value: str, what: str = "service name") -> str:
    """A name against the closed pattern, the length limit and the `..` rule.

    **`names.validate` is the one answer, not a copy of it.** It is where the
    service name's rules live — the pattern, the 31-character limit (because
    the name becomes a Linux user name) and the `..` refusal — so the creator
    asks it rather than re-deriving half of it.
    """
    value = value.strip()
    if not value:
        raise errors.GuardenError(f"{what} is empty")
    return names.validate(value, what)


def validate_volume(value: str) -> str:
    """A volume's name against the closed pattern."""
    value = value.strip()
    if not VOLUME_RE.match(value):
        raise errors.GuardenError(
            f"volume name {value!r} must match {VOLUME_RE.pattern}"
        )
    return value


def validate_key(value: str) -> str:
    """A credential key against the closed pattern."""
    value = value.strip()
    if not KEY_RE.match(value):
        raise errors.GuardenError(
            f"credential key {value!r} must match {KEY_RE.pattern}"
        )
    return value


def validate_container(value: str) -> str:
    """A container's own name, which is also the unit file's stem."""
    value = value.strip()
    if not CONTAINER_RE.match(value) or ".." in value:
        raise errors.GuardenError(
            f"container name {value!r} must match {CONTAINER_RE.pattern}"
        )
    return value


def validate_image(value: str) -> str:
    """An image reference: podman validates the reference itself, and this keeps
    it an argument and never a path or an option."""
    value = value.strip()
    if not value:
        raise errors.GuardenError("the image is empty")
    if not IMAGE_RE.match(value):
        raise errors.GuardenError(
            f"the image {value!r} must be an image reference (a name and a registry, "
            "separated by slashes and colons) and nothing else"
        )
    if "/" in value and value.split("/", 1)[0] in (".", ".."):
        raise errors.GuardenError(
            f"the image {value!r} may not name a path; it is a registry and a name"
        )
    return value


def validate_tag(value: str) -> str:
    """A tag: the part of the reference after the last colon."""
    value = value.strip()
    if not value:
        raise errors.GuardenError("the tag is empty")
    if not TAG_RE.match(value):
        raise errors.GuardenError(f"the tag {value!r} must match {TAG_RE.pattern}")
    return value


def validate_port(value: str) -> int:
    """A port: a number in range, as a number and not as a string."""
    value = value.strip()
    if not value.isdigit():
        raise errors.GuardenError(f"the port {value!r} is not a number")
    number = int(value)
    if not PORT_MIN <= number <= PORT_MAX:
        raise errors.GuardenError(
            f"the port {number} is outside {PORT_MIN}-{PORT_MAX}"
        )
    return number


def validate_provides(value: str) -> str:
    """A `provides:` kind, out of the closed set."""
    value = value.strip()
    if value not in PROVIDES_KINDS:
        raise errors.GuardenError(
            f"the provides kind {value!r} is not one of {', '.join(PROVIDES_KINDS)}"
        )
    return value


def validate_firewall_name(value: str) -> str:
    """A firewall entry's name — what a grant names, so it is a name."""
    value = value.strip()
    if not re.match(r"^[a-z0-9][a-z0-9._-]*$", value):
        raise errors.GuardenError(
            f"the firewall rule name {value!r} must match ^[a-z0-9][a-z0-9._-]*$"
        )
    return value


# --- the questions -----------------------------------------------------------


def require_terminal(what: str) -> None:
    """Refuse a question that cannot be asked safely, with one line.

    A secret is the case that matters: `credentials.prompt()` reads stdin when
    stdin is not a terminal, and a pipe has no echo to turn off — whatever
    produced the pipe already had the value in the clear. The creator refuses
    before it reads, rather than taking a value from a pipe.
    """
    if not sys.stdin.isatty():
        raise errors.GuardenError(
            f"{what} needs a terminal; stdin is not one, so it is refused",
            errors.HOST_NOT_AS_ASSUMED,
        )


def ask(question: str, default: str = "") -> str:
    """One line from the operator, and one refusal when stdin ends."""
    suffix = f" [{default}]" if default else ""
    try:
        answer = input(f"{question}{suffix}: ").strip()
    except EOFError:
        raise errors.GuardenError(
            "the creator needs a terminal to answer its prompts; stdin ended before one came",
            errors.HOST_NOT_AS_ASSUMED,
        ) from None
    return answer or default


def ask_validated(question: str, validator, default: str = "", what: str = "value"):
    """One line, validated against a closed pattern, and re-asked until it fits.

    The re-ask is bounded: a value that does not fit is the operator's typo,
    and a typo is answered again. The bound is what stops a closed pattern
    from becoming a loop an operator cannot leave.
    """
    for _ in range(ATTEMPTS):
        answer = ask(question, default)
        try:
            return validator(answer)
        except errors.GuardenError as exc:
            sys.stderr.write(errors.warn(str(exc)) + "\n")
    raise errors.GuardenError(
        f"{what} was not given a value that fits after {ATTEMPTS} attempts",
        errors.REJECTED_INPUT,
    )


# How many times a question is re-asked before the creator gives up.
ATTEMPTS = 5


def ask_yes_no(question: str, default: bool = False) -> bool:
    """A yes or a no, and anything that is neither is re-asked."""
    hint = "Y/n" if default else "y/N"
    for _ in range(ATTEMPTS):
        answer = ask(f"{question} ({hint})").strip().lower()
        if not answer:
            return default
        if answer in ("y", "yes"):
            return True
        if answer in ("n", "no"):
            return False
        sys.stderr.write(errors.warn("answer y or n") + "\n")
    raise errors.GuardenError(
        f"{question} was not answered with y or n after {ATTEMPTS} attempts",
        errors.REJECTED_INPUT,
    )


# --- the questions themselves ------------------------------------------------


def ask_provides() -> list[str]:
    """The `provides:` kind, or none.

    A service with no `provides:` cannot be reached by any other service, so
    the creator asks — but it does not force one: an operator who wants a
    service nothing reaches may say so.
    """
    kinds = ", ".join(PROVIDES_KINDS)
    answer = ask(f"provides (one of {kinds}, or none)").strip()
    if not answer or answer.lower() == "none":
        return []
    try:
        return [validate_provides(answer)]
    except errors.GuardenError as exc:
        sys.stderr.write(errors.warn(str(exc)) + "\n")
        return []


def ask_ports() -> list[Port]:
    """The ports the service wants, ONE number each.

    The number is both the container's own port and the public port requested
    for it (ticket 328). It is asked in the `container:port` shape, because a
    port with no container names no destination for a grant.
    """
    ports: list[Port] = []
    while True:
        answer = ask(
            "port to publish (container:port, or none to finish)", "none"
        ).strip()
        if not answer or answer.lower() == "none":
            return ports
        container, separator, number = answer.rpartition(":")
        if not separator:
            sys.stderr.write(errors.warn("a port is written container:port") + "\n")
            continue
        try:
            ports.append(
                Port(
                    container=validate_container(container),
                    port=validate_port(number),
                )
            )
        except errors.GuardenError as exc:
            sys.stderr.write(errors.warn(str(exc)) + "\n")


def ask_volumes() -> dict[str, str]:
    """The volumes the service wants: `state:` (snapshotted) or `bulk:`.

    The kind is asked because the two are not the same thing: a `state:` volume
    is snapshotted and a `bulk:` volume is not, and the manifest says which.
    """
    volumes: dict[str, str] = {}
    while True:
        answer = ask("volume (name and kind: state or bulk, or none to finish)", "none")
        answer = answer.strip()
        if not answer or answer.lower() == "none":
            return volumes
        name, separator, kind = answer.partition(":")
        if not separator:
            name, kind = answer, "state"
        kind = kind.strip().lower() or "state"
        if kind not in ("state", "bulk"):
            sys.stderr.write(errors.warn("a volume's kind is state or bulk") + "\n")
            continue
        try:
            volumes[validate_volume(name)] = kind
        except errors.GuardenError as exc:
            sys.stderr.write(errors.warn(str(exc)) + "\n")


def ask_firewall() -> list[dict]:
    """The firewall rule the service ASKS for — the request, never the grant.

    The rule's line is iptables-shaped and is checked by `rules.parse` before
    it is written. The creator records the request and prints the command that
    grants it; it never runs that command.
    """
    from guarden import rules

    entries: list[dict] = []
    while True:
        name = ask("firewall rule name (or none to finish)", "none").strip()
        if not name or name.lower() == "none":
            return entries
        try:
            name = validate_firewall_name(name)
        except errors.GuardenError as exc:
            sys.stderr.write(errors.warn(str(exc)) + "\n")
            continue
        rule = ask("firewall rule (one iptables-shaped line)").strip()
        try:
            rules.parse(rule, f"the firewall entry {name!r}")
        except errors.GuardenError as exc:
            sys.stderr.write(errors.warn(str(exc)) + "\n")
            continue
        entries.append({"name": name, "rule": rule})


def ask_secrets() -> list[Secret]:
    """The credential KEYS the service wants, and nothing else.

    **No value is asked here.** A value is read at the terminal, at the moment
    it is planted, with the echo off, through `credentials.prompt()` — and it
    is never written into the tree.
    """
    keys: list[Secret] = []
    while True:
        key = ask("credential key (or none to finish)", "none").strip()
        if not key or key.lower() == "none":
            return keys
        try:
            keys.append(Secret(key=validate_key(key)))
        except errors.GuardenError as exc:
            sys.stderr.write(errors.warn(str(exc)) + "\n")


def ask_start() -> bool:
    """Whether the service is started now — and the verification follows."""
    return ask_yes_no("start the service now", default=False)


# --- the tree ----------------------------------------------------------------


def manifest_document(answers: Answers) -> dict:
    """The manifest as a document, and nothing in it that is not an answer."""
    document: dict = {}
    if answers.provides:
        document["provides"] = list(answers.provides)
    if answers.ports:
        document["ports"] = [
            {"container": entry.container, "port": entry.port} for entry in answers.ports
        ]
    state = sorted(name for name, kind in answers.volumes.items() if kind == "state")
    bulk = sorted(name for name, kind in answers.volumes.items() if kind == "bulk")
    if state:
        document["state"] = state
    if bulk:
        document["bulk"] = bulk
    if answers.firewall:
        document["firewall"] = [dict(entry) for entry in answers.firewall]
    if answers.secrets:
        # The schema is named, and the schema is the shape — never a value.
        document["schema"] = SCHEMA_MAML_REL
    return document


def unit_document(answers: Answers, container: str) -> str:
    """The starting-point unit: what the operator asked for.

    **The renderer owns `PublishPort=`, `Network=` and `Volume=` outright**, and
    overwrites them (`render.py:OWNED_KEYS`). So this file carries the image,
    the description and the volume MOUNTS, and the rest is the renderer's.

    The volume mount is written even though the renderer owns the key, because
    the renderer's own check refuses a manifest that declares a volume the
    unit source does not mount (`render.py:check_volumes`): the mount is the
    DECLARATION of what the volume is for, and the renderer replaces the
    volume's name with the subvolume's own path.
    """
    lines = [
        "[Unit]",
        f"Description={answers.name} {container} from a guarden service creator",
        "",
        "[Container]",
        f"Image={answers.reference}",
    ]
    for name, kind in sorted(answers.volumes.items()):
        lines.append(f"Volume={name}:{volume_target(name, kind)}")
    lines.append("")
    return "\n".join(lines)


def volume_target(name: str, kind: str) -> str:
    """Where a volume is mounted in the container, and the default the creator
    offers. The operator edits the tree — it is a starting point."""
    return f"/var/lib/{name}"


def schema_document(answers: Answers) -> str:
    """The credential shape: the KEYS, and never a value.

    A key is `@required` and `@sensitive`, so the renderer emits a
    `Secret=<KEY>` request for it and the gate treats it as a credential. **The
    value is never in this file and never in the tree** — it is read at the
    terminal, at the moment it is planted, and it lives in the root-owned
    encrypted blob.
    """
    lines = [
        "// The credential shape of this service. Names and types; never a value.",
        "//",
        "// @defaultSensitive=false",
        "// @defaultRequired=infer",
        "",
    ]
    for secret in answers.secrets:
        lines.append(f"// {secret.key}")
        lines.append("//   @required")
        lines.append("//   @sensitive")
        lines.append("")
    return "\n".join(lines)


def write_tree(tree: Path, answers: Answers) -> Path:
    """Write the tree: `.guarden/service.yml` and `.guarden/quadlet/*.container`.

    **No secret material is written here, and there is no code path that could
    write one.** The answers carry credential KEYS and never values, and the
    manifest is the only document that carries them.
    """
    tree.mkdir(parents=True, exist_ok=True)
    guarden = tree / MANIFEST_REL.parent
    guarden.mkdir(parents=True, exist_ok=True)
    quadlet = tree / QUADLET_REL
    quadlet.mkdir(parents=True, exist_ok=True)

    document = manifest_document(answers)
    manifest_path = tree / MANIFEST_REL
    manifest_path.write_text(_yaml_text(document), encoding="utf-8")

    if answers.secrets:
        (tree / SCHEMA_REL).write_text(schema_document(answers), encoding="utf-8")

    containers = sorted({entry.container for entry in answers.ports}) or [answers.name]
    for container in containers:
        (quadlet / f"{container}.container").write_text(
            unit_document(answers, container), encoding="utf-8"
        )
    return manifest_path


def _yaml_text(document: dict) -> str:
    """The manifest as YAML, written by hand and not by a serializer.

    A serializer would quote and reorder in ways that differ between versions,
    and the manifest is a document a person reads. Every value here is a name,
    a number or a list of them — none of them needs a quoting rule, and a
    value that did would have been refused by the validation before it got
    here.
    """
    lines: list[str] = []
    for key, value in document.items():
        if isinstance(value, list) and value and isinstance(value[0], dict):
            lines.append(f"{key}:")
            for entry in value:
                for index, (name, item) in enumerate(entry.items()):
                    prefix = "- " if index == 0 else "  "
                    lines.append(f"{prefix}{name}: {item}")
        elif isinstance(value, list):
            lines.append(f"{key}:")
            for item in value:
                lines.append(f"- {item}")
        else:
            lines.append(f"{key}: {value}")
    return "\n".join(lines) + "\n"


# --- the pull ----------------------------------------------------------------


def pull_background(
    reference: str,
    name: str = "",
    home: Path | None = None,
) -> Pull:
    """Start the pull in the background and hand back the handle.

    **The pull runs as the SERVICE user when a service is named**, through the
    same shape the probe uses (`service.py:_podman`): the image lands in the
    service's own store, and a pull as root would land in root's store where
    the service could not use it.

    **With no service named it runs as the CALLER.** The guided flow starts
    the pull before the service exists — the pull begins as soon as the image
    and the tag are known, which is before the service is created — so there
    is no service user to run it as. The image lands in the calling user's
    store, and the service pulls it into its own store on its first start.
    The cost is a second pull; the alternative contradicts the requirement
    that the pull start as soon as the image and the tag are known.
    """
    argv = ["podman", "pull", reference]
    if name:
        argv = ["runuser", "-u", name, "--", "env", f"USER={name}", f"LOGNAME={name}", *argv]
    try:
        process = subprocess.Popen(  # noqa: S603
            argv,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL,
            cwd=str(home) if home else None,
            start_new_session=True,
        )
    except OSError as exc:
        raise errors.GuardenError(
            f"the pull of {reference} could not be started: {exc.strerror}",
            errors.HOST_NOT_AS_ASSUMED,
        ) from None
    return Pull(process=process, reference=reference)


def abort_pull(pull: Pull | None) -> None:
    """Stop the pull, wait for it, and reclaim what it left.

    **The limits, stated rather than promised.** The abort cannot be guaranteed
    against a SIGKILL: a killed CLI cannot abort a process it no longer
    controls, so the pull may be orphaned and keep running. "The partial image
    is deleted" is NOT a podman operation: a half-pulled image is never
    committed, so `podman rmi` does not find it — the layers are unreferenced
    blobs in the service's store. And "a later start would find it and use it"
    is false: a half-pulled image is not a runnable image.

    So the reclaim here is the honest one — the process is stopped and waited
    for — and the cost of an uncleaned pull is **disk**, not correctness and not
    safety.
    """
    if pull is None or pull.aborted:
        return
    pull.aborted = True
    process = pull.process
    if process.poll() is not None:
        return
    try:
        process.send_signal(signal.SIGTERM)
    except (OSError, ProcessLookupError):
        return
    try:
        process.wait(timeout=PULL_ABORT_TIMEOUT)
    except subprocess.TimeoutExpired:
        try:
            process.kill()
        except (OSError, ProcessLookupError):
            pass
        try:
            process.wait(timeout=PULL_ABORT_TIMEOUT)
        except subprocess.TimeoutExpired:
            return


# How long the abort waits for the pull to die before it kills it.
PULL_ABORT_TIMEOUT = 10.0


def stage_tree(tree: Path) -> Path:
    """A copy of the tree where the RENDERER can read it, and nothing else.

    **The renderer runs as `guarden`, and the tree is the operator's own.**
    `loom` is handed the tree as `guarden` (ADR-0012), and a tree the
    operator wrote in their own home — `/root` is `0700` — is a tree the
    renderer cannot enter. So the tree is copied into a directory root owns
    and the world may read, exactly as a poke's staging tree has always been
    (`hose.py:unpack` writes `0755` and `0644` for the same reason).

    The copy holds the whole tree, and it is the invocation's own: the caller
    removes it.

    **The whole tree, and not only the render inputs, because the tree is
    also the build's context** (spec 6.6): the home the staged tree is copied
    into is what `podman build` reads, and a Containerfile that COPYs a source
    file needs that file in the context. A staged copy holding four files
    would put a four-file context in the home, and the build would die with
    `125` on a `COPY` of a file the tree carried (ticket 317).

    **A link inside the tree is refused, and the copy does not dereference
    one.** `shutil.copytree` follows symlinks by default, so a tree holding
    `.guarden/leak -> /etc/guarden/creds` would have the root half COPY the
    target's bytes into a `0755` directory every uid on the box can read — and
    the tree is a path the CALLER named, in a directory any service may write.
    So: a link is refused by name, and the copy is made with `symlinks=True`
    so that nothing is dereferenced even if one appears.
    """
    _refuse_links(tree)
    staging = paths.LIB / "render-source" / "guided"
    staging.mkdir(parents=True, exist_ok=True)
    os.chmod(staging.parent, 0o755)
    os.chmod(staging, 0o755)
    stage = Path(tempfile.mkdtemp(prefix=f"{os.getpid()}-", dir=staging))
    for path in sorted(tree.rglob("*")):
        relative = path.relative_to(tree)
        target = stage / relative
        if path.is_symlink():
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, target, follow_symlinks=False)
            continue
        if path.is_dir():
            target.mkdir(parents=True, exist_ok=True)
            continue
        if not path.is_file():
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target, follow_symlinks=False)
    for path in [stage, *sorted(stage.rglob("*"))]:
        os.chmod(path, 0o755 if path.is_dir() else 0o644)
    return stage


def _refuse_links(tree: Path) -> None:
    """A tree with a link in it is refused, and the link is named.

    **The tree is a path the caller named**, and between the unprivileged
    half's write and the root half's read, an unprivileged local user — which
    in this threat model is any *service* — can replace a file in it with a
    symlink. The root half would then copy the target's bytes into a
    world-readable staging directory.

    So the tree is walked BEFORE anything is copied, and a link is refused by
    name. A tree with no link in it is the ordinary case and is not affected.
    """
    for path in [tree, *sorted(tree.rglob("*"))]:
        if path.is_symlink():
            raise errors.GuardenError(
                f"the tree {tree} holds a link at {path.relative_to(tree)}, and a link "
                f"is refused: the tree is copied for another account to read, and a "
                f"link would carry something outside it in",
                errors.REJECTED_INPUT,
            )


def drop_tree(stage: Path) -> None:
    """Take the staged copy away, whatever happened to it."""
    shutil.rmtree(stage, ignore_errors=True)


# --- the verification --------------------------------------------------------


@dataclass
class Check:
    """One check and what it answered."""

    what: str
    ok: bool
    detail: str = ""


def unit_active(name: str, unit: str) -> Check:
    """Check one: the unit is active in the service's own manager.

    `systemctl --user --machine <name>@ is-active <unit>` — the service's own
    user manager, reached through the machine's `@` form, which is how every
    other verb in this program talks to it.
    """
    result = tool.call(
        ["systemctl", "--user", "--machine", f"{name}@", "is-active", unit]
    )
    answer = (result.stdout or result.stderr).strip()
    ok = result.ok and answer == "active"
    return Check(
        what=f"the unit {unit} is active",
        ok=ok,
        detail=answer or f"systemctl exited {result.returncode}",
    )


def container_running(name: str, container: str, record=None) -> Check:
    """Check two: the container is running **in the service's own store**.

    `podman ps --filter name=<container>` — and it runs **as the service**,
    with the service's `USER` and `LOGNAME`, because the container lives in
    the service's podman store and root's store is a different one.

    **This was the check that could not see what it checked.** It ran
    `podman ps` as root, and root's podman has root's own store, so the row
    that answers was never the service's — and the check reported "the
    container is not running" for a perfectly healthy service. That is how an
    operator learns to ignore a verification.

    The pattern is the one the mutator uses (`service._podman`): `runuser -u
    <service>` with `USER` and `LOGNAME` named for the service, because
    `runuser` swaps the uid but keeps the caller's environment, and podman's
    keep-id mapping reads the subid files keyed by `USER`.
    """
    argv = ["ps", "--filter", f"name={container}", "--format", "{{.Names}}"]
    if record is not None:
        result = service._podman(name, record, *argv)
    else:
        # No record (the unit was never written): there is no service to ask,
        # and the honest answer is that the check could not be made.
        return Check(
            what=f"the container {container} is running",
            ok=False,
            detail="the service has no registry record, so its podman store is unknown",
        )
    rows = [line for line in (result.stdout or "").splitlines() if line.strip()]
    ok = bool(rows)
    return Check(
        what=f"the container {container} is running",
        ok=ok,
        detail=", ".join(rows) if rows else "podman ps returned no row",
    )


def publication_listening(port: int) -> Check:
    """Check three: the publication is listening **on the loopback**.

    `ss -tln` shows the allocated loopback port in LISTEN, and the check
    looks for `127.0.0.1:<port>` — **not merely for the port number**.

    **This was the check that could not see what it checked.** It matched any
    listener on ANY address with that port number, so `0.0.0.0:<port>` — a
    PUBLIC binding, which is the one thing a loopback publication is not —
    satisfied it, and so did another service's container or a host daemon on
    the same number. A false PASS is the one failure mode the verification
    exists to prevent, and this is what it was doing.

    A loopback publication is not a public one: this check says the port is
    bound on `127.0.0.1`, and it says nothing about the world — a grant is a
    separate act, and the creator never performs it.
    """
    result = tool.call(["ss", "-tln"])
    for line in (result.stdout or "").splitlines():
        fields = line.split()
        if len(fields) < 4:
            continue
        local = fields[3]
        if not local.startswith("127.0.0.1:"):
            continue
        if local.split(":", 1)[1] != str(port):
            continue
        if "LISTEN" not in fields:
            continue
        return Check(
            what=f"the publication {port} is listening on the loopback",
            ok=True,
            detail=line.strip(),
        )
    return Check(
        what=f"the publication {port} is listening on the loopback",
        ok=False,
        detail=f"ss -tln shows no loopback listener on {port}",
    )


def verify(
    name: str, unit: str, container: str, port: int | None = None, record=None
) -> list[Check]:
    """The verification, and it is EXACTLY three checks.

    1. the unit is active;
    2. the container is running;
    3. the publication is listening.

    **A fourth check — "the service answers" — is NOT in scope.** There is no
    general way to know that an arbitrary image is serving: an HTTP service
    answers with a 200, a database with a connection, a Bitcoin node with a
    protocol handshake. Without a per-service probe specification the check is
    either unimplementable or a false positive — and a false positive here is
    the exact failure the verification exists to catch.

    `record` is the service's registry record, and it is what lets the
    container check ask the SERVICE's podman store rather than root's.
    """
    checks = [
        unit_active(name, unit),
        container_running(name, container, record),
    ]
    if port is not None:
        checks.append(publication_listening(port))
    return checks


def report_checks(checks: list[Check]) -> bool:
    """Print the checks and say whether they all passed."""
    ok = True
    for check in checks:
        mark = "ok" if check.ok else "FAIL"
        detail = f" ({check.detail})" if check.detail else ""
        sys.stdout.write(f"{mark}   {check.what}{detail}\n")
        ok = ok and check.ok
    return ok


# --- the secret --------------------------------------------------------------


def read_secret(service: str, key: str) -> str:
    """Read one secret value at the terminal and plant it.

    **The terminal is checked FIRST**, before anything is read: a value taken
    from a pipe was already in the clear where the pipe produced it. The value
    is read through `credentials.prompt()` — the existing mechanism, with the
    echo off — and never from a command line, a flag or a file.
    """
    require_terminal(f"reading the value of {key}")
    value = credentials.prompt(f"{service} {key}")
    if not value:
        raise errors.GuardenError(
            f"nothing was typed for {key} of {service}, so there is nothing to plant"
        )
    return value


def plant_secret(service: str, key: str) -> Path:
    """Read one value at the terminal and plant it in the service's blob.

    The value goes through the EXISTING mechanism — `credentials.prompt()` for
    the read and `credentials.plant()` for the write — and this module
    reimplements neither. The blob is root-owned and the value is encrypted
    into it; the tree carries the key's NAME and never the value.
    """
    value = read_secret(service, key)
    blob = credentials.plant(service, key, value)
    credentials.ask_materialiser(service, key, blob)
    return blob


# --- the commands the operator runs -----------------------------------------


def grant_commands(name: str, answers: Answers) -> list[str]:
    """The commands the operator has to run — printed, never run.

    **The request/grant split, kept.** A manifest asks for a port and for a
    firewall rule; `weedr port open` and `weedr firewall open` are root and on
    no sudoers rule, so nothing that answers a push can reach them. A creator
    that asked "do you want a firewall rule?" and then granted it in the same
    breath would collapse the split into one act.
    """
    commands: list[str] = []
    for entry in answers.ports:
        commands.append(f"weedr port open {name} {entry.port}")
    for entry in answers.firewall:
        commands.append(f"weedr firewall open {name} {entry['name']}")
    return commands


def report_grants(name: str, answers: Answers) -> None:
    """Print the commands the operator runs, and say what they are."""
    commands = grant_commands(name, answers)
    if not commands:
        return
    sys.stdout.write("this service ASKS for the following; the grant is a separate act:\n")
    for command in commands:
        sys.stdout.write(f"  {command}\n")
    sys.stdout.write(
        "these are root-only verbs and are not run for you; run them yourself to grant them\n"
    )
