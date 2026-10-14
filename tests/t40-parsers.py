#!/usr/bin/env python3
"""The unit-source and secret-schema parsers, tested directly.

spec 11 permits exactly this exception — "the manifest and registry parsers, are
tested directly, because their failure is invisible from outside until it
silently drops a service's configuration" — and the two parsers the renderer
depends on for the same reason are the unit source (a `.container` file, or what
the converter made of a Compose file) and the varlock schema.

Both are load-bearing in a way a command-line test cannot see. A unit file
parsed with its `[Container]` table attributed to `[Unit]` has its `Volume=`
lines rewritten by a pass that was looking at the wrong table, and the rendered
unit ships with the repository's own mount; a schema that drops one annotation
drops one credential request, and a container that starts without a key it
needed is a failure nobody was told about.

Run by tests/t40-parsers.sh.
"""

from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path

os.environ.setdefault("GUARDEN_PREFIX", tempfile.mkdtemp())
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

from guarden import errors, secretschema, unitsource  # noqa: E402

FAILURES: list[str] = []


def check(condition: bool, what: str) -> None:
    if not condition:
        FAILURES.append(what)


def refuses(text: str, code: int, contains: str, what: str) -> None:
    path = _write(text, ".container")
    try:
        unitsource.parse(path)
    except errors.GuardenError as exc:
        check(exc.code == code, f"{what}: exit {exc.code}, expected {code}")
        check(contains in exc.message, f"{what}: {exc.message!r} does not name {contains!r}")
    else:
        FAILURES.append(f"{what}: accepted")
    finally:
        path.unlink()


def _write(body: str, suffix: str) -> Path:
    handle = tempfile.NamedTemporaryFile("w", suffix=suffix, delete=False, encoding="utf-8")
    handle.write(body)
    handle.close()
    return Path(handle.name)


def sections() -> None:
    path = _write(
        "# a comment\n"
        "[Unit]\n"
        "Description=the web container\n"
        "\n"
        "[Container]\n"
        "Image=docker.io/library/nginx:1.27\n"
        "Volume=data:/var/lib/app\n"
        "Volume=chainstate:/data\n"
        "AddHost=provider:10.0.2.2\n"
        "AddHost=other:10.0.2.3\n"
        "Environment=APP_HOST=example.com\n"
        "\n"
        "[Service]\n"
        "Restart=always\n",
        ".container",
    )
    try:
        unit = unitsource.parse(path)
        check(unit.one("Container", "Image") == "docker.io/library/nginx:1.27", "Image is read")
        check(unit.one("Unit", "Description") == "the web container", "Description is read")
        # Repeated keys are meaningful and order is kept: `Volume=` and
        # `AddHost=` are both list-valued in quadlet, and a renderer that
        # collapsed them into a set would install a unit with one of the two.
        check(unit.get("Container", "Volume") == ["data:/var/lib/app", "chainstate:/data"],
              "both Volume lines are kept, in order")
        check(unit.get("Container", "AddHost") == ["provider:10.0.2.2", "other:10.0.2.3"],
              "both AddHost lines are kept, in order")
        check(unit.one("Service", "Restart") == "always", "a [Service] key is read")
        check(unit.get("Unit", "Image") == [], "a key is not read into another table")
        check(unit.get("Container", "Description") == [],
              "a [Unit] key is not read into [Container]")
        check(unit.stem() == Path(path.name).stem, "the stem is the file's")
    finally:
        path.unlink()


def continuations() -> None:
    """A line ending in a backslash continues. podlet emits them, and a joined
    value read as two keys is a unit systemd refuses to start."""
    path = _write(
        "[Container]\n"
        "Environment=A=1 \\\n"
        "    B=2 \\\n"
        "    C=3\n"
        "Image=alpine:3.20\n",
        ".container",
    )
    try:
        unit = unitsource.parse(path)
        check(unit.get("Container", "Environment") == ["A=1 B=2 C=3"],
              "a continuation is one value")
        check(unit.get("Container", "Image") == ["alpine:3.20"],
              "the key after a continuation is its own")
    finally:
        path.unlink()


