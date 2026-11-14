"""The one package list, read as data, and the capability probe that picks a family.

`packages/packages.toml` is the whole list and has two consumers that must not
disagree: `soil packages` converges its `packages` rows, and
`tools/render-user-data` renders `packages` plus `harness` into the cloud-init
document a throwaway machine boots. They cannot drift because there is one file.

Per-family entries are the point rather than decoration. The layout and the six
phases name no distribution; the *package names* do, and they differ
(`python3-yaml` on Debian, `python3-pyyaml` on Fedora, `python-yaml` on Arch). So
each family carries its own install argv, its own update argv, its own query argv,
and its own answer for "is it installed" -- a separate key because that is where
the families differ most sharply, and a probe that asks the wrong question reports
a package that is absent as present.

**Every distribution-specific command here is behind a capability probe with a
documented fallback**, which is what makes the layout portable even though the
install path is not:

- **the family** — probed by `ID_LIKE` in `/etc/os-release`, then by the query
  tool on `PATH`. The fallback is a refusal: no family found is exit 2, naming
  the families the list carries, rather than a guess at the nearest one.
- **is it installed** — the family's own `query` argv from the list. No fallback:
  asking the wrong question reports a package that is absent as present, which is
  worse than not asking.
- **install it** — the family's own `install` argv from the list. No fallback:
  installing with another family's tool is not a degraded install, it is a
  different one.
- **refresh the index** — the family's own `update` argv from the list. No
  fallback and no guess: an install is resolved against the index, so an index
  nobody refreshed is the reason a converge fails on a version the mirror has
  moved past. An argv the list does not carry is a row nobody filled in, and the
  caller says so rather than refreshing nothing and installing anyway.

Neither probe runs a command, so answering "which family is this" cannot have a
side effect.

Nothing here fetches anything from PyPI and nothing fetches a wheel: the whole
list is distribution packages, plus the pinned releases `hostprep` installs
separately, each under its own SHA256 check (ADR-0015).
"""

from __future__ import annotations

import shutil
import subprocess
import tomllib
from pathlib import Path

LIST_NAME = "packages.toml"

# The list ships in the checkout. It is read from the source tree first and from
# the installed copy second, for the reason `hosttool.template()` reads its
# templates that way: a converger that read a stale installed list would be a
# different program on a developer's box than on a host.
SEARCHED = (
    Path(__file__).resolve().parents[2] / "packages" / LIST_NAME,
    Path(__file__).resolve().parent / LIST_NAME,
)


class UnknownFamily(Exception):
    """No row for the family this host is, or for the one that was asked for."""


def list_path() -> Path:
    """The one list, or a diagnostic naming where it was expected."""
    for candidate in SEARCHED:
        if candidate.is_file():
            return candidate
    raise UnknownFamily(f"the package list is missing; expected it at {SEARCHED[0]}")


def _document() -> dict:
    """The whole file, parsed. Every reader goes through here."""
    try:
        with open(list_path(), "rb") as handle:
            return tomllib.load(handle)
    except tomllib.TOMLDecodeError as exc:
        raise UnknownFamily(f"{list_path()} does not parse: {exc}") from exc


def families() -> dict[str, dict]:
    """Every family's substrate row, keyed by family."""
    return dict(_document().get("families", {}))


def harness_table() -> dict[str, dict]:
    """Every family's harness row, keyed by family."""
    return dict(_document().get("harness", {}))


def family_names() -> tuple[str, ...]:
    """Every family the list carries, sorted, for a diagnostic that names them."""
    return tuple(sorted(families()))


def conditional_table() -> dict[str, dict]:
    """Every family's optional row, keyed by role."""
    return dict(_document().get("conditional", {}))


def conditional_names(role: str, name: str | None = None) -> tuple[str, ...]:
    """The packages a role needs on this family, or nothing.

    A role is the package list's word for "only when somebody asked". The
    substrate is unconditional because a guarden host cannot be one without it;
    a role like the zram generator is installed only when the operator's own
    configuration asks for the thing it provides, so a host that never asked
    installs nothing.
    """
    family_name, _ = resolve(name)
    return tuple(conditional_table().get(family_name, {}).get(role, []))


