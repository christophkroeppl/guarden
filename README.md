# guarden

One VPS. A handful of projects. No Kubernetes, no dashboard you have to learn.

`guarden` turns a fresh Ubuntu box into a small, honest deployment host. It puts each
project into a **bed** (its own Linux user, its own containers, its own volumes), routes
traffic to it through Traefik, shares one Postgres for production and one for everything
else, and takes btrfs snapshots so you can undo a bad deploy.

There is no web UI. Everything is a command you can read, and every piece talks to the
next one over files.

---

## What you get

| piece | what it does |
|---|---|
| **soil** | Prepares the host: btrfs, snapper, ferm, rootless podman. |
| **weedr** | The one command that creates and removes beds, secrets, and databases. |
| **roots** | Reads `bed.yaml` from every bed and writes Traefik config. |
| **stakes** | Remembers which snapshots you care about so the ladder cannot delete them. |
| **pond** | Two Postgres instances. Production one is snapshotted, the other is disposable. |
| **twig** | Renders your Homepage dashboard from one small file per service. |
| **hose** | Optional. Watches git and keeps beds in sync with what is on a branch. |

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

Log in as root and run the cloud-init or the install scripts. The short version:

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

A project repo needs three files at its root. Nothing else.

```yaml
# compose.yaml  —  a normal Compose file. Services, volumes, networks.
services:
  api:
    image: ghcr.io/you/nutristack-api
    ports: ["8080"]
  web:
    image: ghcr.io/you/nutristack-web
    ports: ["3000"]
```

```yaml
# bed.yaml  —  what guarden needs to know. Routes, databases, hostnames.
routes:
  api: "api.${env}.${domain}"
  web: "${env}.${domain}"
pond:
  databases: ["app"]
hyphae:
  aliases: ["nutristack.internal"]
```

```yaml
# widgets/api.yml  —  one file per service. What the dashboard shows.
description: Nutristack API
href: "https://api.${env}.${domain}"
icon: mdi-api
```

Then, on the VPS:

```sh
weedr bed new nutristack --env production --from /path/to/nutristack
```

That single command creates the Linux user, writes the quadlet units, makes the database
in `pond-production`, plants a generated password, writes the hostnames, and brings the services
up. Traefik starts routing to `api.yourdomain.com` on its own.

To take it away:

```sh
weedr bed drop nutristack --env production
```

Production asks first. Previews do not.

---

## Everyday commands

```sh
weedr bed list                       # what is running
weedr bed start nutristack --env staging
weedr bed stop  nutristack --env staging
weedr bed drop  nutristack --env staging

weedr secret set nutristack-production STRIPE_KEY    # paste a real secret
weedr secret set nutristack-production               # see what is missing

weedr pond mint nutristack --env staging             # make the database
weedr pond drop nutristack --env staging             # remove it

stakes pin   1234 --holder nutristack-staging        # hold a snapshot
stakes query 1234                                    # who is holding it
stakes unpin 1234 --holder nutristack-staging        # let it go

weedr redeploy nutristack --env production           # pull and restart
```

`weedr --help` and `stakes --help` list everything else.

---

## Secrets, the honest version

There is no secrets service. There is no encrypted blob in git.

- **Production:** you type the real value once with `weedr secret set`. It lives on the
  VPS in the bed and nowhere else. If you lose the VPS and your own backup of those
  values, the secret is gone. That is the deal for one human and one box.
- **Staging and previews:** `weedr` invents a random value the first time the bed is
  created and reuses it until you drop the bed. Good enough for a staging login, not for
  a payment key.
- **The gate:** a production service will not start if a required variable is empty or
  still says `changeme`. This is deliberate. The error tells you which key is missing.

The shape of every key lives in a tracked `.env.schema` in your project repo. Values
never do.

---

## Staging and previews

Every project has an `environment`: `production`, `staging`, or `preview:<ref>`.

- **staging** is `develop`. It drinks from `pond-staging`, which is not snapshotted. If
  it breaks, throw it away and make it again from a production dump.
- **preview** is a pull request. `hose` opens one when the branch appears and drops it
  when the branch is gone. Up to three at a time; the oldest goes when a fourth shows up.

Both get a fresh database restored from a pinned production snapshot, with a fresh
password. They never see a production credential.

---

## Snapshots and pins

`soil` puts snapper on root, home, and the production pond. The ladder prunes the oldest
first, and keeps your free-disk margin by trimming home first, root second, and the
production pond last.

If a snapshot is important — a staging bed is reading it, or you are about to do
something risky — pin it:

```sh
stakes pin <snapshot-id> --holder <bed>
```

The snapper cleanup hook will not delete a pinned id. Drop the holder and it becomes
prunable again. `stakes query <id>` shows who is holding what.

---

## What `hose` is for

`hose` is the optional gitops piece. Point it at a list of project repos and it will:

- create a staging bed for `develop` if it is not there,
- create a preview bed for every feature branch,
- drop a preview when its branch is merged away,
- redeploy a bed when its manifests changed.

It does this by calling `weedr` and nothing else. It has no root of its own — just a
narrow `sudoers` rule that lets it run `weedr preview new`, `weedr preview drop`, and
`weedr redeploy`. If you do not want gitops, do not install it.

---

## If something goes wrong

Start here:

```sh
soil --check                # did the host drift?
weedr bed list              # what does guarden think is running?
journalctl -u traefik -u roots -u stakes
snapper list                # how many snapshots, how much room
stakes query <id>           # is something holding a snapshot?
```

The full recovery runbook is in [`docs/sysadmin.md`](docs/sysadmin.md). If you lock
yourself out of the firewall, wait — the dead-man timer will let you back in.

---

## Where to look next

| file | what is in it |
|---|---|
| [`CONTEXT.md`](CONTEXT.md) | The vocabulary. Read this before changing anything. |
| [`docs/PRD.md`](docs/PRD.md) | Why the system is shaped this way. |
| [`docs/adr/`](docs/adr/) | The five decisions we are not going to relitigate. |
| [`docs/sysadmin.md`](docs/sysadmin.md) | Recovery, backups, and the commands at 3am. |
| [`AGENTS.md`](AGENTS.md) | How to work on the code. |

---

## The shape of it, in one picture

```
      Internet
         │
     ┌───▼────┐
     │ traefik │   edge. Binds 80/443 without root.
     └───┬────┘
         │  127.0.0.1   (this is "hyphae")
   ┌─────┼──────────────────┐
   │     │                  │
┌──▼──┐ ┌▼─────────┐  ┌─────▼────┐
│pond │ │ bed-a    │  │ bed-b    │  each bed is its own
│prod │ │ api, web │  │ api      │  Linux user + podman
└─────┘ └──────────┘  └──────────┘

  weedr makes the beds. roots makes the routes.
  stakes holds the snapshots. twig makes the dashboard.
  hose (optional) keeps it all true to git.
```

Welcome to the guarden.
