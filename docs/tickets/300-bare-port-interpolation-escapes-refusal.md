# 300 — a bare $PORT interpolation reaches podlet; only ${ is refused

Blockers: none. Found 2026-10-19 by an adversarial review of develop 10f7457
(verified: _refuse_templated_ports at compose.py:205).

## What happens
`_refuse_templated_ports` matches only the literal `${`; a Compose-interpolated bare
`$PORT` (`127.0.0.1:$PORT:8069`) passes and dies in podlet with the very
"invalid IP address syntax" message the refusal exists to pre-empt (compose.py:206-212).

## What to build
Match both interpolation forms (and state the rule in the refusal text), red-first:
both `${PORT}` and `$PORT` forms refused from the same entry point with nothing written.
