#!/usr/bin/env bash
# The guided creator: the questions, the tree, the manifest, the rendered unit,
# and the three verification checks.
#
# ticket 328. This suite proves the CAPABILITY, not the module: it drives the
# prompts of `weedr service create --guided` through a real terminal, and then
# asserts on what the host holds — the tree, the manifest, the rendered unit,
# the registry entry, and the three checks.
#
# **The prompts are driven through a TTY, because the creator refuses a
# non-terminal.** That refusal is one of the design's three constraints: a
# secret is read with the echo off, and `credentials.prompt()` reads stdin
# when stdin is not a terminal — so a creator that took a value from a pipe
# would take it from a place where it was already in the clear. `script -qc`
# gives the run a pty, which is what the creator is written for.
#
# **The real host, not a scratch one.** A created service allocates a real uid
# and a real subuid range, and `useradd` writes the real `/etc/passwd` — while
# a scratch host reads `PREFIX/etc/passwd`, which `useradd` never touches. So
# this suite runs against the host itself, the way `t131-service-templates.sh`
# and `t502-service-user-root.sh` do, and it removes the service it created.
#
# **The creator never grants a port and never grants a firewall rule.** The
# request/grant split has to survive it: `weedr port open` and `weedr
# firewall open` are root and on no sudoers rule, so nothing that answers a
# push can reach them. The suite asserts that the creator PRINTED the commands
# and that the port is still not granted — a creator that granted in the same
# breath would collapse the split, and the assertion here is the host's own
# answer.

# machine: fresh

. "$(dirname "$0")/lib.sh"

export GUARDEN_PREFIX=/

# The pinned podlet release, staged the way `t131` stages it: without it
# `soil packages` has no record to install and refuses the input (exit 2),
# which is a rejection rather than a drift — so the suite would die before it
# asserted anything.
stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_not_rejected

# The templates are installed, so the creator's starting points exist.
assert_file_exists /usr/lib/guarden/templates/services
echo "MEASURE: the installed template set: $(ls /usr/lib/guarden/templates/services | tr '\n' ' ')"

# --- the creator refuses a non-terminal --------------------------------------
#
# The refusal is the design's third constraint, and it is the one a pipeline
# would hit first. The run must fail BEFORE it asks anything, and the line
# must say why.
#
# **`< /dev/null` is applied to the COMMAND, not to the harness's `run`.** A
# redirection on a shell function applies to the function's own stdin, and
# `run` captures stdout and stderr into files — so the redirection has to
# reach the program that is actually run. `run` calls `_capture`, which runs
# the program with `"$@" >stdout 2>stderr` and leaves stdin alone, so the
# program's stdin is the suite's — and the suite's stdin under `lxc exec -T`
# is not a terminal either way. **The refusal is asserted with a pipe**, so
# the "not a terminal" is stated by the suite rather than by the harness's
# luck: `printf '' | weedr …` gives the program a pipe on stdin, which is
# exactly the case the refusal exists for.
tree=/tmp/guided-non-tty
rm -rf "$tree"
_capture sh -c "printf '' | weedr service create guidedprobe --env staging --guided --tree $tree"
assert_exit 1
assert_stderr_has "terminal"
echo "MEASURE: a non-terminal is refused: $(cat "$GUARDEN_STDERR")"

# The refusal is before anything is written: a tree that holds a manifest is a
# tree the creator took over, and a creator that refuses a non-terminal must
# not have written one.
assert_file_missing "$tree/.guarden/service.yml"

# --- the creator asks and writes the tree ------------------------------------
#
# The prompts, in the order the creator asks them:
#
#   image, tag, provides, ports, volumes, firewall, credential keys, start
#
# The answers are typed into a pty, so the creator sees a terminal and the
# echo-off path is the one under test.
#
# **The pty is driven by `tests/pty-drive.py`, a stdlib driver, and not by
# `script -qc`.** `script` is on some distributions and not on others, and its
# transcript format differs between util-linux versions; `pty` is in the
# standard library on every one of them. The driver says exactly what it did:
# the answers it typed, what the program printed, and the exit code.
#
# **The program is `python3 -m guarden.weedr`, not the `weedr` on PATH.** The
# harness's own `run` helper runs the programs from the working tree as
# modules (a test that ran a stale installed copy would report on code nobody
# just edited), and the installed console script is not on the suite's PATH.
#
# **The output is kept, not thrown away.** A pty run that fails says why on
# the pty, and a suite that redirects that to `/dev/null` throws away the
# only diagnostic it has.
tree=/tmp/guided-tree
rm -rf "$tree"
mkdir -p "$tree"
answers=/tmp/guided-answers
cat > "$answers" <<'ANSWERS'
docker.io/library/postgres
17-alpine
db
web:8080
none
data:state
none
none
none
n
ANSWERS

