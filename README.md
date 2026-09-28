# guarden

One VPS. A handful of projects. No Kubernetes, no dashboard you have to learn.

`guarden` turns a fresh Ubuntu box into a small, honest deployment host. It puts each
project into a **bed** (its own Linux user, its own containers, its own volumes), routes
traffic to it through Traefik at the **fence**, shares Postgres through optional named
ponds when a project wants one, and takes btrfs snapshots so you can undo a bad deploy.

There is no web UI. Everything is a command you can read, and every piece talks to the
next one over files.

---

## What you get

| piece | what it does |
|---|---|
| **soil** | Prepares the host: btrfs, snapper, ferm, rootless podman. |
| **weedr** | The one command that creates and removes beds, ponds, secrets, and databases. |
| **roots** | Reads `.guarden/bed.yaml` from every bed and writes Traefik config. |
| **fence** | The boundary: Traefik's own bed, `bed-fence-traefik`, on 80/443, sharing one config directory with `roots`. |
| **stakes** | Remembers which snapshots you care about — and shows who is holding each one. |
| **pond** | Named Postgres instances you dig when you want one. Named like a bed (`pond-production-postgres`), entirely optional. |
| **twig** | Renders your Homepage dashboard from one small file per service. |
| **hose** | Optional. Takes each project's CI pokes and keeps beds in sync with what is on a branch — plus a drift check when it can read the repo. |

You can run `soil` + `weedr` + `roots` + `stakes` and stop there. `pond`, `twig`, and
`hose` are extras.

---

## What you need

- One VPS you do not mind reformatting.
- Ubuntu 26.04.
- A domain whose DNS you control.
- About 30 minutes the first time.

---

## Install

Log in as root. On a cloud-init host most of this is already done for you — the install
scripts are inlined and the packages come up with the box. On any other host, run the
scripts by hand. The short version:

```sh
# 1. Install the base. This reboots once to convert the disk to btrfs.
soil users   --apply
soil firewall --apply
soil sysctl  --apply
soil btrfs   --apply
# ... reboot when it tells you to ...
soil storage --apply

# 2. Check nothing drifted.
soil --check
```

After this the host has btrfs with snapper, a firewall that locks you out gently (there is
a dead-man timer), rootless podman, and Traefik ready to bind :80 and :443.

The full command list lives in [`docs/sysadmin.md`](docs/sysadmin.md).

---

## Put a project on the box

A project repo needs three tracked files: `compose.yaml` at the root, `.guarden/bed.yaml`,
and `.guarden/widgets/…`. A `.guarden/.env.schema` describes your env keys — values never
live in the repo.

```
myapp/
├── compose.yaml              # the app, as plain Compose ...
└── .guarden/
    ├── quadlet/              # ... or your own quadlet units in here instead
    ├── bed.yaml              # routes, databases, hostnames, ports
    ├── .env.schema           # the shape of every key. never values
    └── widgets/
        └── api.yml           # one file per service. what the dashboard shows
```

`compose.yaml` and `.guarden/quadlet/` are an either/or: exactly one of them, and a
pre-commit hook stops you when neither is there.

```yaml
# compose.yaml  —  a normal Compose file. Services, volumes, networks.
services:
  api:
    image: ghcr.io/you/myapp-api
    ports: ["8080"]
  web:
    image: ghcr.io/you/myapp-web
    ports: ["3000"]
```

```yaml
# .guarden/bed.yaml  —  what guarden needs to know. Environment, routes, databases, hostnames, ports.
environment: production
routes:
  api: "api.${env}.${domain}"
  web: "${env}.${domain}"
pond:
  databases:
    app:
      roles:
        - name: app
          grants: ["ALL"]
hyphae:
  aliases: ["myapp.internal"]
ports:
  - 8080/tcp
```

```yaml
# .guarden/widgets/api.yml  —  one file per service. What the dashboard shows.
description: Myapp API
href: "https://api.${env}.${domain}"
icon: mdi-api
```

