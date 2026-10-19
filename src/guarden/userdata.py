"""The cloud-init user-data, rendered from one template and the one package list.

spec 6.1's six phases are the whole of what a fresh box needs, and the order they
run in is the order `soil list` prints. This module renders the document a
cloud-init-capable machine boots from, in one of two profiles:

    golden-vm   the throwaway harness machine. Substrate + harness packages, an
                evidence directory, and the six phases run directly.
    vps         a fresh host. Substrate packages, a repo clone, and install.sh,
                which owns convergence and resumes across the btrfs reboots.

**One template, two profiles.** The document used to be built twice: by string
concatenation in this module, and by a second jinja2 template under `tools/`.
Two renderers for one document is the drift this repository fights, so there is
now one template (`templates/cloud-init/template.yaml`) and this module is the
one renderer. The two profiles differ in the header, in whether the harness
packages are installed, and in what `runcmd` does; everything else is shared, so
a change to the package list or the phase sequence lands in both at once.

**What the rendered document does and does not do.** It installs the substrate
and, for the golden VM, the throwaway machine's harness tools. It does **not**
create the program users, write `/usr/lib/guarden`, or set `ingress.alias`:
`soil install` owns those, and a document that pre-empted them would make the
phases untestable — a phase that finds its own work already done is a phase that
proves nothing.

**The VPS profile does not converge.** It clones the repository and runs
`tools/install.sh`, which owns convergence and knows how to resume: the btrfs
conversion reboots twice, and a cloud-init `runcmd` that tried to span a reboot
would be a document that silently stopped half way. Re-running `install.sh` is
the expected recovery.

**No PyPI, no wheel, no venv.** Every line of the package list comes from the
distribution's own repository. The one artefact fetched from outside a
distribution repository is the pinned `podlet` release, which `soil packages`
verifies against the SHA256 recorded in this repository; a cloud-init document
that fetched anything else would be a second, unpinned fetch path.
"""

from __future__ import annotations

from pathlib import Path

from guarden import packagelist, paths

GOLDEN_VM = "golden-vm"
VPS = "vps"
PROFILES = (GOLDEN_VM, VPS)

DEFAULT_REPO_URL = "https://github.com/christophkroeppl/guarden.git"
DEFAULT_REPO_BRANCH = "main"
DEFAULT_REPO_DIR = "/usr/local/src/guarden"


def phases() -> tuple[str, ...]:
    """The phases, in spec 6.1's order, read from the program rather than kept here.

    The runner and the document cannot drift from `soil list` because both ask
    the program rather than carrying their own copy of the order.
    """
    from guarden import hostprep

    return tuple(hostprep.PHASES)


def sequence() -> str:
    """Converge every phase, then check every phase. A run ending in drift failed.

    The checks are not optional and not a separate step: a boot that applied
    everything and never asked is a boot that reported success without having
    looked, which is the failure mode this document exists to rule out.

    **This is the one statement of the sequence.** `tools/golden-vm` used to
    build its own copy and append it to the ssh command, so every golden-VM boot
    converged all six phases twice; it now relies on the document's `runcmd`,
    which is this.
    """
    names = phases()
    apply = ";".join(f"soil {phase} --apply" for phase in names)
    check = ";".join(f"soil {phase} --check" for phase in names)
    return f"{apply};{check}"


