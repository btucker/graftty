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

# The three Linux membership shapes Package.swift uses: an exclude list with a
# pending-files constant (GrafttyKitTests since #477), a `sources:` allowlist
# (GrafttyKitTests before #477, #526), and a Linux-only target with a fixed
# `sources:` list under a `path:` override (GrafttyDirectSSHTests).
FIXTURE_PACKAGE = """
let linuxPendingKitTests = [
    "Web/PendingTests.swift", // not ported yet
]

let package = Package(
    targets: [
        .target(
            name: "GrafttyProtocol",
            exclude: isLinux ? ["UI"] : [],
            swiftSettings: strictWarnings
        ),
        .testTarget(
            name: "GrafttyHostTests",
            dependencies: ["GrafttyHost"],
            swiftSettings: strictWarnings
        ),
        .testTarget(
            name: "GrafttyKitTests",
            dependencies: ["GrafttyKit", "GrafttyProtocol",
                           .product(name: "NIOEmbedded", package: "swift-nio")] + cryptoDependencies,
            exclude: isLinux ? ["Apple"] + linuxPendingKitTests : [],
            resources: [
                .process("Hosting/Fixtures"),
            ],
            swiftSettings: strictWarnings
        ),
        .testTarget(
            name: "LegacyTests",
            sources: isLinux ? ["Ports/PortBindingTests.swift",
                "Teams/TeamInboxTests.swift"] : nil,
            swiftSettings: strictWarnings
        ),
    ] + (isLinux ? [
        .testTarget(
            name: "GrafttyDirectSSHTests",
            path: "Tests/GrafttyTests/Remote/SSH",
            sources: ["DirectSSHLoopbackTests.swift"],
            swiftSettings: strictWarnings
        ),
    ] : [])
)
"""

PORTABLE = "import Testing\n@testable import GrafttyKit\n\nstruct T { @Test func t() {} }\n"
GUARDED = "// Copyright\nimport Foundation\n\n#if os(macOS)\nimport AppKit\nstruct T {}\n#endif\n"


def write(root: Path, rel: str, text: str = PORTABLE) -> None:
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