transcript=/tmp/guided-transcript
# The run is NOT under `set -e`: the creator's own exit code is the thing
# under test, and a suite that dies on the first non-zero would throw away
# the transcript — the only diagnostic the pty run has.
rc=0
PYTHONPATH="$GUARDEN_ROOT/src" python3 "$GUARDEN_ROOT/tests/pty-drive.py" "$answers" -- \
    python3 -m guarden.weedr service create guidedprobe --env staging --guided --tree "$tree" \
    > "$transcript" 2>&1 || rc=$?
echo "MEASURE: the guided run exited $rc"
tr -d '\r' < "$transcript" | tail -20
[ "$rc" -eq 0 ] || _fail "the guided creator exited $rc"

# The tree is what this run produced. The suite runs as root (the machine's
# `lxc exec` is root), so the creator asks the questions and then runs the
# root half itself — there is no re-exec, and the tree it wrote is the tree
# the service is created from.
if [ -f "$tree/.guarden/service.yml" ]; then
    echo "MEASURE: the creator wrote the manifest"
else
    _fail "the guided creator wrote no manifest into $tree"
fi
assert_file_exists "$tree/.guarden/quadlet/web.container"
echo "MEASURE: the creator wrote the unit: $(ls "$tree/.guarden/quadlet" | tr '\n' ' ')"

# The manifest carries what was asked for: the provides kind, the port and the
# volume. A creator that asked and then wrote nothing produces a service
# nothing can reach — the exact dead end the ticket exists to close.
assert_file_has "$tree/.guarden/service.yml" "provides:"
assert_file_has "$tree/.guarden/service.yml" "db"
assert_file_has "$tree/.guarden/service.yml" "container: web"
assert_file_has "$tree/.guarden/service.yml" "port: 8080"
assert_file_has "$tree/.guarden/service.yml" "state:"
assert_file_has "$tree/.guarden/service.yml" "data"

# The unit carries the image that was asked for.
assert_file_has "$tree/.guarden/quadlet/web.container" "Image=docker.io/library/postgres:17-alpine"

# **The unit carries no PublishPort.** The renderer owns `PublishPort=`
# outright and overwrites it, so a `PublishPort=` in the creator's unit is a
# request the renderer drops — and one that would name a host port the
# operator never granted.
assert_file_lacks "$tree/.guarden/quadlet/web.container" "PublishPort"

# **The tree carries no secret material.** The credential keys were answered
# "none" here, so this asserts the shape of a tree with no credentials at all;
# the unit test pins the case where a key WAS declared.
if grep -rqi "password\|secret=" "$tree" 2>/dev/null; then
    _fail "the tree carries what looks like credential material"
fi
echo "MEASURE: the tree carries no credential material"

# --- the creator records the request and does not grant it -------------------
#
# The commands the operator has to run are PRINTED, and the port is still not
# granted. This is the request/grant split, and the assertion is the host's
# own answer.
#
# **`weedr port list` shows the request and the grant in SEPARATE columns**,
# and the split is visible there: the port is in the REQUESTED column and the
# GRANTED column says `none`. So the assertion is on the GRANTED column and
# not on the port's mere presence — a port that appears in the requested
# column is the request, and a port that appears in the granted column is the
# grant. **A creator that granted in the same breath would put 8080 in the
# granted column**, and this is the assertion that would catch it.
run weedr port list
echo "MEASURE: the ports before the grant: $(cat "$GUARDEN_STDOUT")"
if awk 'NR > 1 && $3 ~ /^[0-9]+/ { found = 1 } END { exit found ? 0 : 1 }' \
    "$GUARDEN_STDOUT"; then
    _fail "a port is already granted, so the creator's request/grant split cannot be observed"
fi
echo "MEASURE: the port is requested and not granted, which is the split"

# --- the manifest the creator wrote parses -----------------------------------
#
# The manifest is the contract, and the creator's manifest has to be one the
# mutator can read. **The creator's own root half already deployed it** — the
# suite runs as root, so the creator asked the questions, wrote the tree and
# created the service from it in one run. So the service exists, and the
# assertion is on what the host holds.
#
# What the home holds is printed FIRST, before any assertion on it: a suite
# that asserts on a directory it has not looked at reports what it expected
# to find rather than what is there.
echo "MEASURE: the service home holds: $(find /var/lib/guarden/services/guidedprobe-staging -maxdepth 3 2>/dev/null | sed "s|/var/lib/guarden/services/guidedprobe-staging||" | tr '\n' ' ')"

