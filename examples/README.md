# Example service templates

`weedr service create <name> --template <template>` copies the files of one
directory out of the installed template set into the service's own quadlet
directory. The set is read from

```
$GUARDEN_TEMPLATES/services  when that is set
<prefix>/usr/lib/guarden/templates/services/      otherwise
```

which `soil install` creates from `src/guarden/templates/` — and
`src/guarden/templates/` ships no `services/` subdirectory, so **no template set
ships with guarden**. On a fresh host `weedr service create` refuses with exit 1
until one is installed:

```sh
cd /usr/local/src/guarden                # the checkout; the path below is relative to it
install -d -m 0755 /usr/lib/guarden/templates/services
cp -r examples/services/postgres /usr/lib/guarden/templates/services/
weedr service create postgres-staging --env staging --template postgres
```

The `cd` matters: `examples/services/…` resolves only from the repository
root, and on a host the installer set up that root is `/usr/local/src/guarden`.
From anywhere else the `cp` answers `cp: cannot stat 'examples/services/postgres':
No such file or directory`. If you keep the checkout somewhere else, `cd` to
it instead.

**And then check that it answers** — `weedr service start` returning
`started` is the mutator's word for it, not the service's. The runbook's
**verifying a service answers** section has the command per example, what a
healthy answer looks like, and the client tooling each one needs:
[`docs/sysadmin.md`](../docs/sysadmin.md).

`soil install` copies the checkout's `src/guarden/templates/` over the installed
tree and does not delete anything the checkout does not carry, and
`soil install --check` compares the other way — installed against the checkout —
so a `services/` set installed by hand is neither overwritten nor reported as
drift.

## What a template is

A template is a directory of quadlet files and nothing else. `create` walks it
and writes **every file in it** into `home/.config/containers/systemd/`, `0640`
owned by the service user, so a `.guarden/` or a `compose.yaml` dropped in here
would land in the unit directory rather than where the renderer looks for it.

A template is not a manifest, and it declares nothing guarden reads:

* no `state:` and no `bulk:` — no subvolume and no snapper configuration is
  created, so a `Volume=` in the template names a podman volume in the service's
  own store;
* no `ports:` — no publication is allocated and no firewall rule is written, so
  a `PublishPort=` binds loopback;
* no `schema:` — the credential gate has nothing to check, so a `Secret=` line
  names a key that has to be planted by hand before the first start.

A manifest brings all of that, and the first `weedr service add` that copies one
in creates the volumes. See `docs/sysadmin.md`, **Deploying a service by hand**.

## The set

| template | image | what it shows |
|---|---|---|
| `postgres` | `docker.io/library/postgres:17-alpine` | the third-party database deployment from the app-VM runbook: loopback publication, a `Secret=` read as an environment variable, `PGDATA` a subdirectory of the mount |
| `vaultwarden` | `docker.io/vaultwarden/server:latest` | a self-hosted web service with one data volume and no credential line |
| `rustfs` | `docker.io/rustfs/rustfs:latest` | an S3-compatible object store, and a **provider of the `secret` kind**: a consumer edges to it with `auth: secret` and reads the minted value as `<AS>_SECRET` |

Each is one `.container` file, which is all `create` needs. The file name is the
unit name in the service's own user manager, and the manager is per service uid,
so two services created from the same template do not share a unit.

**A template carries no `provides:`**, and the `rustfs` one is where that
matters: a consumer's edge to a provider is checked against the provider's
**registry** (spec 7.3), and the kinds reach the registry from the provider's
manifest — which a template does not ship. So the operator writes it, and
`weedr service add <name> --from <name>` reconciles it in:

```yaml
project: rustfs
units: .guarden/quadlet/
provides:
  - secret
ports:
  - container: rustfs
    port: 9000
```
