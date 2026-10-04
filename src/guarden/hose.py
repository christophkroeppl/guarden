"""hose — the gitops receiver.

spec 6.7. The only network-facing program, and the only one a poke reaches.
It runs as its own user, keeps no git state, and holds no privilege beyond a
sudoers rule naming `furrow deploy`, `furrow preview drop`, `furrow queue list`,
`furrow status` and `weedr project list`, run as `(guarden)`.

**There is no `<project>` argument in any verb, and its absence is the whole of
the per-project binding.** The project arrives in the forced command
`weedr project grant` writes and nowhere else. sshd *appends* the client's own
command to the forced one, so a key holder for project A could send
`--project B` and every conventional parser takes the last occurrence of a
repeated option — the client would have won. So the count is checked before the
value is used, the one occurrence that is accepted has to be the leading one
sshd wrote, and argparse below never sees the option at all.

**A poke may create a service in a gated track, production included, and that is
forced rather than chosen.** With no git clone and no `add --from <service>`
reachable from CI, the staged tree a poke carries is the only way code reaches a
workload that does not exist yet. What stands between a push and a running
production container is the gate, not the creation, so the deploy's own blocked
gate is a state: exit `0`, the service installed and waiting, the reason in the
registry.

A poke never grants: no port, no firewall rule, no override entry. The verbs it
may reach are fixed here, and none of them carries a flag that could grant one.
"""

from __future__ import annotations

import argparse
import os
import shutil
import stat
import sys
import tarfile
from dataclasses import dataclass
from pathlib import Path

from guarden import cli, errors, names, paths, projects, registry, tool
from guarden import config as config_mod

FURROW = paths.BIN / "furrow"
QUEUE = paths.LIB / "queue"
GUARDEN = "guarden"

TREE_MODE = 0o755
FILE_MODE = 0o644
UMASK = 0o022

DEPLOY = "deploy"
PREVIEW_DROP = ("preview", "drop")
# The phrase `furrow deploy` uses when a `kind = "instance"` track is handed a
# name with no `/<ref>`. Matching on a phrase of another program's own
# diagnostic is a heuristic, so it is the last resort: where the track table is
# readable this program never asks, and where it is not this is the only answer
# available without inventing a track from its name.
INSTANCE_REFUSAL = "kind = \"instance\""

GROUPS = (
    ("poke", "deploy the tree on stdin to the track the ref maps to", None),
    ("drop", "remove the instance the ref names, on a track that permits it", None),
    ("check", "could a poke for this project deploy right now; changes nothing", None),
)

EPILOG = """\
The project is a property of the key, not of the request: it comes from the
forced command in /etc/ssh/authorized_keys.d/hose. A `--project` argument is
refused with exit 2, because sshd appends the client's own command to the
forced one and the client would win.

A blocked gate is a state and not a failure: the deploy exits 0, the service
is installed and waiting, and the registry carries the reason. A poke grants
nothing — no port, no firewall rule, no override entry.
"""


@dataclass(frozen=True)
class Target:
    """The service a request names, derived here and never taken as an argument."""

    service: str
    ref: str | None
    environment: str
    kind: str


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="hose",
        description="The gitops receiver.",
        epilog=EPILOG,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    top = cli.add_groups(parser, "group", GROUPS)

    poke = top["poke"]["parser"]
    poke.add_argument("ref", metavar="REF", help="the ref, taken raw")
    poke.add_argument("sha", metavar="SHA", help="the commit, and the staging directory's name")
    poke.add_argument(
        "environment",
        metavar="ENVIRONMENT",
        nargs="?",
        help="only when the ref's allowlist grants more than one track",
    )

    top["drop"]["parser"].add_argument("ref", metavar="REF", help="the ref, taken raw")
    check = top["check"]["parser"]
    check.add_argument(
        "ref",
        metavar="REF",
        nargs="?",
        help="the ref to map; without one, every pattern in the allowlist is checked",
    )
    return parser


# --- the project, from the forced command and nowhere else --------------------