class ParseTargetsTests(unittest.TestCase):
    def targets(self, text: str = FIXTURE_PACKAGE) -> dict:
        return {t.name: t for t in lint.parse_targets(text)}

    def test_finds_only_targets_with_linux_membership(self) -> None:
        self.assertEqual(sorted(self.targets()), ["GrafttyDirectSSHTests", "GrafttyKitTests", "GrafttyProtocol", "LegacyTests"])

    def test_exclude_list_includes_the_referenced_constant(self) -> None:
        kit = self.targets()["GrafttyKitTests"]
        self.assertEqual(kit.linux_exclude, ["Apple", "Web/PendingTests.swift"])
        self.assertIsNone(kit.linux_sources)

    def test_unknown_exclude_constant_is_an_error(self) -> None:
        with self.assertRaises(ValueError):
            lint.parse_targets(FIXTURE_PACKAGE.replace("+ linuxPendingKitTests", "+ missingList"))

    def test_sources_allowlist_collects_entries_across_lines(self) -> None:
        self.assertEqual(self.targets()["LegacyTests"].linux_sources, ["Ports/PortBindingTests.swift", "Teams/TeamInboxTests.swift"])

    def test_path_override_sets_the_directory(self) -> None:
        ssh = self.targets()["GrafttyDirectSSHTests"]
        self.assertEqual(ssh.directory, "Tests/GrafttyTests/Remote/SSH")
        self.assertEqual(ssh.fixed_sources, ["DirectSSHLoopbackTests.swift"])

    def test_default_directory_depends_on_target_kind(self) -> None:
        targets = self.targets()
        self.assertEqual(targets["GrafttyKitTests"].directory, "Tests/GrafttyKitTests")
        self.assertEqual(targets["GrafttyProtocol"].directory, "Sources/GrafttyProtocol")

    def test_allowlist_on_executable_target_is_attributed_to_that_target(self) -> None:
        text = '.target(name: "Lib", dependencies: []),\n.executableTarget(name: "Exe", sources: isLinux ? ["a.swift"] : nil)\n'
        self.assertEqual([(t.name, t.linux_sources) for t in lint.parse_targets(text)], [("Exe", ["a.swift"])])

    def test_exclude_may_be_a_bare_constant(self) -> None:
        # GrafttyKit's shape: `exclude: isLinux ? linuxKitExclusions : []`.
        text = 'let kitExclusions = ["Updater", "Model/PNGThumbnail.swift"]\nlet targets = [\n    .target(name: "Kit", exclude: isLinux ? kitExclusions : [])\n]\n'
        self.assertEqual([(t.name, t.linux_exclude) for t in lint.parse_targets(text)], [("Kit", ["Updater", "Model/PNGThumbnail.swift"])])

    def test_comments_do_not_hide_or_redirect_membership(self) -> None:
        # Codex review of #654: a comment before the constant used to drop
        # the target, and a commented-out `path:` used to win.
        text = FIXTURE_PACKAGE.replace("+ linuxPendingKitTests", "+ /* not yet ported */ linuxPendingKitTests").replace(
            '            path: "Tests/GrafttyTests/Remote/SSH",',
            '            // path: "Tests/OldSSH",\n            path: "Tests/GrafttyTests/Remote/SSH",',
        )
        targets = self.targets(text)
        self.assertEqual(targets["GrafttyKitTests"].linux_exclude, ["Apple", "Web/PendingTests.swift"])
        self.assertEqual(targets["GrafttyDirectSSHTests"].directory, "Tests/GrafttyTests/Remote/SSH")

    def test_comment_markers_inside_strings_are_kept(self) -> None:
        text = 'let x = 1\n.testTarget(name: "T", exclude: isLinux ? ["a//b.swift", "c/*d*/.swift"] : [])\n'
        self.assertEqual(lint.parse_targets(text)[0].linux_exclude, ["a//b.swift", "c/*d*/.swift"])

    def test_nested_target_dependency_stays_inside_its_owner(self) -> None:
        text = FIXTURE_PACKAGE.replace('dependencies: ["GrafttyKit", "GrafttyProtocol",', 'dependencies: [.target(name: "GrafttyKit"), "GrafttyProtocol",')
        targets = self.targets(text)
        self.assertNotIn("GrafttyKit", targets)
        self.assertEqual(targets["GrafttyKitTests"].directory, "Tests/GrafttyKitTests")

    def test_unsupported_linux_membership_expression_is_an_error(self) -> None:
        text = FIXTURE_PACKAGE.replace('exclude: isLinux ? ["Apple"] + linuxPendingKitTests : [],', 'exclude: isLinux ? linuxPendingKitTests + ["Apple"] : [],')
        with self.assertRaises(ValueError):
            lint.parse_targets(text)

    def test_grouped_linux_expression_is_an_error(self) -> None:
        # Codex re-review of #654: grouping used to take the target out of the check.
        text = FIXTURE_PACKAGE.replace('exclude: isLinux ? ["Apple"] + linuxPendingKitTests : [],', 'exclude: (isLinux ? ["Apple"] + linuxPendingKitTests : []),')
        with self.assertRaises(ValueError):
            lint.parse_targets(text)

    def test_supported_argument_does_not_validate_an_unsupported_one(self) -> None:
        text = FIXTURE_PACKAGE.replace(
            'exclude: isLinux ? ["Apple"] + linuxPendingKitTests : [],',
            'sources: isLinux ? ["Teams"] : nil,\n            exclude: isLinux ? linuxPendingKitTests + ["Apple"] : [],',
        )
        with self.assertRaises(ValueError):
            lint.parse_targets(text)

    def test_composed_constant_initializer_is_an_error(self) -> None:
        text = FIXTURE_PACKAGE.replace("// not ported yet\n]", "\n] + [\"DeletedTests.swift\"]")
        self.assertIn('] + ["DeletedTests.swift"]', text)
        with self.assertRaises(ValueError):
            lint.parse_targets(text)

    def test_constant_continued_on_the_next_line_is_an_error(self) -> None:
        for tail in ('\n]\n    + ["DeletedTests.swift"]', '\n]\n    .map { _ in "DeletedTests.swift" }'):
            with self.subTest(tail=tail), self.assertRaises(ValueError):
                lint.parse_targets(FIXTURE_PACKAGE.replace("// not ported yet\n]", tail))

    def test_real_package_swift_excludes_apple_dir_from_kit_tests(self) -> None:
        targets = {t.name: t for t in lint.parse_targets((lint.REPO_ROOT / "Package.swift").read_text())}
        self.assertIn("Apple", targets["GrafttyKitTests"].linux_exclude)
        self.assertIsNone(targets["GrafttyKitTests"].linux_sources)
        self.assertIn("Updater", targets["GrafttyKit"].linux_exclude)
        self.assertEqual(targets["GrafttyDirectSSHTests"].directory, "Tests/GrafttyTests/Remote/SSH")


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

    def test_guard_must_wrap_the_rest_of_the_file(self) -> None:
        # A conditional import followed by portable tests still runs on Linux.
        self.assertFalse(self.check("import Testing\n#if canImport(AppKit)\nimport AppKit\n#endif\n\nstruct Portable {}\n"))
        self.assertFalse(self.check("#if os(macOS)\nstruct A {}\n#else\nstruct LinuxOnly {}\n#endif\n"))
        self.assertFalse(self.check("#if os(macOS)\nstruct A {}\n#elseif os(Linux)\nstruct B {}\n#endif\n"))

    def test_nested_conditionals_inside_the_guard_count(self) -> None:
        self.assertTrue(self.check("#if os(macOS)\n#if DEBUG\nstruct A {}\n#else\nstruct B {}\n#endif\nstruct C {}\n#endif // os(macOS)\n// end\n"))

    def test_disjunction_with_a_non_apple_platform_does_not_count(self) -> None:
        self.assertFalse(self.check("#if os(macOS) || os(Linux)\nstruct A {}\n#endif\n"))
        self.assertFalse(self.check("#if canImport(AppKit) || canImport(Glibc)\nstruct A {}\n#endif\n"))
        self.assertTrue(self.check("#if os(macOS) || os(iOS)\nstruct A {}\n#endif\n"))

    def test_spi_import_before_guard_is_skipped(self) -> None:
        self.assertTrue(self.check("@_spi(Testing) @testable import GrafttyKit\n#if os(macOS)\nstruct A {}\n#endif\n"))

    def test_block_comment_opener_inside_line_comment_is_ignored(self) -> None:
        self.assertTrue(self.check("// Matches Tests/*.swift\nimport Testing\n#if os(macOS)\nstruct A {}\n/* note */\n#endif\n"))


class CheckTreeTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        (self.root / "Package.swift").write_text(FIXTURE_PACKAGE)
        write(self.root, "Sources/GrafttyProtocol/UI/View.swift")
        kit = "Tests/GrafttyKitTests"
        write(self.root, f"{kit}/Teams/TeamInboxTests.swift")
        write(self.root, f"{kit}/Web/PendingTests.swift")
        write(self.root, f"{kit}/Apple/ThumbnailTests.swift")
        write(self.root, f"{kit}/UI/SidebarTests.swift", GUARDED)
        legacy = "Tests/LegacyTests"
        for rel in ("Ports/PortBindingTests.swift", "Teams/TeamInboxTests.swift"):
            write(self.root, f"{legacy}/{rel}")
        write(self.root, f"{legacy}/UI/SidebarTests.swift", GUARDED)
        write(self.root, f"{legacy}/Apple/ThumbnailTests.swift")
        write(self.root, "Tests/GrafttyTests/Remote/SSH/DirectSSHLoopbackTests.swift")
        write(self.root, "Tests/GrafttyTests/Remote/SSH/MacOnlySSHTests.swift")
        # A target without Linux membership is never inspected.
        write(self.root, "Tests/GrafttyHostTests/AnythingTests.swift")

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def edit_package(self, old: str, new: str) -> None:
        text = (self.root / "Package.swift").read_text()
        self.assertIn(old, text)
        (self.root / "Package.swift").write_text(text.replace(old, new))

    def problems(self) -> list[str]:
        return lint.check_tree(self.root)

    def assert_one_problem(self, *fragments: str) -> None:
        problems = self.problems()
        self.assertEqual(len(problems), 1, problems)
        for fragment in fragments:
            self.assertIn(fragment, problems[0])

    def test_clean_tree_passes(self) -> None:
        self.assertEqual(self.problems(), [])

    # exclude convention

    def test_new_kit_test_file_needs_no_listing(self) -> None:
        write(self.root, "Tests/GrafttyKitTests/Persistence/JSONStoreCompatibilityTests.swift")
        self.assertEqual(self.problems(), [])

    def test_stale_pending_entry_fails(self) -> None:
        (self.root / "Tests/GrafttyKitTests/Web/PendingTests.swift").unlink()
        self.assert_one_problem("Web/PendingTests.swift", "does not exist")

    def test_missing_excluded_directory_fails(self) -> None:
        (self.root / "Tests/GrafttyKitTests/Apple/ThumbnailTests.swift").unlink()
        (self.root / "Tests/GrafttyKitTests/Apple").rmdir()
        self.assert_one_problem("Tests/GrafttyKitTests/Apple", "does not exist")

    def test_pending_entry_that_is_now_guarded_fails(self) -> None:
        write(self.root, "Tests/GrafttyKitTests/Web/PendingTests.swift", GUARDED)
        self.assert_one_problem("Web/PendingTests.swift", "Apple-only `#if`")

    def test_pending_entry_under_apple_dir_fails(self) -> None:
        self.edit_package('"Web/PendingTests.swift",', '"Web/PendingTests.swift", "Apple/ThumbnailTests.swift",')
        self.assert_one_problem("Apple/ThumbnailTests.swift", "already covered by `Apple`")

    def test_excluded_subdirectory_of_excluded_directory_fails(self) -> None:
        write(self.root, "Tests/GrafttyKitTests/Apple/Sub/OtherTests.swift")
        self.edit_package('"Web/PendingTests.swift",', '"Web/PendingTests.swift", "Apple/Sub",')
        self.assert_one_problem("Apple/Sub", "already covered by `Apple`")

    def test_excluded_directory_of_guarded_files_fails(self) -> None:
        write(self.root, "Tests/GrafttyKitTests/Mac/OnlyTests.swift", GUARDED)
        self.edit_package('"Web/PendingTests.swift",', '"Web/PendingTests.swift", "Mac",')
        self.assert_one_problem("Tests/GrafttyKitTests/Mac", "every Swift file in it")

    def test_source_target_exclude_resolves_under_sources(self) -> None:
        (self.root / "Sources/GrafttyProtocol/UI/View.swift").unlink()
        (self.root / "Sources/GrafttyProtocol/UI").rmdir()
        self.assert_one_problem("Sources/GrafttyProtocol/UI", "does not exist")

    # sources: allowlist

    def test_reproduces_526_unlisted_portable_file(self) -> None:
        write(self.root, "Tests/LegacyTests/Persistence/JSONStoreCompatibilityTests.swift")
        self.assert_one_problem("Tests/LegacyTests/Persistence/JSONStoreCompatibilityTests.swift", "not in the Linux `sources:` allowlist")

    def test_listed_path_missing_from_tree_fails(self) -> None:
        (self.root / "Tests/LegacyTests/Teams/TeamInboxTests.swift").unlink()
        self.assert_one_problem("Teams/TeamInboxTests.swift", "does not exist")

    def test_listed_file_under_apple_dir_fails(self) -> None:
        self.edit_package('"Teams/TeamInboxTests.swift"]', '"Teams/TeamInboxTests.swift", "Apple/ThumbnailTests.swift"]')
        self.assert_one_problem("Apple/ThumbnailTests.swift", "Apple/ directory")

    def test_listed_file_wrapped_in_apple_guard_fails(self) -> None:
        write(self.root, "Tests/LegacyTests/Teams/TeamInboxTests.swift", GUARDED)
        self.assert_one_problem("Teams/TeamInboxTests.swift", "compiles to nothing on Linux")

    def test_listed_directory_covers_its_files(self) -> None:
        self.edit_package('"Teams/TeamInboxTests.swift"]', '"Teams"]')
        write(self.root, "Tests/LegacyTests/Teams/TeamPresenceTests.swift")
        self.assertEqual(self.problems(), [])

    # fixed sources: under a path: override

    def test_fixed_source_missing_under_path_override_fails(self) -> None:
        (self.root / "Tests/GrafttyTests/Remote/SSH/DirectSSHLoopbackTests.swift").unlink()
        self.assert_one_problem("Tests/GrafttyTests/Remote/SSH/DirectSSHLoopbackTests.swift", "does not exist")

    def test_fixed_source_wrapped_in_apple_guard_fails(self) -> None:
        write(self.root, "Tests/GrafttyTests/Remote/SSH/DirectSSHLoopbackTests.swift", GUARDED)
        self.assert_one_problem("DirectSSHLoopbackTests.swift", "compiles to nothing on Linux")


class RealTreeTests(unittest.TestCase):
    def test_repository_passes(self) -> None:
        self.assertEqual(lint.check_tree(lint.REPO_ROOT), [])


if __name__ == "__main__":
    unittest.main()
