# 263: the edge is listening, the routes load, and the packet still does not arrive

**Blocked by:** nothing. **Blocks:** `t50-slice.sh`, and therefore any release gate that runs
the whole suite.

**What to build:** A measurement that says why a `curl` from the host to the edge's own
loopback publication times out, when the edge is demonstrably listening on that publication.

This ticket supersedes its own earlier text. Two hypotheses have been tested and **both
refuted**, and the refutations are the useful part.

## Refuted: container group inheritance

`/var/lib/guarden/edge/dynamic` is `2750 guarden:edge`. The hypothesis was that the edge
container does not inherit its user's supplementary groups, and the proposed fix was
`GroupAdd=keep-groups` in the rendered unit.

**Refuted by experiment.** Making the route file world-readable on the host let the container
read it — and `curl` still timed out with exit 28. The permission path is not the cause.
`assert_supplementary_group traefik-production edge` was always true.

## Refuted: Traefik flag case sensitivity

The quadlet source used `--entryPoints.web.address=:80` (PascalCase). The hypothesis was that
Traefik v3.2 only accepts `--entrypoints` and silently ignored the PascalCase flags, so the
`:443` and `:8080` entrypoints never bound and every request 404'd.

**Refuted by instrumenting the suite.** Adding a trace after each assertion shows the run
reaches:

```
REACHED: assert_stdout_has 127.0.0.1:20001
REACHED: assert_stdout_has 127.0.0.1:20002
REACHED: assert_stdout_has 127.0.0.1:20003
```

All three publications — web, TLS and API — **are** bound, with the original PascalCase flags.
Traefik accepts them. The `--api.insecure=true` flag that came with that patch would also have
widened the API's exposure, and it is not needed.

The patch is preserved at `/tmp/263-entrypoints.patch` and is **not** on any branch.

## What is established

- the edge container runs, as uid 994, with pasta mapping `127.0.0.1/20000-20000:8080-8080`
  and `127.0.0.1/20001-20001:80-80`;
- all three entrypoints are bound on their loopback publications;
- the route file is written and readable inside the container;
- the suite dies on the **first `curl`**, `http://127.0.0.1:$web_publication/`, with exit 28
  — a connection timeout, meaning **no TCP connection was established at all**.

A timeout rather than a 404 is the load-bearing observation. A route that does not match, or a
router that does not exist, still produces an HTTP answer. A timeout means the SYN went
somewhere that did not answer.

## THE CAUSE — found by counter, not by reading

The agent's turn ended with a tool still pending, so this came out of its transcript rather
than a summary. It is right, and it is verifiable in the render:

```
chain guarden-svc {
    mod owner uid-owner 0 daddr 127.0.0.1 proto tcp jump ACCEPT;
    <per-publication accepts>
    <resolver accepts>
    <granted rules>
    daddr 127.0.0.0/8 jump DROP;
}
```

**There is no conntrack accept in this chain.** `INPUT` has
`mod conntrack ctstate (ESTABLISHED RELATED) jump ACCEPT`; `guarden-svc`, the OUTPUT chain,
does not — `grep -n 'conntrack' src/guarden/firewall.py src/guarden/rules.py` finds one hit
and it is a comment.

The path, as measured:

1. root's SYN leaves through OUTPUT, jumps to `guarden-svc`, and is accepted by
   `uid-owner 0 daddr 127.0.0.1 proto tcp`. The request gets through.
2. **The SYN-ACK comes back from pasta as uid 994** (traefik-production), also through OUTPUT,
   also through `guarden-svc`.
3. It matches no accept — the per-publication accepts name service and edge uids, and root's
   rule names uid 0 — and falls to `daddr 127.0.0.0/8 jump DROP`.
4. The client sees **no reply**, which is exit 28.

**A reply packet's destination is an ephemeral port on loopback, so it is always inside the
deny's range.** The deny is correct for a service uid reaching a publication it did not ask
for; it is wrong for the far side of a connection that was just permitted.

This is why the failure is a *timeout* and not a 404, and why every attempt to fix it from
inside the container failed: nothing inside the container was ever wrong. The edge listened,
the routes loaded, the file was readable. The reply never reached it.

## The fix, and why it is narrow

Add a conntrack accept to the top of `guarden-svc`, above root's rule:

```
mod conntrack ctstate (ESTABLISHED RELATED) jump ACCEPT;
```

This is narrow in the way that matters — it accepts only traffic belonging to a connection
that already exists, so it cannot be used to open a new path. It is also **required by the
existing design and merely missing**: `INPUT` has carried that rule from the first commit,
and a uid-matched output chain without it drops the reply half of every permitted connection.
Any service-to-service call that leaves a service uid is affected today, not only the edge.