def _project_from(argv: list[str]) -> tuple[str, list[str]]:
    """The leading `--project <name>`, or the refusal.

    Two conditions, and both are needed. The occurrence must be the one sshd
    wrote, which is the leading pair: a trailing `--project` with no forced
    command in front of it is a client's, and it is refused rather than used.
    And there must be exactly one of them, because a client that sends
    `--project other` produces two, and whichever a parser read would be the
    one that decides the project.
    """
    count = sum(1 for word in argv if word == "--project")
    if argv[:1] != ["--project"]:
        raise errors.GuardenError(
            "`hose` takes no --project argument: the project is in the forced command "
            "at the front of this line, written by `weedr project grant`, and one "
            "supplied here would be the client's and the one that won",
            errors.REJECTED_INPUT,
        )
    if count != 1 or len(argv) < 2:
        raise errors.GuardenError(
            f"this line carries {count} occurrences of --project and the forced command "
            f"supplies exactly one, so the project cannot be decided from it; a client "
            f"that sends its own --project is refused rather than obeyed",
            errors.REJECTED_INPUT,
        )
    name = argv[1]
    if not name or ".." in name or "/" in name:
        raise errors.GuardenError(
            f"the forced command names a project of {name!r}, which is not a project name",
            errors.REJECTED_INPUT,
        )
    return name, argv[2:]


# --- what a ref maps to ------------------------------------------------------


def _track(environment: str) -> str | None:
    """The kind of the track the allowlist permitted, or `None` when this
    program may not read the table that says.

    `/etc/guarden/guarden.toml` is `0640 root:guarden` and `hose` is
    deliberately not in the `guarden` group, so on a conforming host this is
    `None` and the shape of the deploy is settled by asking `furrow`, which may
    read it. Where it is readable the kind is used directly; where it is not,
    nothing is invented from the track's *name*, because a track is a row and
    not a keyword.
    """
    try:
        config = config_mod.load()
    except (errors.GuardenError, OSError):
        return None
    track = next((item for item in config.tracks if item.name == environment), None)
    return track.kind if track is not None else None


def _target(project: projects.Project, ref: str, requested: str | None) -> Target:
    environment = projects.choose(project, ref, requested)
    service = f"{project.name}-{environment}"
    names.validate(service, "the service this ref maps to")
    kind = _track(environment)
    return Target(
        service=service,
        ref=ref if kind != "slot" else None,
        environment=environment,
        kind=kind or "",
    )


REF_SET = set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._/-")
HEX = set("0123456789abcdef")
SHA_LENGTH = 7


def _ref_shape(ref: str) -> None:
    """A ref outside this set is not a ref, and it is never a path."""
    if not ref:
        raise errors.GuardenError("a ref is required and this one is empty",
                                  errors.REJECTED_INPUT)
    if set(ref) - REF_SET:
        raise errors.GuardenError(
            f"ref {ref!r} holds a character a ref may not, and the set is [A-Za-z0-9._/-]",
            errors.REJECTED_INPUT,
        )
    if ref.startswith("/") or ".." in ref:
        raise errors.GuardenError(
            f"ref {ref!r} is a path and not a ref; a ref is taken raw, escaped internally, "
            f"and never a location",
            errors.REJECTED_INPUT,
        )


def _sha_shape(sha: str) -> None:
    if not sha or set(sha.lower()) - HEX:
        raise errors.GuardenError(
            f"sha {sha!r} is not hexadecimal, and the staging directory is named from a "
            f"commit; nothing was unpacked",
            errors.REJECTED_INPUT,
        )
    if len(sha) < SHA_LENGTH:
        raise errors.GuardenError(
            f"sha {sha!r} is shorter than the {SHA_LENGTH} hexadecimal characters a commit "
            f"may be abbreviated to",
            errors.REJECTED_INPUT,
        )


# --- the archive --------------------------------------------------------------


def _refuse(member_name: str, why: str) -> errors.GuardenError:
    return errors.GuardenError(
        f"the archive member {member_name!r} {why}, so it is refused and no service was "
        f"touched",
        errors.REJECTED_INPUT,
    )


def _member_path(target: Path, name: str) -> Path:
    """Where one member lands, and whether that is inside the target at all."""
    if name.startswith("/") or name.startswith("~"):
        raise _refuse(name, "is an absolute name")
    parts = [part for part in name.split("/") if part not in ("", ".")]
    if any(part == ".." for part in parts):
        raise _refuse(name, "carries a '..' component")
    where = target.joinpath(*parts)
    resolved = Path(os.path.realpath(where))
    root = Path(os.path.realpath(target))
    if resolved != root and root not in resolved.parents:
        raise _refuse(name, "would land outside the staging directory")
    return where


