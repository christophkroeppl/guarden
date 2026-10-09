# what a from-scratch run found

Found by provisioning a second golden from `ubuntu:26.04` and converging it end to
end — six `soil` phases, then all four modules — rather than by a suite. Both
findings are small and neither blocks the run: the run **succeeded** (all four
modules enabled, four services, eight programs, `guarden` and `edge` groups).

They are worth a ticket because a suite cannot see either of them: the first is a
diagnostic, and the second is a property of first boot.

## 1. The alias probe reports a false network claim for every failure cause

On a host with no `podman`, `soil install --apply` says:

```
error: alias probe 1 of 4: the container's default route names no gateway
```

There is nothing wrong with the route. Measured on the same machine:

```
$ ip route show default
default via 10.26.102.1 dev enp5s0 proto dhcp src 10.26.102.103 metric 100
```

`podman` is simply not installed yet — `soil packages --apply` installs it — and
the *same* misleading line appears when podman **is** installed and the probe image
is absent, because podman then tries a registry pull and fails:

```
Error: unable to copy from source docker://localhost/guarden-probe:latest:
pinging container registry localhost: ... connection refused
```

**The mechanism.** `_probe_gateway` (hostprep.py:2219) returns `""` for any
non-ok result:

```python
result = h.run(*_podman_argv(network, "ip", "-4", "route", "show", "default"))
if not result.ok:
    return ""
```

and the caller turns `""` into the gateway claim. But `hosttool.run` already
converts a missing binary into a Result rather than raising, with the real reason
in `.err`:

```python
except OSError as exc:
    return Result(tuple(argv), 127, "", f"{argv[0]} is not installed ({exc.strerror})")
```

So `result.err` says `podman is not installed (No such file or directory)` and it is
**discarded**. The `except OSError` handler around the probe body, whose message is
correct — *"is not installed or not on PATH … `soil packages --apply` installs
it"* — is therefore **unreachable for this cause**, because nothing in the guarded
region raises `OSError` for a missing tool any more.

**The fix** is to surface the reason instead of collapsing it: distinguish "the
tool did not run" from "it ran and named no gateway", and use `result.err` in the
first case. The operator's next command is different in each case — `soil packages
--apply` for one, configuring the probe image for the other — and today neither is
reachable from the message.

The probe image `localhost/guarden-probe` being external is **by design and already
documented** (`tests/t20-install.sh:50`, "this repository neither builds nor ships
it"), and `soil install --apply` exiting 1 without it is asserted. Only the
diagnostic is wrong.

## 2. The harness's cloud-init list names a package that does not exist

`tests/lxc.sh`'s `_user_data` lists `btrfs-convert` as a package. On
`ubuntu:26.04`:

```
$ apt-cache policy btrfs-convert        # empty: the name is not known
$ dpkg -S /usr/bin/btrfs-convert
btrfs-progs: /usr/bin/btrfs-convert     # the binary ships in btrfs-progs
```

So cloud-init tries, fails, and reports the whole run as failed:

```
cloudinit.distros.PackageInstallerError: Failed to install the following
packages: {'btrfs-convert'}.
...
finish: modules-final: FAIL: running modules for final
cloud-init status -> error
```

Nothing breaks: the binary arrives with `btrfs-progs`, the conversion runs, and the
golden provisions. **But every freshly provisioned machine reports
`cloud-init status: error`**, which is the same class the code's own comment warns
about — "cloud-init installs the list, and it silently skips a package whose
install fails … Re-assert the list rather than trust that it landed" — and a
permanently-red status is how the real instance of that gets ignored.

**The fix** is to drop the entry; `btrfs-progs` is already on the list and is what
provides the binary. The claim it carries — "cloud-init reports no failure on a
fresh provision" — needs a fresh provision to verify, so it is not a change to
merge on the strength of `apt-cache` alone.
