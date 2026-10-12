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
exist, and the redirection between them, comes from the gate-traefik module's quadlet
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

Every flag in the gate-traefik module is PascalCase:

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

1. The gate-traefik module's quadlet source uses lowercase `--entrypoints.*`.
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
$ grep -h 'entrypoints\.' /usr/lib/guarden/modules/gate-traefik/traefik-production/.guarden/quadlet/traefik.container
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

## Measured again from the generated unit, with the container up

```
$ grep '^ExecStart' /run/user/994/systemd/generator/traefik.service | tr ' ' '\n' | grep -E '^--'
--name --replace --rm --cgroups=split --add-host --network --sdnotify=conmon
--publish --publish --publish --publish --log.level=INFO
```

Podman's own flags, then **`--log.level=INFO` and nothing else**. `--log.level=INFO`
is the last `Exec=` line in the `.container`. Every earlier line — the providers,
the accesslog, and all nine `--entrypoints.*` — is gone.

**This is a quadlet `Exec=` semantic, not a guarden bug and not a traefik one.**
The `.container` file guarden writes is complete and correct; the generator
consumes `Exec=` as a single last-wins argument rather than as an accumulating
list.

**The blast radius is every service in the system**, not the edge. Any rendered
container that passes more than one argument to an image has the same shape, and
every one of them is running on fewer arguments than guarden asked for. Nothing
in guarden asserts it, because nothing in guarden can see it: the flags are
dropped between the `.container` and the `ExecStart`, and both files are
correct.

That is why three suites could check ports, files, ownership and mounts and all
of them pass while the edge serves nothing.

**Two candidate fixes, and one thing to establish first:**

- Does quadlet document `Exec=` as last-wins, or is `Entrypoint=` / `Cmd=` the
  key that appends? The traefik image carries its own `/entrypoint.sh`, which
  lands on `Path` in the generated unit, so the arguments have to be appended
  after it rather than replacing it.
- Whatever the key, an assertion belongs on the GENERATED unit: that the number
  of `--` arguments guarden wrote is the number the generator emitted. That
  catches this class for every service at once, and it is checkable without a
  container running.

## ANSWERED: quadlet does not support multiple `Exec=` entries at all

podman-container-tools/podman#24901, "Quadlet: Handle multiple Exec= entries",
is an **open feature request**, not a bug report. Its description:

> Allowing multiple Exec= entries, like with Label=, would provide better
> readability and maintainability. A prime example is the example docker-compose.yml
> of traefik with four long entries.

So last-wins is not a documented semantic that guarden misread. It is an
**unimplemented key**, and guarden's eleven `Exec=` lines have been silently
collapsing to one for as long as this module has existed.

**The fix is therefore not a spelling change and not a workaround: it is to stop
using a key that cannot carry what guarden needs to say.**

The quadlet key that does accumulate is `Exec=`'s sibling — `Command=` for a
plain `.container`, or `Entrypoint=`/`Cmd=` when the image brings its own
entrypoint. The traefik image carries `/entrypoint.sh` (it is `Path` in the
generated unit), so an argument list meant to follow it has to be `Cmd=` or
`Entrypoint=`, not `Exec=`.

**What is settled, and it is worth separating from what is not:**

- Settled: `Exec=` cannot carry eleven arguments, quadlet keeps one, and the
  other ten vanish. Confirmed by measurement and by upstream's own tracker.
- Settled: this is not edge-specific. Every service that passes more than one
  argument to an image is affected the same way, and none of them can see it
  from guarden because both files are individually correct.
- Not settled: which accumulating key is right per image, and whether guarden's
  renderer should emit one line or many. That is a decision about the renderer,
  and it needs to be made for every service rather than for traefik.

The assertion proposed in the previous commit is the part that survives
regardless of which key is chosen: **count the `--` arguments guarden emitted
and count them again in the generated `ExecStart`; they must match.** That is
checkable with no container running, and it is the only thing that would have
caught this.

## After 8392a18: the flags reach the process, and it still binds only :80

The chain is now verified end to end, in this order:

```
$ podman top traefik-production-traefik
traefik traefik --providers.file.directory=/etc/guarden/edge
  --providers.file.watch=true --entrypoints.web.address=:80
  --entrypoints.web.http.redirections.entrypoint.to=websecure
  --entrypoints.websecure.address=:443 --entrypoints.websecure.http3
  --entrypoints.api.address=:8080 --entrypoints.api.http.api=true ... --log.level=INFO
```

**All eleven arguments are in the process.** And yet:

```
$ podman exec traefik-production-traefik ... /proc/net/tcp{,6}  (LISTEN, 0A)
00000000000000000000000000000000:0050
```

One socket. Port 80 only. `:443` and `:8080` are absent even though both are
declared, and the log is empty. **So `--entrypoints.websecure.address=:443` is
being accepted and then not bound**, which is a different question from whether
the flag arrived -- and it is the one that matters now.

I could not settle it by running traefik standalone, and the reason is
environmental rather than diagnostic: the root store has no traefik image and
cannot reach a registry.