def unpack(stream, target: Path) -> int:
    """Unpack as the `hose` user, and refuse rather than follow.

    No ownership and no timestamps come out of the archive: every file is
    `0644` and every directory `0755`, under `umask 022`, because `guarden` has
    to read the tree and root has to render it. Only regular files and
    directories are written — a symlink, a hardlink, a device and a fifo are all
    refused by name, because a member that is followed is a member whose target
    this program chose.
    """
    os.umask(UMASK)
    target.mkdir(parents=True, exist_ok=True)
    os.chmod(target, TREE_MODE)
    written = 0
    with tarfile.open(fileobj=stream, mode="r|*") as archive:
        for member in archive:
            where = _member_path(target, member.name)
            if member.isdir():
                where.mkdir(parents=True, exist_ok=True)
                os.chmod(where, TREE_MODE)
                continue
            if not member.isfile():
                kind = "link" if member.issym() or member.islnk() else "special file"
                raise _refuse(member.name, f"is a {kind}, and only a regular file is unpacked")
            where.parent.mkdir(parents=True, exist_ok=True)
            extracted = archive.extractfile(member)
            if extracted is None:
                raise _refuse(member.name, "carries no data")
            with open(where, "wb") as out:
                shutil.copyfileobj(extracted, out)
            os.chmod(where, FILE_MODE)
            written += 1
    return written


def _remove(path: Path) -> None:
    """Whoever created the tree removes it, and a failed deploy is not a reason
    to leave one behind."""
    shutil.rmtree(path, ignore_errors=True)


# --- the verbs ----------------------------------------------------------------


def _sudo(argv: list[str]) -> tool.Result:
    """`sudo -n` and never `sudo`: a program that could prompt is a program that
    could leave a workflow waiting on a human. A poke already holding root runs
    the program directly, which is what the throwaway harness is."""
    if not FURROW.is_file():
        raise errors.GuardenError(
            f"{FURROW} is not installed, and a poke reaches the deploy queue only through "
            f"it; `soil install --apply` installs it and writes the sudoers rule that "
            f"names it",
            errors.HOST_NOT_AS_ASSUMED,
        )
    command = [str(FURROW), *argv] if os.geteuid() == 0 else ["sudo", "-n", str(FURROW), *argv]
    return tool.call(command)


def _relay(result: tool.Result) -> int:
    """What the deploy said reaches the workflow log, which is where a pending
    port and a blocked gate are read."""
    for stream, text in ((sys.stdout, result.stdout), (sys.stderr, result.stderr)):
        if text:
            stream.write(text if text.endswith("\n") else text + "\n")
            stream.flush()
    return result.returncode


def _target_argument(target: Target) -> str:
    return f"{target.service}/{target.ref}" if target.ref else target.service


def _poke(project: projects.Project, args) -> int:
    _ref_shape(args.ref)
    _sha_shape(args.sha)
    target = _target(project, args.ref, args.environment)
    target_dir = projects.staging(project.name) / args.sha

    if _already_deployed(target, args.sha):
        sys.stdout.write(f"{target.service} is already at {args.sha}; no deploy was queued\n")
        return 0

    files = unpack(sys.stdin.buffer, target_dir)
    sys.stdout.write(f"unpacked {files} files into {target_dir}\n")
    # `finally`, not a following line: a refusal raised out of _deploy — a
    # missing furrow, an unknown project — left the whole staged tree on disk,
    # and "a failed deploy is not a reason to leave one behind" has to mean it
    # on every path out, not only on the one that returns.
    try:
        return _deploy(target, args, project)
    finally:
        _remove(target_dir)


def _deploy(target: Target, args, project: projects.Project) -> int:
    """`furrow deploy`, and the one shape of its name the host answers.

    Where the track table is readable the instance form is chosen from it, and
    nothing else is tried. Where it is not — which is a conforming host, because
    `guarden.toml` is `0640 root:guarden` and `hose` is deliberately not in the
    `guarden` group — the bare name is tried first and `furrow`'s own refusal
    says which kind the track is, so the retry carries the ref. Both calls are
    the same verb with the same flags, so neither grants anything: `deploy`
    takes no flag that could grant a port, a firewall rule or an override entry,
    and a poke may create a service in a gated track precisely because the gate
    rather than the creation is what stands between a push and a running
    production container.
    """
    pair = _pair(project, args)
    first = _sudo([DEPLOY, target.service, "--from", "poke", pair])
    if target.kind or target.ref is None:
        return _relay(first)
    detail = errors.oneline(first.stderr.strip() or first.stdout.strip())
    if INSTANCE_REFUSAL not in detail:
        return _relay(first)
    _relay(first)
    return _relay(_sudo([DEPLOY, _target_argument(target), "--from", "poke", pair]))


