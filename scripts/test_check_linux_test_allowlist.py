#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# ///
"""Regression tests for check-linux-test-allowlist.py.

Run with: `uv run scripts/test_check_linux_test_allowlist.py`
"""

from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

_SPEC = importlib.util.spec_from_file_location(
    "check_linux_test_allowlist", Path(__file__).parent / "check-linux-test-allowlist.py"
)
assert _SPEC and _SPEC.loader
lint = importlib.util.module_from_spec(_SPEC)
sys.modules["check_linux_test_allowlist"] = lint
_SPEC.loader.exec_module(lint)

# Mirrors the Package.swift shape from #526: a multi-line allowlist where
# Persistence/JSONStoreCompatibilityTests.swift was added to the tree but not
# to the list, so its seven compatibility cases never ran on Linux.
FIXTURE_PACKAGE = """
let package = Package(
    targets: [
        .testTarget(
            name: "GrafttyHostTests",
            dependencies: ["GrafttyHost"],
            swiftSettings: strictWarnings
        ),
        .testTarget(
            name: "GrafttyKitTests",
            dependencies: ["GrafttyKit", "GrafttyProtocol",
                           .product(name: "NIOEmbedded", package: "swift-nio")] + cryptoDependencies,
            sources: isLinux ? ["Ports/PortBindingTests.swift", "Support/MutableBox.swift",
                "Teams/TeamInboxTests.swift"] : nil,
            resources: [
                .process("Hosting/Fixtures"),
            ],
            swiftSettings: strictWarnings
        ),
    ]
)
"""

PORTABLE = "import Testing\n@testable import GrafttyKit\n\nstruct T { @Test func t() {} }\n"
GUARDED = "// Copyright\nimport Foundation\n\n#if os(macOS)\nimport AppKit\nstruct T {}\n#endif\n"


def write(root: Path, rel: str, text: str = PORTABLE) -> None:
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


class ParseAllowlistsTests(unittest.TestCase):
    def test_finds_only_targets_using_the_islinux_sources_pattern(self) -> None:
        allowlists = lint.parse_allowlists(FIXTURE_PACKAGE)
        self.assertEqual(list(allowlists), ["GrafttyKitTests"])

    def test_collects_entries_across_lines(self) -> None:
        allowlists = lint.parse_allowlists(FIXTURE_PACKAGE)
        self.assertEqual(
            allowlists["GrafttyKitTests"],
            ["Ports/PortBindingTests.swift", "Support/MutableBox.swift", "Teams/TeamInboxTests.swift"],
        )

    def test_real_package_swift_has_kit_tests_allowlist(self) -> None:
        text = (lint.REPO_ROOT / "Package.swift").read_text()
        allowlists = lint.parse_allowlists(text)
        self.assertIn("GrafttyKitTests", allowlists)
        self.assertIn("Persistence/JSONStoreCompatibilityTests.swift", allowlists["GrafttyKitTests"])


class AppleOnlyGuardTests(unittest.TestCase):
    def check(self, text: str) -> bool:
        return lint.has_apple_only_guard(text)

    def test_guards_after_comments_and_imports_count(self) -> None:
        for guard in ("#if os(macOS)", "#if os(iOS)", "#if canImport(AppKit)", "#if canImport(UIKit)"):
            with self.subTest(guard=guard):
                self.assertTrue(self.check(f"/* header\n   more */\n// c\nimport Foundation\n\n{guard}\nx\n#endif\n"))

    def test_portable_file_is_not_guarded(self) -> None:
        self.assertFalse(self.check(PORTABLE))

    def test_guard_must_be_first_code_line(self) -> None:
        self.assertFalse(self.check("import Testing\nstruct A {}\n#if os(macOS)\nstruct B {}\n#endif\n"))

    def test_non_apple_guard_does_not_count(self) -> None:
        self.assertFalse(self.check("import Testing\n#if canImport(Darwin)\nstruct A {}\n#endif\n"))
        self.assertFalse(self.check("import Testing\n#if os(Linux)\nstruct A {}\n#endif\n"))


class CheckTreeTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        (self.root / "Package.swift").write_text(FIXTURE_PACKAGE)
        kit = "Tests/GrafttyKitTests"
        for rel in ("Ports/PortBindingTests.swift", "Support/MutableBox.swift", "Teams/TeamInboxTests.swift"):
            write(self.root, f"{kit}/{rel}")
        write(self.root, f"{kit}/UI/SidebarTests.swift", GUARDED)
        write(self.root, f"{kit}/Apple/ThumbnailTests.swift")
        write(self.root, f"{kit}/Model/LegacyAppleOnlyTests.swift")
        # A target without the pattern is never inspected.
        write(self.root, "Tests/GrafttyHostTests/AnythingTests.swift")
        self.baseline = {f"{kit}/Model/LegacyAppleOnlyTests.swift"}

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def problems(self) -> list[str]:
        return lint.check_tree(self.root, self.baseline)

    def test_clean_tree_passes(self) -> None:
        self.assertEqual(self.problems(), [])

    def test_reproduces_526_unlisted_portable_file(self) -> None:
        write(self.root, "Tests/GrafttyKitTests/Persistence/JSONStoreCompatibilityTests.swift")
        problems = self.problems()
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("Tests/GrafttyKitTests/Persistence/JSONStoreCompatibilityTests.swift", problems[0])
        self.assertIn("not in the Linux `sources:` allowlist", problems[0])

    def test_listed_path_missing_from_tree_fails(self) -> None:
        (self.root / "Tests/GrafttyKitTests/Teams/TeamInboxTests.swift").unlink()
        problems = self.problems()
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("Teams/TeamInboxTests.swift", problems[0])
        self.assertIn("does not exist", problems[0])

    def test_baseline_entry_missing_from_tree_fails(self) -> None:
        (self.root / "Tests/GrafttyKitTests/Model/LegacyAppleOnlyTests.swift").unlink()
        problems = self.problems()
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("Model/LegacyAppleOnlyTests.swift", problems[0])
        self.assertIn("baseline", problems[0])

    def test_listed_file_also_in_baseline_fails(self) -> None:
        self.baseline.add("Tests/GrafttyKitTests/Support/MutableBox.swift")
        problems = self.problems()
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("Support/MutableBox.swift", problems[0])

    def test_baseline_entry_that_is_now_guarded_fails(self) -> None:
        write(self.root, "Tests/GrafttyKitTests/Model/LegacyAppleOnlyTests.swift", GUARDED)
        problems = self.problems()
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("already marked Apple-only", problems[0])

    def test_portable_file_listed_under_apple_dir_fails(self) -> None:
        # The inverse mistake once #477 lands: an Apple/ file in the allowlist.
        text = FIXTURE_PACKAGE.replace('"Support/MutableBox.swift",', '"Support/MutableBox.swift", "Apple/ThumbnailTests.swift",')
        (self.root / "Package.swift").write_text(text)
        problems = self.problems()
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("Apple/ThumbnailTests.swift", problems[0])


class BaselineParsingTests(unittest.TestCase):
    def test_skips_comments_and_blank_lines(self) -> None:
        text = "# header\n\nTests/A/B.swift\n  Tests/A/C.swift  # trailing\n"
        self.assertEqual(lint.parse_baseline(text), {"Tests/A/B.swift", "Tests/A/C.swift"})


class RealTreeTests(unittest.TestCase):
    def test_repository_passes(self) -> None:
        self.assertEqual(lint.check_tree(lint.REPO_ROOT, lint.load_baseline(lint.BASELINE_PATH)), [])


if __name__ == "__main__":
    unittest.main()
