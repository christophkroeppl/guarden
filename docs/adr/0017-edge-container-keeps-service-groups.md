# the edge's container keeps the service user's groups

Accepted 2026-10-09. Ticket 263. It amends no ownership rule — `/var/lib/guarden/edge/dynamic/`
stays `guarden:edge 2750`, as spec §7.5's table and §6.4's `roots sync` section both say — and it
does **not** open the blanket `GroupAdd=keep-groups` that was refused earlier. It records the one
unit that carries the line, and why no group number could replace it.

## What was measured

The edge starts, binds its default `:80`, and serves nothing. The journal, read as root:

```
ERR Cannot start the provider *file.Provider
error="unable to read directory /etc/guarden/edge: open /etc/guarden/edge: permission denied"
```

`/etc/guarden/edge` in the container is `/var/lib/guarden/edge/dynamic` on the host. It is
`drwxr-s--- guarden edge` — mode `2750`, so the group `edge` has `r-x` and every other class has
nothing. The service user reads it without trouble:

```
id traefik-production   ->  uid=994 gid=982 groups=982,981(edge)
cat /var/lib/guarden/edge/dynamic/routed-staging.yml   ->  succeeds
```

The container does not:

| run | result |
|---|---|
| `--group-add 981` | `permission denied` |
| `--group-add keep-groups` | provider loads |

**The number cannot work, and the reason is the subgid window.** `/etc/subgid` holds
`traefik-production:231072:65536`, so inside the container every group number from `1` to `65535`
is translated into `231072`–`296607`. Container group `981` is host group `232053`. Host group
`981` is outside every window this user has, so **no `--group-add <gid>` reaches the `edge`
group**; there is no number to name. `keep-groups` is the mechanism that stops the translation
for the supplementary groups and passes the user's own list through.

## The decision

One line, in the edge's own unit source, `modules/traefik/traefik-production/.guarden/quadlet/`:

```
GroupAdd=keep-groups
```

`GroupAdd=` is quadlet's spelling of `--group-add`, and the man page names the value explicitly:
"Also supports the `keep-groups` special flag."

## Why not the alternatives

**A group number.** Measured impossible, above. It is the fix the first reading reached for and
it is not available at all.

**Re-group the directory** to the service user's private group, so the container's own gid
matches. It works, and it is rejected on the design rather than on the mechanism: the directory
is `guarden:edge` because a group names a *reader set*, and `weedr module add traefik` created the
`edge` group for that job. Pointing the directory at one user's private group deletes the set and
keeps one member of it, and the next reader has to be added by hand.

**Widen the mode** to admit `other`. The routes are the whole public surface of the box. Every
local user would read them. Refused.

**A blanket `GroupAdd=keep-groups` on every unit.** The earlier refusal stands. A service holding
group grants through `overrides.toml`'s `[groups] add` — a transcoder reaching `/dev/dri` is the
example the spec gives — would carry every one of those groups into its container. That is a
widening nobody asked for.

## What it costs, stated plainly

**The container carries every supplementary group the service user has.** For this user that is
`edge` and the user's own primary group, which is the set the design already gave it. It is not
nothing: if the edge is ever granted a group through `overrides.toml`, that group enters the
container with no second decision. This is why the line is on one unit and why this document
exists rather than a comment.

**It is a property of the unit and not of the service.** A second service that needs to read a
directory it does not own needs its own decision; nothing here generalises automatically.

## The general lesson, which outlives this ticket

**A host user's group membership is not a container's.** `id` on the host and the process inside
the container answer different questions, and a rootless group number is not the host's number of
the same name. Any future claim of the form "the user is in the group, so it can read it" has to
say which user, on which side of the namespace.
