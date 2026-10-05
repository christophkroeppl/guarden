# Ticket 250's premise is refuted: the generator is reached and the manager loads it

**Status: measured. No code change is needed, and the ticket should be closed as
answered rather than implemented.**

## What was measured, on the machine, as `routed-staging`

`/usr/lib/systemd/user-generators/podman-user-generator` **is installed and
enabled** — it is in `/usr/lib/systemd/user-generators/` alongside
`systemd-xdg-autostart-generator`.

Run the way systemd runs it, as the service user, with the three directories
systemd names:

```
$ podman-user-generator $out/normal $out/early $out/late
$ ls -la $out/normal
-rw-r--r-- 1 routed-staging routed-staging 1516 web.service
```

And the **manager's own** `daemon-reload`:

```
$ ls -la /run/user/993/systemd/generator/
-rw-r--r-- 1 routed-staging routed-staging 1516 web.service
```

Byte-identical size. The generator runs, and the manager loads what it produced.

## Both causes the ticket named are false

1. **"The output lands in a directory the manager is not reading."** There is no
   `systemd/user/` level for a user manager. It writes to
   `$XDG_RUNTIME_DIR/systemd/generator{,.early,.late}`, and that is exactly the
   directory `daemon-reload` populated. An earlier probe asserted on
   `systemd/user/generator.normal/web.service` — a path that does not exist on a user
   manager — and reported "does not name ExecStart" from a `grep` of a missing file.
   The empty-directory reading that came from it was an artefact of the assertion.

2. **"Nothing gives a service user a `/run/user/<uid>`."** It exists, mode `0700`,
   owned by the service uid. `generator.late/` holds the xdg-desktop-autostart
   generator's output, which is what a late generator is for.

## The container still does not start, for a different reason

```
ExecStart=/usr/bin/podman run --name routed-staging-web --replace --rm \
  --cgroups=split --network pasta:--map-gw --sdnotify=conmon -d \
  --publish 127.0.0.1:20003:80 docker.io/library/nginx:1.27
```

The generated unit is **correct** — pasta with the gateway mapped, the loopback
publication, the image. Running exactly that by hand:

```
Error: unable to copy from source docker://nginx:1.27: pinging container registry
registry-1.docker.io: dial tcp: lookup registry-1.docker.io on 127.0.0.53:53:
write udp 127.0.0.1:40100->127.0.0.53:53: write: operation not permitted
```

That is the unresolved question in `dns-under-the-loopback-deny.md`, verbatim: the
service uid's DNS stub send is refused. It is a firewall question, not a quadlet one,
and it is the only thing between this suite and green.

## What 240 had to fix first

Before ticket 240 the generator refused the render outright —
`requested Quadlet source myapp-staging-chainstate.volume was not found` — so there
was nothing to generate. With the `.volume` unit gone and the volume bound by its
subvolume path, the render is valid input and the generator produces a unit.
