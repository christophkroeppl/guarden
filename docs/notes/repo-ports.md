# Repo-controlled ports — an option, documented and not installed

**Status: not part of guarden. Not recommended. Documented because an administrator may want
it and should not have to invent it.**

ADR-0006 says a repository may request a host port and may not grant it. That is the right
default: a repository is remote input from a workflow, and a line in a YAML file should not be
able to open a port on the machine. The cost is a human in the loop for every new port, which
is a real cost when an agent is opening services all day.

This note is the mechanism for removing the human from the loop, and the reason not to. If you
install it, you are re-deciding ADR-0006 in the direction it was written to avoid.

## What it would do

A path unit watches `/etc/guarden/services/` for changes. When a service's
`overrides.toml` gains a `ports.auto` list, a oneshot service promotes those ports into
`ports.open`, re-renders the firewall, and restarts nothing. The grant then looks exactly like
an admin grant, so nothing downstream learns a second path exists.

## The two files

```systemd
# /etc/systemd/system/guarden-ports-auto.path
[Unit]
Description=Promote repository-requested ports when an admin allows it

[Path]
PathChanged=/etc/guarden/services
Unit=guarden-ports-auto.service

[Install]
WantedBy=multi-user.target
```

```systemd
# /etc/systemd/system/guarden-ports-auto.service
[Unit]
Description=Promote ports listed under [ports] auto
After=guarden-firewall.service
Requires=guarden-firewall.service

[Service]
Type=oneshot
ExecStart=/usr/lib/guarden/bin/weedr port promote-auto
```

And the flag in the service's overrides, which is the part that has to be set by a human once:

```toml
# /etc/guarden/services/myapp-production/overrides.toml
[ports]
open   = ["8080/tcp"]
auto   = ["9090/tcp"]     # promoted without asking
```

`weedr port promote-auto` is not implemented. Writing it is roughly forty lines: read every
`overrides.toml`, move each `auto` entry into `open` if the port is unheld, render, print the
diff, install. What does not exist is the reason to exist.

## What it costs

- **The repository now opens host ports.** That is the entire thing ADR-0006 declined. A
  compromised workflow key, or a pull request merged by someone who did not read the diff, can
  open a port on the box. The key is bound to one project by a forced command, which limits the
  blast radius to that project's services — but the ports are on the host, not in the project.
- **The pending state stops being visible.** Today an unopened port shows in `weedr port list`
  and in the pull request's log, and it stays visible until a human acts. With promotion, a port
  opens and the only trace is a journal line nobody reads.
- **It is a second writer of the firewall.** The render is still pure, so this does not corrupt
  rules, but there are now two reasons a port can be open, and the audit question becomes "which
  one was it" rather than "who granted it".
- **A service can open a port nobody intended** by adding one line to its own manifest, which is
  indistinguishable in review from adding a route.

## If you install it anyway

Install it per service, not globally. A path unit that watches the whole services directory
promotes everything; one that watches a single `overrides.toml` limits the decision to the
services you named. And keep the `auto` list short and explicit — the mechanism is only
defensible for ports a project is expected to open, such as a metrics port that must be
scrapeable, and indefensible for anything a human should see first.

The honest summary: guarden keeps the port grant with the human because that is the only place
in the system where a human is strictly better than automation, and the cost of that choice is
one command.
