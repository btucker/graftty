#!/usr/bin/env python3
"""Exercise build locking with real lockf and no network or compiler work."""
import os
import pathlib
import signal
import subprocess
import tempfile
import textwrap
import time
import unittest


class BuildLockTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="graftty-codex-lock-")
        self.addCleanup(self.directory.cleanup)
        self.root = pathlib.Path(self.directory.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.build = pathlib.Path(__file__).with_name("build.sh")
        self.processes = []
        self.addCleanup(self.stop_processes)
        self.executable("rustup", """
            import os, pathlib
            root = pathlib.Path(os.environ['FIXTURE_ROOT'])
            (root / ('ready-' + os.environ['FIXTURE_LABEL'])).touch()
            print(root / 'bin/cargo')
        """)
        self.executable("git", """
            import os, pathlib, sys, time
            if sys.argv[1:2] != ['init']:
                raise SystemExit('Unexpected git command; network work is forbidden')
            root = pathlib.Path(os.environ['FIXTURE_ROOT'])
            label = os.environ['FIXTURE_LABEL']
            (root / ('entered-' + label)).touch()
            deadline = time.monotonic() + 15
            while not (root / ('release-' + label)).exists():
                if time.monotonic() >= deadline:
                    raise SystemExit('Fixture gate timed out')
                time.sleep(.01)
            # Stop before fetch, source patching, rustc, or cargo can execute.
            raise SystemExit(73)
        """)

    def executable(self, name, body):
        path = self.bin / name
        path.write_text("#!/usr/bin/python3\n" + textwrap.dedent(body).lstrip())
        path.chmod(0o700)

    def launch(self, label, cache, output):
        env = {
            "PATH": str(self.bin) + ":/usr/bin:/bin",
            "HOME": str(self.root),
            "FIXTURE_ROOT": str(self.root),
            "FIXTURE_LABEL": label,
        }
        process = subprocess.Popen(
            ["/bin/bash", str(self.build), str(cache), str(output)],
            env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, start_new_session=True,
        )
        self.processes.append(process)
        return process

    def wait_for(self, name, process):
        deadline = time.monotonic() + 5
        while not (self.root / name).exists():
            if process.poll() is not None:
                self.fail("Build exited before " + name + ": " + process.communicate()[0])
            if time.monotonic() >= deadline:
                self.fail("Build did not reach " + name)
            time.sleep(.01)

    def stop_processes(self):
        for process in self.processes:
            if process.poll() is None:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            process.communicate(timeout=5)

    def assert_serialized(self, first_cache, second_cache, first_output, second_output):
        first = self.launch("first", first_cache, first_output)
        self.wait_for("entered-first", first)
        second = self.launch("second", second_cache, second_output)
        self.wait_for("ready-second", second)
        # The second command has completed its toolchain preflight and has time
        # to reach git if no lock protects the shared resource.
        time.sleep(.3)
        self.assertIsNone(second.poll(), "Contending build exited rather than waiting")
        self.assertFalse((self.root / "entered-second").exists(),
                         "Second build accessed shared artifacts before the first released its lock")
        (self.root / "release-first").touch()
        first_log = first.communicate(timeout=5)[0]
        self.assertEqual(first.returncode, 73, first_log)
        self.wait_for("entered-second", second)
        (self.root / "release-second").touch()
        second_log = second.communicate(timeout=5)[0]
        self.assertEqual(second.returncode, 73, second_log)

    def test_shared_cache_serializes_distinct_outputs(self):
        cache = self.root / "cache"
        self.assert_serialized(cache, cache, self.root / "output-first", self.root / "output-second")

    def test_shared_output_serializes_distinct_caches(self):
        output = self.root / "output"
        self.assert_serialized(self.root / "cache-first", self.root / "cache-second", output, output)


if __name__ == "__main__":
    unittest.main()
