#!/usr/bin/env python3
"""Exercise installer paths, service arguments, upgrades, and library selection."""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent

class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="graftty-installer-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.archive = self.root / "archive"
        self.archive.mkdir()
        for name in ("bin", "lib", "libexec", "share"):
            (self.archive / name).mkdir()
        for name in ("graftty", "graftty-host", "zmx"):
            target = self.archive / "bin" / name
            target.write_text("""#!/bin/sh
if [ "$1" = status ]; then echo '{"running":true,"sshPort":8801}'; fi
exit 0
""")
            target.chmod(0o755)
        (self.archive / "VERSION").write_text("0.1.0-test\n")
        shutil.copy(ROOT / "install.sh", self.archive / "install.sh")
        self.home = self.root / 'user with spaces'
        self.home.mkdir()
        self.env = {**os.environ, "HOME": str(self.home)}
        self.env.pop("XDG_CONFIG_HOME", None)
        self.env.pop("XDG_DATA_HOME", None)

    def install(self, *args, success=True):
        result = subprocess.run(["bash", str(self.archive / "install.sh"), *args],
                                env=self.env, text=True, capture_output=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
        return result

    def test_custom_ports_and_repeat_upgrade(self):
        self.install("--no-start", "--bind-address", "0.0.0.0", "--ssh-port", "9001", "--http-port", "9000")
        service = self.home / ".config/systemd/user/graftty-host.service"
        text = service.read_text()
        self.assertIn("KillMode=process\n", text)
        self.assertIn(' --bind-address 0.0.0.0 --ssh-port 9001 --http-port 9000 ', text)
        self.assertIn('ExecStart="' + str(self.home), text)
        cli = self.home / ".local/bin/graftty"
        self.assertTrue(cli.is_symlink())
        self.assertTrue(cli.exists())
        self.install("--no-start")
        self.assertTrue(cli.exists())
        previous = list((self.home / ".local/share/graftty/releases").glob("*.previous.*"))
        self.assertEqual(len(previous), 1)
        self.assertTrue((previous[0] / "bin/zmx").exists())

    def test_rejects_invalid_options_before_installing(self):
        for args in (("--ssh-port", "0"), ("--http-port", "65536"),
                     ("--ssh-port", "22;echo"), ("--bind-address", "host\nExecStart=oops"),
                     ("--ssh-port", "00080", "--http-port", "80")):
            self.install("--no-start", *args, success=False)
        self.assertFalse((self.home / ".config/systemd/user/graftty-host.service").exists())

    def test_semver_build_metadata_is_supported(self):
        (self.archive / "VERSION").write_text("1.2.3+build.4\n")
        self.install("--no-start")
        self.assertTrue((self.home / ".local/share/graftty/releases/1.2.3+build.4/bin/graftty").exists())

    def test_version_cannot_escape_release_directory(self):
        (self.archive / "VERSION").write_text("..\n")
        self.install("--no-start", success=False)
        self.assertFalse((self.home / ".local/share/graftty/releases").exists())

    def test_systemctl_invocations_are_user_scoped(self):
        fake = self.root / "fake-bin"
        fake.mkdir()
        systemctl = fake / "systemctl"
        log = self.root / "systemctl.log"
        systemctl.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$SYSTEMCTL_TEST_LOG"\ncase "$*" in *is-active*) exit 1 ;; esac\n')
        systemctl.chmod(0o755)
        self.env.update(PATH=str(fake) + os.pathsep + self.env["PATH"], SYSTEMCTL_TEST_LOG=str(log))
        self.install()
        self.assertEqual(log.read_text().splitlines(), ["--user is-active --quiet graftty-host.service", "--user daemon-reload", "--user enable graftty-host.service", "--user restart graftty-host.service"])

    def test_running_upgrade_stops_before_setup_and_recovers_failure(self):
        self.install("--no-start")
        service = self.home / ".config/systemd/user/graftty-host.service"
        previous_service = service.read_text()
        previous_cli = (self.home / ".local/bin/graftty").readlink()
        fake = self.root / "fake-bin"
        fake.mkdir()
        log = self.root / "operations.log"
        systemctl = fake / "systemctl"
        systemctl.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$SYSTEMCTL_TEST_LOG"\n')
        systemctl.chmod(0o755)
        host = self.archive / "bin/graftty-host"
        host.write_text('#!/bin/sh\necho setup >> "$SYSTEMCTL_TEST_LOG"\nexit 42\n')
        self.env.update(PATH=str(fake) + os.pathsep + self.env["PATH"], SYSTEMCTL_TEST_LOG=str(log))
        self.install(success=False)
        operations = log.read_text().splitlines()
        self.assertLess(operations.index("--user stop graftty-host.service"), operations.index("setup"))
        self.assertIn("--user start graftty-host.service", operations)
        self.assertEqual(service.read_text(), previous_service)
        self.assertEqual((self.home / ".local/bin/graftty").readlink(), previous_cli)
        self.assertIn("exit 0", (self.home / ".local/bin/graftty-host").read_text())

    def test_failed_readiness_stops_replacement_before_restoring_service(self):
        self.install("--no-start")
        previous_service = (self.home / ".config/systemd/user/graftty-host.service").read_text()
        fake = self.root / "fake-bin"
        fake.mkdir()
        log = self.root / "operations.log"
        systemctl = fake / "systemctl"
        systemctl.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$SYSTEMCTL_TEST_LOG"\n')
        systemctl.chmod(0o755)
        host = self.archive / "bin/graftty-host"
        host.write_text("""#!/bin/sh
if [ "$1" = status ]; then echo '{"running":false,"sshPort":8801}'; fi
exit 0
""")
        self.env.update(PATH=str(fake) + os.pathsep + self.env["PATH"], SYSTEMCTL_TEST_LOG=str(log),
                        GRAFTTY_INSTALL_READY_TIMEOUT_SECONDS="1")
        self.install(success=False)
        operations = log.read_text().splitlines()
        restart = operations.index("--user restart graftty-host.service")
        self.assertEqual(operations[restart + 1], "--user stop graftty-host.service")
        self.assertEqual(operations[-1], "--user start graftty-host.service")
        self.assertEqual((self.home / ".config/systemd/user/graftty-host.service").read_text(), previous_service)

    def test_wrong_ssh_port_does_not_complete_installation(self):
        fake = self.root / "fake-bin"
        fake.mkdir()
        systemctl = fake / "systemctl"
        log = self.root / "operations.log"
        systemctl.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$SYSTEMCTL_TEST_LOG"\ncase "$*" in *is-active*) exit 1 ;; esac\n')
        systemctl.chmod(0o755)
        self.env.update(PATH=str(fake) + os.pathsep + self.env["PATH"], SYSTEMCTL_TEST_LOG=str(log),
                        GRAFTTY_INSTALL_READY_TIMEOUT_SECONDS="1")
        self.install("--ssh-port", "9001", success=False)
        self.assertEqual(log.read_text().splitlines()[-1], "--user stop graftty-host.service")

    def test_systemd_percent_and_dollar_escaping(self):
        self.home = self.root / 'user $dollar'
        self.home.mkdir()
        self.env["HOME"] = str(self.home)
        self.install("--no-start", "--bind-address", "fe80::1%eth0")
        service = (self.home / ".config/systemd/user/graftty-host.service").read_text()
        self.assertIn('user $$dollar', service)
        self.assertIn('--bind-address fe80::1%%eth0', service)

class LibraryTests(unittest.TestCase):
    def test_glibc_and_loader_stay_on_target(self):
        spec = importlib.util.spec_from_file_location("bundle_libraries", ROOT / "bundle-libraries.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        for name in ("libc.so.6", "libm.so.6", "libpthread.so.0", "ld-linux-aarch64.so.1"):
            self.assertTrue(module.SYSTEM_LIBRARIES.match(name))
        for name in ("libswiftCore.so", "libFoundation.so", "libcurl.so.4", "libstdc++.so.6", "libicuuc.so.74"):
            self.assertFalse(module.SYSTEM_LIBRARIES.match(name))

if __name__ == "__main__":
    unittest.main()