def _pair(project: projects.Project, args) -> str:
    return f"{project.name}@{args.sha}"


def _already_deployed(target: Target, sha: str) -> bool:
    """Whether the registry already records this sha for this service, and what
    to do when this program may not read it.

    `hose` is not in the `guarden` group, so on a conforming host the registry
    is unreadable here and the answer is "not known" — which is not the same as
    "not deployed". A poke of the deployed sha then makes its `furrow deploy`
    call, and `weedr service ingest` is idempotent: it converges, says `converged`
    and changes nothing, so the deploy exits 0 and no service is touched. The
    short-circuit is a saving, never a correctness requirement, and it is where
    the record is readable.
    """
    try:
        record = registry.load(target.service)
    except OSError:
        return False
    if record is None:
        return False
    if target.ref is not None and names.systemd_escape(target.ref) not in record.instances:
        return False
    return record.deployed_sha == sha


def _drop(project: projects.Project, ref: str) -> int:
    """`furrow preview drop` with a name derived here.

    The name is computed from the project and the ref through the allowlist and
    never accepted, so a key for one project cannot drop another project's
    instance. The refusal for a gated track is root-side in
    `weedr service remove` against `/etc/guarden/allow-gated-drop`, and this
    program never reads that file: what stops a poke is the verb `hose` is not
    permitted, not the mode of the marker.
    """
    _ref_shape(ref)
    target = _target(project, ref, None)
    if target.kind == "slot":
        raise errors.GuardenError(
            f"ref {ref!r} of {project.name} maps to the track {target.environment!r}, which "
            f"is kind = \"slot\" and holds one service per workload, so a drop names no "
            f"instance. A drop removes an instance; a service is removed by an operator",
            errors.REJECTED_INPUT,
        )
    return _relay(_sudo([*PREVIEW_DROP, target.service, ref]))


def _check(project: projects.Project, ref: str | None) -> int:
    """One question a workflow can ask before it pushes: could a poke for this
    project deploy right now?

    In order — the project is registered; the key that names it is installed and
    carries a forced command binding this project and no other; the per-project
    staging directory exists and belongs to the `hose` user; the ref asked for
    maps to a track; and what `furrow` reads as `guarden` is readable by the
    `guarden` group. Each failure is a `warning:` naming what failed and the exit
    is 1 if any failed. It changes nothing, so CI may call it on every push.
    """
    failures: list[str] = []

    installed = projects.key_projects()
    blob = installed.get(project.name)
    if blob is None:
        failures.append(
            f"no poke key in {projects.KEYS} names the project {project.name!r}, so a push "
            f"from this project's workflow would not arrive; `weedr project grant "
            f"{project.name} <pubkey>` installs one"
        )
    else:
        # The blob is ALREADY the key field, so `_decode` — which splits
        # `<type> <base64>` — refused every real key for having one word. What
        # this claim is really about is that the blob decodes, and
        # `fingerprint` is the check that makes it: b64decode with validate=True
        # rejects anything that is not base64.
        try:
            projects.fingerprint(blob)
        except (ValueError, TypeError) as exc:
            failures.append(
                f"the poke key in {projects.KEYS} that names {project.name!r} is not a "
                f"decodable {projects.KEY_TYPE} key: {exc}"
            )
        for line in projects.key_entries(project.name):
            missing = [
                option for option in projects.REQUIRED_OPTIONS if option not in line
            ]
            if missing:
                failures.append(
                    f"the key {projects.fingerprint(blob)} is installed without "
                    f"{', '.join(missing)}, so sshd would grant it a pty or a forwarded "
                    f"port; `weedr project grant` writes every option and nothing else "
                    f"does"
                )
                break
        shared = [
            other for other, key in installed.items()
            if other != project.name and key == blob
        ]
        if shared:
            failures.append(
                f"the key {projects.fingerprint(blob)} is installed for "
                f"{', '.join(sorted(shared))} as well as for {project.name}, so one "
                f"repository's key would reach another project's services"
            )

    directory = projects.staging(project.name)
    try:
        hose_ids = projects._hose_ids()
    except errors.GuardenError as exc:
        failures.append(exc.message)
    else:
        try:
            info = directory.stat()
        except OSError:
            failures.append(
                f"the staging directory {directory} does not exist, and a poke for "
                f"{project.name!r} cannot unpack into it; `weedr project grant` creates "
                f"it, because a poke cannot mkdir under a 0755 root:root parent"
            )
        else:
            if info.st_uid != hose_ids[0]:
                failures.append(
                    f"{directory} is owned by uid {info.st_uid} and not by the "
                    f"{projects.HOSE_USER} user, so a poke cannot write its tree there"
                )
            if not info.st_mode & stat.S_IWUSR:
                failures.append(f"{directory} is not writable by its owner")

    if ref is None:
        for pattern, tracks in project.environments.items():
            if not tracks:
                failures.append(
                    f"the pattern {pattern!r} in {project.where} grants no environment, so "
                    f"a ref matching it may deploy nowhere"
                )
    else:
        try:
            projects.allowed(project, ref)
        except errors.GuardenError as exc:
            failures.append(exc.message)

    if not project.environments:
        failures.append(
            f"{project.where} grants no ref any environment, so no poke for "
            f"{project.name!r} can deploy anywhere"
        )

    failures += _furrow_readable()

    for message in failures:
        sys.stderr.write(errors.warn(message) + "\n")
    if failures:
        return 1
    sys.stdout.write(f"{project.name} could deploy a poke right now\n")
    return 0