```
$ podman run --rm docker.io/library/traefik:v3.2 ...
Error: unable to copy from source docker://traefik:v3.2: ... lookup
registry-1.docker.io on 127.0.0.53:53: write: operation not permitted
```

Two earlier "container exited immediately" results were this, not a config error,
and I should have read them as such instead of treating them as findings.

**Where the two fixes stand.** 408f898 (spelling) and 8392a18 (one Exec= line)
are both correct and both verified in the argv. Neither is sufficient on its own.
The question they have narrowed to is: does traefik v3.2 bind `:443` and `:8080`
when they are declared on the command line, and if not, what does it require --
a `ListenAddress`, an `EntryPoint` block in the file provider, or something else
that a CLI flag alone does not do.

## SOLVED: quadlet does not split a single `Exec=` line either

Comparing the suite's container with a hand-written one, in the same VM, same
store, same flags:

```
$ podman inspect traefik-production-traefik --format '{{json .Args}}'
["--providers.file.directory=/etc/guarden/edge --providers.file.watch=true
 --entrypoints.web.address=:80 ... --log.level=INFO"]

$ podman inspect dbg --format '{{json .Args}}'
["--entrypoints.web.address=:80","--entrypoints.websecure.address=:443",
 "--entrypoints.api.address=:8080",
 "--entrypoints.web.http.redirections.entrypoint.to=websecure","--log.level=DEBUG"]
```

**Five separate argv tokens in one, and ONE token in the other.** The suite's is a
single string with spaces in it. Traefik therefore receives one argument it does
not recognise, discards the lot, and runs on its defaults -- which is why it binds
only :80, and why the log is empty.

And the hand-written run answers the earlier question:

```
$ podman exec dbg ... /proc/net/tcp{,6}   (LISTEN)
00000000000000000000000000000000:1F90   # 8080
00000000000000000000000000000000:0050   # 80
00000000000000000000000000000000:01BB   # 443
```

**Three sockets, all three entrypoints bound.** So v3.2 does bind `:443` and
`:8080` from command-line flags. That question is closed; the flags were always
right.