def own_branch() -> str:
    """The branch of the checkout this renderer runs from.

    **The renderer is aware of its branch, and this is where it learns it.**
    A document rendered from a checkout of `develop` must install `develop`,
    and a document rendered from a checkout of `main` must install `main`:
    an operator who rendered the document from the tree they are testing
    would otherwise get a document that installs a different tree. The branch
    is therefore read out of the checkout rather than carried as a constant,
    and the default is `main` — the branch a raw URL names when it names the
    repository's own head.

    **The question is asked of git, and not of `.git/HEAD`.** A worktree's
    `.git` is a *file* naming the real git directory, and a linked
    worktree's `HEAD` is in that directory rather than beside the
    checkout — so reading `.git/HEAD` answers `main` for every worktree,
    which is exactly the case this repository spends its time in. `git
    rev-parse --abbrev-ref HEAD` answers the same question in both shapes
    and knows where the real `HEAD` is.

    A checkout with no branch to be had — a tarball, a copy without its
    `.git`, a machine with no git at all — answers `main`, which is the same
    answer the constant carries. The question is asked of the checkout and
    not of the remote, so a renderer never needs the network to answer it.
    """
    checkout = Path(__file__).resolve().parent.parent.parent
    try:
        import subprocess

        done = subprocess.run(
            ["git", "-C", str(checkout), "rev-parse", "--abbrev-ref", "HEAD"],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError:
        return DEFAULT_REPO_BRANCH
    branch = done.stdout.strip()
    if done.returncode != 0 or not branch or branch == "HEAD":
        return DEFAULT_REPO_BRANCH
    return branch


def templates_dir() -> Path:
    """Where the cloud-init templates live: the checkout, or the installed copy.

    Same order and the same reason as `hostprep.template`: on a checkout — which
    is what a development tree and the VPS-prep case are — the file being read
    and the file being edited are the same one, and on an installed host it is
    the copy `soil install` put under `/usr/lib/guarden/templates/`.
    """
    beside = Path(__file__).resolve().parent / "templates" / "cloud-init"
    if (beside / "template.yaml").is_file():
        return beside
    return paths.TEMPLATES / "cloud-init"


def _script(name: str) -> str:
    """One tracked script, read for inlining.

    The scripts over ten lines live in the repository rather than in the
    template, so the bytes a machine runs and the bytes in the repository are
    the same, and a script can be read and linted on its own.
    """
    return (templates_dir() / name).read_text(encoding="utf-8")


def _provision_script(repo_url: str, branch: str, repo_dir: str) -> str:
    """`provision.sh` with its placeholders resolved to this render's values.

    The clone target is a placeholder rather than a jinja variable because the
    script is also readable on its own, where `{{ }}` would be a syntax error in
    a shell script and a jinja variable would be a name the reader has to go
    looking for.
    """
    return (
        _script("provision.sh")
        .replace("__REPO_URL__", repo_url)
        .replace("__REPO_BRANCH__", branch)
        .replace("__REPO_DIR__", repo_dir)
    )


def render(
    profile: str = GOLDEN_VM,
    family: str | None = None,
    branch: str = DEFAULT_REPO_BRANCH,
    repo_url: str = DEFAULT_REPO_URL,
    repo_dir: str = DEFAULT_REPO_DIR,
) -> str:
    """The whole document for one profile: the template, rendered.

    A profile that is not one of the two is exit 2 rather than a document with a
    silently empty half, and a missing template says which path it looked for
    rather than raising a bare `TemplateNotFound`.
    """
    if profile not in PROFILES:
        from guarden import errors

        raise errors.GuardenError(
            f"the profile {profile!r} is not one of {', '.join(PROFILES)}",
            errors.REJECTED_INPUT,
        )

    try:
        import jinja2
    except ImportError:
        from guarden import errors

        raise errors.GuardenError(
            "python3-jinja2 is not importable; it is the distribution's package, "
            "installed by `soil packages`",
            errors.HOST_NOT_AS_ASSUMED,
        ) from None

    directory = templates_dir()
    environment = jinja2.Environment(
        loader=jinja2.FileSystemLoader(str(directory)),
        keep_trailing_newline=True,
        trim_blocks=True,
        lstrip_blocks=True,
        autoescape=False,
    )
    template = environment.get_template("template.yaml")

    golden = profile == GOLDEN_VM
    return template.render(
        profile=profile,
        substrate=packagelist.package_names(family),
        harness=packagelist.harness_names(family) if golden else [],
        sequence=sequence() if golden else "",
        verify_substrate=_script("verify-substrate.sh") if golden else "",
        record_iptables=_script("record-iptables.sh") if golden else "",
        provision_script="" if golden else _provision_script(repo_url, branch, repo_dir),
        repo_url=repo_url,
        repo_branch=branch,
        repo_dir=repo_dir,
        final_message=(
            "guarden golden VM ready after $UPTIME seconds"
            if golden
            else "guarden provisioned after $UPTIME seconds"
        ),
    )
