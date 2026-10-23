#!/usr/bin/env python3
"""Exercise build locking with real lockf and no network or compiler work.

The checks are ordering-based, not timed: the first build signals that it
holds the lock, the second is observed blocked inside `lockf`, and only then
is the first released. A build that enters the guarded section while the
other still holds it records the overlap itself. Waits end on the event or on
the build exiting; HANG_GUARD only turns a wedged fixture into a failure.
"""
import os
import pathlib
import signal
import subprocess
import tempfile
import textwrap
import time
import unittest

# Not a timing budget: a healthy run never comes near it.
HANG_GUARD = 120


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
            import os, pathlib, time
            root = pathlib.Path(os.environ['FIXTURE_ROOT'])
            # Lets a run simulate a loaded runner without changing the checks.
            time.sleep(float(os.environ.get('FIXTURE_START_DELAY', '0')))
            (root / ('ready-' + os.environ['FIXTURE_LABEL'])).touch()
            print(root / 'bin/cargo')
        """)
        self.executable("git", """
            import os, pathlib, sys, time
            if sys.argv[1:2] != ['init']:
                raise SystemExit('Unexpected git command; network work is forbidden')
            root = pathlib.Path(os.environ['FIXTURE_ROOT'])
            label = os.environ['FIXTURE_LABEL']
            other = os.environ.get('FIXTURE_HOLDER')
            # Entering while the other build has not been released means the
            # lock did not serialize the two.
            if other and not (root / ('release-' + other)).exists():
                (root / ('overlap-' + label)).touch()
            (root / ('entered-' + label)).touch()
            deadline = time.monotonic() + float(os.environ['FIXTURE_HANG_GUARD'])
            while not (root / ('release-' + label)).exists():
                if time.monotonic() >= deadline:
                    raise SystemExit('Fixture gate was never released')
                time.sleep(.01)
            # Stop before fetch, source patching, rustc, or cargo can execute.
            raise SystemExit(73)
        """)

    def executable(self, name, body):
        path = self.bin / name
        path.write_text("#!/usr/bin/python3\n" + textwrap.dedent(body).lstrip())
        path.chmod(0o700)

    def launch(self, label, cache, output, holder=None):
        env = {
            "PATH": str(self.bin) + ":/usr/bin:/bin",
            "HOME": str(self.root),
            "FIXTURE_ROOT": str(self.root),
            "FIXTURE_LABEL": label,
            "FIXTURE_HANG_GUARD": str(HANG_GUARD),
            "FIXTURE_START_DELAY": os.environ.get("FIXTURE_START_DELAY", "0"),
        }
        if holder:
            env["FIXTURE_HOLDER"] = holder
        process = subprocess.Popen(
            ["/bin/bash", str(self.build), str(cache), str(output)],
            env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, start_new_session=True,
        )
        self.processes.append(process)
        return process

    def wait_until(self, description, process, condition):
        """Polls `condition` until it holds; fails if `process` exits first."""
        guard = time.monotonic() + HANG_GUARD
        while not condition():
            if process.poll() is not None:
                self.fail("Build exited before " + description + ": " + process.communicate()[0])
            if time.monotonic() >= guard:
                self.fail("Fixture hung waiting for " + description)
            time.sleep(.01)

    def marker(self, name):
        return lambda: (self.root / name).exists()

    def blocked_in_lockf(self, process):
        """True once every leaf process in the build's session is a waiting
        `lockf`: it has not yet acquired its lock and started its command."""
        def check():
            table = subprocess.run(["/bin/ps", "-A", "-o", "pid=,ppid=,pgid=,comm="],
                                   capture_output=True, text=True, check=True).stdout
            rows = [line.split(None, 3) for line in table.splitlines() if line.strip()]
            group = [row for row in rows if len(row) == 4 and int(row[2]) == process.pid]
            parents = {int(row[1]) for row in group}
            leaves = [row for row in group if int(row[0]) not in parents]
            return bool(leaves) and all(row[3].endswith("lockf") for row in leaves)
        return check

    def stop_processes(self):
        for process in self.processes:
            if process.poll() is None:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            process.communicate(timeout=HANG_GUARD)

    def assert_serialized(self, first_cache, second_cache, first_output, second_output):
        first = self.launch("first", first_cache, first_output)
        self.wait_until("entered-first", first, self.marker("entered-first"))
        second = self.launch("second", second_cache, second_output, holder="first")
        # Contended: the second build waits in lockf. Unprotected, it would
        # enter instead and record the overlap.
        self.wait_until("second build waiting on the lock", second,
                        lambda: self.blocked_in_lockf(second)() or self.marker("entered-second")())
        self.assertFalse((self.root / "overlap-second").exists(),
                         "Second build accessed shared artifacts before the first released its lock")
        (self.root / "release-first").touch()
        first_log = first.communicate(timeout=HANG_GUARD)[0]
        self.assertEqual(first.returncode, 73, first_log)
        self.wait_until("entered-second", second, self.marker("entered-second"))
        self.assertFalse((self.root / "overlap-second").exists(),
                         "Second build accessed shared artifacts before the first released its lock")
        (self.root / "release-second").touch()
        second_log = second.communicate(timeout=HANG_GUARD)[0]
        self.assertEqual(second.returncode, 73, second_log)

    def test_shared_cache_serializes_distinct_outputs(self):
        cache = self.root / "cache"
        self.assert_serialized(cache, cache, self.root / "output-first", self.root / "output-second")

    def test_shared_output_serializes_distinct_caches(self):
        output = self.root / "output"
        self.assert_serialized(self.root / "cache-first", self.root / "cache-second", output, output)


if __name__ == "__main__":
    unittest.main()
