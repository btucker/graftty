#!/usr/bin/env python3
"""Exercise installer paths, service arguments, upgrades, and library selection."""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parent

def write_flock(path):
    """Use the same flock primitive for portable macOS/Linux shell tests."""
    path.write_text(f"#!{sys.executable}\n" + """
import fcntl, subprocess, sys
args = sys.argv[1:]
unlock = args[0] == '-u'
if unlock: args.pop(0)
if args[0].isdigit():
    fcntl.flock(int(args[0]), fcntl.LOCK_UN if unlock else fcntl.LOCK_EX)
else:
    with open(args[0], 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        sys.exit(subprocess.call(args[1:], pass_fds=(lock.fileno(),)))
""")
    path.chmod(0o755)

def write_timeout(path):
    """Bound fixture commands without requiring GNU coreutils on macOS."""
    path.write_text(f"#!{sys.executable}\n" + """
import subprocess, sys
# Support the invocation used by install.sh; the fake host has no descendants.
assert sys.argv[1] == '--kill-after=1', sys.argv
try:
    sys.exit(subprocess.run(sys.argv[3:], timeout=float(sys.argv[2])).returncode)
except subprocess.TimeoutExpired:
    sys.exit(124)
""")
    path.chmod(0o755)

class PackagingBuildTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="graftty-package-build-")
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        scripts = self.repo / "scripts/linux"
        scripts.mkdir(parents=True)
        for name in ("package.sh", "launcher.sh", "install.sh"):
            shutil.copy(ROOT / name, scripts / name)
        shutil.copy(ROOT.parent / "swiftpm", self.repo / "scripts/swiftpm")
        (self.repo / "scripts/zmx").mkdir()
        (self.repo / "scripts/zmx/UPSTREAM_COMMIT").write_text("fixture\n")
        (self.repo / "LICENSE").write_text("fixture\n")
        for resource in ("ghostty", "terminfo"):
            (self.repo / "Sources/GrafttyKit/GhosttyResources" / resource).mkdir(parents=True)
        self.tools = self.repo / "tools"
        self.tools.mkdir()
        self.cache = self.repo / "shared cache"
        self.env = {**os.environ, "PATH": str(self.tools) + os.pathsep + os.environ["PATH"],
                    "CI": "false", "GRAFTTY_SWIFTPM_SHARED_DIR": str(self.cache),
                    "GRAFTTY_TEST_REPO": str(self.repo)}

        def executable(path, body):
            path.write_text(body)
            path.chmod(0o755)

        python = f"#!{sys.executable}\n"
        executable(self.tools / "uname", "#!/bin/sh\nif [ \"$1\" = -s ]; then echo Linux; else echo x86_64; fi\n")
        executable(self.tools / "git", '#!/bin/sh\nprintf "%s\\n" "$GRAFTTY_TEST_REPO"\n')
        write_flock(self.tools / "flock")
        executable(self.tools / "swift", python + """
from pathlib import Path
import sys
args = sys.argv[1:]
build = Path(args[args.index('--scratch-path') + 1]) / 'release'
build.mkdir(parents=True, exist_ok=True)
if '--show-bin-path' in args:
    print(build)
else:
    binary = build / args[args.index('--product') + 1]
    binary.write_text('#!/bin/sh\\n# expected worktree\\nexit 0\\n')
    binary.chmod(0o755)
    resource = build / 'Graftty_GrafttyKit.resources'
    resource.mkdir(exist_ok=True)
    (resource / 'marker').write_text('expected worktree')
""")
        executable(scripts / "build-zmx.sh", '#!/bin/sh\nprintf \'#!/bin/sh\\nexit 0\\n\' > "$2"\nchmod 755 "$2"\n')
        (scripts / "bundle-libraries.py").write_text("from pathlib import Path\nimport sys\n(Path(sys.argv[1]) / 'libswiftCore.so').touch()\n")
        # At the first artifact copy, impersonate another worktree build. It
        # can overwrite the shared products only when packaging lost its lock.
        native_install = shutil.which("install")
        executable(self.tools / "install", python + f"""
import fcntl, os, subprocess, sys
from pathlib import Path
cache = Path(os.environ['GRAFTTY_SWIFTPM_SHARED_DIR'])
with open(cache / 'build.lock', 'a') as lock:
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        pass
    else:
        build = cache / 'build/release'
        for name in ('graftty-host', 'graftty-cli'):
            (build / name).write_text('#!/bin/sh\\n# other worktree\\nexit 0\\n')
        (build / 'Graftty_GrafttyKit.resources/marker').write_text('other worktree')
sys.exit(subprocess.call([{native_install!r}] + sys.argv[1:]))
""")
        executable(self.tools / "sha256sum", python + "import hashlib, sys\nfrom pathlib import Path\np = Path(sys.argv[1])\nprint(hashlib.sha256(p.read_bytes()).hexdigest() + '  ' + str(p))\n")

    def test_shared_build_is_locked_until_artifacts_are_copied(self):
        result = subprocess.run(["bash", str(self.repo / "scripts/linux/package.sh"), "test"],
                                env=self.env, text=True, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        archive = self.repo / "dist/graftty-linux-test-x86_64.tar.gz"
        with tarfile.open(archive) as bundle:
            for name in ("libexec/graftty-host", "libexec/graftty-cli", "libexec/Graftty_GrafttyKit.resources/marker"):
                self.assertIn(b"expected worktree", bundle.extractfile("./" + name).read(), name)

    def test_relative_shared_cache_is_rejected(self):
        self.env["GRAFTTY_SWIFTPM_SHARED_DIR"] = "relative-cache"
        result = subprocess.run(["bash", str(self.repo / "scripts/linux/package.sh"), "test"],
                                env=self.env, text=True, capture_output=True, timeout=20)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("absolute", result.stderr)
        self.assertFalse((self.repo / "relative-cache").exists())

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
        # Installer tests must not borrow GNU tools from a developer's PATH.
        self.env = {**os.environ, "HOME": str(self.home), "PATH": os.defpath}
        self.env.pop("XDG_CONFIG_HOME", None)
        self.env.pop("XDG_DATA_HOME", None)
        tools = self.root / "tools"
        tools.mkdir()
        write_flock(tools / "flock")
        write_timeout(tools / "timeout")
        self.env["PATH"] = str(tools) + os.pathsep + self.env["PATH"]

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

    def test_concurrent_upgrade_cannot_roll_back_another_install(self):
        self.install("--no-start")
        (self.archive / "VERSION").write_text("0.2.0-test\n")
        replacement = self.root / "replacement"
        shutil.copytree(self.archive, replacement)
        entered = self.root / "setup-entered"
        release = self.root / "setup-release"
        running = self.root / "running"
        running.touch()
        self.env.update(GRAFTTY_TEST_ENTERED=str(entered), GRAFTTY_TEST_RELEASE=str(release),
                        GRAFTTY_TEST_RUNNING=str(running))
        systemctl = self.root / "tools/systemctl"
        systemctl.write_text('''#!/bin/sh
case "$*" in
    *is-active*) test -f "$GRAFTTY_TEST_RUNNING" ;;
    *stop*) rm -f "$GRAFTTY_TEST_RUNNING" ;;
    *start*) touch "$GRAFTTY_TEST_RUNNING" ;;
esac
''')
        systemctl.chmod(0o755)
        (self.archive / "bin/graftty-host").write_text('''#!/bin/sh
touch "$GRAFTTY_TEST_ENTERED"
for attempt in $(seq 1 200); do
    test ! -f "$GRAFTTY_TEST_RELEASE" || exit 42
    sleep 0.02
done
exit 42
''')
        first = subprocess.Popen(["bash", str(self.archive / "install.sh")], env=self.env,
                                 text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        second = None
        try:
            deadline = time.monotonic() + 5
            while not entered.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(entered.exists(), "First installer did not reach setup")
            second = subprocess.Popen(["bash", str(replacement / "install.sh")], env=self.env,
                                      text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            # An unlocked installer finishes while the first is paused. A
            # serialized installer waits until the failed install rolls back.
            try:
                second.communicate(timeout=0.5)
            except subprocess.TimeoutExpired:
                pass
        finally:
            release.touch()
            first.communicate(timeout=10)
            if second is not None:
                second_output = second.communicate(timeout=10)
        self.assertNotEqual(first.returncode, 0)
        self.assertEqual(second.returncode, 0, second_output)
        installed = self.home / ".local/share/graftty/releases/0.2.0-test/bin/graftty-host"
        self.assertTrue(installed.exists(), "The failed install removed the successful replacement")
        self.assertEqual((self.home / ".local/bin/graftty-host").resolve(), installed.resolve())

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