def refusals() -> None:
    refuses("Image=alpine:3.20\n", 2, "before any section header", "a key before a section")
    refuses("[Container]\nnot a key value\n", 2, "neither a section header", "a bare line")
    refuses("[Container\nImage=x\n", 2, "section header", "a malformed header")
    refuses("[Container]\n=x\n", 2, "neither a section header", "an empty key")
    # A value with a space in a key that does not take a quoted value is refused
    # when the unit is *written*, not when it is read: reading it strictly would
    # refuse a file the repository can still fix, and the alternative to
    # refusing is a line that means one thing and parses as another.
    try:
        unitsource.format_line("AddHost", "a:1 2", Path("/tmp/web.container"))
    except errors.GuardenError as exc:
        check(exc.code == 2, f"a spaced value: exit {exc.code}, expected 2")
        check("does not take a quoted value" in exc.message, "a spaced value names the reason")
    else:
        FAILURES.append("a spaced value: accepted")
    # **`Environment=` is a list of assignments and is never quoted.** A quoted
    # value collapses to a SINGLE `--env`, so `Environment="A=1 B=2"` gives the
    # container one variable named `A` whose value is `1 B=2` and no `B` at all --
    # measured: the unquoted form renders `--env A=1 --env B=2` and the container
    # sees both. A Compose file's `environment:` map is exactly this list, so the
    # quoting silently dropped every key but the first.
    check(
        unitsource.format_line("Environment", "A=1 B=2", Path("/tmp/web.container"))
        == "Environment=A=1 B=2",
        "a multi-assignment Environment= stays unquoted so quadlet splits it",
    )
    check(
        unitsource.format_line("Environment", "A=hello world", Path("/tmp/web.container"))
        == "Environment=A=hello world",
        "a spaced Environment= value is not quoted either",
    )
    try:
        unitsource.format_line("Environment", '"A=1 B=2"', Path("/tmp/web.container"))
    except errors.GuardenError as exc:
        check(exc.code == 2, f"a wholly quoted Environment=: exit {exc.code}, expected 2")
        check("SINGLE argv token" in exc.message, "a quoted Environment= names the reason")
    else:
        FAILURES.append("a wholly quoted Environment=: accepted")
    # **`Exec=` is never quoted, and one quoted argument is refused.** A quoted
    # value collapses to a SINGLE argv token, which the process receives as one
    # unrecognised flag and discards -- measured by running the quadlet generator
    # by hand. A quoted *segment* is a different thing and must survive: that is
    # how one argument holds a space, and the generator emits it correctly.
    check(
        unitsource.format_line("Exec", "--a=1 --b=2", Path("/tmp/web.container"))
        == "Exec=--a=1 --b=2",
        "an Exec= argument list stays unquoted",
    )
    check(
        unitsource.format_line("Exec", 'sh -c "echo hi"', Path("/tmp/web.container"))
        == 'Exec=sh -c "echo hi"',
        "an Exec= argument with a quoted segment is left alone",
    )
    check(
        unitsource.format_line("Exec", '--flag="a b"', Path("/tmp/web.container"))
        == 'Exec=--flag="a b"',
        "an Exec= flag with a quoted tail is left alone",
    )
    try:
        unitsource.format_line("Exec", '"--a=1 --b=2"', Path("/tmp/web.container"))
    except errors.GuardenError as exc:
        check(exc.code == 2, f"a wholly quoted Exec=: exit {exc.code}, expected 2")
        check("SINGLE argv token" in exc.message, "a wholly quoted Exec= names the reason")
    else:
        FAILURES.append("a wholly quoted Exec=: accepted")


def dropping() -> None:
    """The opinionated pass depends on `drop` removing *every* value of a key,
    which is what makes "the whole PublishPort set" the whole set."""
    unit = unitsource.Unit(path=Path("/dev/null"))
    unit.put("Container", "PublishPort", ["1:1:1", "2:2:2"])
    check(len(unit.drop("Container", "PublishPort")) == 2, "drop returns every value")
    check(unit.get("Container", "PublishPort") == [], "and leaves the key empty")
    unit.put("Container", "Volume", ["a:/b"])
    unit.put("Container", "AddHost", ["x:1"])
    check(unit.keys("Container") == ["Volume", "AddHost"], "keys keep the order they were set in")
    check(unit.lines("Container") == [("Volume", "a:/b"), ("AddHost", "x:1")],
          "lines are (key, value) in that order")


def schema() -> None:
    """Both decorators, both spellings of an annotation, and the fail-closed
    defaults — because a schema that is read wrong produces a container that
    starts without a key it needed, and nothing says so."""
    defaults = secretschema.loads("// DB_PASSWORD\n", Path("/tmp/.env.schema"))
    key = defaults.keys[0]
    check(key.required is True, "a key is required unless the schema says otherwise")
    check(key.sensitive is True, "a key is a credential unless the schema says otherwise")
    check(key.injection == secretschema.INFILE, "a key is a file unless it says otherwise")

    decorated = secretschema.loads(
        "// @defaultSensitive=false\n"
        "// @defaultRequired=infer\n"
        "\n"
        "// DB_PASSWORD=EXAMPLE-not-real\n"
        "//   @required\n"
        "//   @sensitive\n"
        "//   @example EXAMPLE-not-real\n"
        "\n"
        "// SESSION_SIGNING_KEY\n"
        "//   @sensitive\n"
        "//   @type env\n"
        "\n"
        "// LOG_LEVEL=info\n",
        Path("/tmp/.env.schema"),
    )
    by_name = {key.name: key for key in decorated.keys}
    check(list(by_name) == ["DB_PASSWORD", "SESSION_SIGNING_KEY", "LOG_LEVEL"],
          "the keys are read in declaration order")
    check(by_name["DB_PASSWORD"].required is True, "a key with a value is required under infer")
    check(by_name["DB_PASSWORD"].sensitive is True, "@sensitive is read")
    check(by_name["DB_PASSWORD"].example == "EXAMPLE-not-real", "@example is read")
    check(by_name["SESSION_SIGNING_KEY"].required is False,
          "a key with no value is not required under infer")
    check(by_name["SESSION_SIGNING_KEY"].sensitive is True, "a bare @sensitive is on")
    check(by_name["SESSION_SIGNING_KEY"].injection == secretschema.INENV,
          "@type env is the one that is not a file")
    check(by_name["LOG_LEVEL"].sensitive is False, "@defaultSensitive=false is read")
    check([key.name for key in decorated.requests()]
          == ["DB_PASSWORD", "SESSION_SIGNING_KEY", "LOG_LEVEL"],
          "a request is emitted for every required or sensitive key")

    prose = secretschema.loads(
        "// The shape of this service's credentials. Never a value.\n"
        "//\n"
        "// @defaultSensitive=true\n"
        "// TOKEN\n",
        Path("/tmp/.env.schema"),
    )
    check([key.name for key in prose.keys] == ["TOKEN"], "a prose comment is not a key")

    absent = secretschema.read(Path("/nonexistent/guarden/.env.schema"))
    check(absent.requests() == [], "a project with no schema asks for nothing")


def main() -> int:
    for suite in (sections, continuations, refusals, dropping, schema):
        suite()
    for failure in FAILURES:
        sys.stderr.write(f"error: {failure}\n")
    return 1 if FAILURES else 0


if __name__ == "__main__":
    raise SystemExit(main())
