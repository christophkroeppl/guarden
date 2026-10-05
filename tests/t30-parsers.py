#!/usr/bin/env python3
"""The manifest and registry parsers, tested directly.

spec 11 permits exactly this exception: "No test imports a program's internals.
The one exception is the manifest and registry parsers, which are tested
directly, because their failure is invisible from outside until it silently
drops a service's configuration."

Everything else the fast harness drives goes through a command line, because a
program's contract is its verbs, flags, exit codes, diagnostics and the files it
writes. A parser's contract is different: a key it drops is a key nobody hears
about, and the rule this ticket needs proven — **an unknown key is refused by
name, at every level** — is only observable from inside.

Run by tests/t30-parsers.sh.
"""

from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path

# The prefix is set before the import because guarden.paths reads it at module
# scope, and a parser test that read the real /etc/guarden would be a test that
# depends on the machine it ran on.
os.environ.setdefault("GUARDEN_PREFIX", tempfile.mkdtemp())
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

from guarden import conf, errors, manifest, names, overrides, registry  # noqa: E402

FAILURES: list[str] = []


def check(condition: bool, what: str) -> None:
    if not condition:
        FAILURES.append(what)


def refuses(document: str, code: int, contains: str, what: str) -> None:
    """One document, one refusal, one exit code, and the diagnostic naming the
    thing it is about."""
    path = _write(document)
    try:
        manifest.read(path)
    except errors.GuardenError as exc:
        check(exc.code == code, f"{what}: exit {exc.code}, expected {code}")
        check(contains in exc.message, f"{what}: {exc.message!r} does not name {contains!r}")
    else:
        FAILURES.append(f"{what}: accepted")
    finally:
        path.unlink()


def _write(body: str) -> Path:
    handle = tempfile.NamedTemporaryFile("w", suffix=".yml", delete=False, encoding="utf-8")
    handle.write(body)
    handle.close()
    return Path(handle.name)


def refuses_seed(value: str, contains: str, what: str) -> None:
    """One `seed` value as it arrives — as text in a file — and one refusal.

    Planted as text rather than built as a document, because the case is a hand
    edit: a registry is a file, and the shape an operator would type is the one
    the parser has to refuse. Quoting the number would have made it a string and
    tested something nobody would write.
    """
    path = Path(tempfile.mkdtemp()) / "myapp-preview.toml"
    path.write_text(
        'service = "myapp-preview"\n'
        'workload = "myapp"\n'
        'created = "2026-09-29T10:12:00Z"\n'
        '\n[instances."feature\\\\x2dlogin"]\n'
        'ref = "feature-login"\n'
        f"seed = {{ data = {value} }}\n",
        encoding="utf-8",
    )
    table = conf.read_toml(path)["instances"]["feature\\x2dlogin"]
    try:
        registry.Instance.from_document("feature\\x2dlogin", table)
    except errors.GuardenError as exc:
        check(exc.code == 1, f"{what}: exit {exc.code}, expected 1")
        check(contains in exc.message, f"{what}: {exc.message!r} does not name {contains!r}")
    else:
        FAILURES.append(f"{what}: accepted")