## Where that leaves it

Candidates, none yet excluded:

- **the firewall.** `accept_lines` grants a publication to the service itself, its declared
  consumers, the edge's uid per route publication, and `host.admin_user` alone on the API.
  The suite's `curl` runs as **root**. Is root in any accept set for the edge's own web
  publication? `mod owner uid-owner 0` appears in some renders; whether it covers this path is
  the thing to check, and whether root's traffic to `127.0.0.1` traverses `guarden-svc` at all.
- **pasta's host mapping.** ADR-0013 / spec §7.6: pasta translates to `127.0.0.1` in userspace
  before the kernel's packet path, so a rule matching anything other than `127.0.0.1` matches
  no packet. If the accept or the deny is matching the alias rather than loopback, the packet
  is dropped and the client sees a timeout — exactly this symptom.
- **the deny.** `-A guarden-svc -d 127.0.0.0/8 -j DROP` with the resolver accepts above it. Is
  uid 0 or the edge's uid reaching that deny for this destination?

## Acceptance

- A measurement names the layer that drops the packet — firewall, pasta mapping, or something
  else — with the command that produced it.
- The fix is at that layer and no wider. **No `GroupAdd`.** If the answer is that the API's
  accept set needs root, that is a grant-surface question and needs an ADR.
- `t50-slice.sh` green on `develop` with no branch applied, and its failure path names itself
  rather than exiting with empty stderr (ticket 262, criterion 3).

## Why this ticket exists at all

Three agents have spent hours here, and each one reached for the nearest plausible cause rather
than measuring. One proposed a security-model change on an unconfirmed hypothesis. One
diagnosed a flag-casing bug that the suite's own passing assertions disprove. Both were
recorded here rather than merged, which is the only reason the next agent inherits facts
instead of three confident wrong answers.
## Solved in two steps: conntrack, then a missing router on the web entrypoint

**Step one, merged (`519903c`):** the conntrack accept. `t50-slice` stopped timing out.

**Step two, measured after the fix.** With the connection established, the edge answers:

```
$ curl -s -i -H 'Host: staging.web' http://127.0.0.1:20001/
HTTP/1.1 404 Not Found
```

A 404, not a redirect. The rendered route file explains it:

```yaml
routers:
  routed-staging-web:
    rule: "Host(`staging.web`)"
    entryPoints:
      - websecure          <-- the suite curls the web entrypoint
    service: routed-staging-web
```

**No router is bound to `web`, so traefik has nothing to match there and 404s.** The
suite expects a 301, which only `http.redirections.entrypoint` produces, and that
redirection is configured on the `web` entrypoint.

So the defect is that the renderer attaches a router to `websecure` when the
service is reachable on `web`. `edgeconf.py:22` parses the module's
`--entryPoints.<name>.…` flags with a case-sensitive regex, so which entrypoints
exist, and the redirection between them, comes from the gate module's quadlet
flags rather than from the router the renderer writes per route.

**This corrects an earlier refutation in this ticket.** A previous agent claimed
Traefik v3.2 ignores `--entryPoints` in PascalCase, and I refuted it by showing
all three entrypoints bound. That refutation stands — the ports do bind. What the
agent was reaching for is adjacent and real: guarden's own `edgeconf` regex *is*
case-sensitive, and the entrypoint a router lands on is not a property anyone
asserts.

## What it needs

A decision, not a patch: **is a route published on `web` as well as `websecure`,
or only on `websecure` with `web` carrying nothing but the entrypoint redirect?**

- If `web` is redirect-only, the renderer must not attach routers to it, and the
  suite's expectation of a 301 from `web` is right — so the fix is to stop
  emitting the router's `entryPoints: [websecure]` when the route was declared for
  the web entrypoint, or to attach it to both.
- If routes should serve on both, the renderer's per-route entrypoint needs to
  come from the manifest rather than from a module-level default.

Whichever is chosen, an assertion should pin it: today nothing states which
entrypoints a route is published on, which is why this reached a test failure
instead of a decision.

## Narrowed again: the render is correct, the redirect is not firing

The question this ticket raised — publish on `web` as well as `websecure`? — is
**answered by the code, and the answer is no.**

`roots._entrypoints` (roots.py:309) reads the entrypoints from the edge's own
shipped unit source and deliberately excludes the redirect entrypoint:

> The redirect entrypoint is never one of them: every request to it becomes a
> redirect, so a router on it would answer a 301 for a host it was meant to proxy.

So a router on `websecure` is correct, and spec §7.3 agrees: the entrypoint
answers on "80/tcp for the redirect and the ACME HTTP-01 challenge, 443/tcp for
TLS". **`web` carries the redirect and ACME; it does not serve routes.** No
decision is needed here and the earlier framing of it as a choice was wrong.

