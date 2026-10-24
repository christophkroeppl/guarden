# 290 — a manifest-declared config file, rendered into the service home

2026-10-16. Implemented on `feat/config-files`, verified by `t40-configfiles.sh`
and `t40-config-home.sh` on the throwaway machine.

## The problem this closes

A service that needs a config file — `odoo.conf`, NBXplorer's `settings.config` —
had two ways to get one, and both were wrong:

- a `Containerfile` entrypoint that writes the file at start. It breaks on every
  image change, it is a second place for the database's host and port to be
  wrong, and a repository cannot change it without a rebuild.
- a file copied into the service home by hand. It works and it is not
  reproducible: the home is `0700` to the service user, so the copy is an
  operator's `ssh` and a `chown`, and nothing records that it happened.

The mount mechanism was never the problem. guarden allows a bind mount under the
service's own tree (`/var/lib/guarden/services/<svc>/home/`), and the odoo-btc-bcr
repository already declares one. What was missing was the other end of it: a
standard way to get the file into that tree at deploy time.

## What was built

A `config_files:` block in the manifest:

```yaml
config_files:
  - source: templates/odoo.conf.j2
    target: /etc/odoo/odoo.conf
```

`source` is a path inside the repository, a jinja2 template. `target` is an
absolute path inside the container.

`loom` renders the template with the service's **edge variables** — the same
`<AS>_HOST`, `<AS>_PORT` and `<AS>_<DB>_USER` rows the environment file carries,
as `{{ DB_HOST }}` — plus `{{ service }}` and `{{ domain }}`. The bytes are
written under `config/<target>` in the render, and the mutator installs them into
the service home at the target's own path: `home/etc/odoo/odoo.conf`.

The unit source's own `volumes:` entry is what delivers it, unchanged —
`<home>/<target>:<target>` — and that mount is inside the service's own tree, so
it needs no admin grant. The home is therefore a mirror of the container's
filesystem at the paths the service needs configured, and the same manifest
renders the same path on every track.

## Decisions worth recording

- **The home mirrors the target, not the source.** `home/<target>` rather than
  `home/<source>` is what makes the mount the repository writes identical on
  staging, preview and production: the target comes from the manifest and the
  home from the service's own name. A source can live anywhere in the repository.
- **`loom check` renders leniently and `loom render` strictly.** `check` has no
  registry and therefore no edge variables, so its environment treats an
  undefined name as empty: it proves the template parses and the file exists.
  `render` is the verb that proves it renders against the host.
- **`check` allows the service tree as a whole; `render` narrows it to one
  service's own.** `check` has no service, so "the service's own volumes" is not
  a question it can ask — and the bind mount this feature exists to make
  checkable lives under the service's own home. The service tree is a constant
  of the host layout rather than a host answer, so `check` allows it; a mount
  into *another* service's home is refused by `render`, which knows the name.
- **A missing source is refused before identity.** `service.create` checks each
  declared source against the tree before it makes a user or a home, for the same
  reason `edges.check` and `check_hosts` run where they do: a refusal after the
  user exists leaves a system account behind on the way out.
- **The convergence predicate now covers the templates.** `_source_hash` hashed
  `.guarden/` and `compose.yaml`; a changed template is a change the rendered
  output depends on, so it is in the hash. The hash is also computed for every
  source kind rather than only `poke`, because `add --from <path>` and
  `add --from <service>` are the paths a re-render after a template edit takes.
- **Nothing root-owned inside the home.** The rendered file and every directory
  its path needs are the service user's, which is the one thing spec 2 forbids
  root from being inside a service's home.

## What the suites assert

`t40-configfiles.sh` (the render): the file is keyed by the target, the edge
variables and the domain reach it, the unit carries no second copy of the path,
`check` writes nothing, and the manifest's own shape is refused by name — an
unknown key inside an entry, an absolute or `..` source, a relative or `//`
target, a duplicate target, a missing source, a template that does not parse.

`t40-config-home.sh` (the install): the file is in the home at the target's own
path, it and its directories are the service user's, the unit source's own mount
is what names it, the template travels with the service so a re-render can read
it, a changed template re-renders and an unchanged one converges, and a missing
source is refused before a user or a home exists.

## Not done here

- The odoo-btc-bcr repository still carries its stopgap: a baked entrypoint that
  writes `odoo.conf`, and a `.config/` tree whose contents were copied into the
  home by hand. Migrating it is a repository change, not a guarden one, and it is
  the proof that the mechanism works on a real service.
- A render that refuses leaves the previous output in place, because `build`
  raises before `write`. The mutator empties the directory before it renders, so
  no stale file reaches a home; the observation is recorded rather than changed,
  since it is not this ticket's subject.