def _furrow_readable() -> list[str]:
    """What `furrow` reads as `guarden` and could not read.

    `furrow` reaches the queue as `guarden`, so the queue directory has to be
    writable by the group and the environment table has to be readable by it.
    Both are root-owned group permissions, and `hose` may read a mode without
    holding the group — which is what makes this checkable from here at all.
    """
    failures: list[str] = []
    guarden_gid = _group_id(GUARDEN)
    if guarden_gid is None:
        return [
            f"there is no {GUARDEN} group on this host, so no unprivileged program can "
            f"read the root-owned files guarden keeps"
        ]
    for path, want in ((paths.GUARDEN_TOML, stat.S_IRGRP), (QUEUE, stat.S_IWGRP)):
        try:
            info = path.stat()
        except OSError as exc:
            failures.append(f"{path} could not be read: {exc.strerror}")
            continue
        if info.st_gid != guarden_gid and info.st_uid != 0:
            failures.append(
                f"{path} is owned by {info.st_gid}:{info.st_gid} and not by "
                f"root:{GUARDEN}, and `furrow` reads it as {GUARDEN}"
            )
            continue
        if not info.st_mode & want:
            failures.append(
                f"{path} is not readable by the {GUARDEN} group"
                if want == stat.S_IRGRP
                else f"{path} is not writable by the {GUARDEN} group, so `furrow` cannot "
                     f"enqueue a deploy into it"
            )
    return failures


def _group_id(name: str) -> int | None:
    try:
        with open(paths.GROUP) as handle:
            for line in handle:
                parts = line.strip().split(":")
                if len(parts) >= 3 and parts[0] == name and parts[2].isdigit():
                    return int(parts[2])
    except OSError:
        return None
    return None


def main(argv: list[str] | None = None) -> int:
    words = list(sys.argv[1:] if argv is None else argv)
    # A usage request is answered before the forced command is read, because the
    # guard below refuses any line whose first pair is not `--project <name>` and
    # `hose --help` is exactly such a line. The guard itself is unchanged: what is
    # relaxed is only that `--help` prints and exits rather than being refused.
    if words[:1] in (["--help"], ["-h"], ["help"]):
        build_parser().print_help()
        return 0
    try:
        project_name, rest = _project_from(words)
    except errors.GuardenError as exc:
        sys.stderr.write(exc.report("hose") + "\n")
        return exc.code
    args = build_parser().parse_args(rest)
    verb = args.verb if args.verb and args.verb != args.group else None
    call = cli.invocation("hose", args.group, verb)
    try:
        project = projects.get(project_name)
        if args.verb == "poke":
            return _poke(project, args)
        if args.verb == "drop":
            return _drop(project, args.ref)
        return _check(project, args.ref)
    except errors.GuardenError as exc:
        sys.stderr.write(exc.report(call) + "\n")
        return exc.code


if __name__ == "__main__":
    raise SystemExit(main())