def _os_release() -> dict[str, str]:
    """The host's own declaration of what it is, or nothing.

    `/etc/os-release` is the distribution's file and its `ID_LIKE` is what it
    says it is compatible with, which is the question "whose package names do I
    want" actually is. A file that is absent or unreadable is not an error: a
    minimal container may not have one, and the PATH probe below still answers.
    """
    values: dict[str, str] = {}
    try:
        text = Path("/etc/os-release").read_text(encoding="utf-8")
    except OSError:
        return values
    for line in text.splitlines():
        key, _, value = line.partition("=")
        values[key.strip()] = value.strip().strip('"')
    return values


# `ID_LIKE` says "compatible with"; these map a declaration onto the family whose
# names this list carries. A distribution that declares nothing is resolved by
# the PATH probe, which is why that probe exists rather than being an error.
_LIKE_TO_FAMILY = {
    "debian": "debian",
    "ubuntu": "debian",
    "fedora": "fedora",
    "rhel": "fedora",
    "centos": "fedora",
    "arch": "arch",
    "archlinux": "arch",
    "manjaro": "arch",
}

# The query tool per family, which is how a distribution that declares no family
# is still resolved. It is the *query* tool and not the install tool because the
# query is the question the phase asks on every `--check`, and a PATH that can
# answer it is a PATH that can be trusted to install.
_QUERY_TOOLS = {
    "debian": "dpkg-query",
    "fedora": "rpm",
    "arch": "pacman",
}


def detect_family(known: set[str]) -> str:
    """The family this host is, from the two probes, or an explanation."""
    declared = _os_release()
    for key in ("ID", "ID_LIKE"):
        for token in declared.get(key, "").split():
            family = _LIKE_TO_FAMILY.get(token.strip().lower())
            if family in known:
                return family
    for family, tool in _QUERY_TOOLS.items():
        if family in known and shutil.which(tool):
            return family
    raise UnknownFamily(
        "no package family for this host: "
        f"{declared.get('ID', 'an undeclared distribution')} declares no family this list "
        f"carries, and none of {', '.join(sorted(_QUERY_TOOLS))} is on PATH. "
        f"The list has: {', '.join(sorted(known))}"
    )


def resolve(name: str | None = None) -> tuple[str, dict]:
    """The family to answer for, and its row.

    `name` is what the caller asked for and is checked against the list, so a
    family that does not exist is a rejected input rather than a silent fallback
    onto a family that does. With none, the host is asked which family it is.
    """
    rows = families()
    if not rows:
        raise UnknownFamily(f"the package list at {list_path()} names no families")
    chosen = name or detect_family(set(rows))
    if chosen not in rows:
        raise UnknownFamily(
            f"{chosen} is not a family the package list carries; "
            f"it has: {', '.join(sorted(rows))}"
        )
    return chosen, rows[chosen]


def family(name: str | None = None) -> dict:
    """One family's row: its toolchain and its packages."""
    return resolve(name)[1]


def package_names(name: str | None = None) -> tuple[str, ...]:
    """The packages a guarden host on this family needs, in file order.

    The `packages` table only. `soil packages` converges what a host needs and
    never the throwaway machine's `harness` extras, which is what keeps a
    golden-VM check's dependency off a production box.
    """
    return tuple(resolve(name)[1].get("packages", []))


def harness_names(name: str | None = None) -> tuple[str, ...]:
    """What a throwaway machine needs on top of the substrate, or nothing.

    A family with no `harness` row gets an empty tuple rather than an error: the
    substrate is what makes a host and the harness tools are what make a
    golden-VM run, so a family that can be a host but not yet a test machine is
    an ordinary state rather than a rejection.
    """
    family_name, _ = resolve(name)
    return tuple(harness_table().get(family_name, {}).get("harness", []))


