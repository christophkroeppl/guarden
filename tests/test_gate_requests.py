"""The gate answers for what the units REQUEST, not only for what the schema requires.

ADR-0027 says a `via: tunnel` edge plants nothing and step 9 does not mint a key
such an edge asks for. That makes a case reachable that was previously covered up
by the planted value: a key the schema calls **optional** while the renderer still
emits `Secret=<KEY>` for it. `@sensitive` alone is enough to emit the request, and
`@defaultRequired=infer` with a bare `// API_SECRET` produces exactly that —
sensitive, not required, and requested.

`gate.evaluate` used to skip every such key:

    if key is not None and not key.required:
        continue

so a gated track with nothing planted reported `ready`, `unsatisfied` was empty,
and the start reached podman's `125 no such secret` — the false green ADR-0027
exists to remove, reached through the schema instead of through a plant.

That is a unit test rather than a suite because the subject is a decision, not a
machine: `evaluate` reads two things, and both are patched here to the state the
question is about. The VM suites (`t457`, `t454`) cover the same claim end to end
with a real registry and a real store.
"""

import unittest
from pathlib import Path
from unittest import mock

from guarden import gate, secretschema

# `@defaultRequired=infer`: a key declared WITHOUT a value is not required.
# `@sensitive` is true unless the file says otherwise, so this key is wanted —
# the renderer emits `Secret=API_SECRET` for it.
INFERRED_OPTIONAL = "// @defaultRequired=infer\n// API_SECRET\n"

# The same inference, with the key explicitly not a credential: nothing asks
# podman for it, so nothing has to satisfy it.
OPTIONAL_AND_NOT_WANTED = (
    "// @defaultRequired=infer\n// @sensitive=false\n// OPTIONAL_NOTE\n"
)


def schema_of(text: str) -> secretschema.Schema:
    return secretschema.loads(text, Path("/fixtures/.env.schema"))


class ARequestOutranksOptionalTest(unittest.TestCase):
    def evaluate(self, *, requested, stored, gated=True, text=INFERRED_OPTIONAL):
        """`evaluate` with the machine's two reads replaced by the state in question."""
        with mock.patch.object(gate, "unit_requests", return_value=list(requested)), \
             mock.patch.object(gate.credentials, "value",
                               side_effect=lambda service, name: stored.get(name)):
            return gate.evaluate("myapp-staging", schema_of(text), gated, "2026-10-22T00:00:00Z")

    def test_the_key_is_sensitive_and_not_required(self):
        """The premise, asserted rather than assumed: this is the combination."""
        key = schema_of(INFERRED_OPTIONAL).keys[0]
        self.assertEqual(key.name, "API_SECRET")
        self.assertTrue(key.sensitive, "the default is to treat every key as a credential")
        self.assertFalse(key.required, "@defaultRequired=infer: no value, not required")
        self.assertTrue(key.wanted, "sensitive is enough to emit the request")

    def test_a_requested_optional_key_blocks_a_gated_track(self):
        """The defect ADR-0027 made reachable: ready, with nothing to satisfy the request."""
        verdict = self.evaluate(requested=["API_SECRET"], stored={})
        self.assertEqual(verdict.state, gate.BLOCKED, verdict.reason)
        self.assertIn("API_SECRET", verdict.unsatisfied)
        self.assertIn("API_SECRET", verdict.reason or "")

    def test_a_planted_value_still_satisfies_it(self):
        """The fix must not block what an operator has already provided."""
        verdict = self.evaluate(requested=["API_SECRET"], stored={"API_SECRET": "a-real-token"})
        self.assertEqual(verdict.state, gate.READY, verdict.reason)
        self.assertEqual(verdict.unsatisfied, ())

    def test_an_optional_key_nothing_requests_is_still_optional(self):
        """The legit skip survives: no request, nothing to answer for."""
        verdict = self.evaluate(
            requested=[], stored={}, text=OPTIONAL_AND_NOT_WANTED
        )
        self.assertEqual(verdict.state, gate.READY, verdict.reason)
        self.assertEqual(verdict.unsatisfied, ())

    def test_an_ungated_track_warns_and_does_not_block(self):
        """The two tracks' one difference, unchanged by this fix."""
        verdict = self.evaluate(requested=["API_SECRET"], stored={}, gated=False)
        self.assertEqual(verdict.state, gate.NOT_REQUIRED)
        self.assertIn("API_SECRET", verdict.unsatisfied)
        self.assertTrue(verdict.warnings, "an ungated track records what it let through")


if __name__ == "__main__":
    unittest.main()
