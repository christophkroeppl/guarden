"""Rendering and grants for tunnel-only routes and the control surface.

These are the fail-closed claims the firewall and the edge renderer make, tested
on their own rather than only on a running host: a route that was named
`tunnel_only` must have no `websecure` entrypoint, and a service whose own
publication is called `api` must keep the ordinary grants.
"""

from __future__ import annotations

import io
import unittest
from contextlib import redirect_stderr
from types import SimpleNamespace
from unittest import mock

from guarden import firewall, overrides, roots


def _route(label: str, destinations: list[str], **extra) -> dict:
    return {
        "label": label,
        "host": label,
        "target": "10.0.2.2:20006",
        "destinations": destinations,
        **extra,
    }


class TunnelOnlyLabelsTest(unittest.TestCase):
    def labels(self, requested, routes, tunnel_entrypoints=("cloudflared",)):
        with mock.patch.object(
            roots.overrides_mod,
            "load",
            return_value=overrides.Overrides(expose_tunnel_only=list(requested)),
        ):
            stderr = io.StringIO()
            with redirect_stderr(stderr):
                effective = roots._tunnel_only_labels(
                    "app", routes, list(tunnel_entrypoints)
                )
        return effective, stderr.getvalue()

    def test_a_tunnel_route_is_effective(self) -> None:
        effective, _ = self.labels(["api"], [_route("api", ["tunnel"])])
        self.assertEqual(effective, {"api"})

    def test_an_unknown_label_is_warned_about_and_ignored(self) -> None:
        effective, stderr = self.labels(["nope"], [_route("api", ["tunnel"])])
        self.assertEqual(effective, set())
        self.assertIn("not a route", stderr)

    def test_a_route_that_is_also_edge_is_ignored(self) -> None:
        effective, stderr = self.labels(
            ["api"], [_route("api", ["tunnel", "edge"])]
        )
        self.assertEqual(effective, set())
        self.assertIn("includes edge", stderr)

    def test_a_route_with_no_tunnel_destination_is_ignored(self) -> None:
        effective, stderr = self.labels(["api"], [_route("api", ["loopback"])])
        self.assertEqual(effective, set())
        self.assertIn("not a tunnel route", stderr)

    def test_a_host_without_cloudflared_warns_instead_of_raising(self) -> None:
        effective, stderr = self.labels(
            ["api"], [_route("api", ["tunnel"])], tunnel_entrypoints=()
        )
        self.assertEqual(effective, {"api"})
        self.assertIn("cloudflared entrypoint is not enabled", stderr)

    def test_no_request_reads_nothing(self) -> None:
        effective, stderr = self.labels([], [_route("api", ["tunnel"])])
        self.assertEqual(effective, set())
        self.assertEqual(stderr, "")


class RenderServiceTest(unittest.TestCase):
    def render(self, routes, tunnel_only=None, tunnel_entrypoints=("cloudflared",)):
        # The template needs jinja2, a distribution package a test box may not
        # have. The rows are the answer this renderer owns; the template only
        # prints them, so capture the rows instead of rendering YAML.
        def fake_template(name, **kwargs):
            return "\n".join(
                f"router: {row['router']} entrypoints: {' '.join(row['entrypoints'])}"
                for row in kwargs["rows"]
            )

        with mock.patch.object(
            roots.render, "render_template", side_effect=fake_template
        ):
            return roots.render_service(
                "app",
                routes,
                ["websecure"],
                provider=None,
                tunnel_entrypoints=list(tunnel_entrypoints),
                preview_host="preview.example",
                tunnel_only=tunnel_only,
            )

    def test_a_plain_tunnel_route_uses_only_the_tunnel_entrypoint(self) -> None:
        body = self.render([_route("web", ["tunnel"])])
        self.assertIn("entrypoints: cloudflared", body)
        self.assertNotIn("websecure", body)

    def test_a_both_route_keeps_both_entrypoints(self) -> None:
        body = self.render([_route("web", ["tunnel", "edge"])])
        self.assertIn("entrypoints: websecure cloudflared", body)

    def test_a_tunnel_only_route_has_no_websecure(self) -> None:
        body = self.render([_route("api", ["tunnel"])], tunnel_only={"api"})
        self.assertNotIn("websecure", body)
        self.assertIn("cloudflared", body)

    def test_a_tunnel_only_route_also_restricts_its_preview_router(self) -> None:
        body = self.render(
            [_route("api", ["tunnel"], ref="abc123")], tunnel_only={"api"}
        )
        self.assertIn("-preview entrypoints: cloudflared", body)
        self.assertNotIn("websecure", body)

    def test_a_tunnel_only_route_is_absent_without_cloudflared(self) -> None:
        body = self.render(
            [_route("api", ["tunnel"])],
            tunnel_only={"api"},
            tunnel_entrypoints=(),
        )
        self.assertEqual(body, "")

    def test_an_unlisted_tunnel_route_is_still_rendered(self) -> None:
        body = self.render(
            [_route("web", ["tunnel"]), _route("api", ["tunnel"])],
            tunnel_only={"api"},
        )
        self.assertIn("cloudflared", body)
        self.assertEqual(body.count("router:"), 2)


