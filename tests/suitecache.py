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

**The summary is refused unless the ledger accounts for the whole run.** The run
hands `report` the number of suites it selected, and a tally that disagrees with
it prints nothing at all: a ledger whose directory was pruned mid-run, truncated,
or left over from another run would otherwise be summarised as a smaller run
that passed — and the summary is the thing that gets believed (ticket 328). The
count comes from the run's selection and never from the file, so a file that
lost its lines cannot certify the run that wrote them.

**The key is a hash of the golden's identity, the suite's name, the tree it
reads, and the machine it was on.** The last of those is `mode` and `group`
together: `mode` is the sharing policy and the order the suites ran in
(`declared`, `fresh`, `shared`, and each reversed), and `group` is which shared
machine. Both come from `tests/lxc.sh` deciding the whole selection before it
runs anything, so a key never depends on which of its neighbours hit or missed.

The tree a suite reads is over-approximated, never narrowed below what is
provable. `fixtures/`, `modules/`, `packages/`, `tools/`, `examples/`,
`src/guarden/**` and `pyproject.toml` are in every key, because a suite
reaches those through helpers whose arguments cannot be resolved from
outside — `stage_config` reads `fixtures/$1` and `$1` is a bare name in the
suite. The root `.env.schema` is in every key as an over-approximation: the
only reader is `t35-env-schema.sh`, which the runner does not select, so
nothing in a machine run reads it, and carrying it costs one hash.

**Everything under `tests/` that is not a suite is in every key**, and the
predicate is the runner's own: `tests/lxc.sh` selects exactly
`tests/t[0-9]*.sh`, so a file under `tests/` is a suite iff its name matches
that, and the negation of that is every helper. `lib.sh`, `lxc.sh`,
`aptlock.sh`, `failure_messages.sh` and the `*.py` helpers are covered
because they exist, not because a list remembered them: naming four helpers
was the same enumeration that lost ticket 309, one file class wide — a
`tests/newhelper.sh` satisfied none of them and failed nothing. A suite's own
file is excluded from that set and added by path, so two suites are two read
sets and two digests, and a change to one suite moves that suite's key and no
other.

**The package is hashed whole rather than narrowed to an import closure**
(ticket 309): the closure asked which modules the suite's text named, and a
suite's result is not a function of that, so a src-only change could leave
every inherited green standing over code nothing had re-run. A key that misses
is worse than a key that hits too often, so what a suite executes is in and
what it only quotes — `docs/` — is out.

**A file's execute bit is in its row.** The tools under `tools/` are exec'd
rather than read, so the same bytes without the execute bit is a different
result — `Permission denied` where the suite expected an answer — and a
committed `100755` to `100644` would move no key at all.

**The developer's `.venv` is not a suite input and is not in the key.** It
supplies the interpreter and the two libraries the renderer needs, so it can
change what a suite runs against — but the runner's push leaves it behind,
so the machine ran against the guest's own `python3-yaml` and
`python3-jinja2` and never saw the developer's copy. A venv in the key would
make every `pip install` invalidate every cached green, and it would
describe a tree no suite ever reads.

**A suite may name the tree it reads, in its own text: `# reads: <path>`.** A
doc-assertion suite reads documents, and without this its green would be
inherited over an edited document — the same stale pass ticket 309 fixed for the
package, with a different tree. The name is per suite rather than universal
because a document is read by the suite that asserts on it and by nothing else:
`docs/` stays out of every key, and a doc enters the key of the one suite that
names it.

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
    suitecache.py report --ledger F --selected N --golden G --cuts N [--no-cache]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from datetime import UTC, datetime
from pathlib import Path

UNIVERSAL_FILES = ("pyproject.toml", ".env.schema")
UNIVERSAL_TREES = ("fixtures", "modules", "packages", "tools", "examples", "src/guarden")
# The runner's own notion of a suite: `tests/lxc.sh` selects exactly
# `tests/t[0-9]*.sh`. Everything under `tests/` that is NOT one of those is a
# helper the suites share, and it is in every key because it exists rather than
# because a list remembered it.
SUITE_FILE = re.compile(r"t[0-9].*\.sh")

# A suite may name the tree it reads, and the name is a line in the suite
# itself: `# reads: docs/sysadmin.md README.md`. **The claim is per suite,
# because a doc is read by the suite that asserts on it and by nothing else** —
# `docs/` is out of every key (a doc-only change must invalidate no cached
# green), and a suite that reads a doc is the one whose result changes when
# that doc does. Without this, a doc-assertion suite's green would be
# inherited over an edited document, which is the failure ticket 309 fixed for
# the package and the same failure for a different tree.
#
# The line is a list of paths relative to the repository root, one per line
# after the marker, so a suite names several without a parser for a
# comma-separated field. A path that does not exist is ignored rather than
# refused: a suite may name a file a future change adds, and a key that
# depended on a file's absence would move when the file appeared.
SUITE_READS = "reads:"
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


