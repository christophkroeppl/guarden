"""The guided creator: the validation, the refusals, and the tree it writes.

Ticket 328. The creator is the one place where a human types values that end
up in a service's tree, so these tests pin the three things the design says
must hold:

  1. **every value is checked against a closed pattern** before it is
     written — a name, a volume, a credential key, a port, an image
     reference;
  2. **a secret is read only at a terminal**, and no secret material ever
     reaches the tree;
  3. **the creator records what the service ASKS for and never grants it** —
     `weedr port open` and `weedr firewall open` are root and on no sudoers
     rule, so the request/grant split has to survive the creator.

The third is asserted by SOURCE, not by a mock's call log: the module is
searched for the granting verbs, and the commands it prints are checked to be
the ones the operator has to run by hand.
"""

from __future__ import annotations

import io
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from guarden import creator, errors, weedr
from guarden import manifest as manifest_mod


def _answers(**overrides) -> creator.Answers:
    """A complete set of answers, and each test overrides one thing."""
    answers = creator.Answers(
        name="myapp",
        environment="production",
        image="docker.io/library/postgres",
        tag="17-alpine",
    )
    for key, value in overrides.items():
        setattr(answers, key, value)
    return answers


class ValidationTest(unittest.TestCase):
    """Every value is checked against a closed pattern before it is written."""

    def test_a_good_name_is_accepted(self) -> None:
        self.assertEqual(creator.validate_name("myapp"), "myapp")
        self.assertEqual(creator.validate_name("my.app-1_x"), "my.app-1_x")

    def test_a_bad_name_is_refused(self) -> None:
        for bad in ("", "MyApp", "-myapp", "my app", "my/app", "myapp!", "a" * 40):
            with self.subTest(bad=bad):
                with self.assertRaises(errors.GuardenError):
                    creator.validate_name(bad)

    def test_a_name_with_two_dots_is_refused(self) -> None:
        with self.assertRaises(errors.GuardenError) as caught:
            creator.validate_name("my..app")
        self.assertIn("..", str(caught.exception))

    def test_a_good_volume_is_accepted(self) -> None:
        self.assertEqual(creator.validate_volume("data"), "data")
        self.assertEqual(creator.validate_volume("data.1-x"), "data.1-x")

    def test_a_bad_volume_is_refused(self) -> None:
        for bad in ("", "Data", "-data", "data/x", "data x"):
            with self.subTest(bad=bad):
                with self.assertRaises(errors.GuardenError):
                    creator.validate_volume(bad)

    def test_a_good_key_is_accepted(self) -> None:
        self.assertEqual(creator.validate_key("DB_PASSWORD"), "DB_PASSWORD")
        self.assertEqual(creator.validate_key("_private"), "_private")

    def test_a_bad_key_is_refused(self) -> None:
        for bad in ("", "1PASSWORD", "DB-PASSWORD", "DB PASSWORD", "DB.PASSWORD"):
            with self.subTest(bad=bad):
                with self.assertRaises(errors.GuardenError):
                    creator.validate_key(bad)

    def test_a_good_port_is_accepted(self) -> None:
        self.assertEqual(creator.validate_port("8080"), 8080)
        self.assertEqual(creator.validate_port("1"), 1)
        self.assertEqual(creator.validate_port("65535"), 65535)

    def test_a_bad_port_is_refused(self) -> None:
        for bad in ("", "0", "65536", "-1", "http", "80.5", "80 90"):
            with self.subTest(bad=bad):
                with self.assertRaises(errors.GuardenError):
                    creator.validate_port(bad)

    def test_a_good_image_is_accepted(self) -> None:
        self.assertEqual(
            creator.validate_image("docker.io/library/postgres"),
            "docker.io/library/postgres",
        )
        self.assertEqual(
            creator.validate_image("quay.io/team/app:v1"), "quay.io/team/app:v1"
        )

    def test_a_bad_image_is_refused(self) -> None:
        for bad in ("", "-rf", "../etc/passwd", "image with space", "img;rm -rf /"):
            with self.subTest(bad=bad):
                with self.assertRaises(errors.GuardenError):
                    creator.validate_image(bad)

    def test_a_bad_tag_is_refused(self) -> None:
        for bad in ("", "with space", "with/slash", "-leading"):
            with self.subTest(bad=bad):
                with self.assertRaises(errors.GuardenError):
                    creator.validate_tag(bad)

    def test_a_provides_kind_outside_the_set_is_refused(self) -> None:
        self.assertEqual(creator.validate_provides("db"), "db")
        for bad in ("", "database", "postgres", "DB"):
            with self.subTest(bad=bad):
                with self.assertRaises(errors.GuardenError):
                    creator.validate_provides(bad)