**What is left is one real question.** Both properties the suite asserts are
correct about different entrypoints — a 301 from `web` for any host, and no
router there — and the observed answer is:

```
$ curl -s -i -H 'Host: staging.web' http://127.0.0.1:20001/
HTTP/1.1 404 Not Found
```

If the entrypoint-level redirect were configured, **every** host on `web` would
answer 301 regardless of routers. A 404 means the redirection is not being
applied. The flag is present and correctly spelled:

```
Exec=--entryPoints.web.http.redirections.entrypoint.to=websecure
```

and `edgeconf.ARGUMENT` matches it — `^--entryPoints\.(?P<name>[A-Za-z0-9_-]+)\.(?P<rest>.+)$` —
so guarden reads the entrypoint as declared.

**The open question is therefore narrow:** does traefik v3.2 apply
`http.redirections.entrypoint` from that flag, and if not, what is the correct
spelling or shape? That is a question about traefik, measured in the VM, and it
wants an agent rather than another reading of this repository.

Note for whoever takes it: an earlier agent claimed PascalCase `--entryPoints`
is ignored, and I refuted that by showing all three entrypoints bound. The
refutation stands. What was adjacent and real is that guarden's own regex is
case-sensitive, so a lowercase spelling would be silently invisible to
`edgeconf` — a second way for a rename to break silently.

## SOLVED: traefik v3.2 ignores `--entryPoints`, and so did I

`podman run --rm docker.io/library/traefik:v3.2 --help | grep -c entryPoints` in the
VM:

    --entrypoints.<name>.http.redirections.entrypoint.to  (Default: "")
    ...
    41

**41 lowercase `entrypoints` flags. Zero `entryPoints`.**

Every flag in the gate module is PascalCase:

```
Exec=--entryPoints.web.address=:80
Exec=--entryPoints.web.http.redirections.entrypoint.to=websecure
Exec=--entryPoints.websecure.address=:443
Exec=--entryPoints.api.address=:8080
```

so traefik ignores all of them and runs on its defaults. **The first agent to work
this ticket was right and I refuted it wrongly.** My refutation was that all three
publications appeared bound — and they were, but on traefik's DEFAULT entrypoints,
not the ones guarden asked for. `:80` is both the requested web address and traefik's
default, which is why the coincidence looked like success. `:8080` and `:443` were
never configured at all.

**And guarden cannot see it.** `edgeconf.ARGUMENT` is
`^--entryPoints\.(?P<name>[A-Za-z0-9_-]+)\.(?P<rest>.+)$` — case-sensitive, matching
guarden's own spelling rather than traefik's. So `roots._entrypoints` reads
`web`, `websecure` and `api` out of flags the edge never received, and the
entrypoint redirect it deliberately excludes from routing is a flag that was
never in effect.

**The fix is two parts, and the second is the one that stops it recurring.**

1. The gate module's quadlet source uses lowercase `--entrypoints.*`.
2. `edgeconf.ARGUMENT` matches what traefik actually accepts, so a flag traefik
   would ignore is refused at read time with a diagnostic naming it, rather than
   read as a declaration. A spelling the vendor does not recognise is not a
   declaration; treating it as one is how this stayed invisible while every
   suite that checked a bound port saw it pass.

The first part alone makes the suites pass. The second is what makes the next
miss visible, and it is the difference between a fix and a patch.

## Post-fix state: the flags arrive correct, the redirect still does not fire

Measured after `408f898`, inside the VM after `t50-slice` has run its install:

```
$ grep -h 'entrypoints\.' /usr/lib/guarden/modules/gate/traefik-production/.guarden/quadlet/traefik.container
Exec=--entrypoints.web.address=:80
Exec=--entrypoints.web.http.redirections.entrypoint.to=websecure
Exec=--entrypoints.websecure.address=:443
```

**The corrected flags reach the installed module.** That rules out the first of
the three possibilities — the install does copy the source guarden ships, and it
is the corrected one.

So the remaining question is the second: does traefik v3.2 apply
`http.redirections.entrypoint` from `--entrypoints.web.http.redirections.entrypoint.to`?

I could not answer it by hand. Two attempts to run traefik directly with the
flags failed for reasons of my own making — the first put pasta's `-t` mapping
before the image, so podman read the mapping as the image name; the second hit a
registry lookup on 127.0.0.1 for the same reason. Getting it right needs a
careful command, and a wrong one teaches nothing.

**What would settle it**, for whoever has a VM and a working command:

