"""The storage phase's layout predicate, and the `/tmp` property it verifies.

The layout predicate decides between converting a host and finishing it, and it
is a function's answer rather than a host's state: a VM suite can only ever
observe the host a conversion produced, so the question "does a host with `@`
and `@var` and no `@tmp` hold?" is answered here and nowhere else. That question
is the whole of ticket 340's RED — a host converted before `@tmp` existed must
not hold, or the phase would report it converged and the layout would stay two
subvolumes forever.

`_tmp_configuration` is the parser for "no snapper configuration exists for
`/tmp`". The requirement is about the **subvolume**, not the configuration's
name, and that distinction is one a host cannot be asked about: a configuration
called `tmp` for some other subvolume is not a ladder for `/tmp`, while a
configuration with an opaque name whose subvolume *is* `/tmp` is.
"""

from __future__ import annotations

import unittest
from unittest import mock

from guarden import hostprep
from guarden import hosttool as h


def _result(out: str, code: int = 0) -> h.Result:
    return h.Result(("snapper",), code, out, "")


def _subvolumes(*names: str) -> h.Result:
    """`btrfs subvolume list /` for a layout, in the tool's own shape."""
    lines = [f"ID {256 + index} gen 1 top level 5 path {name}" for index, name in enumerate(names)]
    return h.Result(("btrfs",), 0, "\n".join(lines) + "\n", "")


class BtrfsLayoutHoldsTest(unittest.TestCase):
    def test_the_three_subvolumes_hold(self) -> None:
        with mock.patch.object(hostprep.h, "run", return_value=_subvolumes("@", "@var", "@tmp")):
            self.assertTrue(hostprep._btrfs_layout_holds())

    def test_a_host_converted_before_atmp_existed_does_not_hold(self) -> None:
        """The RED. `@` and `@var` were the whole layout before this change, and
        a predicate that accepted them would report the old golden as converged
        while `/tmp` stayed a tmpfs."""
        with mock.patch.object(hostprep.h, "run", return_value=_subvolumes("@", "@var")):
            self.assertFalse(hostprep._btrfs_layout_holds())

    def test_no_subvolumes_at_all_does_not_hold(self) -> None:
        with mock.patch.object(hostprep.h, "run", return_value=_subvolumes()):
            self.assertFalse(hostprep._btrfs_layout_holds())

    def test_a_subvolume_named_atmp_somewhere_else_does_not_hold(self) -> None:
        """The name is what is matched, so `@tmp` as a nested path is not the
        top-level subvolume the layout names — and a nested one is the
        fail-open shape, because `subvol=@tmp` resolves against the top level."""
        with mock.patch.object(
            hostprep.h, "run", return_value=_subvolumes("@", "@var", "@/.snapshots")
        ):
            self.assertFalse(hostprep._btrfs_layout_holds())

    def test_btrfs_absent_is_not_a_layout(self) -> None:
        result = h.Result(("btrfs",), 1, "", "not btrfs")
        with mock.patch.object(hostprep.h, "run", return_value=result):
            self.assertFalse(hostprep._btrfs_layout_holds())


class TmpConfigurationTest(unittest.TestCase):
    LISTING = "Config | Subvolume\n-------+----------\nroot   | /\n"

    def test_no_configuration_when_there_is_only_root(self) -> None:
        with mock.patch.object(hostprep.h, "run", return_value=_result(self.LISTING)):
            self.assertIsNone(hostprep._tmp_configuration())

    def test_the_configuration_whose_subvolume_is_tmp_is_named(self) -> None:
        listing = self.LISTING + "scratch | /tmp\n"
        with mock.patch.object(hostprep.h, "run", return_value=_result(listing)):
            self.assertEqual(hostprep._tmp_configuration(), "scratch")

    def test_a_configuration_called_tmp_for_another_subvolume_is_not_one(self) -> None:
        """The requirement is about the subvolume. `assert_no_snapper_config tmp`
        would answer this the other way and fail a host that satisfies it."""
        listing = self.LISTING + "tmp    | /var/lib/guarden/tests/seeded-tmp\n"
        with mock.patch.object(hostprep.h, "run", return_value=_result(listing)):
            self.assertIsNone(hostprep._tmp_configuration())

    def test_the_header_and_the_rule_line_are_not_configurations(self) -> None:
        listing = "Config | Subvolume\n-------+----------\n"
        with mock.patch.object(hostprep.h, "run", return_value=_result(listing)):
            self.assertIsNone(hostprep._tmp_configuration())

    def test_snapper_absent_is_no_configuration(self) -> None:
        with mock.patch.object(hostprep.h, "run", return_value=_result("", 127)):
            self.assertIsNone(hostprep._tmp_configuration())

    def test_an_empty_listing_is_no_configuration(self) -> None:
        with mock.patch.object(hostprep.h, "run", return_value=_result("")):
            self.assertIsNone(hostprep._tmp_configuration())


class StorageItemsTest(unittest.TestCase):
    """The items the phase walks, asserted as a list rather than on a host.

    A host can only show the items that hold; the *shape* of the list — that the
    layout item names three subvolumes and that the `/tmp` item is one the phase
    reports and cannot correct — is a fact about the phase and nothing a machine
    can answer.
    """

    def setUp(self) -> None:
        self.items = hostprep.storage_items()

    def test_the_layout_item_names_three_subvolumes(self) -> None:
        wanted = "btrfs with the @, @var and @tmp subvolumes"
        self.assertIn(wanted, [item.what for item in self.items])

    def test_the_tmp_item_is_reported_and_never_corrected(self) -> None:
        item = next(item for item in self.items if item.what.startswith("no snapper configuration"))
        self.assertFalse(item.correctable)

    def test_the_tmp_item_names_the_ladder_it_is_about(self) -> None:
        item = next(item for item in self.items if item.what.startswith("no snapper configuration"))
        self.assertIn("/tmp", item.what)


class HostConfigurationsTest(unittest.TestCase):
    """`/tmp` must not be a configuration, and the dict is where that lives.

    The operator's requirement is that `/tmp` has no ladder, and a ladder is a
    per-configuration thing: a configuration that does not exist has none. So
    the requirement is carried by `HOST_CONFIGURATIONS` NOT naming `/tmp`, and
    a change that adds it would give `/tmp` a ladder the operator refused.
    """

    def test_tmp_is_not_a_host_configuration(self) -> None:
        self.assertNotIn("/tmp", hostprep.HOST_CONFIGURATIONS.values())

    def test_the_host_has_exactly_one_configuration(self) -> None:
        self.assertEqual({"root": "/"}, hostprep.HOST_CONFIGURATIONS)


if __name__ == "__main__":
    unittest.main()
