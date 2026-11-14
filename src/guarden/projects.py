"""Projects, the refs each may deploy, and the key that pokes for it.

spec 3.2. `projects.toml` holds the projects, `projects.d/<project>.toml`
overrides one of them, and `weedr project add` writes the override so a project
can be edited without touching the file every other project shares.

**The environment a ref maps to is a permission set, not an assignment.** The
first matching pattern decides which set applies and nothing inside it is
decided by order, so a pattern carrying several tracks is legal and the caller
names the one it wants — or is refused with the set printed.

**The track table is not consulted on the read path.** `hose` is unprivileged
and `/etc/guarden/guarden.toml` is `0640 root:guarden` with no carve-out for it,
so a mapping is checked against the `[[environments]]` rows where root can see
them — `add` — and everywhere else a name the mutator does not recognise is
refused by the mutator, which is the layer that has to agree anyway.

A poke key is one `authorized_keys` line carrying a forced command, and
installing one is a root act. The line is written by this module and by nothing
else, `hose` has no verb that writes it, and the forced command is the only
place a project name appears at runtime.
"""

from __future__ import annotations

import base64
import binascii
import hashlib
import json
import os
import shutil
import sys
import time
from dataclasses import dataclass
from pathlib import Path

from guarden import conf, errors, names, paths, users

PROJECTS_D = paths.ETC_GUARDEN / "projects.d"
KEYS = paths.ETC / "ssh" / "authorized_keys.d" / "hose"
CONFIG_MODE = 0o444
KEYS_MODE = 0o644
STAGING_MODE = 0o755
HOSE_USER = "hose"
KEY_TYPE = "ssh-ed25519"
ADDED_TAG = "guarden-added-"
OPTIONS = "no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty"
REQUIRED_OPTIONS = tuple(OPTIONS.split(","))

# ADR-0009's per-project default: the three refs a new repository ships with.
# It is a permission set an admin narrows by editing the file `add` wrote, and
# `main` reaching `production` is the documented answer — the gate, not the
# creation, is what stands between it and a running container.
DEFAULT_ENVIRONMENTS = {
    "main": ["production"],
    "develop": ["staging"],
    "*": ["preview"],
}


@dataclass(frozen=True)
class Project:
    name: str
    repository: str
    environments: dict[str, tuple[str, ...]]
    where: Path


def _type_error(where: Path, key: str) -> errors.GuardenError:
    return errors.GuardenError(
        f"{where}: {key} is not what this file may carry",
        errors.HOST_NOT_AS_ASSUMED,
    )


def _entry(document: dict, name: str, where: Path) -> Project | None:
    projects = document.get("projects", {})
    if projects and not isinstance(projects, dict):
        raise _type_error(where, "projects")
    table = projects.get(name) if isinstance(projects, dict) else None
    if table is None and name == where.stem and where.parent == PROJECTS_D:
        table = document
    if table is None:
        return None
    if not isinstance(table, dict):
        raise _type_error(where, f"projects.{name}")
    repository = table.get("repository", "")
    if not isinstance(repository, str):
        raise _type_error(where, f"projects.{name}.repository")
    mapping = table.get("environments", {})
    if not isinstance(mapping, dict):
        raise _type_error(where, f"projects.{name}.environments")
    environments: dict[str, tuple[str, ...]] = {}
    for pattern, tracks in mapping.items():
        if (
            not isinstance(tracks, list)
            or not tracks
            or not all(isinstance(track, str) for track in tracks)
        ):
            raise errors.GuardenError(
                f"{where}: the key {pattern!r} under {name} is not a list of environment "
                f"names, and an allowlist that grants nothing is not an allowlist",
                errors.HOST_NOT_AS_ASSUMED,
            )
        for track in tracks:
            names.validate(track, f"the environment named by {pattern!r} in {where}")
        environments[pattern] = tuple(tracks)
    return Project(name=name, repository=repository, environments=environments, where=where)