```sh
podman run --rm -p 20001:80 docker.io/library/traefik:v3.2 \
  --entrypoints.web.address=:80 \
  --entrypoints.web.http.redirections.entrypoint.to=websecure
# then, from the host:
curl -sI -H 'Host: anything.example' http://127.0.0.1:20001/
```

A `301` means the flag works and something else is wrong at the install. A `404`
means v3.2 does not apply it from this shape, and the fix is a different
spelling or a dynamic-config block rather than a flag rename.

One thing already established that makes this worth chasing rather than parking:
`--entrypoints.api.address=:8080` was ignored for the whole time the module
shipped PascalCase, so the edge's API has never been on the publication guarden
advertises. The spelling fix corrects that whatever the redirect turns out to
need.

## Answered: traefik does apply the flag. 408f898 was the fix.

Run by hand in the VM with the corrected flags:

```
$ podman run -d --name tj2 -p 127.0.0.1:20002:80 traefik:v3.2 \
    --entrypoints.web.address=:80 \
    --entrypoints.websecure.address=:443 \
    --entrypoints.web.http.redirections.entrypoint.to=websecure
$ curl -s -o /dev/null -w '%{http_code} %{redirect_url}' -H 'Host: anything.example' \
    http://127.0.0.1:20002/
301 https://anything.example/
```

Zero errors in the log, and a 301 carrying the requested name back — exactly
what `t50-slice.sh` asserts. **The redirection is applied from the flag; the
PascalCase spelling was the whole defect.**

A one-flag run is the useful negative, and it is why the earlier three-way
framing was wrong to leave open. Naming a target that does not exist:

```
ERR error="'to' entry point field references a non-existing entry point: websecure"
entryPointName=web providerName=internal
```

So traefik validates the target and refuses the redirect rather than silently
serving. The generated unit in the suite declares both `web` and `websecure`, so
that is not the suite's failure — but it is the shape a mistake in this area
takes, and worth knowing.

**`t50-slice.sh` still fails after 408f898**, and the generated unit carries the
corrected flags at every stage:

```
/var/lib/guarden/render/traefik-production/units/traefik.container
/var/lib/guarden/services/traefik-production/home/.config/containers/systemd/traefik.container
```

so what differs between the two runs is not the flags and not the spelling.
The container is torn down when the suite ends, which is why reading its runtime
is not available afterwards, and instrumenting the suite to catch it is the
thing this ticket exists to stop.

What is left is a runtime difference: what traefik binds inside the container,
what its log says, and whether pasta's publication mapping reaches the port the
unit declares. That is a run-with-the-container-up question and it needs an
agent, which the daily quota is currently refusing.

## THE REAL CAUSE: quadlet keeps only the LAST `Exec=` line

Measured with the container held up, so the argv is readable:

```
$ podman inspect traefik-production-traefik --format "{{.Path}}|{{.Args}}"
/entrypoint.sh|[--log.level=INFO]
```

**Every `--entrypoints.*` flag is gone.** Only `--log.level=INFO` survived, and it is
the last `Exec=` line in the file. The generated unit says the same:

```
$ grep '^ExecStart' /run/user/994/systemd/generator/traefik.service | tr ' ' '\n' \
    | grep -E 'entrypoints|accesslog|log.level'
--log.level=INFO
```

while the `.container` it was generated from is complete and correct:

```
Exec=--providers.file.directory=/etc/guarden/edge
Exec=--providers.file.watch=true
Exec=--entrypoints.web.address=:80
Exec=--entrypoints.web.http.redirections.entrypoint.to=websecure
... (eleven lines)
Exec=--accesslog=true
Exec=--log.level=INFO
```

**So the spelling fix was necessary and is not sufficient.** Correct flags that
quadlet discards are still no flags. Traefik ran on pure defaults, bound its
default `:80`, and answered 404 because no entrypoint and no redirect existed —
which is precisely the behaviour observed, and why `podman ps` showed it "Up"
while every request 404'd.

**This invalidates part of what I recorded above.** I claimed the redirection "is
applied from the flag" on the strength of a direct `podman run`. That was true of
my hand-written command and false of what guarden actually produces. The two
differ only in that mine was one command line and guarden's is eleven `Exec=`
lines, which quadlet reads as one.

**The question is now narrow and answerable:** does quadlet treat `Exec=` as
last-wins, or is `Exec=` not the key that appends arguments at all? The traefik
image's own `/entrypoint.sh` is what ends up on `Path`, and the flags may need to
be `Entrypoint=` or `Cmd=` rather than `Exec=`. Nothing in guarden asserts which,
and every service that passes flags to an image with its own entrypoint has the
same shape.

This is the third defect in this ticket and none of the three would have been
found by a suite that only checked whether a port was bound: they all leave the
port bound.
