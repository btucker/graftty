#!/usr/bin/env python3
"""Verify that patch validation fails before modifying an already patched tree."""
import pathlib
import subprocess
import sys
import tempfile
import unittest


class PatchApplicationTests(unittest.TestCase):
    def assert_repeat_preserves_existing_patch(self, remove_module):
        apply = pathlib.Path(__file__).with_name("apply.py")
        with tempfile.TemporaryDirectory(prefix="graftty-codex-patch-") as directory:
            source = pathlib.Path(directory)
            root = source / "codex-rs/tui/src"
            (root / "app").mkdir(parents=True)
            (root / "lib.rs").write_text("mod branch_summary;\n")
            (root / "app/history_ui.rs").write_text(
                "    pub(super) fn open_url_in_browser(&mut self, url: String) {\n"
                "        native_open(&url);\n    }\n"
            )
            def run(*args):
                return subprocess.run([sys.executable, str(apply), *args, str(source)],
                                      capture_output=True, text=True, timeout=5)
            first = run()
            self.assertEqual(first.returncode, 0, first.stderr)
            if remove_module:
                (root / "browser_command.rs").unlink()
            before = {p: p.read_bytes() for p in root.rglob("*.rs")}
            second = run()
            self.assertNotEqual(second.returncode, 0, "Repeated patch silently modified source")
            self.assertEqual(before, {p: p.read_bytes() for p in root.rglob("*.rs")})
            check = run("--check")
            if not remove_module:
                self.assertEqual(check.returncode, 0, check.stderr)

    def test_second_application_preserves_existing_patch(self):
        self.assert_repeat_preserves_existing_patch(False)

    def test_partial_application_is_rejected_without_more_changes(self):
        self.assert_repeat_preserves_existing_patch(True)


if __name__ == "__main__":
    unittest.main()