Then, on the VPS:

```sh
weedr bed plow myapp --env production --from /path/to/myapp -p pond-production-postgres
```

Every bed says its environment out loud — `--env` is required, and git manifests declare
it too. That single command creates the Linux user, writes the quadlet units, connects the
bed's hyphae to `pond-production-postgres` (`-p` / `--pond`), mints a database role and
password, writes the hostnames, and brings the services up. Traefik starts routing to
`api.yourdomain.com` on its own. Ask for a pond nobody has dug yet and `weedr` lists the
ponds it knows and offers to dig it for you.

To take it away:

```sh
weedr bed remove myapp --env production
```

Production asks first.

### Ponds are optional

Dig a pond only when you want shared state:

```sh
weedr pond dig pond-production-postgres  # none exist by default; name is pond-<env>-<name>
```

The dig gives the pond its own Linux user and quadlet dir — `pond-production-postgres`
here — exactly like a bed. Ponds are separated from each other by that user boundary,
not just by database roles.

Not everything wants a pond. A bitcoin node, say, keeps its own chainstate — it may own
its own container, its own subvolume, ladder, and state:

```sh
weedr bed plow bitcoin --env production  # no -p: the bed carries its own state
```

That is allowed, just not the default. Prefer a shared pond for anything that behaves like
an app database.

---

## Everyday commands

```sh
weedr bed list                          # what is running
weedr bed plow  myapp --env staging     # create or re-converge a bed
weedr bed start myapp --env staging
weedr bed stop  myapp --env staging
weedr bed remove myapp --env staging

weedr secret set bed-production-myapp STRIPE_KEY    # paste a real secret
weedr secret set bed-production-myapp               # see what is missing

weedr pond dig   pond-staging-postgres                            # create a pond
weedr pond fill  myapp --env staging -p pond-staging-postgres     # database + role for the bed
weedr pond drain myapp --env staging -p pond-staging-postgres     # take them away (production asks first)

stakes pin   1234 --holder bed-staging-myapp       # hold a snapshot
stakes query 1234                                  # who is holding it
stakes list                                        # every ladder and its pins

weedr redeploy myapp --env production              # pull and restart
weedr redeploy myapp --env production --now        # skip the queue
```

One container build runs on the box at a time — by default. The queue is FIFO with
production jumped to the front, and repeat requests for the same bed collapse into one —
`--now` skips the queue for one request. If the box has headroom, `weedr queue lanes 2`
lets two builds run at once; the count applies between builds and never kills one.

`weedr --help` and `stakes --help` list everything else.

---

## Secrets, the honest version

There is no secrets service. There is no encrypted blob in git.

- **Production and fence:** you type the real value once with `weedr secret set`. It lives on
  the VPS in the bed and nowhere else. If you lose the VPS and your own backup of those
  values, the secret is gone. That is the deal for one human and one box.
- **Staging and previews:** `weedr` invents a random value the first time the bed is
  created and reuses it until you drop the bed. Good enough for a staging login, not for
  a payment key.
- **The gate:** a production or fence service will not start if a required variable is empty
  or still says `changeme`. The gate is checked **before the old container is shut down**, so
  a deploy that fails it leaves the running service untouched. The error tells you which
  key is missing.

The shape of every key lives in a tracked `.guarden/.env.schema` in your project repo.
Values never do.

---

## Staging and previews

Every bed declares its environment out loud: `production`, `staging`, `preview`, or
`fence`.

- **staging** is `develop`. It drinks from a staging pond — rebuildable, its data carries
  no ladder by default. If it breaks, throw it away and make it again from a production
  dump.
- **preview** is a pull request. There is one preview bed per project — `bed-preview-myapp` —
  and each ref gets its own nested instance inside it
  (`/home/bed-preview-myapp/<ref>/`). `hose` opens an instance when the branch appears and
  drops it when the branch is gone. Up to three concurrent refs per project by default,
  the oldest goes when a fourth shows up, and the cap is overridable.

