# Secrets: a systemd credential, materialised into a podman secret

There are no secrets in a repository and none in CI, and no secret value is readable at rest
by anything except the one service that owns it.

`weedr secret set <service> <KEY>` takes the value on a terminal, encrypts it with
`systemd-creds`, and writes one blob to `/etc/guarden/creds/<service>/<KEY>.cred`. Rootless
podman secrets are per-user, so the materialisation step runs as the service: one system unit
reads the blob and creates or replaces a podman secret of the same name in that service's store.

**The key is stated once, here.** Either `systemd-creds --with-key=host`, against a host key at
`/var/lib/systemd/credential.secret`, or `systemd-creds --with-key=tpm2`, binding it to the
machine's TPM. The `auto` setting is **not** used, and the reason is worth recording: its meaning
varies with the hardware — it prefers a TPM2 key when it finds one — so a box that happened to
have a TPM would silently encrypt with a different key than every document here describes, and
nothing at the time would say so. One key per host, chosen explicitly, is the only form in which
"which key is this?" has an answer.

A podman secret is injected by name, and that is all a generated unit carries:
`Secret=<KEY>,type=file` in the `[Container]` table and nothing else. Podman resolves `<KEY>`
from that service's own secret store and presents the value inside the container at
`/run/secrets/<KEY>`; the type suffix is the only thing that decides whether it arrives as a file
or as an environment variable, and the file is the default.

**A generated unit carries no `LoadCredentialEncrypted=`, and must not.** These units run in the
*service user's* user manager, which cannot read the system host key: it is `0600 root`, and a
user manager has no business holding it. Decryption happens once, root-side, in the credential
materialiser, which is why that unit exists — by the time the renderer runs, the value is already
a podman secret and the renderer only names it. The renderer emits the *request* and never a
value, because the renderer has no value.

Two units do this for the whole host, not one pair per service: a path unit watching
`/etc/guarden/creds/` re-materialises a changed blob, and a boot-time oneshot re-materialises
everything. A unit per service would be a unit per service to install, reload and eventually
forget to remove.

The trust boundary is worth stating plainly, because the mechanism is easy to overclaim.
`systemd-creds` protects the value at rest on the host filesystem: the value is in no file, it is
in no snapshot of a service's state, it is in nothing a backup of the host filesystem carries, and
no other service user can read it. It does not, and cannot, protect the value from the service
that owns it. A rootless container shares its service's uid, so the container and the service user
are the same principal, and the podman secret database lives in that service's own home. The
correct statement is that a credential is protected from every other service and from a backup
of `/etc`, and is deliberately available to its own service — **and to a backup of
`/var/lib`**, because the materialised podman secret store inside the service's home is
cleartext and the home's `0700` is the only thing protecting it. An earlier revision of this
document said "from the host's storage and from backups" without qualification, which is false
for any backup that includes a service's home, and an operations runbook repeated it verbatim.

It is equally wrong to overclaim the other way. There is one encryption key and no second copy of
it on the box and no mechanism for one, so losing `/var/lib/systemd/credential.secret` — or the
machine that held a TPM-sealed key — makes every credential on the host unrecoverable and each
has to be re-planted from the operator's own copy. The operator holds the only offline copy, and
there is no mechanism for a second one.

Which makes scoping, not secrecy, the real control. One credential and one least-privilege
role per declared edge, so a compromised service gains exactly its own access and nothing
more. Rotation is `weedr secret set` followed by a restart, and it is cheap precisely because
nothing is stored centrally to keep in step.

Injection form matters. A podman secret injected as a file is the default, because one
injected as an environment variable is visible in `/proc/<pid>/environ`, is routinely echoed
by frameworks in stack traces, and is inherited by every child process the service spawns. A
manifest that genuinely needs an environment variable may have one generated from the secret,
but the file is what it gets, and applications are expected to read it.

A written-out `.env` file would be created under root's umask, inside a directory the service
user owns. It would be world-readable, present in every snapshot of that volume and in anything
derived from one, and its mode would be a decision nobody remembers to make. That is why a
credential is an encrypted blob and not a file. The same reasoning puts admin configuration
outside every service's home: a mode on a file inside a user-owned directory says nothing about
unlinking it.

Keys come from a tracked varlock schema, `.guarden/.env.schema`, which holds names, types and
example values and never a real one. Nothing is generated from it into the repository, and there
is no `.env.example` to keep in step with anything: a service's credentials exist only in its own
store. On a track with `gated = true` the gate refuses to start a service whose required key is
missing, empty, or still an example, and on a track with `gated = false` the same condition is
one `warning:` line and the start proceeds. The operator keeps the only offline copy. A snapshot
of a service's state volume does not contain its credentials, which is what makes cloning and
rolling back safe to do automatically.