def load() -> dict[str, Project]:
    """Every project, with `projects.d/` winning over the file above it."""
    out: dict[str, Project] = {}
    root = conf.read_toml(paths.PROJECTS_TOML)
    table = root.get("projects", {})
    if table and not isinstance(table, dict):
        raise _type_error(paths.PROJECTS_TOML, "projects")
    for name in sorted(table):
        entry = _entry(root, name, paths.PROJECTS_TOML)
        if entry is not None:
            out[name] = entry
    if PROJECTS_D.is_dir():
        for path in sorted(PROJECTS_D.glob("*.toml")):
            if not path.is_file():
                continue
            entry = _entry(conf.read_toml(path), path.stem, path)
            if entry is None:
                raise errors.GuardenError(
                    f"{path} declares no project, so the file a `weedr project add` wrote "
                    f"has nothing in it",
                    errors.HOST_NOT_AS_ASSUMED,
                )
            out[path.stem] = entry
    return out


def get(name: str) -> Project:
    """One registered project, or the host not being in the state assumed."""
    project = load().get(name)
    if project is None:
        known = ", ".join(sorted(load())) or "none"
        raise errors.GuardenError(
            f"no project {name!r} in {paths.PROJECTS_TOML} or {PROJECTS_D}/; the projects "
            f"registered here are: {known}. `weedr project add {name} --repository <url>` "
            f"registers one",
            errors.HOST_NOT_AS_ASSUMED,
        )
    return project


def _matches(pattern: str, ref: str) -> bool:
    """`fnmatch` without the shell: a pattern is a glob over a ref, and `*` is
    the only wildcard anything here promises."""
    parts = pattern.split("*")
    if len(parts) == 1:
        return pattern == ref
    if not ref.startswith(parts[0]) or not ref.endswith(parts[-1]):
        return len(parts) > 1 and pattern.strip("*") == ""
    position = len(parts[0])
    for part in parts[1:-1]:
        found = ref.find(part, position)
        if found < 0:
            return False
        position = found + len(part)
    return True


def allowed(project: Project, ref: str) -> tuple[str, ...]:
    """The tracks this ref may deploy to, from the first pattern that matches."""
    for pattern, tracks in project.environments.items():
        if _matches(pattern, ref):
            return tracks
    patterns = ", ".join(repr(pattern) for pattern in project.environments) or "none"
    raise errors.GuardenError(
        f"ref {ref!r} matches no pattern in {project.where} for project {project.name!r}, "
        f"so it may deploy nowhere; the patterns are: {patterns}",
        errors.HOST_NOT_AS_ASSUMED,
    )


def choose(project: Project, ref: str, requested: str | None) -> str:
    """The one environment a request may use, from the set its ref is granted."""
    tracks = allowed(project, ref)
    if requested is None:
        if len(tracks) == 1:
            return tracks[0]
        raise errors.GuardenError(
            f"the pattern matching ref {ref!r} in {project.where} grants "
            f"{len(tracks)} environments ({', '.join(tracks)}), and naming none of them "
            f"would make a permission set behave like an assignment; `hose poke` takes "
            f"the environment as its third argument",
            errors.REJECTED_INPUT,
        )
    if requested not in tracks:
        raise errors.GuardenError(
            f"ref {ref!r} of project {project.name!r} may deploy to "
            f"{', '.join(tracks)} in {project.where} and not to {requested!r}",
            errors.REJECTED_INPUT,
        )
    return requested


def parse_mapping(argument: str | None) -> dict[str, list[str]]:
    """`main=production,develop=staging`, and `pattern=one|two` for a set."""
    if not argument:
        return {pattern: list(tracks) for pattern, tracks in DEFAULT_ENVIRONMENTS.items()}
    out: dict[str, list[str]] = {}
    for pair in argument.split(","):
        pattern, sep, value = pair.partition("=")
        pattern = pattern.strip()
        if not sep or not pattern or not value.strip():
            raise errors.GuardenError(
                f"--environments takes `ref=track` pairs separated by commas, and "
                f"{pair!r} is not one of them",
                errors.REJECTED_INPUT,
            )
        tracks = [item.strip() for item in value.split("|") if item.strip()]
        if not tracks:
            raise errors.GuardenError(
                f"--environments names no track for {pattern!r}",
                errors.REJECTED_INPUT,
            )
        out[pattern] = tracks
    return out


def validate_tracks(where: Path, environments: dict[str, list[str]], tracks) -> None:
    """Every environment a mapping names must be a row the operator wrote.

    Refused rather than created: a mapping naming an unknown environment would
    otherwise be a track the deploy then cannot resolve, and the failure would
    arrive as a service name with a segment nothing on the host knows.
    """
    known = names.known_tracks(list(tracks))
    for pattern, wanted in environments.items():
        for track in wanted:
            if track not in known:
                raise errors.GuardenError(
                    f"{where}: the key {pattern!r} names the environment {track!r}, and "
                    f"{paths.GUARDEN_TOML} defines no such track; the tracks are: {known}. "
                    f"A mapping may narrow what a ref may deploy to and may not add a "
                    f"track of its own",
                    errors.REJECTED_INPUT,
                )


