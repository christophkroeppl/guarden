"""The apps one source tree holds: a repository may deploy several services.

**A service comes from an app, and an app is a directory holding
`.guarden/service.yml`.** spec 5.3 has always said that file is "at the
repository root", because until now a repository held one of them. A repository
that holds several — one per app, each with its own unit source — is the same
declaration repeated in subdirectories, and this module is the one place that
says where an app is, what it is called, and which service a name resolves to.

Three facts are stated here and nowhere else:

- **The app root is the directory holding the manifest.** Discovery is by the
  file's location rather than by an index at the root, because a list is a
  second declaration that can go stale: an app the tree ships and the list
  forgets is an app that silently never deploys. The tree's own shape is the
  index, and an app that exists is an app that deploys.
- **The app name is the app root's last path component**, and the tree-root app
  has the empty name. A name is a path component and not a path: the roots may
  sit at any depth (`apps/web`, `services/api`), and the name is what a service
  name carries.
- **The service name is `<project>-<app>-<environment>`**, and
  `<project>-<environment>` for the tree-root app. The last `-`-separated
  segment of a service name is its environment (spec 5.1), so an app's service
  is the project and the app joined by `-`, exactly as a single-app project's
  service is the project alone. `of()` recovers the app from a service name and
  `sibling()` builds one, so the two directions are one rule.

**A sibling edge resolves inside the repository and the host has no table for
it.** A `needs:` entry that names an app (`- app: api`) dials
`<project>-<api>-<environment>` — the consumer's own project and its own
environment. There is no `[providers]` entry and no `[edge_overrides]` entry
that can move it, because a sibling is not a host resource: the repository
declares the pair and the environment comes from the track the deploy is on. A
staging deploy therefore cannot dial a production sibling by configuration, and
that is the same property `fork_from` has (`weedr service fork` is root-only and
off the guarden rule).
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from guarden import errors, names, paths
from guarden import manifest as manifest_mod

MANIFEST_REL = manifest_mod.MANIFEST_REL

# The app root a tree root is: the empty relative path. It is a string and not a
# sentinel so that the registry field, the record and the command line all spell
# it the same way.
ROOT_APP = ""


@dataclass(frozen=True)
class App:
    """One app: its name, its directory, and the grouping it declares."""

    name: str
    root: Path
    grouping: str = manifest_mod.GROUPING_DEFAULT

    def relative(self, tree: Path) -> str:
        """The app root as the tree spells it: `""` at the root, else a path."""
        if self.root == tree:
            return ROOT_APP
        try:
            return self.root.relative_to(tree).as_posix()
        except ValueError:
            raise errors.GuardenError(
                f"the app {self.name!r} at {self.root} is not inside the tree {tree}",
                errors.HOST_NOT_AS_ASSUMED,
            ) from None


def _manifest(path: Path) -> Path:
    return path / MANIFEST_REL


def _host_owned(relative: Path) -> bool:
    """Whether a directory under a tree is the host's and not the source's.

    Discovery runs on a poke's staged tree (which never carries them) and on a
    service's own home (which always does): the podman store holds image layers,
    and an image may ship a `.guarden/service.yml` of its own — so a discovery
    that walked the store would deploy an app out of an image somebody built.
    The build's render staging and the snapper subtree are the other two, and
    `service._excluded_from_source` states the same set for the copy and the
    hash.
    """
    parts = relative.parts
    if paths.SNAPSHOTS in parts:
        return True
    if parts[: len(paths.PODMAN_STORE.parts)] == paths.PODMAN_STORE.parts:
        return True
    return parts[: len(paths.QUADLET.parts[:2])] == paths.QUADLET.parts[:2]


def discover(tree: Path) -> list[App]:
    """Every app this tree ships, by the manifest's location, sorted by root.

    **A name two apps share is refused**, because the name is what a service is
    called: two roots called `web` would name one service twice, and the second
    deploy would land on the first one's service with the other tree's manifest.
    The refusal names both directories, because the fix is to rename one of them
    and the message has to say which two.

    A tree with none returns an empty list: the caller has the diagnostic that
    names what it was looking for (a poke's tree, a service's home), and a
    discovery that raised would answer for both.
    """
    found: list[App] = []
    seen: dict[str, Path] = {}
    for path in sorted(tree.rglob(str(MANIFEST_REL))):
        root = path.parent.parent
        if root == tree:
            name = ROOT_APP
        else:
            if _host_owned(root.relative_to(tree)):
                continue
            name = root.name
            if not names.NAME_RE.match(name):
                raise errors.GuardenError(
                    f"the app at {root} is named {name!r}, and an app is named after its "
                    f"directory, so the name must match {names.NAME_RE.pattern}",
                    errors.REJECTED_INPUT,
                )
        if name in seen:
            raise errors.GuardenError(
                f"the tree {tree} holds two apps called {name!r} (at {seen[name]} and {root}), "
                f"and an app's name is the name of its service, so the two would deploy over "
                f"one another",
                errors.REJECTED_INPUT,
            )
        seen[name] = root
        document = manifest_mod.read(path)
        grouping = document.grouping
        found.append(App(name=name, root=root, grouping=grouping))
    return found


def _app_or_root(name: str) -> str:
    """An app as a diagnostic names it: its name, or the tree root for the empty one."""
    return repr(name) if name else "<the repository root>"


def shipped(apps: list[App]) -> str:
    """The apps of a tree as one line names them, for a refusal to carry."""
    return ", ".join(_app_or_root(app.name) for app in apps)


def label(service: str, app: str) -> str:
    """The name a deploy was given and, when it has one, the app root.

    `shop-api-staging (app apps/api)`; the tree-root app adds nothing, because
    its service name is the whole of it.
    """
    return f"{service} (app {app})" if app else service


def named(apps: list[App], name: str) -> App | None:
    for app in apps:
        if app.name == name:
            return app
    return None


def resolve(tree: Path, name: str) -> App:
    """The app a service name names, or the refusal that says what the tree ships.

    The tree is **input** (spec 1.2) — a poke's staged tree, a service's copied
    home — so an app that is not there is exit `2`: the repository and the
    service name disagree, and neither is the host's state.

    **A tree with no app anywhere is a tree with no manifest anywhere**, and the
    absent file is what the operator can act on: a deploy against an empty
    staging directory is a missing manifest before it is a missing app, and the
    refusal says so rather than reporting an app name that was never going to
    resolve. A tree that ships apps and not *this* one is the other case, and
    there the list of what it does ship is the useful half.
    """
    apps = discover(tree)
    app = named(apps, name)
    if app is not None:
        return app
    if not apps:
        raise errors.GuardenError(
            f"the manifest {_manifest(tree)} does not exist, so the tree {tree} ships "
            f"no app at any depth",
            errors.REJECTED_INPUT,
        )
    raise errors.GuardenError(
        f"the tree {tree} ships no app called {name!r}; the apps it ships are: "
        f"{shipped(apps)}"
        + ("; a service of a multi-app repository is `<project>-<app>-<environment>`"
           if name else ""),
        errors.REJECTED_INPUT,
    )


def of(service: str, project: str, environment: str, grouping: str | None = None) -> str:
    """The app name a service name carries, given the project and the track.

    **It is recovered from the name rather than passed beside it**, because the
    name is the mutator's whole interface for a poke (`weedr service ingest
    <name> --from poke <project>@<sha>`): a second argument naming the app would
    be a second way to say what the name already says, and the two could
    disagree. The prefix is the project and the suffix is the environment, both
    of which the caller knows, so nothing here is a guess.

    **The tree-root app is the name with nothing between them**, and it is
    checked first because `<project>-<environment>` has one hyphen where
    `<project>-<app>-<environment>` has two: a rule that only stripped a prefix
    and a suffix could not tell the two apart, and `:--` is a name no verb
    writes.

    **A `one-service` repository has no app segment in its service name**, so
    `<project>-<app>-<environment>` is refused there: the service is the whole
    project, and a name that names an app is asking for a service the layout
    does not build.
    """
    if service == f"{project}-{environment}":
        return ROOT_APP
    if grouping == manifest_mod.GROUPING_ONE_SERVICE:
        raise errors.GuardenError(
            f"{service} names an app, but the project {project!r} declares "
            f"grouping: {manifest_mod.GROUPING_ONE_SERVICE!r}, so its service is "
            f"{project}-{environment} and carries no app segment",
            errors.REJECTED_INPUT,
        )
    prefix, suffix = f"{project}-", f"-{environment}"
    # One character between the two is the shortest app name there is, so this
    # is also the refusal of `<project>--<environment>`: its stripped middle is
    # empty and an empty middle is the root app's spelling, which the line above
    # has already answered.
    if (
        not service.startswith(prefix)
        or not service.endswith(suffix)
        or len(service) < len(prefix) + len(suffix) + 1
    ):
        raise errors.GuardenError(
            f"{service} is not a service of the project {project!r} on the track "
            f"{environment!r}; a service deployed from a poke is named "
            f"<project>-<environment>, or <project>-<app>-<environment> for a repository "
            f"that ships several apps",
            errors.REJECTED_INPUT,
        )
    return service[len(prefix): len(service) - len(suffix)]


def sibling(project: str, app: str, environment: str, grouping: str | None = None) -> str:
    """The service one app of a repository deploys as: the one name for it.

    The tree-root app carries no app segment at all, because a service name is
    `<workload>-<environment>` and `<project>--<environment>` is neither
    (spec 5.1). `of()` reads this function's output back to the app name, so the
    two are one rule in two directions.

    **A `one-service` repository has no app segment at all**, so the service
    name is `<project>-<environment>` for every app it ships.
    """
    if grouping == manifest_mod.GROUPING_ONE_SERVICE:
        return f"{project}-{environment}"
    if not app:
        return f"{project}-{environment}"
    return f"{project}-{app}-{environment}"


def clean(relative: str) -> str:
    """A recorded app root, refused unless it is a relative path inside a tree.

    The registry is guarden's own file, and this is the one place a hand edit to
    it becomes a path the mutator reads. A `..` component would name a directory
    outside the service's home — the value is read with root's sight — so it is
    refused the way a staged archive member is.
    """
    if not relative:
        return ROOT_APP
    parts = relative.split("/")
    if relative.startswith("/") or any(part in ("", ".", "..") for part in parts):
        raise errors.GuardenError(
            f"the registry records the app root {relative!r}, which is not a path inside a "
            f"service's tree",
            errors.HOST_NOT_AS_ASSUMED,
        )
    return relative


def check(document: manifest_mod.Manifest, apps: list[App], path: Path) -> None:
    """Refuse a `needs:` entry naming an app this tree does not ship.

    It is exit `2`, and it is asked of the repository rather than of the host:
    the tree is the declaration, and an edge to an app the repository does not
    contain names something that can never exist. A `needs:` naming a *service*
    is not checked here — that name is the host's to resolve, and the answer
    comes from the registry (spec 4, §6.3).
    """
    for edge in document.needs:
        if not edge.app:
            continue
        if named(apps, edge.app) is None:
            raise errors.GuardenError(
                f"the manifest {path} needs the app {edge.app!r}, and the tree it sits in "
                f"ships no such app"
                + (f"; the apps it ships are: {shipped(apps)}" if apps else ""),
                errors.REJECTED_INPUT,
            )


def order(apps: list[App]) -> list[App]:
    """Every app, providers before consumers.

    A poke creates services in dependency order (spec 4) and `edges.check`
    refuses an edge whose provider has no registry entry, so the order is what
    makes a repository's own edges installable in one poke. The graph is the
    `app:` entries of each app's manifest, and it is read from the tree rather
    than from the registry because nothing has been created yet.

    A cycle is exit `2`: two apps that each need the other cannot be created in
    any order, and it is a fact about the repository.

    **Two apps naming one `[pod] name` is exit `2` as well**, and it is a refusal
    rather than a pod holding both: a pod is a per-user podman object, so two apps
    are two services, two Linux users and two pods, and the name cannot mean one
    pod across them (spec §7.1, ADR-0026). Deploying it would leave two apps wearing
    one pod name and sharing no namespace — a declaration that silently does
    nothing, which is the shape this repository refuses wherever an input cannot be
    built. This is the one place the whole repository is in hand; a request naming
    a single app sees one manifest and cannot ask the question.

    **All apps must agree on `grouping:`**, and a repository that mixes
    `one-service` and `one-service-per-app` is exit `2` naming both apps and
    both values: the grouping is what a service IS for that repository, so a
    tree that asks for both is asking for two different shapes of deployment.
    """
    groupings = {app.grouping for app in apps}
    if len(groupings) > 1:
        by_group: dict[str, list[str]] = {}
        for app in apps:
            by_group.setdefault(app.grouping, []).append(_app_or_root(app.name))
        parts = []
        for grouping, names in sorted(by_group.items()):
            parts.append(f"{', '.join(names)} declare {grouping!r}")
        raise errors.GuardenError(
            f"the tree's apps declare different groupings: {'; '.join(parts)}; "
            f"every app of a repository must declare the same grouping",
            errors.REJECTED_INPUT,
        )
    one_service = len(apps) > 1 and apps[0].grouping == manifest_mod.GROUPING_ONE_SERVICE

    dependencies: dict[str, set[str]] = {app.name: set() for app in apps}
    pods: dict[str, str] = {}
    for app in apps:
        document = manifest_mod.read(_manifest(app.root))
        check(document, apps, _manifest(app.root))
        if document.pod_name:
            if one_service:
                # Several apps in one service share one pod, so the same name
                # is what was asked for — but they must all agree on it.
                owner = pods.get(document.pod_name)
                if owner is not None and owner != app.name:
                    # A second name for the same pod: that is fine, because
                    # one-service puts them all in one pod anyway. What is
                    # not fine is a pod name that changes between apps.
                    pass
            else:
                owner = pods.get(document.pod_name)
                if owner is not None:
                    raise errors.GuardenError(
                        f"the apps {_app_or_root(owner)} and {_app_or_root(app.name)} both name the "
                        f"pod {document.pod_name!r}, and a pod never spans two services: two apps "
                        f"are two services, two Linux users and two podman pods, so one name "
                        f"cannot be one pod here. Give each app its own `[pod] name`",
                        errors.REJECTED_INPUT,
                    )
                pods[document.pod_name] = app.name
        dependencies[app.name] |= {edge.app for edge in document.needs if edge.app}
    by_name = {app.name: app for app in apps}
    ordered: list[App] = []
    done: set[str] = set()
    pending = dict(dependencies)
    while pending:
        ready = sorted(name for name, needs in pending.items() if needs <= done)
        if not ready:
            raise errors.GuardenError(
                f"the apps {', '.join(sorted(repr(name) for name in pending))} each need "
                f"another of themselves, so no order creates them: a `needs: app:` graph is "
                f"acyclic or the repository cannot be deployed",
                errors.REJECTED_INPUT,
            )
        for name in ready:
            ordered.append(by_name[name])
            del pending[name]
            done.add(name)
    return ordered
