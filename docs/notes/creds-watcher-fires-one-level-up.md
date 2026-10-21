# The creds watcher fires one level up, not on the blobs

**Measured 2026-10-21 while closing ticket 314.** This note records what
`guarden-creds.path` watches and what it does not. It is not a decision, and the
fix it points at is not made here.

## The unit and the blobs are one directory apart

`src/guarden/templates/guarden-creds.path:10` watches
`PathChanged=/etc/guarden/creds/`. Every blob is at
`/etc/guarden/creds/<service>/<KEY>.cred` (`src/guarden/paths.py:156`
`cred_blob`). A path unit does not recurse: an entry created directly in the
watched directory is an event on it, and a file changed inside a subdirectory is
an event on that subdirectory.

Measured in a fresh LXD VM (a throwaway probe, `t9probe5.sh`, with a marker
oneshot as the watched unit so the credential path cannot confuse the reading;
deleted after the run, not committed):

```
PROBE shipped path unit: active
PROBE shipped spelling: PathChanged=/etc/guarden/creds/
PROBE A parent watch, blob in existing svc-existing/       : NO
PROBE B parent watch, new file in creds/ itself            : YES
PROBE C parent watch, mkdir a new service dir              : YES
PROBE C2 parent watch, blob in that new dir                : NO
PROBE E per-svc watch, blob in existing svc-existing/      : YES
```

B and C are what makes the probe an instrument rather than a broken one: it
fires when the event is on the watched path. A and C2 are the gap. E is the
control — a per-service `PathChanged=` does catch the blob.

A first probe (`t9probe4.sh`) used the real materialiser as the watched unit and
answered NO to every case, including the ones that must fire; that instrument was
broken (one failed trigger takes the path unit down with it) and its output is
not evidence. The `F` cases below use the real pair with the marker reading
replaced by the oneshot's own start timestamp.

## A glob is not a spelling of it

The obvious one-line fix is `PathChanged=/etc/guarden/creds/*/`. It is not a
spelling systemd accepts, and it fails silently: the unit loads `active` and
watches a literal directory named `*` that does not exist.

```
PROBE D parent+glob, blob in existing svc-existing/        : NO
PROBE    unit: loaded active
```

The guest's `systemd.path(5)`:

```
The arguments of these directives must be absolute file system paths.
Something similar does not apply to PathChanged= and PathModified=.
```

(The second sentence is the one saying `PathExists=` fires for a path that
already exists and `PathChanged=` does not — see the next section.)

## What keeps the verb path working

`weedr secret set` writes the blob and then starts the oneshot itself —
`src/guarden/credentials.py:380` `ask_materialiser`, the `systemctl start` at
`:402`, called from `src/guarden/weedr.py:1406` — so the value reaches the
service's own store whether or not the watcher is running. Measured with the
watcher stopped (probe `t9probe3.sh`, also deleted):

```
PROBE watcher enabled: enabled
PROBE watcher active:  inactive
PROBE A secret set exit: 0
PROBE A stdout: planted DB_PASSWORD of svcpa-staging in /etc/guarden/creds/svcpa-staging/DB_PASSWORD.cred
PROBE A value in store: YES
```

That is why the suite is green over the gap, and it is also why ticket 314's
stated symptom — "a first `weedr secret set` on a freshly converged box left no
podman secret at all" — is **not reproducible through that verb on this tree**:
the verb has asked the materialiser since `980c557b` (2026-10-02), two weeks
before the ticket was measured. The 18-line start item `249a792` added is still
load-bearing for the unit being *active* (below), and it is the only thing that
makes the watcher run at all; but the first-plant half of the ticket's rationale
was already covered.

## What is not covered

A blob written by anything else — a restored backup, an operator's `cp`, a
rotated file put back in place — into an EXISTING service directory fires
nothing. The watcher answers "a new entry directly under
`/etc/guarden/creds`" and nothing else. That is narrower than the unit's own
Description ("materialise a credential blob as soon as it changes under
/etc/guarden/creds") and narrower than the closing comment of
`tests/t491-creds-trigger.sh:126-133`, whose two assertions check the unit file's
text and not a trigger.

The same shape is at `tests/t60-secrets.sh:182-187` and `:226`: "What the claim
actually protects ... is the `PathChanged=` line on the path unit". The line says
the unit names the directory; it does not say a change under it triggers.

## What a fix needs, and why it is not in ticket 314

- One unit per service works (`E`) and costs a unit per service to install,
  reload and remove — the reason the template's own header
  (`src/guarden/templates/guarden-creds.path:5-9`) gives for one unit for the
  host.
- One unit with `<creds>/*/` is not a spelling systemd accepts (`D`).
- Enumerating the service directories into an install-time drop-in would miss a
  directory created after the install, and `weedr secret set` creates it.
- A marker file the verb touches directly under `/etc/guarden/creds/` makes the
  verb path fire the watcher; a blob written by something else still would not.

So this is a choice of mechanism and needs a decision. Ticket 314 is about the
watcher being STARTED, which `249a792` does and `t491` pins:

```
# the fix present (38ad235)
ok   t491-creds-trigger.sh
# with only the 18-line item reverted
error: unit guarden-creds.path is 'inactive', not active
FAIL t491-creds-trigger.sh
```

## Also measured: a box that installs over existing blobs

`soil install` starts a `PathChanged` watcher, which does not fire for a path
that already exists, and it only ENABLES the boot oneshot
(`src/guarden/hostprep.py:2643-2657`, with the deliberate "Not `--now`"). So a
box whose blobs are already present when the phase runs — a restore, a
re-install — materialises nothing until a change or the next boot.

Starting the oneshot as a converge step would close that, and it is not an
`Item`: a `Type=oneshot` without `RemainAfterExit=` is `inactive` once it
succeeds, so an `is-active` predicate could never hold and `--check` would report
permanent drift on a converged host. It is a decision of its own and is not made
here.