def path_of(name: str) -> Path:
    return PROJECTS_D / f"{name}.toml"


def add(name: str, repository: str, mapping: str | None, config) -> Project:
    names.validate(name, "project name")
    if not repository:
        raise errors.GuardenError("--repository is required and names nothing here", 2)
    environments = parse_mapping(mapping)
    validate_tracks(path_of(name), environments, config.tracks)
    project = Project(
        name=name,
        repository=repository,
        environments={pattern: tuple(tracks) for pattern, tracks in environments.items()},
        where=path_of(name),
    )
    with conf.lock("projects"):
        conf.write_toml(
            path_of(name),
            {"projects": {name: {
                "repository": repository,
                "environments": {p: list(t) for p, t in environments.items()},
            }}},
            mode=CONFIG_MODE,
        )
    return project


def remove(name: str) -> None:
    project = load().get(name)
    target = path_of(name)
    if project is None and not target.is_file():
        known = ", ".join(sorted(load())) or "none"
        raise errors.GuardenError(
            f"no project {name!r} to remove; the projects registered here are: {known}",
            errors.HOST_NOT_AS_ASSUMED,
        )
    installed = key_entries(name)
    if installed:
        raise errors.GuardenError(
            f"{name} still has {len(installed)} poke key(s) installed in {KEYS}, and "
            f"removing the project under a live key would leave a key whose every poke "
            f"fails for a reason that names nothing; `weedr project revoke {name} <pubkey>` "
            f"takes them away first",
            errors.HOST_NOT_AS_ASSUMED,
        )
    with conf.lock("projects"):
        target.unlink(missing_ok=True)
        _drop_staging(name)
        PROJECTS_D.rmdir() if PROJECTS_D.is_dir() and not any(PROJECTS_D.iterdir()) else None


# --- the keys ----------------------------------------------------------------


