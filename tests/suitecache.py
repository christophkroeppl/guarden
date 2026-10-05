#!/usr/bin/env python3
"""One suite's result, keyed by what that result was a function of.

A suite passes or fails because of two things and nothing else: the machine it
ran on, and the tree it read. So the key is a hash of those two, and a key that
matches means the result may be **inherited** rather than observed again.

Every way this file could lie is closed here rather than at a call site:

- **Only an observed pass is recorded.** `put` takes the suite's exit code and
  refuses anything but `0`, so a failure has no record and the next run runs the
  suite.
- **A record answers only for the golden it was observed on.** The digest is in
  the directory name, in the record and in the key, and `get` checks all three.
  A rebuilt golden digests differently, so nothing is inherited from a machine
  that no longer exists, and `prune` reports what it dropped.
- **The golden's identity is machine-provided.** `golden` refuses a record with
  no readable absolute creation time, because a golden identified only by what
  this harness would have put in it cannot tell a rebuild from a restart.
- **The cache is outside the repository.** `cache_root` refuses a root that
  resolves inside the checkout.

Nothing here asks the clock whether a result is still good. There is no expiry,
because an expiry would make what a run means depend on how long ago it was.

**The key is a hash of the golden's identity, the suite's name, the tree it
reads, and the machine it was on.** The last of those is `mode` and `group`
together: `mode` is the sharing policy and the order the suites ran in
(`declared`, `fresh`, `shared`, and each reversed), and `group` is which shared
machine. Both come from `tests/lxc.sh` deciding the whole selection before it
runs anything, so a key never depends on which of its neighbours hit or missed.

The tree a suite reads is over-approximated, never narrowed below what is
provable. `tests/lib.sh`, `tests/lxc.sh`, `tests/*.py`, `fixtures/`, `modules/`,
`packages/`, `tools/`, `src/guarden/templates/` and `pyproject.toml` are in every
key, because a suite reaches those through helpers whose arguments cannot be
resolved from outside — `stage_config` reads `fixtures/$1` and `$1` is a bare
name in the suite. `src/guarden/*.py` is the narrowable part: the closure of the
modules the suite names, walked with `ast`. No resolvable name widens the key to
the whole package.

Usage:

    suitecache.py golden              identity on stdin, golden digest on stdout
    suitecache.py key <golden> <suite> <mode> <group>
    suitecache.py readset <suite>     the paths the suite's result depends on
    suitecache.py tree <suite>        the read set's digest
    suitecache.py get <golden> <key> <suite>
    suitecache.py why <golden> <key>  the record, for a human
    suitecache.py put <golden> <key> <suite> <mode> <group> <exit>
    suitecache.py prune <golden>      drop records from every other golden
    suitecache.py line <verdict> <suite>
    suitecache.py report --ledger F --golden G --cuts N [--no-cache]
"""

from __future__ import annotations

import argparse
import ast
import hashlib
import json
import os
import re
import sys
from datetime import UTC, datetime
from pathlib import Path

PROGRAMS = ("soil", "weedr", "loom", "roots", "twig", "furrow", "hose", "stakes")
UNIVERSAL_FILES = ("pyproject.toml", "tests/lib.sh", "tests/lxc.sh")
UNIVERSAL_GLOBS = ("tests/*.py",)
UNIVERSAL_TREES = ("fixtures", "modules", "packages", "tools", "src/guarden/templates")
PROGRAM_WORD = re.compile(r"\b(?:{})\b".format("|".join(PROGRAMS)))
ABSOLUTE_TIME = re.compile(r"^[0-9]{4}[-/][0-9]{2}[-/][0-9]{2} [0-9]{2}:[0-9]{2}(:[0-9]{2})?")
IDENTITY_FIELDS = ("instance", "pool", "snapshot", "created")
LEDGER_SEP = "\t"
VERDICTS: tuple[str, ...] = ("pass", "fail", "inherit")
LINES = {
    "pass": "ok   {suite}",
    "fail": "FAIL {suite}",
    "inherited": "inherit {suite}  (green from the cache; not observed this run)",
}


