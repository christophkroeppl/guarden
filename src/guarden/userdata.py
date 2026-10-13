"""The cloud-init user-data, rendered from the one package list.

spec 6.1's six phases are the whole of what a fresh box needs, and the order
they run in is the order `soil list` prints. This module turns that into the one
document a cloud-init-capable machine boots from, and it renders the package
list from `packages/packages.toml` rather than carrying one of its own — because
a package named here and not there is a box that installs three things and
converges on a fourth, with nothing reporting the difference.

**What the rendered document does and does not do.** It installs the substrate
and the throwaway machine's harness tools, then runs every phase's `--apply` and
every phase's `--check`. It does **not** create the program users, write
`/usr/lib/guarden`, or set `ingress.alias`: `soil install` owns those, and a
document that pre-empted them would make the phases untestable — a phase that
finds its own work already done is a phase that proves nothing.

**No PyPI, no wheel, no venv.** Every line of the package list comes from the
distribution's own repository. The one artefact fetched from outside a
distribution repository is the pinned `podlet` release, which `soil packages`
verifies against the SHA256 recorded in this repository; a cloud-init document
that fetched anything else would be a second, unpinned fetch path.
"""

from __future__ import annotations

from guarden import packagelist

# The packages the substrate needs come first and the harness tools after, with
# a comment between them, so a reader of the rendered document can tell which is
# which without cross-referencing the list.
_SUBSTRATE_NOTE = "  # substrate: what `soil packages` converges, from packages.toml"


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
    """
    names = phases()
    apply = ";".join(f"soil {phase} --apply" for phase in names)
    check = ";".join(f"soil {phase} --check" for phase in names)
    return f"{apply};{check}"


def package_block(family: str | None = None) -> str:
    """The `packages:` block, substrate first and harness tools after.

    Rendered from the one list, so a package added to `packages.toml` and not to
    this file is a package that reaches the machine by exactly one path.

    **The conditional roles are not rendered, and that is the design rather than
    an omission.** They carry the packages a *configured* host installs when its
    operator's guarden.toml asks for the thing they provide — the zram
    generator is the one there is today. A machine being provisioned is not yet
    a configured host, so baking them in would put the generator on every
    golden-VM image and make "absent means absent: no package" untestable on the
    machine that has to test it. The phase installs one the moment the knob is
    there, which is the same path a real host takes.
    """
    substrate = packagelist.package_names(family)
    harness = packagelist.harness_names(family)
    lines = ["packages:"]
    lines.append(_SUBSTRATE_NOTE)
    lines.extend(f"  - {package}" for package in substrate)
    if harness:
        lines.append("")
        lines.append("  # harness: the throwaway machine's check tooling, and no host's")
        lines.extend(f"  - {package}" for package in harness)
    return "\n".join(lines) + "\n"


HEADER = """#cloud-config
#
# Rendered by `tools/render-user-data` from packages/packages.toml. Do not edit
# the package list here: this file is generated from the one in the repository,
# and a package named in both is a package that can drift.
#
# The golden VM is the harness that cannot be faked: a throwaway machine with
# real tools, proving the claims the fast harness cannot — that a rootless
# container reaches a dependency by the pinned alias (ADR-0018), that nothing
# unprivileged binds below 1024, and that a clone of a live data volume starts
# and recovers. `tools/golden-vm` is the entry point and asserts none of it; a
# runner that also decided what a pass was would be a harness whose result
# nobody could audit.
#
# This document only PROVISIONS and then CONVERGES. It installs what the soil
# phases run over, and it installs nothing guarden owns: it does not create the
# program users, does not write /usr/lib/guarden, and does not set the ingress
# alias. `soil install` does those, and a document that pre-empted them would
# make the phases untestable — a phase that finds its own work already done is a
# phase that proves nothing.
#
# It fetches nothing from PyPI and no wheel. Everything below is a distribution
# package, and the one artefact from outside a distribution repository — the
# pinned `podlet` release — is fetched by `soil packages` and verified against
# the SHA256 recorded in this repository.
#
# What it must get right, and why:
#
# - podman must be new enough for pasta. Podman 5.0 made pasta the default
#   rootless network; below that, rootless containers get slirp4netns and the
#   alias probe's premise does not hold. Ubuntu 26.04 ships 5.x, so `pasta` is a
#   plain package install and the binary is /usr/bin/pasta. Installing it
#   explicitly rather than relying on Recommends is deliberate: a golden VM that
#   silently lost pasta to a Recommends change would report "not run" for every
#   networking claim, which is how ticket 15's eleven checks came back unproven
#   in the first place.
#
# - btrfs-progs and snapper are needed because `soil storage` converges a btrfs
#   layout and a snapper value set. Ticket 15 measured a real deviation here
#   (5.16.2), so the version is recorded rather than assumed.
#
# - `sysctl` and the kernel modules the sysctl phase writes (route_localnet on
#   the ingress interface, IPv6 off) must be loadable. The sysctl phase is
#   `route_localnet` on one interface; a machine that cannot set it will report
#   drift forever and that is a real answer, not a harness failure.
#
# - iproute2 and nftables-family tooling because `soil firewall` converges ferm
#   and the inspection in ticket 140 reads the installed `nat PREROUTING` chain.
#   **The chain ferm installs is in iptables-LEGACY, and that is ferm's own
#   choice** -- ferm 2.7 prefers the `iptables-legacy*` names when resolving the
#   xtables binary it loads a policy with, measured on the golden by reading the
#   argv out of `ferm --shell`. Both families of tooling are therefore installed:
#   the nft ones for what an operator reading nft sees, and the legacy table for
#   the rules actually in force. See
#   docs/notes/iptables-variant-must-be-stated.md.
#
# The runcmd step below records which table the rules go in before any phase
# runs, so a machine booting into the two halves disagreeing says so there rather
# than after six phases report success.