def manifests() -> None:
    document = manifest.read(_write("project: myapp\nstate:\n  - data\nbulk:\n  - chainstate\n"))
    check(document.project == "myapp", "project is read")
    check(document.state == ["data"], "state is read")
    check(document.bulk == ["chainstate"], "bulk is read")
    check(document.volume_kind("data") == "state", "a state volume says so")
    check(document.volume_kind("chainstate") == "bulk", "a bulk volume says so")

    # A `provides` entry is a single string naming a kind and nothing else,
    # because it carries no value and no structure.
    refuses("provides:\n  - db: 5432\n", 2, "not a string", "a structured provides entry")
    refuses("routes:\n  - web\n", 2, "a bare string is not a valid entry", "a bare string route")
    refuses("provides:\n  - cache\n", 2, "the kinds are", "an unknown provides kind")

    # A name in both lists is refused, naming it: the two differ in whether a
    # snapper configuration exists, and a volume with both is a volume with
    # neither answer.
    refuses(
        "state:\n  - data\nbulk:\n  - data\n", 2, "both a state and a bulk volume", "both lists"
    )

    # A volume name is a name, and `..` and a leading dot are not.
    refuses("state:\n  - ../escape\n", 2, "matching", "a volume name with ..")
    refuses("state:\n  - _x\n", 2, "matching", "a volume name starting with _")

    # The closed key set, at the top level and inside a known block. The top-level
    # check is the one the first version of this parser lacked, and it is why a
    # manifest asking for `authentification: true` used to get a route with no auth
    # on it and no diagnostic saying so.
    refuses("authentification: true\n", 2, "unknown key", "a typo at the top level")
    refuses(
        "routes:\n  - container: web\n    port: 3000\n    authentification: true\n",
        2,
        "a routes entry has an unknown key",
        "a typo inside a routes entry",
    )
    refuses(
        "widgets:\n  - container: web\n    file: w.yml\n    host: x\n",
        2,
        "a widgets entry has an unknown key",
        "a typo inside a widgets entry",
    )
    refuses("state:\n  - data\n  -\n", 2, "matching", "a null state entry")

    # The `environment` key is refused specifically, with a message saying who
    # decides it — it is the key a developer reaches for, and the answer is never
    # in the repository.
    refuses(
        "environment: production\n", 2, "the host decides the environment", "an environment key"
    )
    # A key a repository may not state is refused by name, and the four the
    # renderer consumes — a weight, a retention value, a build priority, a
    # lineage — now say *who owns it*, which is the answer somebody needs and an
    # "unknown key" never was. They are still exit 2 and they still name the key.
    for key in ("fork_from", "weight", "priority", "lineage", "cap", "keep_last"):
        refuses(f"{key}: whatever\n", 2, key, f"the {key} key")

    # A project name is a name; a service name's 31-character limit is applied to
    # the service name and not to this (spec 4).
    check(
        manifest.read(_write(f"project: {'a' * 40}\n")).project == "a" * 40,
        "a long project name is not a long service name",
    )
    refuses("project: MyApp\n", 2, "must match", "an uppercase project name")


def escaping() -> None:
    # One escaped form governs every place a ref becomes a path, a key or a
    # filename (spec 5.2), and `feature/x` and `feature-x` must never collide.
    check(names.systemd_escape("feature-login") == "feature\\x2dlogin", "a dash is escaped")
    check(
        names.systemd_escape("feature/x") == "feature\\x2fx",
        "a slash is escaped in place, so it cannot collide with a dash",
    )
    check(
        names.systemd_escape("feature/x") != names.systemd_escape("feature-x"),
        "a slash and a dash do not collide",
    )
    check(names.systemd_escape("main") == "main", "an ordinary ref is left alone")
    check(
        names.split("myapp-preview/feature/x") == ("myapp-preview", "feature/x"),
        "the split is on the first slash, so a ref may contain one",
    )
    check(names.split("myapp-preview") == ("myapp-preview", None), "no slash, no ref")
    try:
        names.validate("a" * 32)
    except errors.GuardenError as exc:
        check(exc.code == 2, "a long name is rejected input")
        check("31" in exc.message, "the 31-character limit is named")
    else:
        FAILURES.append("a 32-character name was accepted")
    try:
        names.validate("myapp..production")
    except errors.GuardenError as exc:
        check(".." in exc.message, "'..' is named")
    else:
        FAILURES.append("a name containing '..' was accepted")


