# 60: credentials and the gate

**What to build:** A value the operator types once is encrypted on the box and reaches the
container as a podman secret file, and a service in a gated track cannot start without it. No
value is readable by anything but its own service, and a failed gate leaves the running container
running.

**Blocked by:** 30 (weedr), 40 (loom)

**Status:** ready-for-agent

- [ ] `weedr secret set <name> <KEY>` prompts with echo off, encrypts with `systemd-creds` and
      writes `/etc/guarden/creds/<name>/<KEY>.cred` mode 0600
- [ ] **The encryption key is stated once and `auto` is not used.** Either
      `systemd-creds --with-key=host`, against a host key at
      `/var/lib/systemd/credential.secret`, or `systemd-creds --with-key=tpm2`, binding it to
      the machine's TPM. `auto` is avoided because its meaning varies with the hardware — it
      prefers a TPM2 key when it finds one, so a box with a TPM would silently encrypt with a
      different key than every document describes, and nothing at the time would say so. A test
      asserts no call passes `--with-key=auto`
- [ ] One system path unit on `/etc/guarden/creds/` and one boot-time oneshot re-materialise
      blobs into the owning service's podman secret store — two units in total, not two per
      service
- [ ] A podman secret's name is what the container sees, and **injection as a file is the
      default, not as an environment variable.** `loom` emits `Secret=<KEY>,type=file` in the
      `[Container]` table **and nothing else**, podman resolves `<KEY>` from that service's own
      secret store, and the container reads `/run/secrets/<KEY>`. One injected as an
      environment variable is visible in `/proc/<pid>/environ`, is routinely echoed by frameworks
      in stack traces, and is inherited by every child process the service spawns. A manifest that
      genuinely needs an environment variable may have one generated from the secret, and the
      file is what it gets
- [ ] **The generated unit carries no `LoadCredentialEncrypted=`, and a test asserts its
      absence.** The unit runs in the *service user's* user manager, which cannot read the `0600
      root` system host key and has no business holding it. Decryption happens once, root-side,
      in the materialiser unit above, which is why that unit exists; by the time the renderer
      runs, the value is already a podman secret and the renderer only names it
- [ ] **The renderer emits a credential request and never a value**, because it has none. No
      rendered unit, and no registry field, contains one
- [ ] `weedr secret list <name>` prints names and whether each is set, never a value
- [ ] **The trust boundary, stated exactly:** a value is in no plaintext file, in no snapshot of a
      service's state, in no backup of the host filesystem, and is unreadable by any other service
      user. It is deliberately available to its own service, because a rootless container shares
      that service's uid and the podman secret database lives in that service's own home. The test
      asserts the first half; the second half is not a defect and no test should imply it is
- [ ] **Lose the encryption key and every credential is unrecoverable.** There is one key, no
      second copy on the box and no mechanism for one, so the runbook says so plainly: each
      credential must be re-planted with `weedr secret set` from the operator's own offline copy,
      and nothing else about the box is affected. The same is true of the machine that held a
      TPM-sealed key. The README's sentence about losing the VPS says the same thing
- [ ] A track with `gated = true` refuses a start when a `@required` key is missing, empty,
      prefixed `EXAMPLE-`, or equal to `changeme`, and names the key
- [ ] **There are exactly two outcomes and no third.** On a track with `gated = false` the same
      condition produces one `warning:` line naming the key, and the start proceeds. There is no
      such thing as a preview with an override, and nothing in guarden produces a fourth outcome
- [ ] A service on a track with `gated = false` gets generated values for its own keys at
      creation, stable until the service is removed: nothing on it is worth stealing, and a poke
      must not be blocked on a human planting them
- [ ] The gate is evaluated before the old container is stopped: a failed gate exits 1 and the
      call log contains no `stop` for the running unit
- [ ] The varlock schema in `.guarden/.env.schema` is the source of truth for names and types, and
      the only annotations that carry meaning are `@required`, `@sensitive`, `@type` and
      `@example`. Nothing is generated from it into the repository and there is no `.env.example`
      to keep in step with anything
- [ ] Verified at the CLI seam with the fast harness