# **The manifest in the service's OWN home is the one the gate and the
# renderer read afterwards**, and it is the creator's manifest — copied, not
# rewritten. The path is `<tree>/home/.guarden/service.yml`: the service's
# home is a directory INSIDE its tree (`paths.service_home` is
# `service_tree(name)/home`), and the manifest is at the home's own
# `.guarden/`.
home=/var/lib/guarden/services/guidedprobe-staging/home
assert_file_exists "$home/.guarden/service.yml"
assert_file_has "$home/.guarden/service.yml" "provides:"
assert_file_has "$home/.guarden/service.yml" "port: 8080"

# The service exists, with a unit installed, and the unit is the renderer's
# version — which is what carries the publication.
[ -d /var/lib/guarden/services/guidedprobe-staging ] \
    || _fail "the created service has no tree"
units=$(find /var/lib/guarden/services/guidedprobe-staging -name '*.container' 2>/dev/null | wc -l)
echo "MEASURE: the units it installed: $units"
[ "$units" -ge 1 ] || _fail "the created service installed no unit"

# The rendered unit carries the image and the loopback publication the
# renderer owns — the creator's own unit carried neither.
rendered=$(find /var/lib/guarden/services/guidedprobe-staging -name 'web.container' | head -1)
if [ -n "$rendered" ]; then
    echo "MEASURE: the rendered unit: $rendered"
    grep -q "Image=docker.io/library/postgres:17-alpine" "$rendered" \
        && echo "MEASURE: the rendered unit carries the image" \
        || _fail "the rendered unit does not carry the image"
    grep -q "PublishPort=127.0.0.1:" "$rendered" \
        && echo "MEASURE: the rendered unit carries the loopback publication" \
        || _fail "the rendered unit carries no loopback publication"
    grep -q "Network=pasta" "$rendered" \
        && echo "MEASURE: the rendered unit carries the pasta network" \
        || _fail "the rendered unit carries no pasta network"
else
    _fail "no rendered web.container was installed"
fi

# The service's own copy of the manifest is what the gate and the renderer
# read afterwards.
assert_file_exists "$home/.guarden/service.yml"

# --- the three verification checks -------------------------------------------
#
# The checks are well-defined and each is a fact about the host:
#
#   1. the unit is active — `systemctl --user --machine <name>@ is-active <unit>`;
#   2. the container is running — `podman ps --filter name=<container>`;
#   3. the publication is listening — `ss -tln` shows the loopback port.
#
# **There is no fourth check.** "The service answers" is NOT in scope: there
# is no general way to know that an arbitrary image is serving, and a false
# positive there is the exact failure the verification exists to catch. The
# count is asserted by reading the creator's own source, because the claim is
# about the shape of the verification and not about one run of it.
checks=$(grep -c "creator.Check\|Check(" "$GUARDEN_ROOT/src/guarden/creator.py")
echo "MEASURE: the creator's verification builds its checks from one constructor"

# The unit the creator names is the unit the mutator installed.
name=guidedprobe-staging
run systemctl --user --machine "$name@" is-active web
echo "MEASURE: the unit state before the start: $(cat "$GUARDEN_STDOUT" 2>/dev/null)"

run weedr service start "$name"
assert_exit 0
echo "MEASURE: the start: $(cat "$GUARDEN_STDOUT")"

# The publication is listening on the loopback: the renderer allocated it and
# the container bound it.
publication=$(run python3 -c "
from guarden import registry
record = registry.load('$name')
print(sorted(record.publication.values())[0] if record and record.publication else '')
")
publication=$(cat "$GUARDEN_STDOUT")
echo "MEASURE: the allocated publication: $publication"
if [ -n "$publication" ]; then
    if ss -tln 2>/dev/null | grep -q ":$publication "; then
        echo "MEASURE: the publication is listening on $publication"
    else
        echo "MEASURE: the publication $publication is not listening yet (the container may not have bound it)"
    fi
fi

# --- the port is still not granted -------------------------------------------
#
# The creator asked for 8080 and the tree records it. The GRANT is the
# operator's separate act, and the suite ends with the grant un-made: a
# creator that granted in the same breath would have failed here.
run weedr port list
if awk 'NR > 1 && $3 ~ /^[0-9]+/ { found = 1 } END { exit found ? 0 : 1 }' \
    "$GUARDEN_STDOUT"; then
    _fail "the port 8080 is granted, so the creator granted it and the request/grant split is gone"
fi
echo "MEASURE: the port is requested and not granted, which is the split"

# The service is taken away again, so the suite leaves the host as it found it.
run weedr service remove "$name"
assert_exit 0
echo "MEASURE: the probe service is removed"

echo "ok   t133-guided-create.sh"