def refuse(message: str, code: int = 1) -> int:
    sys.stderr.write(f"error: {message}\n")
    return code


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def repo_root() -> Path:
    """The tree a suite's result is a function of.

    `GUARDEN_LXC_ROOT` moves it, and only so that a suite can prove the key
    follows the bytes **on a copy**. Changing a file to watch a digest move, and
    putting it back afterwards, is a test that leaks when it fails: the harness
    kills a suite that overruns with SIGKILL, no trap runs, and the next suite on
    a shared machine reads a tree one test left modified. A copy cannot leak into
    anything.
    """
    override = os.environ.get("GUARDEN_LXC_ROOT")
    return Path(override).resolve() if override else Path(__file__).resolve().parent.parent


def cache_root() -> Path:
    override = os.environ.get("GUARDEN_LXC_CACHE")
    base = Path(override).expanduser() if override else _xdg_cache()
    root = base if override else base / "guarden" / "suite-results"
    inside = root.resolve().is_relative_to(repo_root().resolve())
    if inside:
        raise ValueError(f"the suite cache at {root} is inside the repository")
    return root


def _xdg_cache() -> Path:
    home = os.environ.get("XDG_CACHE_HOME")
    return Path(home).expanduser() if home else Path.home() / ".cache"


def record_path(golden: str, key: str) -> Path:
    return cache_root() / golden / f"{key}.json"


def digests_of(root: Path, relative: str) -> list[tuple[str, str]]:
    target = root / relative
    if target.is_file():
        return [(relative, digest(target.read_bytes()))]
    if not target.is_dir():
        return []
    found = []
    for path in sorted(target.rglob("*")):
        relative_path = str(path.relative_to(root))
        if not path.is_file() or "__pycache__" in relative_path or path.suffix == ".pyc":
            continue
        found.append((relative_path, digest(path.read_bytes())))
    return found


def seeded_modules(root: Path, suite: Path) -> set[str]:
    """The guarden modules the suite names, plus whatever `tools/` reaches.

    Only the suite's own text and the tools are scanned. **`src/guarden` is not
    scanned for program names**, because a module mentions its siblings in prose
    and in data — `modules.py` carries `PROGRAMS = ("soil", "weedr", "loom", …)`,
    so a word-boundary search over the package pulls `loom.py` into the read set
    of every suite that imports `modules`, and `render.py` names `loom` in five
    docstring lines. That is not a narrower cache, it is a wrong one: the key
    would move when a comment moved.

    `tools/` is scanned because the harness's own plan is built by running
    `guarden.soil`, so a suite's outcome really is a function of `soil.py` even
    when the suite never names it.
    """
    seeds = set(PROGRAM_WORD.findall(suite.read_text(errors="replace")))
    tools = root / "tools"
    if tools.is_dir():
        for path in sorted(tools.iterdir()):
            if path.is_file():
                seeds |= set(PROGRAM_WORD.findall(path.read_text(errors="replace")))
    return seeds


def imported_names(path: Path) -> list[str]:
    names = []
    for node in ast.walk(ast.parse(path.read_text())):
        if isinstance(node, ast.ImportFrom) and not node.level and node.module:
            if node.module == "guarden":
                names.extend(alias.name.split(".")[0] for alias in node.names)
            elif node.module.startswith("guarden."):
                names.append(node.module.split(".")[1])
        elif isinstance(node, ast.Import):
            names.extend(
                alias.name.split(".")[1]
                for alias in node.names
                if alias.name.startswith("guarden.")
            )
    return names


def module_closure(root: Path, seeds: set[str]) -> list[str] | None:
    package = root / "src" / "guarden"
    resolved: set[str] = set()
    pending = sorted(seeds)
    while pending:
        name = pending.pop()
        if name in resolved:
            continue
        module = package / f"{name}.py"
        if not module.is_file():
            return None
        resolved.add(name)
        pending.extend(imported_names(module))
    return sorted(resolved)


