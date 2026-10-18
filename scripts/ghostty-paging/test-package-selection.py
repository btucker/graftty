#!/usr/bin/env python3
"""Evaluate the real package manifest with small renderer fixtures, without resolving dependencies."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class RendererSelectionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="graftty-renderer-selection-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        shutil.copy(ROOT / "Package.swift", self.root)
        self.patches = self.root / "scripts/ghostty-paging"
        self.patches.mkdir(parents=True)
        for path in (ROOT / "scripts/ghostty-paging").iterdir():
            if path.suffix in (".patch", ".json"):
                shutil.copy(path, self.patches)
        self.local = self.root / ".dependencies/libghostty-spm"
        self.env = dict(os.environ)
        self.env.pop("GRAFTTY_GHOSTTY_PACKAGE_PATH", None)
        self.env.pop("GRAFTTY_REQUIRE_PAGED_HISTORY", None)

    def package(self):
        self.local.mkdir(parents=True)
        (self.local / "Package.swift").write_text("// fixture\n")
        recipe = json.loads((self.patches / "recipe.json").read_text())
        lines = [f"{key} {recipe[key]}" for key in ("renderer", "wrapper", "zig")]
        lines.append("arm64_only true")
        for name in recipe["rendererPatches"] + recipe["wrapperPatches"]:
            digest = hashlib.sha256((self.patches / (name + ".patch")).read_bytes()).hexdigest()
            lines.append(f"{digest}  {name}.patch")
        (self.local / "PAGING-BUILD.txt").write_text("\n".join(lines) + "\n")
        header = self.local / "BinaryTarget/GhosttyKit.xcframework/macos-arm64/Headers/libghostty/ghostty.h"
        header.parent.mkdir(parents=True)
        header.write_text("// renderer header\n")
        return header

    def manifest(self, success=True):
        result = subprocess.run(["swift", "package", "--manifest-cache", "none", "--package-path", str(self.root), "dump-package"],
                                env=self.env, capture_output=True, text=True, timeout=60)
        if not success:
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn("paging renderer", result.stderr.lower())
            return
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        dependency = next(d for d in data["dependencies"] if "libghostty-spm" in json.dumps(d))
        settings = next(t["settings"] for t in data["targets"] if t["name"] == "Graftty")
        return dependency, json.dumps(settings), result.stderr

    def test_clean_checkout_uses_published(self):
        dependency, settings, _ = self.manifest()
        self.assertIn("sourceControl", dependency)
        self.assertNotIn("GRAFTTY_PAGED_HISTORY", settings)

    def test_stale_auto_package_falls_back_with_diagnostic(self):
        self.package()
        stamp = self.local / "PAGING-BUILD.txt"
        stamp.write_text("\n".join(line for line in stamp.read_text().splitlines() if "source-grid" not in line))
        dependency, settings, diagnostic = self.manifest()
        self.assertIn("sourceControl", dependency)
        self.assertNotIn("GRAFTTY_PAGED_HISTORY", settings)
        self.assertIn("Ignoring auto-discovered paging renderer", diagnostic)

    def test_patch_change_invalidates_explicit_package(self):
        self.package()
        self.env["GRAFTTY_GHOSTTY_PACKAGE_PATH"] = str(self.local)
        with (self.patches / "source-grid.patch").open("a") as output:
            output.write("\nchanged patch\n")
        self.manifest(success=False)

    def test_explicit_stale_package_is_rejected(self):
        self.package()
        (self.local / "PAGING-BUILD.txt").unlink()
        self.env["GRAFTTY_GHOSTTY_PACKAGE_PATH"] = str(self.local)
        self.manifest(success=False)

    def test_valid_package_enables_paging_and_distinct_module_signature(self):
        _, published, _ = self.manifest()
        header = self.package()
        self.env["GRAFTTY_GHOSTTY_PACKAGE_PATH"] = str(self.local)
        dependency, local, _ = self.manifest()
        self.assertIn("fileSystem", dependency)
        self.assertIn("GRAFTTY_PAGED_HISTORY", local)
        self.assertIn("GRAFTTY_RENDERER_", published)
        self.assertIn("GRAFTTY_RENDERER_", local)
        self.assertNotEqual(published, local)
        header.write_text("// rebuilt header with a different API\n")
        _, rebuilt, _ = self.manifest()
        self.assertNotEqual(local, rebuilt)

    def test_valid_auto_package_is_also_ignored(self):
        self.package()
        dependency, settings, diagnostic = self.manifest()
        self.assertIn("sourceControl", dependency)
        self.assertNotIn("GRAFTTY_PAGED_HISTORY", settings)
        self.assertIn("Ignoring auto-discovered paging renderer", diagnostic)

    def test_explicit_empty_disables_auto_package(self):
        self.package()
        self.env["GRAFTTY_GHOSTTY_PACKAGE_PATH"] = ""
        dependency, settings, _ = self.manifest()
        self.assertIn("sourceControl", dependency)
        self.assertNotIn("GRAFTTY_PAGED_HISTORY", settings)

    def test_required_paging_rejects_fallback(self):
        self.env["GRAFTTY_REQUIRE_PAGED_HISTORY"] = "1"
        self.manifest(success=False)
        self.package()
        self.env["GRAFTTY_GHOSTTY_PACKAGE_PATH"] = str(self.local)
        dependency, settings, _ = self.manifest()
        self.assertIn("fileSystem", dependency)
        self.assertIn("GRAFTTY_PAGED_HISTORY", settings)


class ReleaseSelectionTests(unittest.TestCase):
    def test_bundle_requires_explicit_paging_before_build(self):
        with tempfile.TemporaryDirectory(prefix="graftty-release-selection-") as directory:
            root = Path(directory)
            (root / "scripts").mkdir()
            shutil.copy(ROOT / "scripts/bundle.sh", root / "scripts")
            tools = root / "tools"
            tools.mkdir()
            swift = tools / "swift"
            swift.write_text("#!/bin/bash\n" +
                             'echo "path=$GRAFTTY_GHOSTTY_PACKAGE_PATH require=$GRAFTTY_REQUIRE_PAGED_HISTORY args=$*"\nexit 37\n')
            swift.chmod(0o755)
            env = {**os.environ, "PATH": str(tools) + os.pathsep + os.environ["PATH"],
                   "CONFIGURATION": "release", "GRAFTTY_BUILD_VERSION": "1",
                   "SPARKLE_PUBLIC_ED_KEY": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}
            env.pop("GRAFTTY_GHOSTTY_PACKAGE_PATH", None)
            result = subprocess.run(["bash", str(root / "scripts/bundle.sh")], env=env,
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 37, result.stdout + result.stderr)
            self.assertIn(f"path={root}/.dependencies/libghostty-spm require=1", result.stdout)
            self.assertIn("--manifest-cache none", result.stdout)


if __name__ == "__main__":
    unittest.main()
