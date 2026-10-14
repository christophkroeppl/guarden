# 40: loom — the renderer

**What to build:** A manifest plus a registry become quadlet units, a `.volume` unit per
declared volume, an environment file, the `AddHost=` entries and the credential requests, plus
the shared slices the mutator installs for `roots` and `twig`. `loom` is unprivileged and pure.
It refuses to render anything it cannot fully resolve.

**Blocked by:** 10 (harness and program skeletons), 30 (weedr — identities and configuration)

**Status:** ready-for-agent

- [ ] The manifest is parsed with `pyyaml` using the **safe loader only**, never the default one,
      and never a loader that can construct arbitrary python objects from repository input
- [ ] An unknown top-level key is exit 2 with the file named, and an `environment` key is refused
      **specifically**, with a message saying the host decides the environment and where the
      decision is recorded
- [ ] `units:` accepts `compose.yaml` at the repository root or `.guarden/quadlet/`; **both
      present is exit 2 naming both**, and **neither present is exit 2 naming both accepted
      locations**
- [ ] `compose.yaml` is converted in the renderer, unprivileged, by driving the pinned
      `podlet`; a repository shipping quadlet units has them used unchanged. The privileged
      mutator never runs a converter, or any other program, over repository input
- [ ] **podlet's output is treated as untrusted input, not as a finished unit.** `loom`
      overwrites or removes every field guarden has an opinion about — the refusal list, the whole
      `PublishPort` set, `Network=pasta:`, `AddHost=`, the credential requests, the `.volume`
      units, the start-order edges. A test converts a `compose.yaml` declaring `network_mode:
      host`, `cap_add` and a `PublishPort`, and asserts none of the three survives into the
      installed unit: a converter that passes them through is not a security boundary, and this
      is the assertion that proves loom is
- [ ] **The renderer owns the published-port set completely.** Every `PublishPort` found in the
      unit source is stripped before the units are regenerated, and the whole set comes from the
      grants and the allocations. Without this step a `ports:` entry in a Compose file becomes a
      `PublishPort=` line verbatim and the grant ceiling is advisory
- [ ] **Every rendered port is a loopback publication.** Nothing emits a bind on a non-loopback
      address, and a granted public port is rendered as a firewall translation, not as a
      `PublishPort` for every interface
- [ ] **Refused, each naming the key:** `PodmanArgs=`, `--privileged`, `cap_add`, `cap_drop`,
      `devices`, `network_mode: host`, `pid: host`, `userns_mode`, and `network_mode: container:`.
      A host-path bind outside the service's own volumes, `/etc/guarden` and the paths listed in
      the root-owned `overrides.toml` `[mounts] allow` is refused, naming the path
- [ ] A `.volume` unit is emitted for every declared volume, `state` and `bulk` alike, because a
      container must be able to mount either. A `state` one is bound to
      `/var/lib/guarden/services/<name>/state/<vol>`
- [ ] `needs` entries are validated against the **registry** — they name another guarden
      service — and `routes` and `widgets` entries against the **containers the unit source
      defines**. A `service:` key inside a `routes:` or `widgets:` block is exit 2 naming the
      block, and a route naming a container the unit source does not define is **exit 2** naming
      the file and the key: both the manifest and the unit source are input
- [ ] A `needs` entry naming the service that declared it — a self-edge — is refused naming the
      service. It has no consumer and it is nearly always a copy-paste
- [ ] An edge to a service with no registry entry is exit 1 naming the service — loom never
      guesses
- [ ] A `needs`/`provides` disagreement visible from the manifests alone is exit 2; one where the
      provider exists but does not offer the kind is exit 1, and the diagnostic names both
      services and both kinds
- [ ] **A mounted named volume in neither `state` nor `bulk` is refused, naming the volume.**
      An undeclared volume lands in the service's rootless image store, where nothing snapshots
      it, nothing lists it, and removing the user silently discards it. This is the single most
      expensive mistake a manifest can make and the manifest is not allowed to make it
- [ ] `[mounts] allow` is writable only by root, so a repository cannot widen its own mounts
- [ ] **No rendered unit, from any manifest, references a host path outside the service's own
      volumes, `/etc/guarden` and the admin allow list.** Asserted by one test that walks every
      rendered unit of every fixture project, not by per-service tests, because the property
      belongs to the renderer
- [ ] The edge module and the credential materialiser declare any mount they need through
      `[mounts] allow` at install time, so the rule above does not have to be weakened for them
- [ ] **There is no name map and no `/etc/hosts`.** For each edge, `AddHost=<provider>:<alias>`
      goes into every unit of the consumer, and a route target is `<name>:<publication>` — the
      service's own name, with no suffix and no alias
- [ ] A container set is derived from a Compose file's services or from the stems and
      `ContainerName=` of `.guarden/quadlet/` units, so a quadlet-only repository is validated
      the same way a Compose one is
- [ ] An untagged or `latest` image reference is a `warning:` naming the service and the
      container, and does not stop the render
- [ ] `CPUWeight=` and `IOWeight=` are emitted from the track's `weight`. The manifest cannot
      state a weight and a manifest key for one is refused by name
- [ ] `${domain}` is the only substitution, taken from `host.domain`; no host environment
      variable and no service name reaches a rendered unit
- [ ] **For a key the schema marks `@required` or `@sensitive`, a credential *request* is
      emitted and never a value:** `Secret=<KEY>,type=mount` in the `[Container]` table and
      **nothing else**, which podman resolves from that service's own secret store and presents
      at `/run/secrets/<KEY>`. A key whose application needs a variable gets `type=env`. The
      renderer has no value to emit, and no test asserts one
- [ ] **No rendered unit carries `LoadCredentialEncrypted=`, and a test asserts the absence.**
      These units run in the *service user's* user manager, which cannot read the `0600 root`
      system host key and has no business holding it. Decryption happens once, root-side, in the
      credential materialiser, which is why that unit exists; by the time the renderer runs the
      value is already a podman secret and the renderer only names it. A renderer that emitted
      the directive would produce a unit systemd cannot start, and the error would name
      quadlet rather than the cause
- [ ] The same manifest, registry and overrides produce byte-identical output on every run
- [ ] A quadlet drop-in at
      `/etc/containers/systemd/users/<uid>/<unit>.container.d/<n>-<purpose>.conf` is merged into
      the source file before generation, and a drop-in that sets `[Service] MemoryMax=`,
      `MemoryHigh=`, `CPUWeight=` or `IOWeight=` lands in the generated scope. quadlet's own
      `[Container]` has only `Memory=`, so the systemd keys are the only way to express a soft
      and a hard limit together
- [ ] `loom check` validates without writing anything
- [ ] Units are rendered from `templates/` files with jinja2, not from heredocs, and a changed
      template changes the output on the next run
- [ ] `loom` writes only into `--out` **and the shared slices** the mutator installs into
      `/var/lib/guarden/shared/<name>/` for `roots` and `twig`. It writes nothing else anywhere
- [ ] The manifest and registry parsers are tested directly, as the one exception to the seam
- [ ] Verified at the CLI seam, in the VM

**What these refusals are.** They are guardrails against accidents: they make the expensive
mistake unwritable by a manifest and visible in review, and they mean a repository cannot
obtain a capability, a device or a host mount by adding a line. They are not a boundary against
a hostile repository. The repository's code runs as the service user, the service user can write
files in its own home, and the property that actually holds is the per-service uid with `0700`
on the service tree. Write this ticket's tests and the ticket's prose to match, so a refusal is
never described as a security boundary it cannot be.