package_update: true
package_upgrade: false

"""

FOOTER = """
write_files:
  # The evidence the run leaves behind. The ticket requires a tarball of
  # journals, unit states and `soil --check`, and a directory that already
  # exists is the difference between a run that reports and a run that
  # silently produced nothing.
  - path: /var/lib/guarden-evidence
    permissions: "0755"

  # A marker recording what this machine actually was, so a stale evidence
  # directory from an earlier image cannot be mistaken for this run's result.
  - path: /var/lib/guarden-evidence/PROVENANCE
    permissions: "0644"
    content: |
      guarden golden VM user-data, rendered from packages/packages.toml
      image: ubuntu 26.04 (resolute)
      provisioned by cloud-init; guarden itself is converged by `soil`

runcmd:
  # Verify the substrate the checks depend on, loudly and early. If pasta is
  # missing, every networking claim is unprovable and the run must say so at
  # the point of failure rather than eleven separate "not run" verdicts later.
  - |
    set -eu
    {{
      echo "podman: $(podman --version 2>/dev/null || echo MISSING)"
      echo "pasta:  $(command -v pasta || echo MISSING)"
      echo "btrfs:  $(btrfs --version 2>/dev/null || echo MISSING)"
      echo "kernel: $(uname -r)"
      echo "os:     $(. /etc/os-release && echo "$PRETTY_NAME")"
      echo "cgroup: $(stat -fc %T /sys/fs/cgroup 2>/dev/null || echo unknown)"
    }} > /var/lib/guarden-evidence/substrate.txt
    cat /var/lib/guarden-evidence/substrate.txt
    if ! command -v pasta >/dev/null 2>&1; then
      echo "FATAL: pasta is absent; the rootless-network claims cannot be proven" >&2
      exit 1
    fi
    if ! command -v btrfs >/dev/null 2>&1; then
      echo "FATAL: btrfs-progs is absent; soil storage cannot converge" >&2
      exit 1
    fi

  # **Which iptables table the firewall rules go in, recorded before any phase
  # runs.** `soil firewall` converges the variant the package list names and
  # refuses to report a converged firewall whose rules the host's own `iptables`
  # cannot read, but a machine booting into the two halves disagreeing should say
  # so here, where nothing has been converged on top of it yet.
  #
  # Both halves are recorded, and separately on purpose: `update-alternatives`
  # records which variant `/usr/sbin/iptables` NAMES, while ferm resolves its own
  # binary when loading a policy and prefers the `-legacy` names. The two can
  # disagree on a healthy host, and on the golden they did — which is the whole
  # of docs/notes/iptables-variant-must-be-stated.md.
  - |
    set -eu
    vf=/var/lib/guarden-evidence
    echo "iptables name:   $(iptables --version 2>/dev/null || echo MISSING)" >>"$vf/substrate.txt"
    ferm --shell /dev/null >"$vf/.ferm-sh" 2>&1 || true
    echo "ferm would load: $(head -1 "$vf/.ferm-sh" | cut -d' ' -f1)" >>"$vf/substrate.txt"
    echo "alternatives:    $(iptables --version | sed 's/.*(//;s/)//')" >>"$vf/substrate.txt"
    iptables-legacy-save -t filter >"$vf/.legacy" 2>/dev/null || true
    echo "legacy chains:   $(grep -c '^-N' "$vf/.legacy")" >>"$vf/substrate.txt"
    nft list tables >"$vf/.nft" 2>/dev/null || true
    echo "nft tables:      $(wc -w <"$vf/.nft")" >>"$vf/substrate.txt"
    rm -f "$vf/.ferm-sh" "$vf/.legacy" "$vf/.nft"
    tail -5 "$vf/substrate.txt"

  # Converge every phase, then check every phase. The order and the phase list
  # are `soil list`'s, read from the program at render time, so this line and
  # the program cannot disagree about what converged state is.
  - |
    set -eu
    {sequence}

final_message: "guarden golden VM ready after $UPTIME seconds"
"""


def render(family: str | None = None) -> str:
    """The whole document: the header, the rendered packages, and the run."""
    body = HEADER + package_block(family) + FOOTER.format(sequence=sequence())
    return body