def read_set(root: Path, suite: Path) -> list[str]:
    paths: dict[str, None] = {str(suite.relative_to(root)): None}
    for relative in (*UNIVERSAL_FILES, *UNIVERSAL_TREES):
        for relative_path, _ in digests_of(root, relative):
            paths[relative_path] = None
    for pattern in UNIVERSAL_GLOBS:
        for path in sorted(root.glob(pattern)):
            paths[str(path.relative_to(root))] = None
    closure = module_closure(root, seeded_modules(root, suite))
    if not closure:
        candidates = digests_of(root, "src/guarden")
    else:
        candidates = [("src/guarden/__init__.py", "")]
        candidates += [(f"src/guarden/{name}.py", "") for name in closure]
    for relative_path, _ in candidates:
        paths[relative_path] = None
    return sorted(paths)


def tree_digest(root: Path, suite: Path) -> str:
    rows = [f"{name}\0{digest((root / name).read_bytes())}" for name in read_set(root, suite)]
    return digest("\0".join(rows).encode())


def key_of(golden: str, suite: Path, mode: str, group: str) -> str:
    parts = (
        "suitecache-v1",
        golden,
        suite.name,
        mode,
        group,
        tree_digest(repo_root(), suite),
    )
    return digest("\0".join(parts).encode())


def cmd_golden(args: argparse.Namespace) -> int:
    record = sys.stdin.read()
    fields = dict(line.split("=", 1) for line in record.splitlines() if "=" in line)
    for field in IDENTITY_FIELDS:
        if not fields.get(field):
            return refuse(f"the golden's identity carries no {field}")
    if not ABSOLUTE_TIME.match(fields["created"]):
        return refuse(
            "the golden snapshot's creation time is not an absolute timestamp, so a "
            "rebuilt golden could not be told from the same one booted again"
        )
    print(digest(record.encode()))
    return 0


def cmd_key(args: argparse.Namespace) -> int:
    print(key_of(args.golden, Path(args.suite), args.mode, args.group))
    return 0


def cmd_tree(args: argparse.Namespace) -> int:
    suite = Path(args.suite)
    print(tree_digest(repo_root(), suite))
    return 0


def cmd_readset(args: argparse.Namespace) -> int:
    suite = Path(args.suite)
    for name in read_set(repo_root(), suite):
        print(name)
    return 0


def _load(golden: str, key: str) -> dict | None:
    try:
        record = json.loads(record_path(golden, key).read_text())
    except (OSError, json.JSONDecodeError):
        return None
    return record if isinstance(record, dict) else None


def cmd_get(args: argparse.Namespace) -> int:
    record = _load(args.golden, args.key)
    if record is None:
        return 1
    expected = ("green", args.golden, args.key, args.suite)
    if tuple(record.get(name) for name in ("outcome", "golden", "key", "suite")) != expected:
        return 1
    return 0


def cmd_why(args: argparse.Namespace) -> int:
    record = _load(args.golden, args.key)
    if record is None:
        return refuse(f"no recorded result at {record_path(args.golden, args.key)}")
    print(json.dumps(record, indent=2, sort_keys=True))
    return 0


def cmd_put(args: argparse.Namespace) -> int:
    if args.exit_code != "0":
        return refuse(
            f"{args.suite} exited {args.exit_code}, and only an observed pass is recorded, "
            "so the next run runs it again"
        )
    record = {
        "golden": args.golden,
        "group": args.group,
        "key": args.key,
        "mode": args.mode,
        "observed_at": datetime.now(UTC).isoformat(timespec="seconds"),
        "outcome": "green",
        "suite": args.suite,
    }
    path = record_path(args.golden, args.key)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".new")
    temporary.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)
    return 0


