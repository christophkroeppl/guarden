#!/usr/bin/env bash
# The deployment refusals a real repository tripped, in the vocabulary it wrote
# them in (ticket 272, spec 4 and spec 6.3).
#
# **Two findings, and both are a repository stating something the host owns or
# something the host does not have.** Ticket 272 is a findings ledger from the
# first real deployment attempt; two of its four findings are enforced by the
# design already (a bind of the repository root, and a project with no unit
# source at all), and the two below were not.
#
# **A resource cap is the operator's.** Spec 4 refuses a manifest key stating a
# cap or a weight, and the manifest vocabulary did: `memory:`, `memory_max:`,
# `memory_high:`, `weight:`, `cpu_weight:`, `io_weight:`. The COMPOSE vocabulary
# did not, and `mem_limit: 2g` in a compose file is the same statement in the
# other vocabulary — so it reached the pinned converter, which writes it as
# `[Container] Memory=`, which the renderer does not own and therefore does not
# overwrite. The container really was capped, and nothing said so.
#
# **A `networks:` declaration names a network a guarden host does not have.**
# Every container of a service runs in its own pasta namespace (spec 7.1) and
# there is no shared podman network; the renderer writes `Network=pasta:` over
# whatever the source asked for (spec 6.3). A compose file declaring one is
# therefore not a faithful description of what runs — the ticket's own words —
# and it is also the intra-source membership claim spec 7.3 refuses. Measured:
# a service's `networks:` with no top-level table makes the converter exit `1`,
# which spec 1.2 reserves for "the host is not in the state the request
# assumed", over what is a rejected input; with the table present the converter
# writes a `.network` unit that the conversion drops in silence.
#
# **A refusal is checked on the repository's own declaration, before the
# converter is driven**, so the diagnostic is guarden's, the exit is `2`, and
# the message names the key, the container and where the operator's answer
# lives — a `drop-in` for a cap, `guarden.toml` for a weight, and neither for a
# network, because a network cannot be granted at all.
#
# machine: shared
# `guarden_prefix` stages the host, and every staged manifest, staged compose
# file and staged `guarden.toml` is under `$GUARDEN_PREFIX` or
# `$GUARDEN_FIXTURES`. `install_pinned_converter` reaches real apt and the
# machine's apt timers; see the note in t40-manifest.sh. Every refusal below is
# reached through `loom check`, which writes nothing, and no device, network or
# package is touched.

. "$(dirname "$0")/lib.sh"

guarden_prefix
stage_config guarden-measured.toml

# The Compose path runs the pinned converter, installed by the phase that owns
# the fetch at the pinned path — a program, not a file that merely exists. Every
# refusal below is checked on the repository's own declaration before the
# converter is asked anything, so this is about the refusals and not about
# podlet; the assertion that the diagnostic never mentions the converter is what
# says so.
install_pinned_converter

project=$GUARDEN_FIXTURES/project
seed "$project/.guarden/service.yml" "project: myapp" "units: compose.yaml"

# --- the Compose vocabulary: a resource cap ----------------------------------
#
# The short spellings are the ones a Compose file actually uses, and the real
# repository used `mem_limit:` and `cpus:`. Every key in the family is refused
# by name rather than left to the converter's own answer, because the family is
# one statement in one vocabulary: a cap is the operator's.
refuse_cap() {
    local key=$1
    seed "$project/compose.yaml" "services:" "  web:" \
        "    image: docker.io/library/nginx:1.27" "    $2"
    run loom check "$project"
    assert_exit 2
    assert_one_diagnostic "error:"
    assert_stderr_has "$key"
    # The container is named too, because the container and the key are the two
    # facts somebody needs to fix it.
    assert_stderr_has "'web'"
    # The owner is named, because "not allowed" is not actionable and the
    # operator's drop-in is where the answer lives.
    assert_stderr_has "drop-in"
    # And the refusal is guarden's, not the converter's: a cap is refused before
    # podlet is asked to read the file.
    assert_stderr_lacks "podlet"
}