class TerminalTest(unittest.TestCase):
    """A question that cannot be asked safely is refused with one line."""

    def test_a_non_tty_is_refused_for_the_creator(self) -> None:
        with mock.patch.object(sys.stdin, "isatty", return_value=False):
            with self.assertRaises(errors.GuardenError) as caught:
                creator.require_terminal("the guided creator")
        self.assertIn("terminal", str(caught.exception))

    def test_a_non_tty_is_refused_for_a_secret(self) -> None:
        """The value would come from a pipe, where there is no echo to turn off.

        The refusal happens BEFORE anything is read, so no value is taken from
        the pipe at all.
        """
        prompt = mock.Mock()
        with mock.patch.object(sys.stdin, "isatty", return_value=False):
            with mock.patch.object(creator.credentials, "prompt", prompt):
                with self.assertRaises(errors.GuardenError) as caught:
                    creator.read_secret("myapp", "DB_PASSWORD")
        self.assertIn("terminal", str(caught.exception))
        prompt.assert_not_called()

    def test_an_eof_is_a_refusal_and_not_a_traceback(self) -> None:
        with mock.patch("builtins.input", side_effect=EOFError):
            with self.assertRaises(errors.GuardenError):
                creator.ask("service name")


class SecretTest(unittest.TestCase):
    """No secret material reaches the tree, and there is no path that could."""

    def test_the_tree_carries_no_secret_value(self) -> None:
        answers = _answers(secrets=[creator.Secret(key="DB_PASSWORD")])
        with tempfile.TemporaryDirectory() as directory:
            tree = Path(directory)
            creator.write_tree(tree, answers)
            written = "\n".join(
                path.read_text(encoding="utf-8")
                for path in sorted(tree.rglob("*"))
                if path.is_file()
            )
        # The KEY is there — the schema declares the shape — and nothing that
        # looks like a value is.
        self.assertIn("DB_PASSWORD", written)
        for value in ("hunter2", "s3cr3t", "password"):
            self.assertNotIn(value, written)

    def test_the_schema_declares_the_key_and_never_a_value(self) -> None:
        answers = _answers(secrets=[creator.Secret(key="DB_PASSWORD")])
        with tempfile.TemporaryDirectory() as directory:
            tree = Path(directory)
            creator.write_tree(tree, answers)
            schema = (tree / creator.SCHEMA_REL).read_text(encoding="utf-8")
        self.assertIn("DB_PASSWORD", schema)
        self.assertIn("@sensitive", schema)
        self.assertIn("@required", schema)

    def test_the_answers_carry_no_value_to_carry(self) -> None:
        """The `Secret` object has a key and nothing else — a value has
        nowhere to live, so it cannot be written into the tree by accident."""
        secret = creator.Secret(key="DB_PASSWORD")
        self.assertEqual([f for f in secret.__dataclass_fields__], ["key"])

    def test_the_manifest_never_names_a_value(self) -> None:
        answers = _answers(secrets=[creator.Secret(key="DB_PASSWORD")])
        document = creator.manifest_document(answers)
        self.assertNotIn("DB_PASSWORD", document)
        self.assertEqual(document["schema"], creator.SCHEMA_MAML_REL)