Data flows one way. A production bed starts with an **empty** database — its first
deploy never forks from anything. Staging forks from the latest production snapshot.
A preview forks from production too, or from staging when the project has no production
data yet. Every restore gets a fresh role and password; staging and previews never see
a production credential.

---

## Snapshots and pins

`soil` puts snapper on root and home. Every pond and every bed that owns a subvolume gets
its own ladder next to the subvolume it protects. The ladder prunes the oldest first, and
keeps your free-disk margin by trimming home first, root second, and pond data last.

If a snapshot is important — a staging bed is reading it, or you are about to do
something risky — pin it:

```sh
stakes pin <snapshot-id> --holder <bed>
```

The snapper cleanup hook will not delete a pinned id. Drop the holder and it becomes
prunable again. `stakes query <id>` shows who is holding what, and `stakes list` shows
every ladder with its pins.

---

## What `hose` is for

`hose` is the optional gitops piece. Each project's GitHub Action pokes it over ssh —
project, ref, sha, plus the source tree — and `hose` will:

- create a staging bed for `develop` if it is not there,
- open a preview instance for every feature branch,
- redeploy a bed when its manifests changed,
- drop a preview when its branch is merged away, or when `hose check` sees the branch gone.

`hose` keeps no git checkout on the box. When it can read the repo — public, or a
fine-grained read token you store on the VPS — a 15-minute timer runs `hose check`,
which compares the remote with what is deployed and fixes drift by itself. A private
repo without that token is events-only: a lost poke stays wrong until you push an empty
commit.

It calls `weedr` and nothing else. It has no root of its own — just a narrow
`sudoers` rule for the `weedr` subcommands it needs. Deploys queue up like everything
else. A push to `main` can create and deploy the production bed, but a poke never drops
a production bed unless you set a root-owned override. If you do not want gitops, do not
install it.

---

## If something goes wrong

Start here:

```sh
soil --check                # did the host drift?
weedr bed list              # what does guarden think is running?
journalctl -u traefik -u roots -u stakes
snapper list                # how many snapshots, how much room
stakes list                 # every ladder and its pins
stakes query <id>           # is something holding a snapshot?
hose check                  # drift between git and the beds (readable repos)
```

The full recovery runbook is in [`docs/sysadmin.md`](docs/sysadmin.md). If you lock
yourself out of the firewall, wait — the dead-man timer will let you back in.

---

## Where to look next

| file | what is in it |
|---|---|
| [`CONTEXT.md`](CONTEXT.md) | The vocabulary. Read this before changing anything. |
| [`docs/PRD.md`](docs/PRD.md) | Why the system is shaped this way. |
| [`docs/adr/`](docs/adr/) | The decisions that are hard to reverse. |
| [`docs/sysadmin.md`](docs/sysadmin.md) | Recovery, backups, and the commands at 3am. |
| [`AGENTS.md`](AGENTS.md) | How to work on the code. |

---

## The shape of it, in one picture

```
      Internet
         │
     ┌───▼─────────────┐
     │bed-fence-traefik│   the fence. Binds 80/443 without root.
     └───┬─────────────┘
         │  127.0.0.1   (this is "hyphae")
   ┌─────┼─────────────────────────┐
   │     │                         │
┌──▼───────────┐ ┌───────────────┐ ┌▼──────────────┐
│ pond-        │ │ bed-production│ │ bed-staging-  │  each bed is its own
│production-   │ │ -myapp        │ │ myapp         │  Linux user + podman
│postgres      │ └───────────────┘ └───────────────┘
└──────────────┘

  weedr makes the beds. roots makes the routes.
  stakes holds the snapshots. twig makes the dashboard.
  hose (optional) keeps it all true to git.
```

Welcome to guarden.