refuse_cap "mem_limit" "mem_limit: 2g"
refuse_cap "mem_reservation" "mem_reservation: 512m"
refuse_cap "memswap_limit" "memswap_limit: 2g"
refuse_cap "mem_swappiness" "mem_swappiness: 60"
refuse_cap "cpus" "cpus: '2.0'"
refuse_cap "cpu_quota" "cpu_quota: 20000"
refuse_cap "cpu_period" "cpu_period: 100000"
refuse_cap "cpu_rt_runtime" "cpu_rt_runtime: 400000"
refuse_cap "cpu_rt_period" "cpu_rt_period: 1000000"
refuse_cap "cpuset" "cpuset: '0-1'"
refuse_cap "pids_limit" "pids_limit: 512"
refuse_cap "oom_kill_disable" "oom_kill_disable: true"
refuse_cap "oom_score_adj" "oom_score_adj: 500"

# `ulimits:` is a mapping rather than a scalar, and it is the one member of the
# family that reached the installed unit as `[Container] Ulimit=`.
seed "$project/compose.yaml" "services:" "  web:" \
    "    image: docker.io/library/nginx:1.27" "    ulimits:" "      nofile: 1024"
run loom check "$project"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "ulimits"
assert_stderr_has "drop-in"
assert_stderr_lacks "podlet"

# **A weight is the track's, and its answer is the other file.** `cpu_shares:`
# is the one key of the family that states a relative weight rather than a cap,
# so the diagnostic has to name `guarden.toml` instead of a drop-in. A refusal
# that pointed a weight at a drop-in would be pointing at a file that cannot
# answer it.
seed "$project/compose.yaml" "services:" "  web:" \
    "    image: docker.io/library/nginx:1.27" "    cpu_shares: 512"
run loom check "$project"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "cpu_shares"
assert_stderr_has "guarden.toml"
assert_stderr_lacks "podlet"

# The long spelling is the same statement in the other Compose vocabulary, and a
# rule that covered only the short one would be exactly the one-rule-two-
# spellings failure the `zram:` refusal exists to avoid (spec 4). The PATH is
# named rather than the whole `deploy:` table, because `deploy.replicas` and
# `deploy.restart_policy` are not caps.
seed "$project/compose.yaml" "services:" "  web:" \
    "    image: docker.io/library/nginx:1.27" "    deploy:" \
    "      resources:" "        limits:" "          memory: 2G" "          cpus: '2.0'"
run loom check "$project"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "deploy.resources.limits"
assert_stderr_has "memory"
assert_stderr_has "'web'"
assert_stderr_has "drop-in"
assert_stderr_lacks "podlet"

# And the reservations half of the same table: a reservation is a cap the
# operator did not grant, in the one other place Compose writes it.
seed "$project/compose.yaml" "services:" "  web:" \
    "    image: docker.io/library/nginx:1.27" "    deploy:" \
    "      resources:" "        reservations:" "          memory: 512M"
run loom check "$project"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "deploy.resources.reservations"
assert_stderr_has "memory"
assert_stderr_lacks "podlet"

# --- the Compose vocabulary: a network ---------------------------------------

# A `networks:` name resolves to the app's own pod (ADR-0026). The document-level
# table is accepted when its only key is the pod's name and it states no options;
# every other name is refused by name, with the pod named in the diagnostic.
# The service-level list is accepted when it names the pod; the implicit default
# network (no `networks:` key) is that pod. A service on several networks is
# refused, because a pod is one namespace.

# The document-level table naming the WRONG network is refused by name, with the
# pod named in the diagnostic.
seed "$project/compose.yaml" "services:" "  web:" \
    "    image: docker.io/library/nginx:1.27" "networks:" "  klimafit:" \
    "    driver: bridge"
run loom check "$project"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "networks"
assert_stderr_has "myapp"
# There is no operator grant that answers this, so the diagnostic says the
# network does not exist rather than pointing at a drop-in.
assert_stderr_lacks "drop-in"
assert_stderr_lacks "podlet"

# The document-level table naming the pod, with no options, is ACCEPTED.
seed "$project/compose.yaml" "services:" "  web:" \
    "    image: docker.io/library/nginx:1.27" "networks:" "  myapp: {}"
run loom check "$project"
assert_exit 0
assert_stderr_empty

# The service-level list naming the WRONG network is refused by name, with the
# pod named in the diagnostic.
seed "$project/compose.yaml" "services:" "  web:" \
    "    image: docker.io/library/nginx:1.27" "    networks:" "      - klimafit"
