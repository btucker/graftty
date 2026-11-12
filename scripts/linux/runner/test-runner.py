#!/usr/bin/env python3
"""Check the archive-to-image boundary without a Docker daemon."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent


class RunnerBuildTests(unittest.TestCase):
    def test_architecture_and_private_build_context(self):
        for architecture, platform in (("x86_64", "linux/amd64"), ("aarch64", "linux/arm64")):
            with self.subTest(architecture=architecture), tempfile.TemporaryDirectory() as directory:
                scratch = Path(directory)
                archive = scratch / f"graftty-linux-1.2.3-{architecture}.tar.gz"
                archive.write_bytes(b"fixture archive")
                (scratch / "private-key").write_text("must never enter the context")
                record = scratch / "record.json"
                docker = scratch / "docker"
                docker.write_text(f"#!{sys.executable}\n" + """
import json, os, pathlib, sys
context = pathlib.Path(sys.argv[-1])
pathlib.Path(os.environ['RECORD']).write_text(json.dumps({
    'args': sys.argv[1:], 'context': str(context),
    'files': sorted(p.name for p in context.iterdir()),
    'archive': (context / 'graftty-linux.tar.gz').read_text(),
}))
""")
                docker.chmod(0o755)
                result = subprocess.run(["bash", str(ROOT / "build.sh"), str(archive), "graftty-runner:test"],
                                        env={**os.environ, "PATH": str(scratch) + os.pathsep + os.environ["PATH"],
                                             "RECORD": str(record)}, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                built = json.loads(record.read_text())
                self.assertEqual(built["args"][:-1], ["build", "--platform", platform, "--tag", "graftty-runner:test"])
                self.assertEqual(built["files"], ["Dockerfile", "graftty-linux.tar.gz"])
                self.assertEqual(built["archive"], "fixture archive")
                self.assertFalse(Path(built["context"]).exists(), "Temporary build context was left behind")

    def test_rejects_unknown_architecture(self):
        result = subprocess.run(["bash", str(ROOT / "build.sh"), "/tmp/graftty-linux-1.2.3-mips.tar.gz"],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 64)
        self.assertIn("architecture", result.stderr)


class RunnerTagTests(unittest.TestCase):
    def test_full_versions_and_latest(self):
        for version, tags in (("v1.2.3", ["1.2.3", "latest"]),
                              ("v1.2.3-beta.2", ["1.2.3-beta.2"]),
                              ("v1.2.3+notarized.1", ["1.2.3_notarized.1", "latest"]),
                              ("v1.2.3-beta.2+build.4", ["1.2.3-beta.2_build.4"])):
            with self.subTest(version=version):
                result = subprocess.run(["bash", str(ROOT / "tags.sh"), version], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.splitlines(), tags)

    def test_invalid_versions_do_not_publish_tags(self):
        for version in ("latest", "../escape", "v1.2.3-beta.01", "v1.2.3+" + "x" * 128):
            with self.subTest(version=version):
                result = subprocess.run(["bash", str(ROOT / "tags.sh"), version], capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