def files_under(root: Path, relative: str) -> list[str]:
    """The files a path covers, as names relative to the tree.

    A file covers itself and a directory covers everything under it that is not
    a bytecode cache. The bytes are read once, later, by `tree_digest` — this
    walks names only, so a covered file is hashed once per key.
    """
    target = root / relative
    if target.is_file():
        return [relative]
    if not target.is_dir():
        return []
    found = []
    for path in sorted(target.rglob("*")):
        relative_path = str(path.relative_to(root))
        if not path.is_file() or "__pycache__" in relative_path or path.suffix == ".pyc":
            continue
        found.append(relative_path)
    return found


def helper_files(root: Path) -> list[str]:
    """Every file under `tests/` that the runner does not select, as names relative to the tree.

    The predicate is the runner's: `tests/lxc.sh` selects exactly
    `tests/t[0-9]*.sh` — a direct child of `tests/` whose name starts with a
    `t` and a digit — so the negation of that is every helper the suites
    share. Naming them was the enumeration that lost ticket 309 one file class
    wide: a `tests/newhelper.sh` satisfied no list and failed nothing.

    A suite is excluded here and added by path in `read_set`, so the only
    difference between two suites' read sets is their own file, and two suites
    are two digests. A glob of `tests/*.sh` would have put every suite in
    every key and made them one digest, which is the trap this replaces.
    """
    tests = root / "tests"
    if not tests.is_dir():
        return []
    found = []
    for path in sorted(tests.rglob("*")):
        if not path.is_file() or "__pycache__" in path.parts or path.suffix == ".pyc":
            continue
        if path.parent == tests and SUITE_FILE.fullmatch(path.name):
            continue
        found.append(str(path.relative_to(root)))
    return found


def suite_reads(suite: Path) -> list[str]:
    """The paths a suite names in its own `# reads:` line.

    A line of the form `# reads: <path> [<path> ...]`, and every path after
    the marker on that line. The marker is read from the suite's text rather
    than from a list here, for the reason the machine declaration is: the claim
    travels with the suite that makes it, and a suite that forgets it reads
    nothing outside the universal set — which is the safe answer, because a
    missing name can only make a key hit too often, never too rarely for a
    file the suite does read.
    """
    named: list[str] = []
    try:
        text = suite.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return named
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped.startswith("#"):
            continue
        body = stripped.lstrip("#").strip()
        if not body.startswith(SUITE_READS):
            continue
        for token in body[len(SUITE_READS):].split():
            named.append(token)
    return named


def read_set(root: Path, suite: Path) -> list[str]:
    paths: dict[str, None] = {str(suite.relative_to(root)): None}
    for relative in (*UNIVERSAL_FILES, *UNIVERSAL_TREES):
        for relative_path in files_under(root, relative):
            paths[relative_path] = None
    for relative_path in helper_files(root):
        paths[relative_path] = None
    for relative in suite_reads(suite):
        for relative_path in files_under(root, relative):
            paths[relative_path] = None
    return sorted(paths)


def tree_digest(root: Path, suite: Path) -> str:
    """The digest of the read set: each name with its bytes and its execute bit.

    The mode is in the row because a file's bytes do not decide whether it can
    be run: the tools under `tools/` are exec'd rather than read, so the same
    bytes without the execute bit is a different result, and a committed
    `100755` to `100644` would otherwise move no key at all. The bit is read
    from the mode rather than from an access check, because a key must not
    depend on who asks: the same tree has to answer the same key for the
    runner and for the suite.
    """
    rows = []
    for name in read_set(root, suite):
        target = root / name
        executable = "x" if target.stat().st_mode & 0o111 else "-"
        rows.append(f"{name}\0{executable}\0{digest(target.read_bytes())}")
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
    # **The file cannot certify itself.** The number of suites the run selected
    # is the run's own fact and it arrives as an argument, so a tally that
    # disagrees with it is a record that is not the run's — a directory pruned
    # mid-run loses the lines already written, and a file left from another run
    # carries more. Either way there is no summary, because the only thing a
    # reader would take from one is a claim about work that is not in the record
    # (ticket 328).
    if total != args.selected:
        return refuse(
            f"the run's ledger {args.ledger} holds {total} suite line(s) and the run selected "
            f"{args.selected}, so it is not the run's own record; no summary is printed"
        )
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
    report.add_argument("--selected", type=int, required=True)
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
    except ValueError as exc:
        return refuse(str(exc), 2)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))