#!/usr/bin/env python3
"""Evaluate the real package manifest against small .deps fixtures, without resolving dependencies."""
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
KEY = "a" * 64
HEADER = ".deps/GhosttyKit.xcframework/macos-arm64_x86_64/Headers/libghostty/ghostty.h"


def load_compiler_context():
    spec = importlib.util.spec_from_file_location("compiler_context", ROOT / "scripts/ghostty-paging/compiler-context.py")
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class RendererIdentityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="graftty-renderer-identity-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        shutil.copy(ROOT / "Package.swift", self.root)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("GRAFTTY_")}

    def prepare(self, key=KEY, mtime=1_700_000_000):
        (self.root / ".deps").mkdir(exist_ok=True)
        (self.root / ".deps/ghostty.key").write_text(f"{key} ios,macos\n")
        header = self.root / HEADER
        header.parent.mkdir(parents=True, exist_ok=True)
        header.write_text("// renderer header\n")
        os.utime(header, (mtime, mtime))

    def dump(self):
        return subprocess.run(["swift", "package", "--manifest-cache", "none", "--package-path", str(self.root),
                               "dump-package"], env=self.env, capture_output=True, text=True, timeout=120)

    def context(self):
        result = self.dump()
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads(result.stdout)
        return manifest, load_compiler_context().compiler_context(manifest)

    def test_unprepared_checkout_says_how_to_prepare(self):
        result = self.dump()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("scripts/deps prepare", result.stderr)

    def test_prepared_key_enables_paging_on_app_and_ghostty_targets(self):
        self.prepare()
        manifest, flag = self.context()
        self.assertTrue(flag.startswith("-DGRAFTTY_RENDERER_" + KEY[:32] + "_"), flag)
        for name in ("Graftty", "GhosttyKit", "GhosttyTerminal"):
            settings = json.dumps(next(t["settings"] for t in manifest["targets"] if t["name"] == name))
            self.assertIn(flag, settings, name)
            self.assertIn("GRAFTTY_PAGED_HISTORY", settings, name)
        binary = next(t for t in manifest["targets"] if t["name"] == "libghostty")
        self.assertEqual(binary["path"], ".deps/GhosttyKit.xcframework")
        self.assertFalse(any("libghostty-spm" in json.dumps(d) for d in manifest["dependencies"]))

    def test_key_or_header_change_changes_signature(self):
        self.prepare()
        _, original = self.context()
        self.prepare(key="b" * 64)
        _, rekeyed = self.context()
        self.prepare(mtime=1_700_000_001)
        _, rebuilt = self.context()
        self.assertEqual(len({original, rekeyed, rebuilt}), 3)

    def test_swiftpm_wrapper_prepares_then_forwards_context(self):
        self.prepare()
        manifest = self.dump()
        self.assertEqual(manifest.returncode, 0, manifest.stderr)
        flag = load_compiler_context().compiler_context(json.loads(manifest.stdout))
        scripts = self.root / "scripts/ghostty-paging"
        scripts.mkdir(parents=True)
        shutil.copy(ROOT / "scripts/swiftpm", self.root / "scripts/swiftpm")
        shutil.copy(ROOT / "scripts/ghostty-paging/compiler-context.py", scripts)
        log = self.root / "calls.log"
        deps = self.root / "scripts/deps"
        deps.write_text(f"#!/bin/sh\necho \"deps $*\" >> {log}\n")
        deps.chmod(0o755)
        tools = self.root / "tools"
        tools.mkdir()
        dump = self.root / "dump.json"
        dump.write_text(manifest.stdout)
        swift = tools / "swift"
        swift.write_text(f"#!{sys.executable}\n" +
                         "import json, sys\nfrom pathlib import Path\n" +
                         f"if sys.argv[1] == 'package': print(Path({str(dump)!r}).read_text())\n" +
                         f"else:\n    open({str(log)!r}, 'a').write('swift ' + json.dumps(sys.argv[1:]) + '\\n')\n")
        swift.chmod(0o755)
        git = tools / "git"
        git.write_text(f"#!/bin/sh\nif [ \"$1\" = rev-parse ]; then echo {self.root}; else exec /usr/bin/git \"$@\"; fi\n")
        git.chmod(0o755)
        env = {**self.env, "PATH": str(tools) + os.pathsep + self.env["PATH"],
               "GRAFTTY_SWIFTPM_SHARED_DIR": str(self.root / "cache")}
        built = subprocess.run([str(self.root / "scripts/swiftpm"), "build", "--product", "Graftty"],
                               env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
        calls = log.read_text().splitlines()
        self.assertEqual(calls[0], "deps prepare --platforms macos")
        arguments = json.loads(calls[-1].removeprefix("swift "))
        self.assertEqual(arguments[arguments.index("-Xcc") + 1], flag)
        self.assertEqual(arguments[-2:], ["--product", "Graftty"])


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0], *sys.argv[1:]])