class GrantSplitTest(unittest.TestCase):
    """The creator records what the service ASKS for, and never grants it.

    `weedr port open` and `weedr firewall open` are root and on no sudoers
    rule, so nothing that answers a push can reach them. A creator that
    granted in the same breath would collapse the request/grant split into one
    act, so the creator PRINTS the commands and the operator runs them.
    """

    def test_the_creator_never_names_a_granting_verb_in_its_code(self) -> None:
        """The source is searched, not a mock's call log: a mock proves what
        happened on one call, and the source is what every call does."""
        source = Path(creator.__file__).read_text(encoding="utf-8")
        # The commands are PRINTED, and the print is a string in a list of
        # commands. What must not be there is a CALL that runs them — so the
        # module must not hold a subprocess or a tool.call of a granting verb.
        for verb in ("port open", "firewall open"):
            self.assertNotIn(f'"{verb}"', source)
        self.assertIn("weedr port open", source)
        self.assertIn("weedr firewall open", source)

    def test_the_creator_calls_no_granting_verb(self) -> None:
        """No `weedr` invocation at all: the creator runs no other verb."""
        with mock.patch.object(creator.tool, "call") as call:
            answers = _answers(
                ports=[creator.Port(container="web", port=8080)],
                firewall=[{"name": "allow-web", "rule": "-p tcp --dport 8080 -j ACCEPT"}],
            )
            creator.report_grants("myapp", answers)
        call.assert_not_called()

    def test_the_grant_commands_are_printed_and_named(self) -> None:
        answers = _answers(
            ports=[creator.Port(container="web", port=8080)],
            firewall=[{"name": "allow-web", "rule": "-p tcp --dport 8080 -j ACCEPT"}],
        )
        commands = creator.grant_commands("myapp", answers)
        self.assertIn("weedr port open myapp 8080", commands)
        self.assertIn("weedr firewall open myapp allow-web", commands)

    def test_the_manifest_records_the_request(self) -> None:
        answers = _answers(
            ports=[creator.Port(container="web", port=8080)],
            firewall=[{"name": "allow-web", "rule": "-p tcp --dport 8080 -j ACCEPT"}],
        )
        document = creator.manifest_document(answers)
        self.assertEqual(document["ports"], [{"container": "web", "port": 8080}])
        self.assertEqual(document["firewall"], answers.firewall)


class TreeTest(unittest.TestCase):
    """The tree the creator writes, and that it parses."""

    def test_the_manifest_it_writes_parses(self) -> None:
        answers = _answers(
            provides=["db"],
            ports=[creator.Port(container="web", port=8080)],
            volumes={"data": "state", "cache": "bulk"},
            firewall=[{"name": "allow-web", "rule": "-p tcp --dport 8080 -j ACCEPT"}],
        )
        with tempfile.TemporaryDirectory() as directory:
            tree = Path(directory)
            path = creator.write_tree(tree, answers)
            parsed = manifest_mod.read(path)
        self.assertEqual(parsed.provides, ["db"])
        self.assertEqual(parsed.state, ["data"])
        self.assertEqual(parsed.bulk, ["cache"])
        self.assertEqual([(entry.container, entry.port) for entry in parsed.ports], [("web", 8080)])
        self.assertEqual([entry.name for entry in parsed.firewall], ["allow-web"])

    def test_the_unit_is_written_where_a_renderer_looks_for_it(self) -> None:
        answers = _answers(ports=[creator.Port(container="web", port=8080)])
        with tempfile.TemporaryDirectory() as directory:
            tree = Path(directory)
            creator.write_tree(tree, answers)
            unit = tree / creator.QUADLET_REL / "web.container"
            self.assertTrue(unit.is_file())
            text = unit.read_text(encoding="utf-8")
        self.assertIn("Image=docker.io/library/postgres:17-alpine", text)

    def test_the_unit_carries_no_publishport(self) -> None:
        """The renderer owns `PublishPort=` and overwrites it, so a
        `PublishPort=` in the creator's unit is a request the renderer drops."""
        answers = _answers(ports=[creator.Port(container="web", port=8080)])
        with tempfile.TemporaryDirectory() as directory:
            tree = Path(directory)
            creator.write_tree(tree, answers)
            text = (tree / creator.QUADLET_REL / "web.container").read_text(encoding="utf-8")
        self.assertNotIn("PublishPort", text)
        self.assertNotIn("Network", text)

    def test_the_manifest_names_the_schema_only_when_there_is_one(self) -> None:
        without = creator.manifest_document(_answers())
        self.assertNotIn("schema", without)
        with_secrets = creator.manifest_document(
            _answers(secrets=[creator.Secret(key="DB_PASSWORD")])
        )
        self.assertEqual(with_secrets["schema"], creator.SCHEMA_MAML_REL)


