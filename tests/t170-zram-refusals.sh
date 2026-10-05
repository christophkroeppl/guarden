#!/usr/bin/env bash
# `zram:` in a manifest is refused by name, in both vocabularies.
#
# (ticket 170, spec 4 and spec 6.3)
#
# A zram device is host configuration. It lives in the root-owned
# `/etc/guarden/guarden.toml`, it is the operator's, and a repository that could
# state one would be a second place for it to be wrong — the same shape as the
# `weight:` and `environment:` refusals that are already in the manifest parser,
# and refused for the same reason.
#
# **Both vocabularies, because the repository speaks two.** `zram:` at the top
# level of `.guarden/service.yml` is the manifest's own; a `zram:` key on a
# Compose service or a `Sysctl=` line in a hand-written `.container` file is the
# unit source's, and those are checked by two different parsers on two different
# inputs. A refusal in one and not the other would leave the door open in the
# vocabulary most developers actually write.
#
# `swap:` is refused with it, and so is `sysctls:` / `Sysctl=`. Those are the
# two other ways a repository reaches a host memory knob: a swap device guarden
# does not know about, and `vm.swappiness`, which is the one real sysctl this
# ticket adds to the set soil owns. Neither is a grant and neither is a request,
# so neither is anything a repository may state.
#
# machine: shared
# `guarden_prefix` stages the host and every document below is under
# `$GUARDEN_FIXTURES`. The refusals are all reached through `loom check`, which
# writes nothing, and no device, sysctl or package is touched.
#
# `install_pinned_converter` is the one thing that is not staged: it runs a real
# `soil packages --apply`, and apt and `systemctl disable` are not prefixed. That
# reaches the machine every run, which is the leak `t40-manifest.sh` documents,
# and it is why this suite is order-insensitive: it converges the same
# convergent state and asserts nothing about the machine's package set beyond
# what it put there itself.

. "$(dirname "$0")/lib.sh"

guarden_prefix
stage_config guarden-measured.toml

# The Compose path runs the pinned converter, installed by the phase that owns
# the fetch at the pinned path — a program, not a file that merely exists. The
# refusal under test is checked on the repository's own declaration before the
# converter is asked anything, so this is about the refusal and not about podlet.
install_pinned_converter

project=$GUARDEN_FIXTURES/project
seed "$project/compose.yaml" "services:" "  web:" "    image: docker.io/library/nginx:1.27"

# --- the manifest's own vocabulary -------------------------------------------

# The top-level key, and the reason: a developer who reaches for it is told who
# owns it and where the answer lives.
seed "$project/.guarden/service.yml" "project: myapp" "units: compose.yaml" \
    "zram:" "  size_percent: 50"
run loom check "$project"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "zram"
assert_stderr_has "the operator's"
assert_stderr_has "guarden.toml"

# `swap:` and `swappiness:` are the same claim in two other spellings, and each
# gets its own message rather than a generic "unknown key" — the whole point of a
# refusal by name is that it says what the right answer is.
seed "$project/.guarden/service.yml" "project: myapp" "units: compose.yaml" "swap: /dev/zram0"
run loom check "$project"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "swap"
assert_stderr_has "the operator's"

seed "$project/.guarden/service.yml" "project: myapp" "units: compose.yaml" \
    "swappiness: 180"
run loom check "$project"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "swappiness"
assert_stderr_has "guarden converges from its own configuration"

# A nested key is refused the same way, because the closed key set covers the keys
# *inside* a block and a refusal that only worked at the top level would be
# bypassed by one level of indentation.
seed "$project/.guarden/service.yml" "project: myapp" "units: compose.yaml" \
    "routes:" "  - container: web" "    port: 3000" "    host: web" "    zram: true"
run loom check "$project"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "zram"

# --- the Compose vocabulary --------------------------------------------------

# The repository writes `compose.yaml` or `.guarden/quadlet/`, and the Compose
# refusal list is checked on the repository's own declaration in the vocabulary it
# was written in — before the converter ever sees it.
seed "$project/.guarden/service.yml" "project: myapp" "units: compose.yaml"
seed "$project/compose.yaml" "services:" "  web:" \
    "    image: docker.io/library/nginx:1.27" "    zram: true"
run loom check "$project"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "zram"
assert_stderr_has "the operator's"

seed "$project/compose.yaml" "services:" "  web:" \
    "    image: docker.io/library/nginx:1.27" "    sysctls:" "      vm.swappiness: 180"
run loom check "$project"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "sysctls"
assert_stderr_has "vm.swappiness"

# --- the quadlet vocabulary --------------------------------------------------

quadlet=$GUARDEN_FIXTURES/quadlet
seed "$quadlet/.guarden/service.yml" "project: myapp" "units: .guarden/quadlet/"

# `Sysctl=` is the one way a unit source names a host kernel knob at all, which is
# exactly why it needs refusing by name rather than left to the closed key set's
# "unknown key": a repository stating `vm.swappiness` is a repository stating a
# value the host owns.
seed "$quadlet/.guarden/quadlet/web.container" "[Container]" \
    "Image=docker.io/library/nginx:1.27" "Sysctl=vm.swappiness=180"
run loom check "$quadlet"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "Sysctl"
assert_stderr_has "vm.swappiness"

# And the refusal names the directive and the container, which are the two facts
# somebody needs to fix it.
assert_stderr_has "web"

# A repository that states none of this renders, which is the other half: a
# refusal list that refused everything would pass the assertions above and prove
# nothing about what it refuses.
seed "$quadlet/.guarden/quadlet/web.container" "[Container]" \
    "Image=docker.io/library/nginx:1.27"
run loom check "$quadlet"
assert_exit 0
assert_stderr_empty

seed "$project/compose.yaml" "services:" "  web:" "    image: docker.io/library/nginx:1.27"
run loom check "$project"
assert_exit 0
assert_stderr_empty
