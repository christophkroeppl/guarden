"""guarden: one VPS, a handful of projects, one edge.

The programs are the product's whole interface (ADR-0012), and each one is a
console script named in `pyproject.toml`. Nothing here is a public API beyond
`main`, and no test imports any of it.
"""

PROGRAMS = ("soil", "weedr", "loom", "roots", "twig", "furrow", "hose", "stakes")

__all__ = ["PROGRAMS"]
