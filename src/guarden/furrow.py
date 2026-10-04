"""furrow — the build queue and the deploy order.

spec 6.6. Unprivileged, and the only program that calls weedr on a schedule.
The order is the point (ADR-0011): ensure, render, build, gate, stop, install,
start, with the build and the gate both landing before the stop so a failed
either leaves the running container running. It never touches podman.

A request is a service, a ref and a sha and never a path. A lane claimed in the
queue directory bounds BUILDS; `deploy-<service>`, held from the first step to
the last, bounds DEPLOYS. They are different hazards with different mechanisms
and `build.lanes` is the first and never the second. The reasoning, and the two
gaps in the mutator this ticket found, are in
docs/tickets/120-build-queue.md.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from pathlib import Path

from guarden import cli, compose, conf, errors, names, paths, registry, tool, unitsource
from guarden import config as config_mod
from guarden import manifest as manifest_mod

QUEUE = paths.LIB / "queue"
WEEDR = paths.BIN / "weedr"
LOOM = paths.BIN / "loom"

REQUEST_MODE = 0o640
POKE_SHA = re.compile(r"[0-9a-f]{7,64}")
REPORTED = ("service", "ref", "sha", "state", "lane", "weight", "queued_at")

QUEUED = "queued"
BUILDING = "building"
DEPLOYING = "deploying"
FAILED = "failed"
RUNNING = (BUILDING, DEPLOYING)
POLL = 0.2

GROUPS = (
    ("deploy", "queue a deploy: ensure, render, build, gate, stop, install, start", None),
    ("preview", "drop a preview instance", (("drop", "remove one instance of a preview"),)),
    ("queue", "what is waiting", (("list", "the waiting requests, in order"),
                                  ("show", "one service's requests and their last failure"))),
    ("status", "lanes, in flight, deployed and queued", None),
)

EPILOG = """\
`--from` is `poke <project>@<sha>` and never a folder: the mutator resolves that
pair to /var/lib/guarden/staging/<project>/<sha> itself, so a caller chooses no
location, and it is required.