def _decode(pubkey: str, where: str) -> tuple[str, str]:
    """`<type> <base64>`, and the blob is asked what it says it is."""
    words = pubkey.split()
    if len(words) < 2:
        raise errors.GuardenError(
            f"a poke key is `ssh-ed25519 <base64>`, and {pubkey!r} is not that", 2
        )
    kind, blob = words[0], words[1]
    if kind != KEY_TYPE:
        raise errors.GuardenError(
            f"a poke key must be {KEY_TYPE} and {kind!r} is not, so the line would be "
            f"written for a key type this host does not read",
            2,
        )
    try:
        raw = base64.b64decode(blob, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise errors.GuardenError(
            f"the public key in {where} is not base64 and cannot be an ssh key: {exc}", 2
        ) from None
    # The blob is the SSH wire format, so it opens with a 4-byte big-endian
    # length and then the type: \x00\x00\x00\x0bssh-ed25519. Checking for the type
    # at offset 0 refused every real key; the length prefix is what the format
    # puts there.
    want = KEY_TYPE.encode()
    if raw[4:4 + len(want)] != want:
        raise errors.GuardenError(
            f"the key in {where} is declared {KEY_TYPE} but its contents are not, so the "
            f"key blob and the type disagree",
            2,
        )
    return kind, blob


def fingerprint(blob: str) -> str:
    raw = base64.b64decode(blob, validate=True)
    digest = base64.b64encode(hashlib.sha256(raw).digest()).decode().rstrip("=")
    return f"SHA256:{digest}"


def _forced(line: str) -> str | None:
    """The project a line's forced command binds, or `None` for a line without
    one. Parsed out of the option list rather than by token position: the forced
    command itself contains spaces, so every token after the first is shifted."""
    for option in _options(line):
        if option.startswith("command="):
            body = option[len("command="):].strip()
            if len(body) >= 2 and body[0] == body[-1] == '"':
                body = body[1:-1]
            words = body.split()
            if "--project" in words:
                index = words.index("--project")
                if index + 1 < len(words):
                    return words[index + 1]
    return None


def _options(line: str) -> list[str]:
    """The option list, respecting the quotes inside a `command="…"` value.

    Splitting on `,` alone splits a forced command's own words, and the value
    has to come back whole or the project name in it is a fragment."""
    out: list[str] = []
    current = ""
    quoted = False
    for char in line:
        if char == '"':
            quoted = not quoted
            current += char
            continue
        if char == "," and not quoted:
            out.append(current)
            current = ""
            continue
        current += char
    if current:
        out.append(current)
    return out


def parse_line(line: str) -> dict | None:
    """One `authorized_keys` line, or `None` when it is not a poke key."""
    words = line.split()
    if KEY_TYPE not in words:
        return None
    index = words.index(KEY_TYPE)
    if index + 1 >= len(words):
        return None
    blob = words[index + 1]
    tagged = len(words) > index + 2 and words[index + 2].startswith(ADDED_TAG)
    return {
        "project": _forced(line),
        "type": KEY_TYPE,
        "blob": blob,
        "added": words[index + 2][len(ADDED_TAG):] if tagged else "",
    }


def _lines() -> list[str]:
    try:
        return [
            line.strip()
            for line in KEYS.read_text().splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        ]
    except FileNotFoundError:
        return []
    except OSError as exc:
        raise errors.GuardenError(
            f"{KEYS} could not be read: {exc.strerror}", errors.HOST_NOT_AS_ASSUMED
        ) from None


def key_entries(project: str) -> list[str]:
    return [line for line in _lines() if _forced(line) == project]


def key_projects() -> dict[str, str]:
    """Each forced command's project name to the key blob it binds, so `hose`
    can see whether a key names this project and only this project."""
    found: dict[str, str] = {}
    for line in _lines():
        parsed = parse_line(line)
        if parsed is not None and parsed["project"] is not None:
            found[str(parsed["project"])] = str(parsed["blob"])
    return found


def forced_command(project: str) -> str:
    return f'command="{paths.BIN / "hose"} --project {project}",{OPTIONS}'


def grant(project_name: str, pubkey: str) -> str:
    get(project_name)
    kind, blob = _decode(pubkey, "the argument")
    stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    line = f"{forced_command(project_name)} {kind} {blob} {ADDED_TAG}{stamp}"
    with conf.lock("projects"):
        existing = _lines()
        if any(
            _same_key(item, project_name, blob) for item in existing
        ):
            return "already"
        KEYS.parent.mkdir(parents=True, exist_ok=True)
        conf.write_file(KEYS, "".join(f"{item}\n" for item in [*existing, line]), KEYS_MODE)
    _make_staging(project_name)
    return "granted"


def revoke(project_name: str, pubkey: str) -> str:
    project = load().get(project_name)
    if project is None:
        raise errors.GuardenError(
            f"no project {project_name!r} in {paths.PROJECTS_TOML} or {PROJECTS_D}/, so it "
            f"has no key to revoke",
            errors.HOST_NOT_AS_ASSUMED,
        )
    _, blob = _decode(pubkey, "the argument")
    kept: list[str] = []
    taken = 0
    with conf.lock("projects"):
        for line in _lines():
            if _same_key(line, project_name, blob):
                taken += 1
                continue
            kept.append(line)
        if taken:
            KEYS.parent.mkdir(parents=True, exist_ok=True)
            conf.write_file(KEYS, "".join(f"{item}\n" for item in kept), KEYS_MODE)
            if not any(_forced(item) == project_name for item in kept):
                _drop_staging(project_name)
    return "revoked" if taken else "absent"


def _same_key(line: str, project_name: str, blob: str) -> bool:
    """Whether one line is exactly this project's this key, so a revoke takes
    away the line it was asked about and leaves every other line alone."""
    parsed = parse_line(line)
    return parsed is not None and parsed["project"] == project_name \
        and parsed["blob"] == blob


def keys_of(project_name: str) -> list[dict]:
    out: list[dict] = []
    for line in key_entries(project_name):
        parsed = parse_line(line)
        if parsed is None:
            continue
        out.append({
            "type": parsed["type"],
            "fingerprint": fingerprint(str(parsed["blob"])),
            "added": parsed["added"],
        })
    return out


# --- the staging directory ---------------------------------------------------


def staging(project_name: str) -> Path:
    return paths.STAGING / project_name


def _hose_ids() -> tuple[int, int]:
    entry = users.passwd_entries().get(HOSE_USER)
    if entry is None:
        raise errors.GuardenError(
            f"there is no {HOSE_USER} user on this host, and a poke arrives as {HOSE_USER}; "
            f"`soil install --apply` creates it",
            errors.HOST_NOT_AS_ASSUMED,
        )
    return entry


def _make_staging(project_name: str) -> None:
    """Created when the key is installed, because `hose` cannot mkdir under a
    `0755 root:root` parent and a poke must not have to ask permission to exist."""
    target = staging(project_name)
    target.mkdir(parents=True, exist_ok=True)
    os.chmod(target, STAGING_MODE)
    uid, _ = _hose_ids()
    conf.set_owner(target, (uid, users.group_id("root")))


def _drop_staging(project_name: str) -> None:
    target = staging(project_name)
    if not target.exists():
        return
    shutil.rmtree(target)


# --- the verbs, as `weedr project` runs them ---------------------------------


def _config():
    from guarden import config as config_mod

    return config_mod.load()


def list_json(args) -> int:
    """`weedr project list`: the projects, and where each one's copy of the
    allowlist is. The one verb on the poke's sudoers rule, and it reads nothing
    private: `projects.toml` and the files under `projects.d/` are `0444`
    precisely so that it can."""
    as_json = args.json
    found = load()
    if as_json:
        document = {
            "projects": [
                {
                    "name": name,
                    "repository": found[name].repository,
                    "environments": {
                        pattern: list(tracks)
                        for pattern, tracks in found[name].environments.items()
                    },
                }
                for name in sorted(found)
            ]
        }
        sys.stdout.write(json.dumps(document, separators=(",", ":")) + "\n")
        return 0
    if not found:
        sys.stdout.write("no projects\n")
        return 0
    for name in sorted(found):
        entry = found[name]
        sys.stdout.write(f"{name}  {entry.repository}  {entry.where}\n")
        for pattern, tracks in entry.environments.items():
            sys.stdout.write(f"  {pattern} -> {', '.join(tracks)}\n")
    return 0


def list_keys(args) -> int:
    """`weedr project keys`: what is installed, by type and fingerprint. Never a
    value, and a forced command is reported so an operator can see which project
    a line is bound to."""
    project_name = args.name
    get(project_name)
    as_json = args.json
    keys = keys_of(project_name)
    if as_json:
        sys.stdout.write(
            json.dumps({"project": project_name, "keys": keys}, separators=(",", ":")) + "\n"
        )
        return 0
    if not keys:
        sys.stdout.write(f"{project_name} has no poke key\n")
        return 0
    for entry in keys:
        sys.stdout.write(
            f"{project_name}  {entry['type']}  {entry['fingerprint']}  added "
            f"{entry['added'] or 'unknown'}\n"
        )
    return 0


def do_add(args) -> int:
    """Writing the `projects.d/` copy is the whole of what `add` is: the shared
    file is left alone, so an edit is one file and a rollback is one `rm`."""
    project = add(args.name, args.repository, args.environments, _config())
    sys.stdout.write(
        f"added {project.name} to {project.where}; refs and the tracks they may deploy "
        f"to:\n"
    )
    for pattern, tracks in project.environments.items():
        sys.stdout.write(f"  {pattern} -> {', '.join(tracks)}\n")
    return 0


def do_remove(args) -> int:
    remove(args.name)
    sys.stdout.write(f"removed the project {args.name} and its staging directory\n")
    return 0


def do_grant(args) -> int:
    """`weedr project grant`, never `hose grant`: writing an `authorized_keys`
    line is a root action and the only network-facing program has no business
    holding one. The per-project staging directory is created here because
    `hose` cannot mkdir under a `0755 root:root` parent."""
    outcome = grant(args.name, args.pubkey)
    if outcome == "already":
        sys.stdout.write(f"the key is already installed for {args.name}\n")
        return 0
    _, blob = _decode(args.pubkey, "the argument")
    sys.stdout.write(f"granted {args.name} {fingerprint(blob)}\n")
    sys.stdout.write(f"the forced command is: {forced_command(args.name)}\n")
    sys.stdout.write(f"{staging(args.name)} is {STAGING_MODE:04o} and owned by "
                     f"{HOSE_USER}\n")
    return 0


def do_revoke(args) -> int:
    outcome = revoke(args.name, args.pubkey)
    if outcome == "absent":
        sys.stdout.write(f"{args.name} has no such key installed\n")
        return 0
    sys.stdout.write(f"revoked one key of {args.name} from {KEYS}\n")
    return 0