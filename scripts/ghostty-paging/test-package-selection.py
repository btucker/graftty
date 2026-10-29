#!/usr/bin/env python3
"""Evaluate the real package manifest with small renderer fixtures, without resolving dependencies."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
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
        self.local = self.root / ".dependencies/libghostty-spm"
        self.env = dict(os.environ)
        self.env.pop("GRAFTTY_GHOSTTY_PACKAGE_PATH", None)
        self.env.pop("GRAFTTY_REQUIRE_PAGED_HISTORY", None)

    def package(self):
        self.local.mkdir(parents=True)
        (self.local / "Package.swift").write_text('// fixture path: "BinaryTarget/GhosttyKit.xcframework"\n')
        header = self.local / "BinaryTarget/GhosttyKit.xcframework/macos-arm64/Headers/libghostty/ghostty.h"
        header.parent.mkdir(parents=True)
        header.write_text("// renderer header\n")
        (self.local / "Paging").mkdir()
        (self.local / "Paging/recipe.json").write_text('{"snapshotABI":"ghostty-8af6897c-paging-1"}')
        (self.local / 'Sources').mkdir()
        (self.local / 'Sources/Wrapper.swift').write_text('// wrapper\n')
        self.receipt()
        return header

    def receipt(self):
        def hashes(directory):
            return {str(path.relative_to(directory)): hashlib.sha256(path.read_bytes()).hexdigest()
                    for path in directory.rglob("*") if path.is_file()}
        receipt = {"schemaVersion": 1, "snapshotABI": "ghostty-8af6897c-paging-1",
                   "inputs": {"Paging/recipe.json": hashlib.sha256((self.local / "Paging/recipe.json").read_bytes()).hexdigest()},
                   "wrapperInputs": {"Sources/Wrapper.swift": hashlib.sha256((self.local / "Sources/Wrapper.swift").read_bytes()).hexdigest()},
                   "artifacts": hashes(self.local / "BinaryTarget/GhosttyKit.xcframework")}
        (self.local / "PAGING-BUILD.json").write_text(json.dumps(receipt))

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

    def test_compiler_context_is_forwarded_to_dependency_builds(self):
        spec = importlib.util.spec_from_file_location("compiler_context", ROOT / "scripts/ghostty-paging/compiler-context.py")
        context = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(context)
        result = subprocess.run(["swift", "package", "--manifest-cache", "none", "--package-path", str(self.root), "dump-package"],
                                env=self.env, capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        flag = context.compiler_context(json.loads(result.stdout))
        self.assertTrue(flag.startswith("-DGRAFTTY_RENDERER_published_"))
        tools = self.root / "tools"
        tools.mkdir()
        shutil.copy(ROOT / "scripts/swiftpm", self.root / "scripts/swiftpm")
        shutil.copy(ROOT / "scripts/ghostty-paging/compiler-context.py", self.patches)
        manifest = self.root / "dump.json"
        manifest.write_text(result.stdout)
        invocation = self.root / "invocation.json"
        swift = tools / "swift"
        swift.write_text(f"#!{sys.executable}\n" +
                         "import json, sys\nfrom pathlib import Path\n" +
                         f"if sys.argv[1] == 'package': print(Path({str(manifest)!r}).read_text())\n" +
                         f"else: Path({str(invocation)!r}).write_text(json.dumps(sys.argv[1:]))\n")
        swift.chmod(0o755)
        git = tools / "git"
        git.write_text(f"#!{sys.executable}\nprint({str(self.root)!r})\n")
        git.chmod(0o755)
        env = {**self.env, "PATH": str(tools) + os.pathsep + self.env["PATH"],
               "GRAFTTY_SWIFTPM_SHARED_DIR": str(self.root / "cache")}
        built = subprocess.run([str(self.root / "scripts/swiftpm"), "build", "--product", "Graftty"],
                               env=env, capture_output=True, text=True, timeout=20)
        self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
        arguments = json.loads(invocation.read_text())
        self.assertEqual(arguments[arguments.index("-Xcc") + 1], flag)
        self.assertEqual(arguments[-2:], ["--product", "Graftty"])

    def test_clean_checkout_uses_published(self):
        dependency, settings, _ = self.manifest()
        self.assertIn("sourceControl", dependency)
        self.assertIn("GRAFTTY_PAGED_HISTORY", settings)

    def test_stale_auto_package_falls_back_with_diagnostic(self):
        self.package()
        stamp = self.local / "PAGING-BUILD.json"
        stamp.write_text("stale")
        dependency, settings, diagnostic = self.manifest()
        self.assertIn("sourceControl", dependency)
        self.assertIn("GRAFTTY_PAGED_HISTORY", settings)
        self.assertIn("Ignoring auto-discovered paging renderer", diagnostic)

    def test_patch_change_invalidates_explicit_package(self):
        self.package()
        self.env["GRAFTTY_GHOSTTY_PACKAGE_PATH"] = str(self.local)
        with (self.local / "Paging/recipe.json").open("a") as output:
            output.write("\nchanged patch\n")
        self.manifest(success=False)

    def test_unrecorded_wrapper_file_is_rejected(self):
        self.package()
        (self.local / 'Sources/NewFile.swift').write_text('// unrecorded wrapper\n')
        self.env['GRAFTTY_GHOSTTY_PACKAGE_PATH'] = str(self.local)
        self.manifest(success=False)

    def test_remote_binary_manifest_cannot_bypass_local_receipt(self):
        self.package()
        (self.local / "Package.swift").write_text('// remote binary target\n')
        self.env["GRAFTTY_GHOSTTY_PACKAGE_PATH"] = str(self.local)
        self.manifest(success=False)

    def test_binary_tampering_is_rejected(self):
        header = self.package()
        header.write_text("tampered")
        self.env["GRAFTTY_GHOSTTY_PACKAGE_PATH"] = str(self.local)
        self.manifest(success=False)

    def test_explicit_stale_package_is_rejected(self):
        self.package()
        (self.local / "PAGING-BUILD.json").unlink()
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
        self.receipt()
        _, rebuilt, _ = self.manifest()
        self.assertNotEqual(local, rebuilt)

    def test_identical_header_replaced_within_one_second_changes_signature(self):
        header = self.package()
        self.env["GRAFTTY_GHOSTTY_PACKAGE_PATH"] = str(self.local)
        os.utime(header, ns=(1_700_000_000_100_000_000, 1_700_000_000_100_000_000))
        _, before, _ = self.manifest()
        os.utime(header, ns=(1_700_000_000_900_000_000, 1_700_000_000_900_000_000))
        _, after, _ = self.manifest()
        self.assertNotEqual(before, after)

    def test_valid_auto_package_is_also_ignored(self):
        self.package()
        dependency, settings, diagnostic = self.manifest()
        self.assertIn("sourceControl", dependency)
        self.assertIn("GRAFTTY_PAGED_HISTORY", settings)
        self.assertIn("Ignoring auto-discovered paging renderer", diagnostic)

    def test_explicit_empty_disables_auto_package(self):
        self.package()
        self.env["GRAFTTY_GHOSTTY_PACKAGE_PATH"] = ""
        dependency, settings, _ = self.manifest()
        self.assertIn("sourceControl", dependency)
        self.assertIn("GRAFTTY_PAGED_HISTORY", settings)

    def test_required_paging_uses_published_or_valid_local(self):
        self.env["GRAFTTY_REQUIRE_PAGED_HISTORY"] = "1"
        dependency, settings, _ = self.manifest()
        self.assertIn("sourceControl", dependency)
        self.assertIn("GRAFTTY_PAGED_HISTORY", settings)
        self.package()
        self.env["GRAFTTY_GHOSTTY_PACKAGE_PATH"] = str(self.local)
        dependency, settings, _ = self.manifest()
        self.assertIn("fileSystem", dependency)
        self.assertIn("GRAFTTY_PAGED_HISTORY", settings)


class ReleaseSelectionTests(unittest.TestCase):
    def test_bundle_uses_published_paging_by_default(self):
        with tempfile.TemporaryDirectory(prefix="graftty-release-selection-") as directory:
            root = Path(directory)
            (root / "scripts").mkdir()
            shutil.copy(ROOT / "scripts/bundle.sh", root / "scripts")
            (root / "scripts/ghostty-paging").mkdir()
            shutil.copy(ROOT / "scripts/ghostty-paging/compiler-context.py", root / "scripts/ghostty-paging")
            tools = root / "tools"
            tools.mkdir()
            swift = tools / "swift"
            manifest = {"targets": [{"name": "Graftty", "settings": [
                {"kind": {"unsafeFlags": {"_0": ["-Xcc", "-DGRAFTTY_RENDERER_fixture"]}}}]}]}
            swift.write_text(f"#!{sys.executable}\n" +
                             "import os, sys\n" +
                             f"if sys.argv[1] == 'package': print({json.dumps(manifest)!r})\n" +
                             "else:\n" +
                             "    print('path=' + os.environ.get('GRAFTTY_GHOSTTY_PACKAGE_PATH', '') + ' require=' + os.environ['GRAFTTY_REQUIRE_PAGED_HISTORY'] + ' args=' + ' '.join(sys.argv[1:]))\n" +
                             "    sys.exit(37)\n")
            swift.chmod(0o755)
            env = {**os.environ, "PATH": str(tools) + os.pathsep + os.environ["PATH"],
                   "CONFIGURATION": "release", "GRAFTTY_BUILD_VERSION": "1",
                   "SPARKLE_PUBLIC_ED_KEY": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}
            env.pop("GRAFTTY_GHOSTTY_PACKAGE_PATH", None)
            result = subprocess.run(["bash", str(root / "scripts/bundle.sh")], env=env,
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 37, result.stdout + result.stderr)
            self.assertIn("path= require=1", result.stdout)
            self.assertIn("--manifest-cache none -Xcc -DGRAFTTY_RENDERER_fixture", result.stdout)


if __name__ == "__main__":
    unittest.main()