Only builds take a lane. A deploy that pulls a prebuilt image waits for no lane
and still holds `deploy-<service>`, and `--now` moves one request to the front
without moving anybody else.
"""


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="furrow",
        description="The deploy queue.",
        epilog=EPILOG,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    top = cli.add_groups(parser, "group", GROUPS)

    deploy = top["deploy"]["parser"]
    cli.add_name(deploy, "the service, or one instance with /<ref>")
    deploy.add_argument(
        "--from",
        dest="from_values",
        nargs="+",
        metavar="POKE",
        help="`poke <project>@<sha>`, never a path",
    )
    deploy.add_argument("--sha", metavar="SHA", help="what is being deployed")
    deploy.add_argument(
        "--now", action="store_true", help="skip queue position for this request only"
    )

    drop = top["preview"]["verbs"]["drop"]
    drop.add_argument("name", metavar="NAME", help="the preview service")
    drop.add_argument("ref", metavar="REF", help="the ref, taken raw")

    cli.add_json(top["queue"]["verbs"]["list"])
    top["queue"]["verbs"]["show"].add_argument(
        "service", metavar="SERVICE", help="the service to report on"
    )

    cli.add_json(top["status"]["parser"])
    return parser


def _now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _lanes() -> int:
    """`build.lanes`, read at every claim so lowering it lands between builds."""
    lanes = config_mod.load().lanes
    if lanes < 1:
        raise errors.GuardenError(
            f"[build] lanes is {lanes} in {paths.GUARDEN_TOML}; a lane is one concurrent "
            f"build and the table carries no value below one",
            errors.HOST_NOT_AS_ASSUMED,
        )
    return lanes


def _root(*words: str) -> list[str]:
    """The mutator, through the guarden sudoers rule and by nothing else.

    `sudo -n` and never `sudo`: a program that could prompt is a program that
    could leave a CI run waiting on a human. Every verb is granted whole, so the
    rule cannot narrow an argument and this must not try to (spec 6.6).
    """
    if os.geteuid() == 0:
        # Already root: the rule is what an unprivileged furrow needs, and
        # calling through sudo anyway would leave the VM harness unable to
        # deploy at all.
        return [_installed(WEEDR, "soil install --apply", "the mutator"), *words]
    return ["sudo", "-n", str(WEEDR), *words]


def _installed(program: Path, phase: str, role: str) -> str:
    """A guarden program this one runs, or one line naming the phase.

    A box where `soil install --apply` has never run has no mutator for the
    deploy to reach and no renderer for it to call, and a raw errno out of a
    subprocess is a stack frame rather than the two facts somebody needs.
    """
    if not program.is_file():
        raise errors.GuardenError(
            f"{role} is not installed at {program}, and this deploy cannot reach it; "
            f"`{phase}` installs it",
            errors.HOST_NOT_AS_ASSUMED,
        )
    return str(program)


# --- the queue on disk --------------------------------------------------------
#
# `/var/lib/guarden/queue`, a directory of files, so `ls` answers what is
# waiting and a reboot does not lose an accepted request. The locks that cover
# it are on tmpfs, because a lock that outlived the process that took it would
# only be a stale lock — while the claim a file records is on disk and is
# reclaimed by the pid in it.


def _require_queue() -> None:
    if not QUEUE.is_dir():
        raise errors.GuardenError(
            f"{QUEUE} does not exist; `soil storage` creates it 0770 root:guarden and "
            f"guarden does not create it, because a directory guarden created it would own",
            errors.HOST_NOT_AS_ASSUMED,
        )


def _path(name: str) -> Path:
    return QUEUE / f"{name}.json"


def _read(name: str) -> dict:
    try:
        entry = json.loads(_path(name).read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise errors.GuardenError(
            f"{_path(name)} is not a request {QUEUE} wrote: {exc}", errors.HOST_NOT_AS_ASSUMED
        ) from exc
    if not isinstance(entry, dict) or not isinstance(entry.get("name"), str):
        raise errors.GuardenError(
            f"{_path(name)} is not a request {QUEUE} wrote", errors.HOST_NOT_AS_ASSUMED
        )
    return entry


def _write(entry: dict) -> None:
    conf.write_file(
        _path(str(entry["name"])), json.dumps(entry, sort_keys=True) + "\n", REQUEST_MODE
    )


def _entries() -> list[dict]:
    _require_queue()
    return [_read(path.stem) for path in sorted(QUEUE.glob("*.json"))]


def _reclaim(entries: list[dict]) -> list[dict]:
    """Every claim whose process is gone is queued again, and written down.

    The flock is released by the kernel when a process dies, so a dead drainer
    holds no lock; only the file's claim survives, and a lane held by a claim
    with nobody behind it is a lane nothing will ever free.
    """
    for entry in entries:
        if entry.get("state") in RUNNING and not _alive(entry.get("pid")):
            entry["state"] = QUEUED
            entry["lane"] = None
            entry["pid"] = None
            _write(entry)
    return entries


def _alive(pid: object) -> bool:
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _ordered(entries: list[dict]) -> list[dict]:
    """`--now` first, then the track's weight, then arrival.

    A `--now` request is lifted to the front and everybody else keeps the order
    they arrived in, which is the whole of "skips queue position for this
    request and changes nobody else's".
    """
    return sorted(
        entries,
        key=lambda entry: (
            0 if entry.get("now") else 1,
            -int(entry.get("weight") or 0),
            str(entry.get("queued_at") or ""),
            str(entry.get("name") or ""),
        ),
    )


def _waiting(entries: list[dict]) -> list[dict]:
    return _ordered([entry for entry in entries if entry.get("state") == QUEUED])


def _builders(entries: list[dict]) -> list[dict]:
    return [entry for entry in entries if entry.get("state") == BUILDING]


def _in_flight(entries: list[dict]) -> int:
    return sum(1 for entry in entries if entry.get("state") in RUNNING)


def _claim() -> dict | None:
    """Take the next request the lanes allow. The queue lock covers it, alone.

    A request that needs a build waits for a free lane; one that pulls a
    prebuilt image never does, because it competes for no resource with anything
    and putting it behind a lane would make the box feel broken for no reason
    (ADR-0010). The claim and the lane are one act because both are the state of
    the queue directory and nothing else takes this lock.
    """
    with conf.lock("queue"):
        entries = _reclaim(_entries())
        lanes = _lanes()
        builders = _builders(entries)
        for entry in _waiting(entries):
            if not entry.get("build"):
                entry["state"] = DEPLOYING
                entry["lane"] = None
                entry["pid"] = os.getpid()
                _write(entry)
                return entry
            if len(builders) >= lanes:
                continue
            taken = {row.get("lane") for row in builders}
            entry["state"] = BUILDING
            entry["lane"] = next(
                (number for number in range(1, lanes + 1) if number not in taken), None
            )
            entry["pid"] = os.getpid()
            _write(entry)
            return entry
    return None


def _retire(entry: dict) -> None:
    """A finished request leaves no file, unless it failed and must be read.

    A request file left behind after a success is a file on the directory
    `guarden-queue.path` watches, re-triggering the drain for ever; a failed one
    is kept, because `furrow queue list` reports its message and a failure that
    leaves nothing behind is a failure nobody hears about.
    """
    name = str(entry["name"])
    with conf.lock("queue"):
        if entry.get("outcome") == 0:
            _path(name).unlink(missing_ok=True)
            return
        entry["state"] = FAILED
        entry["lane"] = None
        entry["pid"] = None
        entry["finished_at"] = _now()
        _write(entry)


def _reported(entry: dict) -> dict:
    return {field: entry.get(field) for field in REPORTED}


def _request_name(resolved: names.Resolved, sha: str) -> str:
    """The file one request is, so N identical requests are one build.

    The ref is the escaped form — the one rule for every place a ref becomes
    part of a path, a key or a filename — because a raw ref may carry a `/` and
    a queue file named after one is a path that does not exist.
    """
    if resolved.escaped_ref:
        return f"{resolved.name}-{resolved.escaped_ref}@{sha}"
    return f"{resolved.name}@{sha}"


# --- a request ---------------------------------------------------------------


def _poke(values: list[str] | None, sha_argument: str | None, known: bool, name: str
          ) -> tuple[str, str]:
    """`--from poke <project>@<sha>`, and nothing that could be a path.

    Two refusals, and they are different codes because they are different
    facts (spec 1.2): no `--from` and no registry entry is the host not being in
    the state the request assumed — exit `1`, naming the service — while no
    `--from` on a service that does exist is rejected input, exit `2`.
    """
    if not values:
        if not known:
            raise errors.GuardenError(
                f"{name} has no registry entry and no `--from` was given, so there is "
                f"nothing to deploy and nothing to redeploy; `--from poke <project>@<sha>` "
                f"names the commit to install",
                errors.HOST_NOT_AS_ASSUMED,
            )
        raise errors.GuardenError(
            "`--from` is required on a redeploy too: a deploy renders a staged tree, and "
            "the service's own home is 0700 to the service user, so guarden reads no tree "
            "of its own choosing; the form is `poke <project>@<sha>`",
            errors.REJECTED_INPUT,
        )
    if len(values) != 2 or values[0] != "poke":
        raise errors.GuardenError(
            "`--from` takes `poke <project>@<sha>` and never a path, and "
            + " ".join(repr(value) for value in values)
            + " is not that",
            errors.REJECTED_INPUT,
        )
    project, at, sha = values[1].partition("@")
    if not project or not at or not POKE_SHA.fullmatch(sha):
        raise errors.GuardenError(
            f"`--from poke` takes <project>@<sha> with a hexadecimal sha, and "
            f"{values[1]!r} is not that; the staging directory is assembled by the system "
            f"from two validated components",
            errors.REJECTED_INPUT,
        )
    if sha_argument and sha_argument != sha:
        raise errors.GuardenError(
            f"--sha {sha_argument} and --from poke {values[1]} name two different commits"
        )
    return project, sha


def _wants_build(source: Path) -> bool:
    """Whether the staged tree asks for an image to be built.

    Read from the repository's own declaration rather than from a render,
    because the answer decides whether the request takes a build lane and that
    is settled at enqueue time, before anything is rendered. A Compose service
    carrying a `build:` key and a quadlet unit carrying any `Build*` key in
    `[Container]` are the two spellings.
    """
    compose_file = source / compose.COMPOSE_REL
    if compose_file.is_file():
        document = compose.document(compose_file)
        return any(
            "build" in body for body in compose.services(document, compose_file).values()
        )
    quadlet = source / manifest_mod.MANIFEST_REL.parent / "quadlet"
    if not quadlet.is_dir():
        return False
    return any(
        any(key.startswith("Build") for key in unitsource.parse(path).keys("Container"))
        for path in sorted(quadlet.glob("*.container"))
    )


def _enqueue(args) -> dict:
    config = config_mod.load()
    resolved = names.resolve(args.name, list(config.tracks), allow_default=False)
    if resolved.track.kind == "instance" and not resolved.ref:
        raise errors.GuardenError(
            f"the track {resolved.track.name!r} is kind = \"instance\", so every deploy names "
            f"one instance: {resolved.name}/<ref>",
            errors.REJECTED_INPUT,
        )
    if resolved.ref and resolved.track.kind != "instance":
        raise errors.GuardenError(
            f"the track {resolved.track.name!r} is kind = \"slot\" and holds one service per "
            f"workload, so {resolved.name} takes no /<ref>",
            errors.REJECTED_INPUT,
        )

    known = registry.load(resolved.name) is not None
    project, sha = _poke(args.from_values, args.sha, known, resolved.name)
    source = paths.STAGING / project / sha
    if not (source / manifest_mod.MANIFEST_REL).is_file():
        raise errors.GuardenError(
            f"the staged tree {source} carries no {manifest_mod.MANIFEST_REL}, so there is "
            f"nothing to deploy; `weedr service ingest` resolves the same pair and would "
            f"say the same",
            errors.HOST_NOT_AS_ASSUMED,
        )

    name = _request_name(resolved, sha)
    with conf.lock("queue"):
        _require_queue()
        entry = _read(name) if _path(name).is_file() else {
            "name": name,
            "service": resolved.name,
            "ref": resolved.ref,
            "escaped_ref": resolved.escaped_ref,
            "queued_at": _now(),
        }
        if entry.get("state") in RUNNING and _alive(entry.get("pid")):
            return entry
        entry["sha"] = sha
        entry["project"] = project
        entry["weight"] = resolved.track.weight
        entry["now"] = bool(args.now)
        entry["build"] = _wants_build(source)
        entry["state"] = QUEUED
        entry["lane"] = None
        entry["pid"] = None
        entry["error"] = None
        _write(entry)
    return entry


# --- the deploy order --------------------------------------------------------


def _step(name: str, detail: str) -> None:
    sys.stdout.write(f"{name:<7} {detail}\n")


def _weedr(verb: str, target: str, doing: str, *extra: str) -> int:
    """One mutator verb, and the exit code it answered with.

    The return code is returned rather than thrown away because `gate` is the
    one verb whose non-zero answer is an answer: it is `1` on a blocked gate and
    the deploy branches on the verdict it recorded instead (spec 6.6).
    """
    result = tool.call(_root("service", verb, target, *extra))
    detail = errors.oneline(result.stderr.strip() or result.stdout.strip())
    if result.returncode not in (0, 1) or (verb != "gate" and not result.ok):
        raise errors.GuardenError(
            f"{doing}: weedr service {verb} {target} exited {result.returncode}"
            + (f": {detail}" if detail else ""),
            errors.HOST_NOT_AS_ASSUMED,
        )
    return result.returncode


def _ingest_argv(entry: dict) -> tuple[str, ...]:
    """The `--from` the mutator resolves to a staging tree, never a path.

    `weedr service ingest` requires `--from`, so a call without it is argparse's
    exit `2` and no service is ever created — the deploy would fail at step zero
    on every box. The pair the poke carried is what it is given, because the
    mutator builds `/var/lib/guarden/staging/<project>/<sha>` from it itself and
    a caller that could name a directory would be the traversal this form
    removed.
    """
    return ("--from", "poke", f"{entry['project']}@{entry['sha']}")


def _preview_drop(args) -> int:
    """`furrow preview drop <name> <ref>`, by the one verb a removal has."""
    target = f"{args.name}/{args.ref}"
    _weedr("remove", target, f"dropping the preview instance {target}")
    sys.stdout.write(f"dropped the instance {args.ref} of {args.name}\n")
    return 0


def _render(entry: dict, resolved: names.Resolved) -> Path:
    """`loom` as `guarden`, into the directory the mutator installs from."""
    source = paths.STAGING / str(entry["project"]) / str(entry["sha"])
    if not paths.LIB.is_dir():
        raise errors.GuardenError(
            f"{paths.LIB} does not exist; `soil install` creates the render directory "
            f"guarden renders into",
            errors.HOST_NOT_AS_ASSUMED,
        )
    out = paths.LIB / "render" / resolved.name
    if resolved.escaped_ref:
        out = out / str(resolved.escaped_ref)
    argv = [_installed(LOOM, "soil install --apply", "the renderer"),
            "render", str(source), "--service", resolved.name, "--out", str(out)]
    if resolved.escaped_ref:
        argv.extend(["--instance", str(resolved.escaped_ref)])
    result = tool.call(argv)
    if not result.ok:
        detail = errors.oneline(result.stderr.strip() or result.stdout.strip())
        raise errors.GuardenError(
            f"rendering {source} for {resolved.name}: loom exited {result.returncode}"
            + (f": {detail}" if detail else ""),
            errors.HOST_NOT_AS_ASSUMED,
        )
    if not out.is_dir():
        raise errors.GuardenError(
            f"loom wrote no units into {out} for {resolved.name}", errors.HOST_NOT_AS_ASSUMED
        )
    return out


def _gate(resolved: names.Resolved) -> tuple[str, str]:
    """`weedr service gate`, then the verdict it recorded.

    The verb answers `1` on a blocked gate because that is what it was asked and
    it changed nothing; the deploy reads the verdict back and branches, so the
    verb that says `1` and the deploy that says `0` are never both spoken about
    the same attempt (spec 6.6).
    """
    result = tool.call(_root("service", "gate", resolved.name))
    if result.returncode not in (0, 1):
        detail = errors.oneline(result.stderr.strip() or result.stdout.strip())
        raise errors.GuardenError(
            f"the credential gate of {resolved.name}: weedr service gate exited "
            f"{result.returncode}" + (f": {detail}" if detail else ""),
            errors.HOST_NOT_AS_ASSUMED,
        )
    record = registry.load(resolved.name)
    verdict = (record.gate if record else None) or {}
    state = str(verdict.get("state") or "")
    if state not in ("ready", "blocked", "not-required"):
        raise errors.GuardenError(
            f"weedr service gate recorded no verdict for {resolved.name}, so the deploy "
            f"cannot tell whether to start it",
            errors.HOST_NOT_AS_ASSUMED,
        )
    return state, str(verdict.get("reason") or "the gate recorded no reason")


def _deploy_lock(resolved: names.Resolved) -> str:
    """`deploy-<service>`, or `deploy-<service>-<escaped-ref>` for one instance.

    One deploy of one service holds this from its first step to its last, so two
    deploys of the same service cannot interleave their unit writes while
    different services proceed in parallel. An instance takes its own because a
    `kind = "instance"` track deploys every instance separately, and one lock
    per service would serialise the whole track's previews behind each other.
    """
    if resolved.escaped_ref:
        return f"deploy-{resolved.name}-{resolved.escaped_ref}"
    return f"deploy-{resolved.name}"


def _deploy(entry: dict) -> int:
    """One deploy, in the spec's order, and the exit code it earned.

    Nothing here takes the `queue` lock: spec 3.5 puts `queue` before
    `deploy-*`, and taking a lower lock inside a higher one is the deadlock the
    order exists to prevent. The claim was taken before this was called and is
    retired by the caller, so a request that fails in here has already stopped
    holding its lane the moment the caller hears about it.
    """
    resolved = names.resolve(
        str(entry["service"]) if not entry.get("ref") else f"{entry['service']}/{entry['ref']}",
        list(config_mod.load().tracks),
        allow_default=False,
    )
    # The escaped ref, not the raw one: `resolved.escaped_ref` is what the queue
    # file and the deploy lock carry, and a raw `feature/login` reaches the mutator
    # as a path, so no container is installed for the instance and the start that
    # follows finds an empty quadlet directory.
    target = (
        resolved.name
        if not resolved.ref
        else f"{resolved.name}/{resolved.escaped_ref}"
    )
    try:
        with conf.lock(_deploy_lock(resolved)):
            return _sequence(entry, resolved, target)
    except errors.GuardenError as failure:
        entry["outcome"] = failure.code
        entry["error"] = failure.message
        return failure.code


def _sequence(entry: dict, resolved: names.Resolved, target: str) -> int:
    """ensure, render, build, gate, stop, install, start — in that order.

    A step that raises ends the sequence there, and the build and the gate both
    land before the stop, so a failed either leaves the running container
    running (ADR-0011).
    """
    existing = registry.load(resolved.name)
    missing = existing is None or (
        resolved.escaped_ref is not None and resolved.escaped_ref not in existing.instances
    )
    if missing:
        _step("ensure", f"{resolved.name}: weedr service ingest --from poke")
        _weedr(
            "ingest", target, f"{resolved.name} could not be created from its staged tree",
            *_ingest_argv(entry),
        )
    else:
        _step("ensure", f"{resolved.name}: the registry already has an entry")

    out = _render(entry, resolved)
    _step("render", f"{target}: {sum(1 for _ in out.rglob('*'))} files")

    if entry.get("build"):
        _step("build", f"{resolved.name}: weedr service build")
        _weedr("build", resolved.name, f"the build of {resolved.name} failed")
    else:
        _step("build", f"{target}: no build instruction, so no build call")

    state, reason = _gate(resolved)
    _step("gate", f"{resolved.name}: {state}")

    if state == "blocked":
        _install(entry, resolved, target)
        message = (
            f"{resolved.name} deployed, waiting for the credential gate — reason: {reason}"
        )
        sys.stderr.write(errors.warn(message) + "\n")
        entry["outcome"] = 0
        entry["error"] = message
        return 0

    _step("stop", f"{target}: weedr service stop")
    _weedr("stop", target, f"the units of {target} did not stop")

    _install(entry, resolved, target)

    _step("start", f"{target}: weedr service start")
    _weedr("start", target, f"{target} did not start")
    entry["outcome"] = 0
    entry["error"] = None
    sys.stdout.write(f"deployed {target} at {entry['sha']}\n")
    return 0


def _install(entry: dict, resolved: names.Resolved, target: str) -> None:
    """The mutator verb that installs the rendered units and records the sha.

    `weedr service ingest` is the reconcile verb on the grant and it re-renders
    the service's own tree through `units.install`, so it is both the install and
    the record in one call. Calling it a second time for the install is what the
    order has: the units on disk come from the mutator's own render of the
    service's home, not from the unprivileged render this program held.
    """
    _step("install", f"{target}: weedr service ingest --from poke")
    _weedr(
        "ingest", target, f"the rendered units of {target} did not install",
        *_ingest_argv(entry),
    )


def _drain(mine: str) -> int:
    """Run what the queue allows, in order, and answer for the caller's request.

    One deploy at a time in this process and `build.lanes` claims in the queue
    directory, so the lane count bounds builds across every furrow on the box
    rather than inside this one — and `deploy-<service>` is what lets two
    furrows run two different services at the same moment. A request enqueued
    while this box was busy is on disk and survives this process, so whichever
    drain reaches it builds it.
    """
    while True:
        settled = _settled(mine)
        if settled is not None:
            return settled
        entry = _claim()
        if entry is None:
            if not _busy():
                break
            time.sleep(POLL)
            continue
        try:
            _deploy(entry)
        except Exception as failure:  # noqa: BLE001 - one line is the whole report
            entry["outcome"] = errors.HOST_NOT_AS_ASSUMED
            entry["error"] = f"the deploy of {entry['service']} failed: {failure}"
        _retire(entry)
    settled = _settled(mine)
    if settled is None:
        raise errors.GuardenError(
            f"{mine} is still queued on disk and no lane freed up for it; it is built by the "
            f"next drain, and the queue outlives a reboot",
            errors.HOST_NOT_AS_ASSUMED,
        )
    return settled


def _busy() -> bool:
    """Whether anything on this box is still queued or in flight.

    A deploy running in another furrow is a claim with a live pid behind it, and
    two pokes of one sha collapse into one request, so the wait is on the claim
    and not on this process alone.
    """
    return any(entry.get("state") in (QUEUED,) + RUNNING for entry in _entries())


def _entries_fresh() -> list[dict]:
    """Every request, with a claim whose process is gone released first.

    A claim nobody holds is a lane nothing will ever free, and releasing it is
    part of the state of an in-flight request, which is what the `queue` lock
    covers (spec 3.5). A reader takes the lock for this and for nothing else.
    """
    with conf.lock("queue"):
        return _reclaim(_entries())


def _settled(mine: str) -> int | None:
    """The caller's outcome: `0` deployed, `1` failed, `None` not yet."""
    if not _path(mine).is_file():
        return 0
    entry = _read(mine)
    if entry.get("state") != FAILED:
        return None
    sys.stderr.write(
        errors.GuardenError(str(entry.get("error") or "the deploy failed")).report(
            f"furrow deploy {entry.get('service')}") + "\n"
    )
    return int(entry.get("outcome") or 1)


