# The file and command-line surface is the API

guarden's parts never call each other over a network. They exchange files under `/etc/guarden`
and `/var/lib/guarden`, and they are driven from a command line. That is the whole interface, and
it is the part that stays stable.

Everything behind it is an implementation detail. The mutator is python today and will
plausibly be a compiled binary later; the renderers are python and will plausibly be rust.
Shell is used only to invoke programs and sequence them. None of that may be visible from
outside, which produces three rules that constrain implementation choices rather than the
reverse:

- No daemon speaks to another daemon over a socket or an HTTP endpoint. A file, a command, or
  nothing.
- A program's behaviour is specified by its verbs, flags, exit codes, output lines and the
  files it writes. A refactor that changes any of those is a behaviour change and needs a
  decision, not a commit message.
- No runtime logic is spread across shell libraries. Shell is for invoking things and
  sequencing them; anything with branches that matters is a program with a testable seam.

One consequence of the first rule: converting a project's Compose file into quadlet units is
the renderer's work and happens unprivileged. The privileged mutator never runs a converter,
and never runs any program at all, over repository input; it only ever reads files that
`loom` wrote. That is not an extra rule, it is what root executing only root-owned copies
already implies.

**This says who runs the converter, not that the renderer writes it itself.** `loom` drives the
pinned `podlet` for the mechanical translation, and the rule is satisfied because podlet runs as
the unprivileged renderer. The division is in spec §4: podlet owns the fields guarden has no
opinion about, and `loom` overwrites or removes every field it does — the refusal list, the whole
`PublishPort` set, `Network=pasta:`, `AddHost=`, the credential requests, the `.volume` units and
the start-order edges. Running a converter is not the same as trusting its output, and the
distinction is the whole of why the renderer exists.

The formats are normative and specified in `docs/spec.md` precisely so a future
implementation can be checked against them rather than against the current source. When
something cannot be expressed as a file format or a command, it does not go in.

The test seam is the same interface: every test drives a command line and asserts on exit
code, diagnostics, files and the calls made to system tools. The single exception is the
manifest and registry parsers, which may be tested directly, because a parser is the one
place where a bug is invisible from the outside until it silently drops a service's
configuration.