class PullTest(unittest.TestCase):
    """The pull starts in the background, and it is aborted on the way out."""

    def test_the_pull_starts_in_the_background(self) -> None:
        pull = creator.pull_background("docker.io/library/postgres:17-alpine")
        try:
            self.assertIsNone(pull.process.poll())
        finally:
            creator.abort_pull(pull)

    def test_the_abort_stops_the_pull(self) -> None:
        pull = creator.pull_background("docker.io/library/postgres:17-alpine")
        creator.abort_pull(pull)
        self.assertIsNotNone(pull.process.poll())
        self.assertTrue(pull.aborted)

    def test_the_abort_of_nothing_is_not_a_crash(self) -> None:
        creator.abort_pull(None)
        creator.abort_pull(None)


class StagingTest(unittest.TestCase):
    """The tree is staged where the RENDERER can read it.

    **The renderer runs as `guarden`** (`loom` is handed the tree as
    `guarden`, ADR-0012), and the tree the operator wrote is in their own
    home — `/root` is `0700` — so a tree handed to the renderer as it stands
    is a tree the renderer cannot enter.
    """

    def test_the_staged_tree_is_world_readable(self) -> None:
        answers = _answers(
            provides=["db"],
            ports=[creator.Port(container="web", port=8080)],
        )
        with tempfile.TemporaryDirectory() as directory:
            tree = Path(directory) / "tree"
            creator.write_tree(tree, answers)
            with mock.patch.object(creator.paths, "LIB", Path(directory) / "lib"):
                stage = creator.stage_tree(tree)
                try:
                    for path in [stage, *sorted(stage.rglob("*"))]:
                        mode = path.stat().st_mode & 0o777
                        if path.is_dir():
                            self.assertEqual(mode, 0o755, f"{path} is {mode:04o}")
                        else:
                            self.assertEqual(mode, 0o644, f"{path} is {mode:04o}")
                finally:
                    creator.drop_tree(stage)

    def test_the_staged_tree_carries_the_render_inputs(self) -> None:
        answers = _answers(
            ports=[creator.Port(container="web", port=8080)],
            secrets=[creator.Secret(key="DB_PASSWORD")],
        )
        with tempfile.TemporaryDirectory() as directory:
            tree = Path(directory) / "tree"
            creator.write_tree(tree, answers)
            with mock.patch.object(creator.paths, "LIB", Path(directory) / "lib"):
                stage = creator.stage_tree(tree)
                try:
                    self.assertTrue((stage / creator.MANIFEST_REL).is_file())
                    self.assertTrue((stage / creator.QUADLET_REL / "web.container").is_file())
                    self.assertTrue((stage / creator.SCHEMA_REL).is_file())
                finally:
                    creator.drop_tree(stage)

    def test_the_staged_tree_is_taken_away(self) -> None:
        answers = _answers()
        with tempfile.TemporaryDirectory() as directory:
            tree = Path(directory) / "tree"
            creator.write_tree(tree, answers)
            with mock.patch.object(creator.paths, "LIB", Path(directory) / "lib"):
                stage = creator.stage_tree(tree)
                creator.drop_tree(stage)
                self.assertFalse(stage.exists())