class ControlSurfaceGrantsTest(unittest.TestCase):
    def records(self, control_surface: bool):
        return SimpleNamespace(
            service="traefik-production",
            uid=982,
            publication={"api": 20005, "web": 20006},
            instances={},
            route_destinations={},
            control_surface=control_surface,
            installed_by=None,
        )

    def test_the_api_publication_is_admin_only_for_the_control_surface(self) -> None:
        record = self.records(True)
        with mock.patch.object(firewall.registry, "load", return_value=record):
            self.assertEqual(firewall._api_publication("traefik-production"), 20005)

    def test_an_ordinary_service_is_not_the_control_surface(self) -> None:
        record = self.records(False)
        with mock.patch.object(firewall.registry, "load", return_value=record):
            self.assertIsNone(firewall._api_publication("traefik-production"))

    def accept_map(self, record):
        with (
            mock.patch.object(firewall.registry, "names", return_value=[record.service]),
            mock.patch.object(firewall.registry, "load", return_value=record),
            mock.patch.object(firewall, "edge_uids", return_value={982}),
            mock.patch.object(firewall, "tunnel_uids", return_value={994}),
            mock.patch.object(firewall, "consumer_uids", return_value={}),
            mock.patch.object(firewall, "route_publications", return_value=set()),
            mock.patch.object(firewall, "tunnel_publications", return_value={"api"}),
            mock.patch.object(firewall, "admin_uid", return_value=0),
        ):
            return firewall._service_accept_map(SimpleNamespace())

    def test_the_control_surface_api_is_admin_and_nothing_else(self) -> None:
        allowed = self.accept_map(self.records(True))
        self.assertEqual(allowed["traefik-production"][20005], {0: "admin"})

    def test_an_app_publication_named_api_keeps_its_ordinary_grants(self) -> None:
        record = SimpleNamespace(
            service="app",
            uid=1001,
            publication={"api": 21000},
            instances={},
            route_destinations={"api": "tunnel"},
            control_surface=False,
            installed_by=None,
        )
        allowed = self.accept_map(record)
        grants = allowed["app"][21000]
        self.assertEqual(grants[1001], "own")
        self.assertIn(994, grants)
        self.assertNotIn(0, grants)


class OriginAllowlistRenderTest(unittest.TestCase):
    def config(self, allowlist: str):
        return SimpleNamespace(
            interface="eth0",
            edge=SimpleNamespace(origin_allowlist=allowlist),
        )

    def test_the_deny_precedes_every_publication_accept(self) -> None:
        with (
            mock.patch.object(firewall, "_cloudflare_ranges", return_value=["104.16.0.0/13"]),
            mock.patch(
                "guarden.hostprep.module_ingress",
                return_value=[("edge", "tcp", "20006"), ("edge", "tcp", "20007")],
            ),
        ):
            body, _ = firewall.render(self.config("cloudflare"), [])
        jump = body.index("jump guarden-edge-in")
        first_accept = body.index("dport 20006 jump ACCEPT")
        self.assertLess(jump, first_accept)
        self.assertIn("ctorigdstport 443 saddr 104.16.0.0/13 jump ACCEPT", body)
        self.assertIn("proto udp mod conntrack ctorigdstport 443 jump DROP", body)

    def test_off_renders_no_allowlist_chain(self) -> None:
        with mock.patch(
            "guarden.hostprep.module_ingress", return_value=[("edge", "tcp", "20006")]
        ):
            body, _ = firewall.render(self.config("off"), [])
        self.assertNotIn("guarden-edge-in", body)


if __name__ == "__main__":
    unittest.main()