def registries() -> None:
    # The registry is a projection: it round-trips through the write protocol and
    # through the standard library's parser, so what is written is what is read.
    record = registry.Registry(
        service="myapp-preview",
        workload="myapp",
        project="myapp",
        environment="preview",
        uid=1004,
        created="2026-09-29T10:12:00Z",
        source="gitops",
        provides=["db"],
        ports_requested=[8080],
        volumes={
            "data": registry.Volume("data", "state", "myapp-preview-feature\\x2dlogin-data", 42),
            "chainstate": registry.Volume("chainstate", "bulk"),
        },
        instances={
            "feature\\x2dlogin": registry.Instance(
                ref="feature-login",
                escaped_ref="feature\\x2dlogin",
                created="2026-09-29T10:12:00Z",
                publication={"web": 20120},
                seed={
                    "data": registry.Seed(
                        service="myapp-staging", volume="data", number=38
                    )
                },
            )
        },
    )
    path = Path(tempfile.mkdtemp()) / "myapp-preview.toml"
    conf.write_toml(path, record.to_document(), 0o640)
    body = path.read_text()
    check('[instances."feature\\\\x2dlogin"]' in body, "the instance key is quoted")
    check('"feature\\\\x2dlogin"' in body, "the escaped ref survives quoting")
    check('kinds = ["db"]' in body, "provides is written")
    check(
        'config = "myapp-preview-feature\\\\x2dlogin-data"' in body,
        "a volume key with a backslash",
    )
    check("[gate]" not in body, "an unevaluated gate omits the table entirely")

    parsed = conf.read_toml(path)
    back = registry.Registry.from_document(parsed)
    check(back.uid == 1004, "the uid round-trips")
    check(back.ports_requested == [8080], "the requested ports round-trip")
    check(back.volumes["data"].config == record.volumes["data"].config, "a config name round-trips")
    check(back.volumes["chainstate"].config is None, "a bulk volume has no configuration")
    check(back.volumes["chainstate"].snapshots is None, "a bulk volume has no snapshot number")
    check(back.gate is None, "an unevaluated gate is None and not a verdict")
    instance = back.instances["feature\\x2dlogin"]
    check(instance.ref == "feature-login", "the raw ref round-trips, not the escaped key")
    check(instance.publication == {"web": 20120}, "an instance publication round-trips")
    check(
        instance.seed["data"] == record.instances["feature\\x2dlogin"].seed["data"],
        "a seed round-trips",
    )
    check(
        instance.seed["data"].service == "myapp-staging",
        "a seed names the service the snapshot belongs to",
    )
    # A seed is a table of service, volume and number, and a bare number is
    # refused: the snapshot a fork took belongs to the **source**, and a preview
    # is protected because something was forked from the production snapshot it
    # came from. `{ data = 38 }` names a number with no service beside it, so the
    # reconciler could not mark anything and the number it held was unowned. This
    # is the assertion that says the registry refuses the shape spec 3.4's example
    # shows, and it is here rather than left to the reading because a bare number
    # is the shape an operator would hand-edit in.
    refuses_seed("38", "a bare number", "a bare seed number")
    refuses_seed(
        '{ volume = "data", number = 38 }', "is missing service", "a seed with no service"
    )
    check(
        [v.name for v in back.volume_list()] == ["data", "chainstate"],
        "state volumes are listed before bulk ones",
    )

    # A grants file with a key that is not a grant is refused by name, because a
    # silently ignored grant is one an operator believes is in effect, and a
    # retention value the ladder never reads is one nobody will notice is set.
    from guarden import paths

    conf.write_toml(
        paths.overrides("myapp-production"), {"ports": {"open": ["8080/tcp"]}, "routes": {"x": 1}}
    )
    try:
        overrides.load("myapp-production")
    except errors.GuardenError as exc:
        check(exc.code == 1, "an unknown overrides table is the host, so exit 1")
        check("routes" in exc.message, "the unknown table is named")
    else:
        FAILURES.append("an unknown overrides table was accepted")

    # And a grant resolves against one shape: the stored form carries the protocol,
    # the numbers do not.
    granted = overrides.Overrides(open=["8080/tcp", "9090/udp"])
    check(granted.granted_numbers() == [8080, 9090], "a grant is readable as a number")


def keys() -> None:
    """A TOML key is quoted when it is not a bare key, and the escaping is
    json.dumps's rather than a hand-rolled one."""
    check(conf.toml_key("data") == "data", "a bare key stays bare")
    check(conf.toml_key("myapp-production-data") == "myapp-production-data", "a dash is bare")
    check(conf.toml_key("feature\\x2dlogin") == '"feature\\\\x2dlogin"', "a backslash is quoted")
    check(conf.toml_string('say "hi"') == '"say \\"hi\\""', "a quote is escaped")
    check(conf.toml_string("café") == '"café"', "non-ascii is not escaped into a surrogate pair")
    check(conf.toml_value(True) == "true", "a boolean")
    check(conf.toml_value([1, "a"]) == '[1, "a"]', "a list")
    check(conf.toml_value({"a": 1}) == "{ a = 1 }", "an inline table")


def main() -> int:
    manifests()
    escaping()
    registries()
    keys()
    for failure in FAILURES:
        sys.stderr.write(f"error: {failure}\n")
    return 1 if FAILURES else 0


if __name__ == "__main__":
    raise SystemExit(main())