def is_installed(package: str, row: dict | None = None) -> bool:
    """Whether this family's own query says the package is installed.

    Asked with the argv from the list and nothing else. A probe invented here
    would be a second opinion about a package's state, and the point of asking
    the distribution is that it is the one that knows. The family's `installed`
    string is the stdout that means yes; an empty one means the exit code is the
    whole answer, which is how rpm and pacman answer and dpkg-query does not.
    """
    family_row = family() if row is None else row
    argv = [str(part) for part in family_row.get("query", [])]
    if not argv:
        return False
    answer = str(family_row.get("installed", ""))
    result = subprocess.run([*argv, package], capture_output=True, text=True, check=False)
    if result.returncode != 0:
        return False
    return not answer or result.stdout.strip() == answer


def install_argv(packages: list[str], row: dict | None = None) -> list[str]:
    """The argv that installs these packages on this family, and nothing else."""
    family_row = family() if row is None else row
    return [str(part) for part in family_row.get("install", [])] + list(packages)


def update_argv(row: dict | None = None) -> list[str]:
    """The argv that refreshes this family's package index, and nothing else.

    Read from the list beside `install` and `query`, for the same reason those
    are: a command written here would be a second place the families differ, and
    a second place is a second thing to forget. The argv carries no package name,
    because there is no package to name — it is the whole command.

    **An empty argv is a row nobody filled in, and it is the caller's to say so.**
    This returns the empty list rather than guessing, because a guess is either a
    hard-coded `apt-get update` — which runs the wrong tool on two of the three
    families this list carries — or a silent no-op, and a silent no-op is the
    defect this function exists to remove.
    """
    family_row = family() if row is None else row
    return [str(part) for part in family_row.get("update", [])]


# Closed set: `name` is what the phase says out loud, so a fourth spelling would
# produce a diagnostic no operator can act on. An unknown name is a rejected
# input at load time rather than a variant nobody recognises on a converged host.
VARIANT_NAMES = ("legacy", "nft")

# All three or none: a row carrying two states a preference it cannot act on,
# which is the silent mismatch this table exists to remove.
VARIANT_FIELDS = ("name", "set", "report")


def variant_table() -> dict[str, dict]:
    """Every family's `variant` subtable, keyed by family.

    A family this design has not been run on is absent rather than carrying an
    empty row: inventing one would be guarden guessing about a host it has never
    booted.
    """
    rows = {}
    for family_name, row in families().items():
        declared = row.get("variant")
        if isinstance(declared, dict):
            rows[family_name] = declared
    return rows


def variant(name: str | None = None) -> tuple[str, dict]:
    """This family's variant answer and its row, or a rejection naming the gap.

    **A family with no `variant` is exit 2, not exit 1.** The list is a repository
    input, so a row nobody filled in is not drift: the phase has no converged
    state to compare against, because the list does not say which table it
    converges.
    """
    family_name, _ = resolve(name)
    rows = variant_table()
    if family_name not in rows:
        raise UnknownFamily(
            f"the package list at {list_path()} states no iptables variant for "
            f"{family_name}, and `soil firewall` will not write rules into a table it has "
            f"not named: guarden's rules must be readable through the host's own "
            f"iptables, and only the list says which one that is. It carries a variant "
            f"for: {', '.join(sorted(rows)) or 'none'}"
        )
    row = rows[family_name]
    for field in VARIANT_FIELDS:
        if not str(row.get(field, "")).strip():
            raise UnknownFamily(
                f"the package list at {list_path()} states an iptables variant for "
                f"{family_name} that has no {field}: a variant that cannot be selected, or "
                f"cannot be reported, is a preference rather than a converged state"
            )
    declared = str(row["name"]).strip()
    if declared not in VARIANT_NAMES:
        raise UnknownFamily(
            f"the package list at {list_path()} names iptables variant {declared!r} for "
            f"{family_name}, which is not one of {', '.join(VARIANT_NAMES)}"
        )
    return declared, row


def variant_argv(field: str, name: str | None = None) -> list[str]:
    """One of the variant's argvs, from the list.

    `set` makes the host name this variant and `report` answers which one it
    names. Neither is written here, for the reason `update_argv` gives: the
    mechanisms differ per family.
    """
    _, row = variant(name)
    return [str(part) for part in row.get(field, [])]


def variant_name(name: str | None = None) -> str:
    """The variant this family converges, as the list states it."""
    return variant(name)[0]