class VerifyTest(unittest.TestCase):
    """The verification is EXACTLY three checks, and each one is well-defined."""

    def test_there_are_exactly_three_checks(self) -> None:
        with mock.patch.object(creator, "unit_active") as unit:
            with mock.patch.object(creator, "container_running") as container:
                with mock.patch.object(creator, "publication_listening") as publication:
                    unit.return_value = creator.Check("a", True)
                    container.return_value = creator.Check("b", True)
                    publication.return_value = creator.Check("c", True)
                    checks = creator.verify("myapp", "web", "myapp-web", 20001)
        self.assertEqual(len(checks), 3)
        unit.assert_called_once()
        container.assert_called_once()
        publication.assert_called_once()

    def test_the_unit_check_asks_the_services_own_manager(self) -> None:
        with mock.patch.object(creator.tool, "call") as call:
            call.return_value = mock.Mock(ok=True, stdout="active\n", stderr="", returncode=0)
            check = creator.unit_active("myapp", "web")
        call.assert_called_once_with(
            ["systemctl", "--user", "--machine", "myapp@", "is-active", "web"]
        )
        self.assertTrue(check.ok)

    def test_the_container_check_asks_podman(self) -> None:
        with mock.patch.object(creator.tool, "call") as call:
            call.return_value = mock.Mock(
                ok=True, stdout="myapp-web\n", stderr="", returncode=0
            )
            check = creator.container_running("myapp", "myapp-web")
        self.assertTrue(check.ok)
        self.assertIn("podman", call.call_args[0][0])
        self.assertIn("ps", call.call_args[0][0])

    def test_the_publication_check_looks_for_a_listener(self) -> None:
        with mock.patch.object(creator.tool, "call") as call:
            call.return_value = mock.Mock(
                ok=True,
                stdout="LISTEN 0 128 127.0.0.1:20001 0.0.0.0:*\n",
                stderr="",
                returncode=0,
            )
            check = creator.publication_listening(20001)
        self.assertTrue(check.ok)

    def test_a_publication_that_is_not_listening_fails(self) -> None:
        with mock.patch.object(creator.tool, "call") as call:
            call.return_value = mock.Mock(ok=True, stdout="", stderr="", returncode=0)
            check = creator.publication_listening(20001)
        self.assertFalse(check.ok)


class ReportTest(unittest.TestCase):
    """The report says what it found, and it does not claim more than it knows."""

    def test_a_passing_report_says_so(self) -> None:
        out = io.StringIO()
        with mock.patch.object(sys, "stdout", out):
            ok = creator.report_checks([creator.Check("the unit is active", True)])
        self.assertTrue(ok)
        self.assertIn("ok", out.getvalue())

    def test_a_failing_report_says_so(self) -> None:
        out = io.StringIO()
        with mock.patch.object(sys, "stdout", out):
            ok = creator.report_checks([creator.Check("the unit is active", False, "inactive")])
        self.assertFalse(ok)
        self.assertIn("FAIL", out.getvalue())


class DispatchTest(unittest.TestCase):
    """Which half of the guided mode runs, and which one asks.

    **The root half is recognised by `--plant` or `--start`, and not by the
    tree's existing.** A tree directory that exists says nothing about whether
    the questions were asked — the creator makes the directory itself — so
    keying the dispatch on it would skip the questions entirely and read an
    empty tree. That was a real defect: the suite caught it in the VM, where
    the creator refused with "the tree carries no .guarden/service.yml" after
    the questions had been skipped.
    """

    def _args(self, *extra: str):
        parser = weedr.build_parser()
        return parser.parse_args(["service", "create", "myapp", "--guided", *extra])

    def test_without_the_root_flags_the_asking_half_runs(self) -> None:
        args = self._args("--tree", "/tmp/tree")
        self.assertIsNone(args.plant)
        self.assertFalse(args.start)

    def test_with_plant_the_root_half_runs(self) -> None:
        args = self._args("--tree", "/tmp/tree", "--plant")
        self.assertIsNotNone(args.plant)
        self.assertEqual(args.plant, [])

    def test_with_start_the_root_half_runs(self) -> None:
        args = self._args("--tree", "/tmp/tree", "--start")
        self.assertTrue(args.start)


if __name__ == "__main__":
    unittest.main()