run loom check "$project"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "network"
assert_stderr_has "'web'"
assert_stderr_has "myapp"
assert_stderr_lacks "podlet"

# The service-level list naming the pod is ACCEPTED.
seed "$project/compose.yaml" "services:" "  web:" \
    "    image: docker.io/library/nginx:1.27" "    networks:" "      - myapp" \
    "networks:" "  myapp: {}"
run loom check "$project"
assert_exit 0
assert_stderr_empty

# A service on SEVERAL networks is refused: a pod is one namespace.
seed "$project/compose.yaml" "services:" "  web:" \
    "    image: docker.io/library/nginx:1.27" "    networks:" "      - myapp" \
    "      - klimafit" \
    "networks:" "  myapp: {}"
run loom check "$project"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "networks"
assert_stderr_has "'web'"
assert_stderr_has "myapp"
assert_stderr_lacks "podlet"

# The map form of the same key carries `aliases:` and `ipv4_address:` — a name
# map and a static address, and this design has neither (spec 7.3). The wrong
# name is refused by name with the pod named.
seed "$project/compose.yaml" "services:" "  web:" \
    "    image: docker.io/library/nginx:1.27" "    networks:" \
    "      klimafit:" "        aliases: [ api ]" "        ipv4_address: 10.0.2.50"
run loom check "$project"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "network"
assert_stderr_has "myapp"
assert_stderr_lacks "podlet"

# The map form naming the pod but carrying options is refused.
seed "$project/compose.yaml" "services:" "  web:" \
    "    image: docker.io/library/nginx:1.27" "    networks:" \
    "      myapp:" "        aliases: [ api ]"
run loom check "$project"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "network"
assert_stderr_has "myapp"
assert_stderr_lacks "podlet"

# --- what is NOT refused -----------------------------------------------------
#
# A refusal list that refused everything would pass every assertion above and
# prove nothing about what it refuses.
#
# A compose file that states none of this renders. That is the base case, and it
# is the one the two findings above are measured against.
seed "$project/compose.yaml" "services:" "  web:" \
    "    image: docker.io/library/nginx:1.27"
run loom check "$project"
assert_exit 0
assert_stderr_empty

# **A document-level `volumes:` table is not refused**, and the named volume it
# declares pairs with the manifest's `state:` list. This is the nearest
# neighbour of the `networks:` table and it is ordinary Compose; a rule that
# caught the document-level tables whole would refuse every real project.
volumed=$GUARDEN_FIXTURES/volumed
seed "$volumed/.guarden/service.yml" "project: myapp" "units: compose.yaml" \
    "state:" "  - data"
seed "$volumed/compose.yaml" "services:" "  web:" \
    "    image: docker.io/library/nginx:1.27" "    volumes:" \
    "      - data:/var/lib/nginx" "volumes:" "  data:"
run loom check "$volumed"
assert_exit 0
assert_stderr_empty

# **`network_mode:` is still REPLACED rather than refused**, which is what spec
# 6.3 says and what makes it different from `networks:`: the backend is
# guarden's and is written over whatever the source asked for, while a
# membership claim resolves to nothing and is refused by name.
seed "$project/compose.yaml" "services:" "  web:" \
    "    image: docker.io/library/nginx:1.27" "    network_mode: host"
run loom check "$project"
assert_exit 0
assert_stderr_has "network_mode"
assert_stderr_has "replaced rather than passed through"

# --- and the refusal is total ------------------------------------------------
#
# `loom render` refuses the same declaration, and the out directory is never
# created: a refusal that had already written half a unit set would be the
# partial render the lock in spec 3.5 exists to prevent. The registry row is the
# one a deployed service would have, so the render gets as far as the source and
# is stopped by the source itself.
registry=$GUARDEN_PREFIX/var/lib/guarden/registry
seed "$registry/myapp-staging.toml" \
    'service = "myapp-staging"' 'workload = "myapp"' 'project = "myapp"' \
    'environment = "staging"' 'uid = 1102' 'created = "2026-09-30T09:00:00Z"'
seed "$project/compose.yaml" "services:" "  web:" \
    "    image: docker.io/library/nginx:1.27" "    mem_limit: 2g"
refused_out=$GUARDEN_FIXTURES/refused-render
run loom render "$project" --service myapp-staging --out "$refused_out"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "mem_limit"
assert_file_missing "$refused_out"