# --- the read verbs ----------------------------------------------------------


def _visible(entries: list[dict]) -> list[dict]:
    """What is waiting, then what is running, then what failed — and why.

    A failure is reported rather than dropped: a request file left behind after a
    failure is the only record of it, and `queue list` is the verb an operator
    reads when a deploy went red.
    """
    rank = {QUEUED: 0, BUILDING: 1, DEPLOYING: 1, FAILED: 2}
    return sorted(
        entries,
        key=lambda entry: (rank.get(str(entry.get("state")), 3),
                           0 if entry.get("now") else 1,
                           -int(entry.get("weight") or 0),
                           str(entry.get("queued_at") or ""),
                           str(entry.get("name") or "")),
    )


def _lines(entries: list[dict]) -> list[str]:
    out: list[str] = []
    for position, entry in enumerate(entries, 1):
        lane = entry.get("lane")
        out.append(
            f"{position} {entry.get('service', '')}\t{entry.get('ref') or '-'}\t"
            f"{entry.get('sha') or '-'}\t{entry.get('state')}\tlane {lane if lane else '-'}\t"
            f"weight {entry.get('weight')}\t{entry.get('queued_at')}"
        )
        if entry.get("error"):
            out.append(f"  last failure: {entry['error']}")
    return out


def _list(args) -> int:
    waiting = _visible(_entries_fresh())
    if args.json:
        sys.stdout.write(
            json.dumps({"requests": [_reported(entry) for entry in waiting]},
                       separators=(",", ":")) + "\n"
        )
        return 0
    if not waiting:
        sys.stdout.write("nothing is waiting\n")
        return 0
    sys.stdout.write("\n".join(_lines(waiting)) + "\n")
    return 0


