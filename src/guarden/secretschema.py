"""`.guarden/.env.schema`: the shape of a service's credentials, read as text.

**The renderer reads annotations and never a value** (spec 6.3, 4). The schema is
a varlock schema, guarden does not run varlock and does not depend on it, and
the annotations are read as text: a document written by a stranger is read, not
executed, and a dependency would be a dependency `soil` has to install.

The four annotations that carry meaning, and what each one does here:

| annotation | effect |
|---|---|
| `@required` | the key is required, and a gated track refuses to start without it |
| `@sensitive` | the value is a credential: never printed with it, never rendered |
| `@type` | informational, except `@type env` |
| `@example` | the example the gate rejects while it is still present |

**`@type env` is how a key says its application needs a variable.** It is the one
place the renderer emits `Secret=<KEY>,type=env` instead of `type=file`, and it
is read off the key's own annotation because the schema is the only document
either side of this that a project controls. Every other key is a file, which is
the default and the safe one: a secret presented at `/run/secrets/<KEY>` is
readable only by the container, and one presented as a variable is in its
environment.

**The defaults fail closed, and getting them wrong fails in the harmless
direction** (spec 4). varlock's `@defaultSensitive` is true unless the file says
otherwise, and `@defaultRequired` is true unless the file says otherwise, so
guarden treats **every** key as a credential and **every** key as required
without reading a decorator. A key guarden believes is optional is not required,
which is the direction that fails a gate rather than opens one; a key guarden
believes is a credential when it is not is stored encrypted and presented as a
file, which is harmless. `@defaultRequired=infer` is the third spelling: a key
declared with a value is required, a key declared without one is not.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

from guarden import errors

COMMENT = re.compile(r"^\s*(?://|#)\s?(?P<body>.*)$")
# An annotation is `@name`, `@name=value` or `@name value` — varlock writes it
# all three ways and a reader that only understood one of them would drop the
# other two silently, which is the failure this whole module exists to prevent.
ANNOTATION = re.compile(r"^@(?P<name>[A-Za-z][A-Za-z0-9]*)(?:[ \t]*=[ \t]*|[ \t]+)?(?P<value>.*)$")
# A key declaration is a key and nothing else on the line: `KEY` or `KEY=value`.
# Anything else in a comment is prose, and prose in a schema is ignored rather
# than refused — the same way an annotation guarden does not know is ignored.
DECLARATION = re.compile(r"^(?P<name>[A-Za-z_][A-Za-z0-9_]*)(=(?P<value>.*))?$")

INFILE = "file"
INENV = "env"


@dataclass(frozen=True)
class Key:
    name: str
    required: bool
    sensitive: bool
    injection: str = INFILE
    example: str | None = None

    @property
    def wanted(self) -> bool:
        """Whether a credential *request* is emitted for this key.

        A `@required` key and a `@sensitive` key both want one, and the renderer
        emits the request and never a value — it has none to emit.
        """
        return self.required or self.sensitive


@dataclass
class Schema:
    path: Path
    keys: tuple[Key, ...] = ()

    def requests(self) -> list[Key]:
        """The keys to ask podman for, in declaration order."""
        return [key for key in self.keys if key.wanted]


def read(path: Path) -> Schema:
    """Read one schema. A file that is not there is not an error — no schema
    means no declared shape, and a project that ships no credentials declares
    none."""
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return Schema(path=path)
    except (OSError, UnicodeDecodeError) as exc:
        raise errors.GuardenError(
            f"the secret schema {path} could not be read: {getattr(exc, 'strerror', exc)}"
        ) from exc
    return loads(text, path)


def loads(text: str, path: Path) -> Schema:
    keys: list[Key] = []
    default_sensitive: str | None = None
    default_required: str | None = None
    current: dict[str, str] | None = None
    number = 0

    for number, raw in enumerate(text.splitlines(), 1):
        comment = COMMENT.match(raw)
        if not comment:
            continue
        body = comment.group("body").strip()
        if not body:
            continue
        annotation = ANNOTATION.match(body)
        if annotation:
            name = annotation.group("name")
            value = annotation.group("value").strip()
            if name == "defaultSensitive":
                default_sensitive = value
            elif name == "defaultRequired":
                default_required = value
            elif current is not None:
                # A bare `@sensitive` is a flag that is on; storing an empty
                # string for it would make it indistinguishable from the
                # annotation being absent, which is the one distinction the
                # defaults exist to carry.
                current[name] = value or "true"
            continue
        declaration = DECLARATION.match(body)
        if not declaration:
            continue
        if current is not None:
            keys.append(_key(current, default_sensitive, default_required, path, number))
        current = {
            "name": declaration.group("name"),
            "value": (declaration.group("value") or "").strip(),
            "required": "",
            "sensitive": "",
            "type": "",
            "example": "",
        }
    if current is not None:
        keys.append(_key(current, default_sensitive, default_required, path, number))
    return Schema(path=path, keys=tuple(keys))


def _key(
    raw: dict[str, str],
    default_sensitive: str | None,
    default_required: str | None,
    path: Path,
    number: int,
) -> Key:
    sensitive = default_sensitive
    if raw["sensitive"] != "":
        sensitive = raw["sensitive"]
    is_sensitive = True if sensitive is None else _boolean(sensitive, path, number)

    if raw["required"] != "":
        required = _boolean(raw["required"], path, number)
    elif default_required == "infer":
        # `@defaultRequired=infer`: a key declared with a value is required, and
        # a key declared bare is not.
        required = bool(raw["value"])
    elif default_required is not None:
        required = _boolean(default_required, path, number)
    else:
        required = True

    injection = INENV if raw["type"].lower() == INENV else INFILE
    return Key(
        name=raw["name"],
        required=required,
        sensitive=is_sensitive,
        injection=injection,
        example=raw["example"] or None,
    )


def _boolean(value: str, path: Path, number: int) -> bool:
    if value == "":
        return True
    lowered = value.lower()
    if lowered in ("true", "yes"):
        return True
    if lowered in ("false", "no"):
        return False
    raise errors.GuardenError(
        f"{path}:{number}: the annotation is {value!r}, which is neither true nor false"
    )
