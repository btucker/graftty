#!/usr/bin/env python3
"""Exercise build locking with real lockf and no network or compiler work.

The checks are ordering-based, not timed: the first build signals that it
holds the lock, the second is observed blocked inside `lockf` on a lock the
first holds, and only then is the first released. A build that enters the
guarded section while the other still holds it records the overlap itself.
Waits end on the event or on the build exiting; HANG_GUARD only turns a wedged
fixture into a failure.
"""
import os
import pathlib
import re
import signal
import subprocess
import tempfile
import textwrap
import time
import unittest

# Not a timing budget: a healthy run never comes near it.
HANG_GUARD = 120
# build.sh runs `/usr/bin/lockf -k LOCK_FILE env ...`; captures LOCK_FILE.
LOCKF = re.compile(r"\S*/lockf (?:-\S+ )*(.+?) env ")


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
            # Outlasts every test-side wait, so a hang is reported as a hang
            # rather than as the overlap a self-released gate would produce.
            "FIXTURE_HANG_GUARD": str(2 * HANG_GUARD),
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

    def exists(self, name):
        return (self.root / name).exists()

    def waiting_on_lock(self, waiter, holder):
        """True once every leaf process in `waiter`'s session is a `lockf`
        naming a lock file that a `lockf` in `holder`'s session holds, so it is
        blocked on that lock and has not started its command. Matching the
        lock file keeps an uncontended `lockf`, childless for a moment between
        taking its lock and forking, from passing for a blocked one."""
        table = subprocess.run(["/bin/ps", "-A", "-ww", "-o", "pid=,ppid=,pgid=,args="],
                               capture_output=True, text=True, check=True).stdout
        rows = [row for row in (line.split(None, 3) for line in table.splitlines()) if len(row) == 4]

        def lock_file(args):
            match = LOCKF.match(args)
            return match and match.group(1)

        held = {lock_file(args) for _, _, pgid, args in rows if int(pgid) == holder.pid} - {None}
        group = [row for row in rows if int(row[2]) == waiter.pid]
        parents = {row[1] for row in group}
        leaves = [args for pid, _, _, args in group if pid not in parents]
        return bool(leaves) and all(lock_file(args) in held for args in leaves)

    def assert_no_overlap(self):
        self.assertFalse(self.exists("overlap-second"),
                         "Second build accessed shared artifacts before the first released its lock")

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
        self.wait_until("entered-first", first, lambda: self.exists("entered-first"))
        second = self.launch("second", second_cache, second_output, holder="first")
        # Contended: the second build waits in lockf on the first's lock.
        # Unprotected, it would enter instead and record the overlap.
        self.wait_until("second build waiting on the first's lock", second,
                        lambda: self.exists("entered-second") or self.waiting_on_lock(second, first))
        self.assert_no_overlap()
        (self.root / "release-first").touch()
        first_log = first.communicate(timeout=HANG_GUARD)[0]
        self.assertEqual(first.returncode, 73, first_log)
        self.wait_until("entered-second", second, lambda: self.exists("entered-second"))
        self.assert_no_overlap()
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
