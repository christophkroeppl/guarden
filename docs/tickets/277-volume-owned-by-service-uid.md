# 277 — a volume is owned by the service uid, but the container may run as another

Blockers: none. Found 2026-10-14 deploying RustFS.

## What happens

guarden creates a service's volumes owned by the **service user** (uid 992 for
`rustfs-production`). A container that runs as **its own non-root uid** cannot
write them, and the failure is a bare `Permission denied (os error 13)` from the
application, which names nothing.

Measured with `docker.io/rustfs/rustfs:latest`, which runs as **uid 10001**:

```
$ podman run -v .../state/data:/data rustfs/rustfs
[FATAL] Server runtime failed: Io error: Permission denied (os error 13)
```

The host directory is `drwx------ 992 992`; inside the container's user namespace
that is `65534 65534` (nobody), so uid 10001 cannot touch it.

## Why the obvious fix is wrong

`chown 10001:10001` on the host does **not** work: the service's subuid range is
`/etc/subuid:rustfs-production:296608:65536`, so container uid 10001 is host uid
`296608 + 10001 - 1 = 306608`. A host-level `chown 10001` maps to *nobody* in the
container — measured: the container then saw `/data` as `65534` and still could
not write. The ownership has to be set through the namespace:

```
podman unshare chown -R 10001:10001 <volume>     # run as the service user
```

after which the container sees `10001 10001` and writes both `/data` and `/logs`.

## What this ticket wants

A volume has an **owner uid** that is a property of the service, not of guarden's
layout, and the create path must set it through `podman unshare` (or the
equivalent) rather than assuming the service uid is the right one. Two ways to
express it, and either is fine:

- a manifest field (`owner: 10001`, default the service uid), or
- reading the image's `Config.User` at ingest and owning the volume accordingly.

Until then, every image that drops privileges in its own Dockerfile — which is
most non-trivial images — fails at first start with a message that names neither
guarden nor the volume.

## The same class, third instance

This is the third face of one problem in this deploy (272's siblings 273 and
274): a container's *runtime* assumptions about a path guarden provides
(ownership, a writable subdirectory, a mounted subdir rather than the volume
root) are not modelled, and each one surfaces as an application-level error.
`/data` and `/logs` both had to be pre-created and owned; the image expects both
to exist.