def _show(args) -> int:
    names.validate(args.service, "service")
    mine = [entry for entry in _visible(_entries_fresh()) if entry.get("service") == args.service]
    if not mine:
        sys.stdout.write(f"{args.service} has nothing waiting\n")
        return 0
    sys.stdout.write("\n".join(_lines(mine)) + "\n")
    return 0


def _status(args) -> int:
    entries = _entries_fresh()
    listing = {
        "lanes": _lanes(),
        "in_flight": _in_flight(entries),
        "deployed": len(registry.names()),
        "queued": len(_waiting(entries)),
    }
    if args.json:
        sys.stdout.write(json.dumps(listing, separators=(",", ":")) + "\n")
        return 0
    sys.stdout.write(
        f"lanes     {listing['lanes']}\n"
        f"in flight {listing['in_flight']}\n"
        f"deployed  {listing['deployed']}\n"
        f"queued    {listing['queued']}\n"
    )
    return 0


HANDLERS = {
    "furrow deploy": lambda args: _drain(str(_enqueue(args)["name"])),
    "furrow preview drop": _preview_drop,
    "furrow queue list": _list,
    "furrow queue show": _show,
    "furrow status": _status,
}


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    # A LEAF group records its own name in `verb`, so args.verb there is the group
    # repeated and every lookup missed: "furrow deploy deploy is not implemented"
    # for a verb that is implemented. A NESTED verb (`preview drop`, `queue list`)
    # puts the real verb there, and passing None for those lost it — "furrow
    # preview is not implemented". So: the verb, unless it merely repeats the group.
    verb = args.verb if args.verb and args.verb != args.group else None
    call = cli.invocation("furrow", args.group, verb)
    handler = HANDLERS.get(call)
    if handler is None:
        return cli.pending(call)
    try:
        return handler(args)
    except errors.GuardenError as failure:
        sys.stderr.write(failure.report(call) + "\n")
        return failure.code


if __name__ == "__main__":
    raise SystemExit(main())