#!/usr/bin/env bash
# The poke's account is NOT in the mutator's group.
#
# **F2, MEDIUM, from the first security review (`nous/longcat-2.5-preview-free`).**
# The install phase created `hose` with `useradd --gid guarden`, so the poke's
# account was a member of the group that reaches:
#
#   · /etc/guarden/guarden.toml                     0640 root:guarden
#   · /etc/guarden/services/*/overrides.toml        0640 root:guarden
#   · /var/lib/guarden/registry/*.toml              0640, dir 0750
#   · /var/lib/guarden/share/*                      0640, dir 0750
#   · /var/lib/guarden/queue                        0770 root:guarden  (WRITE)
#   · /var/lib/guarden/stakes                       0770 root:guarden  (WRITE)
#
# — and the last of those is watched by `guarden-pins.path`, so a write there
# makes a ROOT unit run.
#
# **Four places in `hose.py` say the opposite** — "hose is deliberately not in
# the `guarden` group, so on a conforming host the registry is unreadable here"
# (hose.py:162, 354, 382, 430) — and the install phase made it a member anyway.
#
# **Why no suite saw it:** every suite creates `hose` ITSELF, without the
# `--gid` flag (tests/t90-gitops.sh, tests/t90-projects.sh), so the membership
# the install phase creates never existed in the VM. The divergence was
# invisible by construction.
#
# The assertions here run AFTER `soil install --apply`, so they see the
# install phase's own user, and each one has a positive control — a check that
# passes on a host where the file is simply missing proves nothing.

. "$(dirname "$0")/lib.sh"

export GUARDEN_PREFIX=/
stage_config guarden.toml
stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_not_rejected

# --- the group membership itself -----------------------------------------------
echo "MEASURE: hose's groups: $(id -nG hose 2>/dev/null | tr ' ' ',')"
case " $(id -nG hose 2>/dev/null) " in
    *" guarden "*)
        _fail "hose is in the guarden group, and that group reads the host's configuration"
        ;;
esac
echo "MEASURE: hose is not in the guarden group"

# --- and the read, with a positive control -------------------------------------
#
# The control matters: the assertion below would pass on a host where
# guarden.toml does not exist, and a test that cannot fail is not a test.
assert_file_exists /etc/guarden/guarden.toml
assert_mode /etc/guarden/guarden.toml 640
assert_owner /etc/guarden/guarden.toml root:guarden

# As `guarden` — the mutator's own identity — the file IS readable. If this
# fails, the host is not the shape the suite thinks it is.
run runuser -u guarden -- cat /etc/guarden/guarden.toml
assert_exit 0
assert_stdout_has "["
echo "MEASURE: the mutator reads the host's configuration: yes"

# As `hose` — the poke's account — it is NOT.
run runuser -u hose -- cat /etc/guarden/guarden.toml
assert_exit 1
assert_stderr_has "Permission denied"
echo "MEASURE: the poke's account reads the host's configuration: no"

# --- and the two directories a root unit watches --------------------------------
#
# The stakes directory is watched by `guarden-pins.path`, so a write there
# makes a root unit run. `hose` must not be able to write it.
assert_mode /var/lib/guarden/stakes 770
run runuser -u hose -- touch /var/lib/guarden/stakes/probe-from-hose
assert_exit 1
echo "MEASURE: the poke's account writes the pin store: no"

assert_mode /var/lib/guarden/queue 770
run runuser -u hose -- touch /var/lib/guarden/queue/probe-from-hose
assert_exit 1
echo "MEASURE: the poke's account writes the deploy queue: no"

# The positive control on the write: the mutator's own identity CAN write
# there, because the queue and the pin store are the mutator's.
run runuser -u guarden -- touch /var/lib/guarden/queue/probe-from-guarden
assert_exit 0
rm -f /var/lib/guarden/queue/probe-from-guarden
echo "MEASURE: the mutator writes the deploy queue: yes"

echo "ok   t134-poke-account-group.sh"
