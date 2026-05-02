#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# ///
"""Regression tests for generate-specs.py.

Run with: `uv run scripts/test_generate_specs.py`
"""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

_SPEC = importlib.util.spec_from_file_location(
    "generate_specs", Path(__file__).parent / "generate-specs.py"
)
assert _SPEC and _SPEC.loader
gs = importlib.util.module_from_spec(_SPEC)
sys.modules["generate_specs"] = gs
_SPEC.loader.exec_module(gs)


class ParseCarrierTextTests(unittest.TestCase):
    def test_triple_collapses_swift_line_continuations(self) -> None:
        carrier = (
            "@spec IOS-4.12: When the fetched Ghostty config specifies a single "
            "theme (not a light:X,dark:Y pair), \\\n"
            "the application shall force overrideUserInterfaceStyle on the terminal "
            "container view to match \\\n"
            "that theme's appearance.\n"
        )
        result = gs.parse_carrier_text("triple", carrier, "IOS-4.12")
        self.assertNotIn("\\", result, f"backslash leaked into rendered text: {result!r}")
        self.assertEqual(
            result,
            "When the fetched Ghostty config specifies a single theme "
            "(not a light:X,dark:Y pair), the application shall force "
            "overrideUserInterfaceStyle on the terminal container view to match "
            "that theme's appearance.",
        )

    def test_triple_without_continuation_still_collapses_newlines(self) -> None:
        carrier = "@spec ABC-1: foo\nbar\nbaz\n"
        result = gs.parse_carrier_text("triple", carrier, "ABC-1")
        self.assertEqual(result, "foo bar baz")

    def test_single_line_unchanged(self) -> None:
        carrier = "@spec LAYOUT-2.14: When PaneTitle.display renders foo, the application shall do bar."
        result = gs.parse_carrier_text("single", carrier, "LAYOUT-2.14")
        self.assertEqual(
            result,
            "When PaneTitle.display renders foo, the application shall do bar.",
        )

    def test_single_unescapes_backslash(self) -> None:
        # Source `\\` (two chars) represents one literal backslash in the
        # compiled Swift string; the generator preserves that semantics.
        carrier = "@spec ABC-2: a\\\\b"
        result = gs.parse_carrier_text("single", carrier, "ABC-2")
        self.assertEqual(result, "a\\b")

    def test_doc_comment_preserves_backslash(self) -> None:
        carrier = "@spec GIT-3.0\nEach worktree shall expose a state."
        result = gs.parse_carrier_text("doc", carrier, "GIT-3.0")
        self.assertEqual(result, "Each worktree shall expose a state.")


if __name__ == "__main__":
    unittest.main()
