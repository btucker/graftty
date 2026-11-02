#!/usr/bin/env python3
"""Exercise archive verification, extraction, and the local installer boundary."""
import hashlib
import importlib.util
import io
import os
from pathlib import Path
import signal
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('wsl_install', Path(__file__).with_name('wsl-install.py'))
setup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup)


class WSLInstallTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.root = Path(self.scratch.name)
        self.archive = self.root / 'archive.tar.gz'

    def tearDown(self):
        self.scratch.cleanup()

    def bundle(self, extra=None):
        with tarfile.open(self.archive, 'w:gz') as output:
            entries = {'VERSION': b'1.2.3\n', 'install.sh': b'#!/bin/bash\nexit 0\n',
                       'bin/graftty-host': b'host', 'bin/graftty': b'cli', 'bin/zmx': b'zmx',
                       'share/ZMX_UPSTREAM_COMMIT': b'a' * 40}
            for name, data in entries.items():
                entry = tarfile.TarInfo(name)
                entry.mode = 0o755 if name.startswith('bin/') or name == 'install.sh' else 0o644
                entry.size = len(data)
                output.addfile(entry, io.BytesIO(data))
            if extra:
                output.addfile(extra)
        return hashlib.sha256(self.archive.read_bytes()).hexdigest()

    def test_verified_archive_runs_existing_installer_on_loopback(self):
        digest = self.bundle()
        with patch.object(setup, 'run', return_value='') as run:
            result = setup.install_archive(self.archive, digest)
        installer = [call for call in run.call_args_list if 'install.sh' in str(call.args)][0]
        self.assertEqual(installer.args[0][0], '/bin/bash')
        self.assertEqual(installer.args[0][-2:], ['--bind-address', '127.0.0.1'])
        self.assertTrue(result['localReady'])
        self.assertFalse(result['remoteReady'])
        self.assertEqual(result['version'], '1.2.3')

    def test_wrong_digest_does_not_execute_anything(self):
        self.bundle()
        with patch.object(setup, 'run') as run:
            with self.assertRaises(ValueError):
                setup.install_archive(self.archive, '0' * 64)
            run.assert_not_called()

    def test_archive_cannot_escape_or_install_special_files(self):
        for name, kind, target in [('../escape', tarfile.REGTYPE, ''),
                                   ('/absolute', tarfile.REGTYPE, ''),
                                   ('bin/link', tarfile.SYMTYPE, '../../escape'),
                                   ('bin/link', tarfile.LNKTYPE, '/escape'),
                                   ('device', tarfile.CHRTYPE, '')]:
            entry = tarfile.TarInfo(name)
            entry.type, entry.linkname = kind, target
            digest = self.bundle(entry)
            with patch.object(setup, 'run') as run:
                with self.assertRaises(ValueError):
                    setup.install_archive(self.archive, digest)
                run.assert_not_called()
        self.assertFalse((self.root / 'escape').exists())

    def test_rejects_archive_writing_through_a_link(self):
        self.bundle()
        with tarfile.open(self.archive, 'r:gz') as source:
            entries = [(member, source.extractfile(member).read()) for member in source]
        with tarfile.open(self.archive, 'w:gz') as output:
            link = tarfile.TarInfo('redirect')
            link.type, link.linkname = tarfile.SYMTYPE, 'bin'
            output.addfile(link)
            child = tarfile.TarInfo('redirect/graftty-host')
            child.size = 4
            output.addfile(child, io.BytesIO(b'evil'))
            for member, data in entries:
                output.addfile(member, io.BytesIO(data))
        digest = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        with patch.object(setup, 'run') as run:
            with self.assertRaises(ValueError):
                setup.install_archive(self.archive, digest)
            run.assert_not_called()

    def test_accepts_internal_cli_symlink(self):
        link = tarfile.TarInfo('libexec/graftty')
        link.type, link.linkname = tarfile.SYMTYPE, '../bin/graftty'
        digest = self.bundle(link)
        with patch.object(setup, 'run', return_value=''):
            self.assertTrue(setup.install_archive(self.archive, digest)['localReady'])

    def test_failed_installer_does_not_report_ready(self):
        digest = self.bundle()
        with patch.object(setup, 'run', side_effect=RuntimeError('startup failed')):
            with self.assertRaisesRegex(RuntimeError, 'startup failed'):
                setup.install_archive(self.archive, digest)

    @unittest.skipIf(setup.platform.system() == 'Windows', 'Linux installer process groups')
    def test_installer_timeout_allows_rollback_and_stops_its_child(self):
        rollback = self.root / 'rollback'
        child_finished = self.root / 'child-finished'
        child_pid = self.root / 'child-pid'
        child = self.root / 'child.py'
        child.write_text('import os,sys,time\nfrom pathlib import Path\n'
                         'Path(sys.argv[2]).write_text(str(os.getpid()))\n'
                         'time.sleep(30)\nPath(sys.argv[1]).write_text("leaked")\n')
        installer = self.root / 'install.sh'
        installer.write_text('trap \'printf restored > "$1"\' EXIT\n'
                             'trap \'exit 130\' TERM\n'
                             '"$3" "$4" "$2" "$5"\n')
        for disposition in ('default', 'blocked', 'ignored'):
            with self.subTest(disposition=disposition):
                rollback.unlink(missing_ok=True)
                child_pid.unlink(missing_ok=True)
                old_handler = signal.getsignal(signal.SIGTERM)
                old_mask = signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGTERM})
                try:
                    signal.signal(signal.SIGTERM, signal.SIG_IGN if disposition == 'ignored' else signal.SIG_DFL)
                    if disposition == 'blocked':
                        signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTERM})
                    with self.assertRaises(subprocess.TimeoutExpired):
                        setup.run(['/bin/bash', str(installer), str(rollback), str(child_finished),
                                   sys.executable, str(child), str(child_pid)], timeout=0.5, cleanup_timeout=1)
                finally:
                    signal.signal(signal.SIGTERM, old_handler)
                    signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)
                self.assertEqual(rollback.read_text(), 'restored')
                self.assertFalse(child_finished.exists())
                with self.assertRaises(ProcessLookupError):
                    os.kill(int(child_pid.read_text()), 0)

    def test_reports_guest_resources_and_tighter_ancestor_cgroup_limits(self):
        proc = self.root / 'proc'
        (proc / 'self').mkdir(parents=True)
        (proc / 'meminfo').write_text('MemTotal: 60000000 kB\nMemAvailable: 50000000 kB\nSwapTotal: 8000000 kB\n')
        (proc / 'self/cgroup').write_text('0::/parent/child\n')
        cgroup = self.root / 'cgroup'
        (cgroup / 'parent/child').mkdir(parents=True)
        (cgroup / 'parent/memory.max').write_text('1073741824')
        (cgroup / 'parent/child/memory.max').write_text('max')
        (cgroup / 'parent/cpu.max').write_text('250000 100000')
        (cgroup / 'parent/child/cpu.max').write_text('max 100000')
        with patch.object(setup.os, 'cpu_count', return_value=32), \
                patch.object(setup.os, 'sched_getaffinity', return_value={0, 1, 2, 3}, create=True):
            report = setup.resources(proc, cgroup)
        self.assertEqual(report['allowedCPUs'], 4)
        self.assertEqual(report['memoryBytes'], 60000000 * 1024)
        self.assertEqual(report['availableMemoryBytes'], 50000000 * 1024)
        self.assertEqual(report['cgroupMemoryLimitBytes'], 1073741824)
        self.assertEqual(report['cgroupCPUQuota'], 2.5)

    def test_preflight_rejects_non_wsl_or_root_before_starting_services(self):
        with patch.object(setup.platform, 'system', return_value='Linux'), \
                patch.object(setup.platform, 'release', return_value='6.8.0'), \
                patch.object(setup, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'WSL2'):
                setup.preflight()
            run.assert_not_called()
        with patch.object(setup.platform, 'system', return_value='Linux'), \
                patch.object(setup.platform, 'release', return_value='6.6.0-microsoft-standard-WSL2'), \
                patch.object(setup.os, 'getuid', return_value=0, create=True), \
                patch.object(setup, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'non-root'):
                setup.preflight()
            run.assert_not_called()

    @unittest.skipIf(setup.platform.system() == 'Windows', 'Linux account lookup')
    def test_startup_does_not_request_interactive_linux_elevation(self):
        with patch.object(setup, 'run', side_effect=['no\n', '', 'yes\n']) as run:
            setup.enable_user_startup()
        self.assertEqual(run.call_args_list[1].args[0][:3], ['loginctl', '--no-ask-password', 'enable-linger'])
        with patch.object(setup, 'run', side_effect=['no\n', '', 'no\n']):
            with self.assertRaisesRegex(RuntimeError, 'lingering'):
                setup.enable_user_startup()


if __name__ == '__main__':
    unittest.main()
