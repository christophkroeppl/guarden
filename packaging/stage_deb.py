#!/usr/bin/env python3
"""Stage the installed file tree for a guarden .deb package."""
import os
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve()
pkgroot = Path(sys.argv[2]).resolve()
version = sys.argv[3]

os.environ["GUARDEN_PREFIX"] = str(pkgroot)
os.environ["GUARDEN_REPO_DIR"] = str(root)

sys.path.insert(0, str(root / "src"))

from guarden import hostprep, hosttool

real_run_or_die = hosttool.run_or_die


def fake_run_or_die(*argv, **kw):
    if not argv:
        return real_run_or_die(*argv, **kw)
    if argv[0] in ("chown", "groupadd", "useradd", "usermod", "groupmod"):
        return None
    if argv[0] == "install":
        # Strip ownership flags so staging works without root; dpkg-deb
        # --root-owner-group restores root ownership in the package.
        cleaned = []
        i = 0
        while i < len(argv):
            if argv[i] in ("-o", "-g", "--owner", "--group"):
                i += 2
                continue
            cleaned.append(argv[i])
            i += 1
        argv = tuple(cleaned)
    return real_run_or_die(*argv, **kw)


hostprep.h.run_or_die = fake_run_or_die

hostprep._install_programs()
hostprep._install_templates()
hostprep._install_modules()
hostprep._install_packagelist()
# _link_programs() uses staging paths; create correct absolute links for the
# final install location instead.
usr_bin = pkgroot / "usr" / "bin"
usr_bin.mkdir(parents=True, exist_ok=True)
for program in hostprep._PROGRAMS:
    link = usr_bin / program
    if link.is_symlink() or link.exists():
        link.unlink()
    link.symlink_to("/usr/lib/guarden/bin/" + program)

print("staged", pkgroot)