**So the mechanism is neither of the two I assumed.** Not "last Exec= wins" (that
is real, and it is what collapsed eleven lines to one) and not "quadlet
unescapes \x20" (it does not). It is that **guarden has no way to express more
than one argument at all**, because the only key that would accumulate is the one
podman has never implemented (#24901), and the key that does work passes the line
through unparsed.

The quadlet key that carries a real argv list is `Command=`, which exists in
this podman binary. With `Command=--entrypoints.web.address=:80
--entrypoints.websecure.address=:443` the values are still one string unless
quadlet splits on whitespace, and **that is the one measurement left**: whether
`Command=` splits, and if not, what form does. Four candidates, in order of
likelihood: `Command=` with a shell-like quoted list, `Exec=` per argument with
podman's `EnvironmentFile=`-style escaping, the file provider's `entryPoints:`
block in dynamic config (which is camelCase and is what traefik's own docs use),
or a wrapper `PodmanArgs=`.

**The file provider is the one I would reach for**, because the rendered dynamic
config already exists, already carries `entryPoints:` in the correct case, and is
already the file traefik is told to read. Moving the entrypoint declarations from
the command line into `/etc/guarden/edge/` would delete this class of problem
rather than work around it.

The assertion is unchanged and still the thing that would have caught all three:
count the `--` arguments guarden emitted, count them again in the generated
`ExecStart`, and require they match.

## The file-provider route fails identically, so my preference was wrong

I said the file provider was the fix I would reach for. Tested it. Same result:

```
$ podman run -d -v /tmp/edgedyn:/etc/guarden/edge:ro traefik:v3.2 \
    --providers.file.directory=/etc/guarden/edge --log.level=INFO
```

with `/etc/guarden/edge/ep.yml` declaring three entrypoints, redirections and all:

```
entryPoints:
  web:       {address: ":80", http: {redirections: {entryPoint: {to: websecure, scheme: https}}}}
  websecure: {address: ":443"}
  api:       {address: ":8080", http: {api: {insecure: true, dashboard: true}}}
```

**One socket, `:0050` = 80. `code=404` for an unrouted host.** The file is mounted
and readable inside the container (`-rw-r--r-- 1 nobody nobody 266 ep.yml`) and
the log is empty.

**So the pattern is not about the mechanism at all.** Both routes -- command-line
flags and the file provider -- bind only the FIRST declared entrypoint, in both
the working hand-written run and this one. The difference between them is not the
way the entrypoints are declared. I have been treating a mechanism question as
though it were the whole question, and the mechanism is not where the fault is.

**What that points at, and what would confirm it.** In every failing run the
surviving entrypoint is `web` on `:80`, and `80` is also the *only* one of the
three that guarden publishes to pasta:

```
--publish 127.0.0.1:20001:80 --publish 127.0.0.1:20002:443 --publish ...
```

`:80` is both traefik's default `web` address and the first thing published. In the
one run that bound all three, the container was started by me with `-p
127.0.0.1:20005:80` only -- a single publish. **So "binds only :80" may be
"binds only what was published", and pasta may be involved after all**, which
would move this away from quadlet entirely and back toward the publication path.

**The measurement that settles it** is the one I should have run first: bind all
three ports in the container and query all three from inside it, without any
pasta mapping at all. If all three answer inside and only one answers from the
host, the fault is in publication. If only one answers inside, it is in traefik's
own parsing and quadlet is exonerated.

## SETTLED: traefik binds only the first declared entrypoint. Pasta exonerated.

The measurement I said should have come first, run at last. The suite's own
container, all three ports queried from INSIDE, so pasta is not in the path at all:

```
port 80    inside: HTTP/1.1 404 Not Found
port 443   inside: can't connect to remote host (127.0.0.1): Connection refused
port 8080  inside: can't connect to remote host (127.0.0.1): Connection refused
```

**`:443` and `:8080` are not bound.** So the fault is not the publication path and
not pasta. Traefik accepted the declarations and did not open the sockets.

Reproduced with quadlet entirely out of the picture -- a bare `podman run`, a
two-entrypoint file, no guarden, no pasta:

```
$ podman run -d -v /tmp/edgedyn:/etc/guarden/edge:ro traefik:v3.2 \
    --providers.file.directory=/etc/guarden/edge
  80    HTTP/1.1 404 Not Found
  443   can't connect to remote host (127.0.0.1): Connection refused
```

Same shape. **One entrypoint binds, the rest do not.** This is traefik's behaviour,
and guarden is a bystander to it.

**What makes it traefik's and not a config error is the contrast with the run that
worked.** The same image, same flags, same store, started with three declared
entrypoints on the command line, bound all three (`1F90`, `0050`, `01BB`). So the
declarations are well-formed and traefik understands them; **something about this
particular invocation collapses them to one.** The difference between the working
run and every failing one is worth listing precisely, because it is now the whole
question:

| | working | failing |
|---|---|---|
| flags | three `--entrypoints.*` on one command line | same |
| publish | `-p 127.0.0.1:20005:80` (one) | `--publish 127.0.0.1:20001:80 --publish …20002:443 --publish …` (three) |
| provider | none passed in one run; directory in another | directory |

**The publish list is the only structural difference, and the failing case is the
one with three of them.** That is pasta again, not from inside the container but
from the way the container is launched -- `--publish` three times is what
`render.py` emits, and it is the one input I have not varied. Querying from inside
removed pasta from the *data path*; it did not remove it from the *launch
configuration*.

So: not exonerated after all, and the isolation I just did is narrower than it
looks. What is now certain is that `:443` and `:8080` are unbound in the container
that guarden launches, and that a hand-launched traefik with the same
declarations binds all three. The variable that differs is the publish list.

## ROOT CAUSE FOUND: publishing one host port as both TCP and UDP kills the container

The `--publish` measurement, run. Replicating guarden's exact list on a throwaway
container:

```
$ podman run --publish 127.0.0.1:20002:443 \
               --publish 127.0.0.1:20002:443/udp traefik:v3.2 ...
Error: pasta failed with exit code 1:
Listen failed for HOST TCP port 127.0.0.1/20002: Address already in use
Couldn't listen on requested TCP ports
```

**The container does not start at all.** One host port published twice -- once TCP,
once UDP -- is a request pasta cannot satisfy, because its host-side listener is a
single TCP socket. So the edge container never ran, and everything observed after
that (one socket, empty log, 404) was a container that had failed rather than a
traefik that mis-bound.

Where the pair comes from: `519903c` added HTTP/3, and the ingress list renders

```
--publish 127.0.0.1:20001:80
--publish 127.0.0.1:20002:443
--publish 127.0.0.1:20002:443/udp      <-- HTTP/3, same host port as the line above
--publish 127.0.0.1:20000:8080
```

**The spec calls 80, 443 and 443/udp "three forwarding rules, not two" and treats
them as independent.** They are independent as *kernel* rules and not independent as
*pasta* publishes, because a publication names a host-side socket and the host side
has one socket per port. That is the same shape as the masquerade error this
repository has already refuted once: three rules on paper, one socket in practice.

**So the earlier reading was wrong in an important way.** I had concluded that
traefik binds only the first declared entrypoint, and reproduced it "with quadlet
out of the picture". That reproduction carried the same publish pair, so it
reproduced the failure rather than the fault. The single-publish run binding all
three ports is the control that matters, and it is what points here.

**Two candidate fixes:**

- **Publish the UDP one with a distinct host port.** `443/udp` needs its own
  publication, and the ingress table already carries the numbers, so this is a
  rendering decision about which host port each kernel rule maps to.
- **Publish both from one line**: podman accepts
  `--publish 127.0.0.1:20002:443` plus a protocol-suffixed *container* port on
  the same host port only if pasta can share the listener, which this error says
  it cannot.

The first is the one the design already implies, and it needs the ingress list to
name a host port per rule rather than sharing one. **The spec says the rules are
disjoint; the renderer currently gives them the same host port.**

Whichever is chosen, the assertion belongs where it is cheap: `soil firewall
--apply` and the renderer should refuse a publication list that names one host
port twice, because the failure is silent -- pasta's message goes to stderr of a
container that then does not exist, and the symptom is a 404 from a service that
was never started.

## The exact line, and the comment that asserts the opposite

`render.py:707`, in `_publications` / the edge publication walk:

```python
for endpoint, port, protocol in modules_mod.read(module).ingress_for(service):
    publication = record.publication.get(endpoint)
    if publication is None:
        continue
    suffix = "/udp" if protocol == "udp" else ""
    out.append(f"{LOOPBACK}:{publication}:{port}{suffix}")
```

**`record.publication` is keyed by ENDPOINT, not by (endpoint, protocol).** So
`web:80` and `websecure:443` -- both of which are the `websecure` endpoint as far
as the registry is concerned -- resolve to the same publication, and the list
comes out:

```
127.0.0.1:20001:80
127.0.0.1:20002:443
127.0.0.1:20002:443/udp     <-- same publication, different protocol
127.0.0.1:20000:8080
```

And the docstring at :686 states the belief that produced it:

> `/udp` rides on the line because a forwarded udp port is a different protocol
> from the same number over tcp.

**That is true of the kernel and false of pasta.** A `PublishPort` names a
host-side socket; pasta's host listener for a port is one TCP socket, so the same
host port twice is unsatisfiable and the container does not start. The comment is
the reasoning that made this look correct, which is why it survived a review and
then a firewall suite.

**Two fixes, and the second is the one that matters.**

1. **The registry allocates per (endpoint, protocol)**, so `443/udp` gets its own
   publication number. The ingress table already carries per-rule numbers, so the
   numbers exist; they are simply keyed the wrong way.
2. **The renderer refuses a publication list naming one host port twice.** That
   is the check that would have caught this regardless of which key is chosen, it
   is cheap, and it is the same shape as the refusal guarden already makes for
   duplicate grants.

Fix 1 without fix 2 leaves the trap: the next contributor who adds a protocol
suffix re-creates it. Fix 2 without fix 1 leaves the edge unable to serve HTTP/3.
Both, and the refusal is the durable half.

## Correction: fix 1 was wrong. The design is deliberate, and the renderer is the defect.

I proposed "the registry allocates per (endpoint, protocol)". Reading the
allocator says otherwise. `publications.allocate` allocates **one number per
name**, and `service._wanted` builds that name list by discarding the protocol:

```python
# service.py:253
for endpoint, _, _ in module.ingress_for(entry.name):
    if endpoint not in out:
        out.append(endpoint)
```

The `_` is the protocol. So `web:80` and `websecure:443/udp` are the name
`websecure`, one publication, by construction -- and the docstring at :237 says so:
"The containers that get a publication, in a fixed order."

**One publication per endpoint is the design, not an oversight.** Changing the key
to (endpoint, protocol) would also change what the firewall emits, because six
consumers read `record.publication` by endpoint name:

```
edges.py:155      provider.publication.get(container)
firewall.py:114   record.publication.get(container)
firewall.py:565   record.publication.get("api")
render.py:706     record.publication.get(endpoint)
render.py:712     record.publication.get(API)
report.py:122     record.publication.get("api")
```

`firewall.py:114` is the DNAT rule, so the DNAT set would grow a second rule per
udp protocol. That is a spec change -- the spec says 80, 443 and 443/udp are
three forwarding rules and I read that as three *kernel* rules -- not a bug fix.
Proposing it as the obvious fix was wrong.

**What is left is therefore narrow and entirely in the renderer:** one
`PublishPort` per publication, which means the udp ingress entry cannot be
published on the same host port as its tcp sibling. Either pasta is asked for a
form that expresses both protocols on one host port, or the renderer refuses the
combination with a diagnostic naming it.

**And the refusal is the part that is not optional.** `soil` cannot silently emit
a list that makes a container fail to start. The check belongs next to the
`PublishPort` write at render.py:916 -- parse the lines it is about to write,
refuse a host port that appears twice, and say which endpoint and protocol
collided. That check is correct regardless of which of the two fixes above wins,
and it is the only thing here that would have caught this before a VM run.

## ANSWERED: pasta DOES accept one host port on both protocols. The fix is one line.

The refusal in `86b6cef` is correct, and it is also stricter than it needs to be.

`pasta --help` in the VM:

```
-t, --tcp-ports SPEC    TCP port forwarding to namespace
-u, --udp-ports SPEC    UDP port forwarding to namespace
```

Two options, one SPEC each, and nothing says the host side must differ. Tested
through podman, which is how it is actually invoked:

```
$ podman run --rm -p 127.0.0.1:20101:80 -p 127.0.0.1:20101:80/udp \
      traefik:v3.2 --entrypoints.web.address=:80
```

**No error, and it stayed running** until the test timed out -- where the
two-publish-same-port case failed instantly with `Address already in use`. Same
host port, same container, one protocol each. It works.

**So the defect is the ORDER of the two `--publish` lines, not the fact that both
exist.** Podman derives pasta's arguments from the publish list; `-p host:80` and
`-p host:80/udp` are two *different* specs, and the failure earlier was guarden
emitting them in a shape that made podman collapse them into one TCP listener --
visible as the `Address already in use` on the TCP port, which is what a duplicate
TCP bind looks like, not what a tcp/udp pair looks like.

**Which means the renderer bug is upstream of `check_publish_ports`**: the two
lines are individually well-formed, and the refusal is treating a valid
configuration as invalid. `86b6cef` is a safe failure -- a rejected render beats a
container that silently does not exist -- but it is a refusal of something that
works, and it must not be the end state.

Two things follow, and the second is a correction:

1. `check_publish_ports` must distinguish a tcp/udp pair on one host port, which
   is **valid**, from a genuine duplicate, which is not. Keying on (host, protocol)
   instead of host alone is the whole change.
2. My reading of the earlier `Address already in use` was that one host port twice
   is unsatisfiable. That is wrong in general. It is satisfiable, and the refusal
   as written would reject a working configuration.

**What is still genuinely open** is why the suite's container fails when it has the
same two lines. The standalone reproduction with the same pair works; the generated
one does not. The difference is the presence of a *third* entry
(`127.0.0.1:20000:8080`) and of `443/udp` mapping to `20002/udp` rather than to
`20002`. Those are the two shapes I have not tried, and one of them is the answer.

## FINAL, and it invalidates 8392a18: `Exec=` cannot express more than one argument

The container is **Up** and still 404s. Not a publish problem, not a spelling
problem. Its argv:

```
$ podman inspect traefik-production-traefik --format '{{json .Args}}'
["--providers.file.directory=/etc/guarden/edge --providers.file.watch=true
 --entrypoints.web.address=:80 --entrypoints.web.http.redirections.entrypoint.to=websecure
 --entrypoints.websecure.address=:443 --entrypoints.websecure.http3
 --entrypoints.api.address=:8080 ..."]

ONE token. A hand-written run's argv for comparison:
["--entrypoints.web.address=:80","--entrypoints.websecure.address=:443", ...]
Five tokens.
```

**`8392a18` did not fix this. It changed the failure.** Collapsing eleven `Exec=`
lines into one line turned "one flag survives" into "one giant flag survives" --
still exactly one argv token, still discarded whole by traefik. I reported that
commit as verified because the argv *text* looked right in the generated unit; it
was one token there too, and I did not count.

**The requirement is multiple argv tokens, and `Exec=` cannot produce it.** The key
is unparsed and single-valued; the accumulating key does not exist in podman
(#24901). So there is no `Exec=` spelling that works, which is also why the file
provider route is the right one: it moves the configuration out of argv entirely,
into `/etc/guarden/edge/`, which is already read, already rendered, and already
carries `entryPoints:` in the camelCase traefik's file format wants.

**What is needed**, concretely:

1. **`modules/gate-traefik/traefik-production`**: delete all nine `--entrypoints.*` and the
   two `--providers.file.*` lines from the `.container`. Keep `Image=` and
   `PublishPort=`. `--providers.file.directory` and `--providers.file.watch` also
   have to move, since they are arguments too.
2. **A rendered `entrypoints.yml`** in `/etc/guarden/edge/`, written by `roots`
   from the same declarations guarden already parses out of the unit source -- the
   `edgeconf` parse exists and works, which is how the (spelling-correct)
   entrypoint names are read today.
3. **A refusal** that catches the general shape: if a `.container` has more than
   one `Exec=`, or one `Exec=` containing a space, refuse it by name. That is the
   check that would have made this whole chain loud at render time instead of
   silent at runtime.

Item 3 is what stops the fifth recurrence of exactly this bug, and it is
independent of items 1 and 2.

## The `check_exec` refusal is correct and cannot land alone: reverted

`35f05a0` added the refusal, mutation-tested both branches, and was green on
`t50-module`. **It broke three suites that were green**, and I did not run them
before committing:

```
t220-tendril    was green at c949878 -> exit 2, refused
t220-share      was green            -> FAIL
t220-ssh-guard  was green            -> FAIL
```

```
error: …/tendril-production.container has one `Exec=` holding 4 arguments, and
quadlet passes the line through unparsed: the process receives ONE argv token…
```

The check is right about both modules — that is why they are refused. **But a
correct refusal that lands before the thing it refuses is fixed trades one red
suite for four**, and `t50-slice` stays red either way. Reverted as `fdc32d5` and
re-verified: `t220-tendril` green.

**This is the ordering that was wrong, and it is the second time this ticket has
had it.** The refusal and the fix are one change, in this order:

1. Move the gate-traefik module's configuration into `/etc/guarden/edge/` — all nine
   `--entrypoints.*`, both `--providers.file.*`, out of argv and into a rendered
   file the provider already reads.
2. Move cloudflared's four arguments the same way (`cloudflared` takes its config in
   argv and has no file provider to fall back on, so this one needs a different
   shape — an entrypoint script, or `PodmanArgs=`).
3. **Then** land the refusal, which is what stops the sixth occurrence.

Landing it first is what made it look landable: it went green on the one suite
that exercises the edge and nobody checked the suites that exercise the tunnel.

**What the check is worth, recorded so it is not lost:** it turns a silent
runtime failure — container up, default port bound, empty log, 404 from a service
that was configured for something else — into an exit-2 render refusal naming the
file, the shape and the remedy. That is the difference this whole ticket needed
from the first commit, and it should land with the fixes rather than instead of
them.

## CORRECTED AND SETTLED: the generator DOES split one `Exec=` line. My conclusion was wrong.

Ran the quadlet user generator by hand, exactly as systemd runs it, with output
directories named (it demands three):

```
$ QUADLET_UNIT_DIRS=/tmp/gq5/units podman-user-generator out/normal out/early out/late
ExecStart=/usr/bin/podman run --name systemd-%N --replace --rm ... -d \
    docker.io/library/traefik:v3.2 \
    --entrypoints.web.address=:80 --entrypoints.websecure.address=:443 \
    --entrypoints.api.address=:8080 --log.level=INFO
```

**Four separate flags, split on whitespace.** A single `Exec=` line carrying
space-separated flags is exactly the right form, and always was.

Verified end to end with a container that reports what it was handed:

```
Cmd: ["sh","-c","echo z; for a in one two three; do echo T=$a; done"]
logs: z / T=one / T=two / T=three
```

Three argv tokens, script intact.

**And here is what misled me.** A `QUOTED` value is one token, because the quotes
are systemd's:

```
Exec="--entrypoints.web.address=:80 --entrypoints.websecure.address=:443"
  ->  traefik:v3.2 "--entrypoints.web.address=:80\x20--entrypoints.websecure.address=:443"
```

The `\x20` is systemd escaping **inside a quoted segment** -- it is the marker of
"this is one token", not the marker of "quadlet cannot split". I read it as the
latter, and reported the opposite of the truth in `8392a18` and `9c7dd11`.

**So the whole chain of conclusions was wrong from `8392a18` onward:**

| claimed | actually |
|---|---|
| one line = one argv token | one line = N tokens split on whitespace |
| `\x20` proves quadlet jams it together | `\x20` proves the segment was QUOTED |
| no `Exec=` form can carry several arguments | the ordinary unquoted form does |
| config must move to a file provider | it must not; that plan is unnecessary |

**The real defect is a pair of quotes.** The generated unit for the edge carries
`"--providers.file.directory=... --entrypoints... --log.level=INFO"` as ONE quoted
argument, so traefik receives a single unrecognised flag and discards it. Removing
the quotes -- one `Exec=` line, plain space-separated, unquoted -- fixes it.

Where the quotes come from is the thing to find, because `edgeconf._arguments`
does `str(value).split()`, which suggests the value was already one string by the
time it was read. `unitsource` may be re-quoting a value that contains spaces when
it round-trips the unit. That is the actual bug and it is small.

## THE ROOT CAUSE: the edge container cannot read its own dynamic config

The log, read as root from the journal, says it outright -- and it has been saying
it since the beginning of this ticket:

```
ERR Cannot start the provider *file.Provider error="unable to read directory
/etc/guarden/edge: open /etc/guarden/edge: permission denied"
```

Traefik **starts**, binds its default `:80`, fails to read the directory its
routes come from, and therefore serves nothing. That is the 404. Not the exit
point spelling, not the `Exec=` quoting, not the publish list -- those were real
defects on the way and none of them was this one.

**Measured, all in one VM:**

| check | result |
|---|---|
| `ls -ld /var/lib/guarden/edge/dynamic` | `drwxr-s--- guarden edge` (2750) |
| `id traefik-production` | `uid=994 gid=982 groups=982,981(edge)` |
| host user reads the file | **yes** (`cat` succeeds) |
| container with `--group-add 981` | **permission denied** |
| container with `--group-add keep-groups` | **provider loads** |

**Why the plain gid does not work, and `keep-groups` does.** `/etc/subgid` is
`traefik-production:231072:65536`, so container gids map into `231072-296607` and
the host gid `981` is outside every mapping the user has. `--group-add 981` adds
*container* gid 981, which resolves to host gid `232053` and matches nothing on
disk. There is no gid number the container can be given that reaches the host's
`edge` group; the only mechanism that carries it is `keep-groups`, which passes
the user's own supplementary groups through.

**So the earlier reading -- "route permissions and group membership were correct"
-- was wrong.** The group membership is correct *for the host user* and
unreachable *for the container*, and the two are not the same claim.

**Two candidate fixes, and this is a security-model decision:**

1. **`GroupAdd=keep-groups` on the edge's own unit only.** Narrower than the
   blanket form that was rejected: the edge's user is in exactly `traefik-production`
   and `edge`, so what passes through is the one group the design already gave it.
   It is still a change to the security model and AGENTS.md wants an ADR.
2. **Change the ownership of `/var/lib/guarden/edge/dynamic`** so the mapped uid
   can read it -- e.g. group `traefik-production`, or a mode that admits uid 994.
   No `keep-groups`, but it widens what that directory admits and it must keep
   `guarden:edge` readable for `roots`.

Option 1 is the smaller change and the one that matches the design's intent --
the edge user is *supposed* to be in the edge group; the container simply loses
that fact in the uid mapping. It should not land without the ADR AGENTS.md asks
for, and that is a decision for the operator rather than a commit.

## RESOLVED: `GroupAdd=keep-groups` on the edge's unit, and the ADR is written

Operator decision: option 1. Implemented as a single line in the edge's own unit
source, `modules/gate-traefik/traefik-production/.guarden/quadlet/traefik.container`:

```
GroupAdd=keep-groups
```

**The key is verified, not assumed.** `man podman-systemd.unit`, read in this
VM's podman 5.7:

```
GroupAdd=
    Assign additional groups to the primary user running within the container
    process. Also supports the keep-groups special flag. Equivalent to the
    Podman --group-add option.
```

and the option table carries the row `GroupAdd=keep-groups` -> `--group-add=keep-groups`.

**It passes the renderer untouched.** `GroupAdd` is in neither `OWNED_KEYS` (which
loom removes before emitting) nor `REFUSED_DIRECTIVES` (which the unit source may
not use), so it survives the merge as written by the module.

**What was written:**

- the line above, with the measurement and the reason in a comment beside it;
- `docs/adr/0017-edge-container-keeps-service-groups.md`, which records the
  measurement, the decision, why a group number cannot work, why re-grouping the
  directory and widening the mode are both refused, and what the line costs — the
  container carries every supplementary group the service user has, which is the
  whole reason it is on one unit;
- a binding-decision bullet in `AGENTS.md` pointing at ADR-0017, because the
  rule "a host user's group membership is not a container's" is the part that
  outlives this ticket. AGENTS.md and the spec carried no prior position on
  `keep-groups`, so nothing was amended — the bullet is new.

**Still owed: the suites.** The change is in a worktree and has not been tested.
The suites that must run against it are the ones that exercise the edge
(`t50-slice`) and the ones that exercise a container at all (`t220-*`,
`t50-module`, `t150-ssh-accept`), because the line changes a container's
credentials and a green edge suite alone would not show a tunnel regression —
which is the mistake `35f05a0` already made once.

## A second defect, exposed by the first fix: the API entrypoint flags are not traefik fields

With the quoting fixed (`c0649cf`), the flags finally reach traefik -- and traefik
**refuses to start**:

```
command traefik error: failed to decode configuration from flags:
field not found, node: api
```

The gate-traefik module declared the API as

```
--entrypoints.api.address=:8080
--entrypoints.api.http.api=true
--entrypoints.api.http.api.dashboard=true
--entrypoints.api.http.api.insecure=true
```

and **`entrypoints.<name>.http.api` is not a field in traefik v3.** Traefik's own
`--help`:

```
--api            (Default: "false")   Enable api/dashboard.
--api.dashboard  (Default: "true")
--api.insecure   (Default: "false")   Activate API directly on the entryPoint named traefik.
```

So the API is **top-level**, and the flag that decides where it is served names the
entrypoint itself: `traefik`. Measured, in one VM:

| flags | result |
|---|---|
| `--entrypoints.api.address=:8080` alone | binds :8080, entrypoint `api` |
| `+ --entrypoints.api.http.api=true` | **decode error, refuses to start** |
| `--entrypoints.traefik.address=:8080 --api=true --api.dashboard=true --api.insecure=true` | starts, `/api/version` -> `{"Version":"3.2.5"}`, `/api/rawdata` 200, `/dashboard/` 200 |

and `--api.insecure` alongside an `api`-named entrypoint on the same port is a
**bind conflict**, because traefik creates the entrypoint it serves the API on.

**This is why the quoting bug hid the flag bug.** While every flag arrived as one
unparsed token, traefik discarded all of them and ran on defaults; nothing ever
validated them. Fixing the quoting made traefik *read* the flags, and the invalid
ones killed the container. Two defects, in series, one masking the other.

`edgeconf` had the same belief baked in: `api_port` found the API entrypoint by the
invalid `http.api` key. It now reads `--api.insecure` and marks the entrypoint
named `traefik`, which is traefik's choice of name and not guarden's, and it
**refuses** `http.api*` by name with the correct flags in the diagnostic.

## And the suite that asserts it

`tests/t50-module.sh` asserted `--entrypoints.api.http.api.insecure=true` -- it was
asserting the invalid flag, so it passed while the edge could not start. It now
asserts `--entrypoints.traefik.address=:8080` and `--api.insecure=true`.

**`t50-slice` is green.** Two further suite defects were fixed on the way, both of
which could never have passed:

- `runuser -u traefik-production -- podman inspect` was refused by the harness's own
  `0700` tree ("cannot chdir to /home/ubuntu/guarden"), which is the documented
  reason `lib.sh` carries `run_in`. Both sites now use a `run_edge` helper that
  scrubs the cwd, `PWD` and `OLDPWD` the way `run_svc` does.
- `assert_stdout_has "ro"` asked for a string `podman inspect` does not emit: the
  read-only flag is the boolean `RW`, printed `false`. Both sites now assert one
  exact string, `"/var/lib/guarden/edge/dynamic /etc/guarden/edge rw=false"`, from a
  targeted `--format` rather than the struct's Go default.

## A fourth reading, after everything above: the container's view of the directory is EMPTY

Recorded because it is not any of the readings above, and because the ticket is
the place this area's measurements live. Measured in the VM after `t50-slice`
runs, with the container up:

```
host       /var/lib/guarden/edge/dynamic/routed-staging.yml
           -rw-r----- 1 guarden edge 337  (guarden:edge 0640)
           contents: routers.routed-staging-web.rule = Host(`staging.web`)

container  podman exec traefik-production-traefik ls -la /etc/guarden/edge/
           total 0                       <-- EMPTY

mount      [{Type:bind, Source:/var/lib/guarden/edge/dynamic,
             Destination:/etc/guarden/edge, RW:false, Propagation:rprivate}]

API        /api/http/routers -> api@internal, dashboard@internal,
           web-to-websecure@internal   (not routed-staging-web)

request    curl -k https://staging.web/  ->  HTTP 404
```

**The ordering rules out the watcher explanation.** `t50-slice` runs `roots sync`
at line 87 and starts the edge at line 103, so the file is on disk *before* the
container is created. A file watcher has nothing to catch, and `--providers.file.watch=true`
is not what is failing. An earlier draft of the comment in `t50-slice.sh` claimed
the opposite and has been corrected.

**What is established:** the host sees the file; the container does not see it;
the mount is present and read-only; the edge answers 404 on the TLS entrypoint
because no router is loaded.

**What is NOT established:** the cause.

**Refuted by reading, before it cost a VM run:** that `_edge_directory`
re-creates the directory and the container holds a stale inode. `_edge_directory`
(`weedr.py:893`) is `path.mkdir(parents=True, exist_ok=True)`, `conf.set_owner`
and `os.chmod` — and `conf.set_owner` is `os.chown`, never an unlink or an
`rmtree`. Nothing in guarden removes that directory, so its inode is stable
across the whole run and the mount source cannot have been replaced. The
hypothesis is recorded here because it is the first one anyone reaches for.

**Still open, and the reading above narrows it rather than closing it.** The
directory's inode is stable; what is not known is whether the container is
looking at that inode at all. The candidates left:

- the rootless mount path — the source is `guarden:edge 2750`, so traversal needs
  the `edge` group, and the mount is set up by podman as the service user *before*
  the container's own group set exists. `keep-groups` carries groups into the
  **process**; whether it carries them into the **mount setup** is a different
  question and is not the same claim.
- whether the suite's `run_edge podman exec` and the unit's `Volume=` resolve the
  same source path.

**The measurement that settles the first**, and it is cheap: in the VM with the
container up, `stat -c '%i %n' /var/lib/guarden/edge/dynamic` on the host, then
`podman exec … stat -c '%i %n' /etc/guarden/edge` inside. Different inode numbers
mean the container is mounted somewhere else; the same number means it is looking
at the right directory and the emptiness is a permission effect on the readdir.

## THE ROOT CAUSE, fully measured: the user manager starts before the edge group exists

The host user IS in the edge group. `keep-groups` is working correctly. The
problem is **when** the user manager starts relative to when the group is added.

```
PROBE host_user_groups=[traefik-production edge]     <- user IS in edge (981)
PROBE umgr_groups=[Gid: 982 ... Groups: 982]        <- manager is NOT
PROBE after_mgr_restart: Groups: 981 982            <- restart fixes it
PROBE after restarting only the service: Groups: 0   <- service restart alone does NOT
```

**The mechanism.** `keep-groups` faithfully carries the launching process's
supplementary groups into the container. The launching process is the systemd
user manager. The user manager's groups are fixed at its own process creation
time — they are inherited from the session that started it, and they do not
update when the user's group membership changes later.

`_edge_group` (called from `weedr module add gate-traefik`) creates the `edge` group and
adds the service user to it. But the user manager may already be running from
an earlier step in the converge (e.g. `soil install` or the first
`weedr module add`). Its group set is stale.

**The fix, in order of preference:**

1. **After `_edge_group` adds the user to `edge`, restart the user manager.**
   `systemctl restart user@<uid>.service` picks up the new group set. This is
   the smallest change and the one the measurement supports.
2. **Create the edge group and add the user before the user manager starts.**
   This means restructuring `weedr module add gate-traefik` so the group setup happens
   before any command that triggers the user manager. More invasive.
3. **Have `_edge_group` itself restart the user manager** after adding the user.
   Self-contained in the one place that changes group membership.

**Why `assert_supplementary_group` didn't catch this.** It runs `id -nG <user>`,
which asks the **host user database** (`getent`), not the running process. The
user IS in the edge group per `/etc/group`. The container process is not. The
assertion checks the wrong thing.

**The probe that settles it**, for future reference:

```sh
# Does the user manager have the edge group?
grep ^Groups /proc/$(pgrep -u traefik-production -f 'systemd --user' | head -1)/status
# -> "Groups: 982" means NO, "Groups: 981 982" means YES
```