def cmd_prune(args: argparse.Namespace) -> int:
    dropped = 0
    for directory in sorted(cache_root().glob("*")):
        if directory.name == args.golden or not directory.is_dir():
            continue
        records = sorted(directory.glob("*.json"))
        dropped += len(records)
        for record in records:
            record.unlink()
        directory.rmdir()
    if dropped:
        print(
            f"note: dropped {dropped} recorded result(s) taken against a golden that is "
            "not the one this run cut from"
        )
    return 0


def cmd_line(args: argparse.Namespace) -> int:
    template = LINES.get(args.verdict)
    if template is None:
        return refuse(f"{args.verdict} is not a verdict; it is {' or '.join(VERDICTS)}", 2)
    print(template.format(suite=args.suite))
    return 0


def _tally(ledger: Path) -> dict[str, int]:
    counts = dict.fromkeys(VERDICTS, 0)
    for line in ledger.read_text().splitlines():
        verdict, _, name = line.partition(LEDGER_SEP)
        if verdict in counts and name:
            counts[verdict] += 1
    return counts


def cmd_report(args: argparse.Namespace) -> int:
    try:
        counts = _tally(Path(args.ledger))
    except OSError as exc:
        return refuse(f"cannot read the run's ledger {args.ledger}: {exc}")
    total = sum(counts.values())
    ran = counts["pass"] + counts["fail"]
    short = args.golden[:8] if args.golden else "none"
    print(
        f"{total} suites: {ran} ran, {counts['inherit']} inherited, "
        f"{counts['fail']} failures, {args.cuts} machines cut"
    )
    if args.no_cache:
        notes = [f"--no-cache: all {total} suites ran and every result was recorded"]
    elif counts["inherit"] == 0:
        notes = [f"all {total} suites ran; nothing was inherited"]
    elif ran == 0:
        notes = [
            f"no suite ran. This run verified nothing: all {total} results were "
            "inherited, and an inherited green is not an observed one",
            f"they are green on golden {short}, against this golden and this tree",
            "--no-cache runs every suite and is what a release gate uses",
        ]
    else:
        notes = [
            f"{counts['inherit']} of {total} suites were inherited, not run: green on "
            f"golden {short}, against this golden and this tree",
            f"the {ran} that ran are the only results this run observed",
            "--no-cache runs every suite and is what a release gate uses",
        ]
    for note in notes:
        print(f"note: {note}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="suitecache")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("golden")
    for name in ("key",):
        sub = commands.add_parser(name)
        sub.add_argument("golden")
        sub.add_argument("suite")
        sub.add_argument("mode")
        sub.add_argument("group")
    for name in ("tree", "readset"):
        commands.add_parser(name).add_argument("suite")
    for name in ("get", "why"):
        sub = commands.add_parser(name)
        sub.add_argument("golden")
        sub.add_argument("key")
        if name == "get":
            sub.add_argument("suite")
    put = commands.add_parser("put")
    put.add_argument("golden")
    put.add_argument("key")
    put.add_argument("suite")
    put.add_argument("mode")
    put.add_argument("group")
    put.add_argument("exit_code")
    commands.add_parser("prune").add_argument("golden")
    line = commands.add_parser("line")
    line.add_argument("verdict")
    line.add_argument("suite")
    report = commands.add_parser("report")
    report.add_argument("--ledger", required=True)
    report.add_argument("--golden", default="")
    report.add_argument("--cuts", type=int, default=0)
    report.add_argument("--no-cache", action="store_true")
    return parser


HANDLERS = {
    "golden": cmd_golden,
    "key": cmd_key,
    "tree": cmd_tree,
    "readset": cmd_readset,
    "get": cmd_get,
    "why": cmd_why,
    "put": cmd_put,
    "prune": cmd_prune,
    "line": cmd_line,
    "report": cmd_report,
}


def main(argv: list[str]) -> int:
    args = build_parser().parse_args(argv)
    try:
        return HANDLERS[args.command](args)
    except (ValueError, SyntaxError) as exc:
        return refuse(str(exc), 2)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))