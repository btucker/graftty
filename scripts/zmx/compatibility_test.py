#!/usr/bin/env python3
"""Exercise zmx client/daemon compatibility across a vendored upgrade."""

from __future__ import annotations

import argparse
import fcntl
import os
import re
import selectors
import shlex
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time
from pathlib import Path


def terminate_on_signal(signum: int, _frame: object) -> None:
    raise SystemExit(128 + signum)


def window_size(rows: int, cols: int, xpixel: int, ypixel: int) -> bytes:
    return struct.pack("HHHH", rows, cols, xpixel, ypixel)


class Attach:
    def __init__(
        self,
        binary: Path,
        env: dict[str, str],
        session: str,
        *,
        rows: int,
        cols: int,
        xpixel: int,
        ypixel: int,
        snapshot: bool = False,
        separate_output: bool = False,
    ) -> None:
        input_master, input_slave = os.openpty()
        output_master, output_slave = (
            os.openpty() if separate_output else (input_master, input_slave)
        )
        for master in {input_master, output_master}:
            fcntl.ioctl(master, termios.TIOCSWINSZ, window_size(rows, cols, xpixel, ypixel))
            os.set_blocking(master, False)

        def child_setup() -> None:
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        try:
            attach_args = [str(binary), "attach"]
            if snapshot:
                attach_args.append("--snapshot")
            attach_args.extend((session, "/bin/sh"))
            self.process = subprocess.Popen(
                attach_args,
                stdin=input_slave,
                stdout=output_slave,
                stderr=output_slave,
                env=env,
                close_fds=True,
                preexec_fn=child_setup,
            )
        except BaseException:
            os.close(input_master)
            if output_master != input_master:
                os.close(output_master)
            raise
        finally:
            os.close(input_slave)
            if output_slave != input_slave:
                os.close(output_slave)
        self.input_master = input_master
        self.master = output_master
        self.output = bytearray()

    def write(self, command: str) -> None:
        os.write(self.input_master, command.encode())

    def resize(
        self,
        *,
        rows: int,
        cols: int,
        xpixel: int,
        ypixel: int,
    ) -> None:
        fcntl.ioctl(
            self.input_master,
            termios.TIOCSWINSZ,
            window_size(rows, cols, xpixel, ypixel),
        )
        if self.master != self.input_master:
            fcntl.ioctl(
                self.master,
                termios.TIOCSWINSZ,
                window_size(rows, cols, xpixel, ypixel),
            )

    def wait_for(self, marker: str, timeout: float = 8.0) -> str:
        marker_bytes = marker.encode()
        deadline = time.monotonic() + timeout
        selector = selectors.DefaultSelector()
        selector.register(self.master, selectors.EVENT_READ)
        try:
            while marker_bytes not in self.output and time.monotonic() < deadline:
                if self.process.poll() is not None:
                    self._drain()
                    break
                for _, _ in selector.select(timeout=0.1):
                    self._drain()
        finally:
            selector.close()
        decoded = self.output.decode(errors="replace")
        if marker not in decoded:
            raise AssertionError(
                f"attach pid {self.process.pid} never emitted {marker!r}; output={decoded!r}"
            )
        return decoded

    def _drain(self) -> None:
        while True:
            try:
                data = os.read(self.master, 65536)
            except BlockingIOError:
                return
            except OSError:
                return
            if not data:
                return
            self.output.extend(data)

    def clear_output(self) -> None:
        self._drain()
        self.output.clear()

    def drain_for(self, duration: float) -> str:
        deadline = time.monotonic() + duration
        selector = selectors.DefaultSelector()
        selector.register(self.master, selectors.EVENT_READ)
        try:
            while time.monotonic() < deadline:
                for _, _ in selector.select(timeout=0.05):
                    self._drain()
        finally:
            selector.close()
        return self.output.decode(errors="replace")

    def assert_raw_output(self) -> None:
        output_flags = termios.tcgetattr(self.master)[1]
        if output_flags & termios.OPOST:
            raise AssertionError(
                "snapshot attach left PTY output processing enabled; binary bytes may be rewritten"
            )

    def terminate_client(self) -> None:
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=2)
        os.close(self.master)
        if self.input_master != self.master:
            os.close(self.input_master)


def zmx_env(directory: Path) -> dict[str, str]:
    env = dict(os.environ)
    env["ZMX_DIR"] = str(directory)
    env["SHELL"] = "/bin/sh"
    env.setdefault("TERM", "xterm-256color")
    env.pop("ZMX_SESSION", None)
    return env


def list_sessions(binary: Path, env: dict[str, str]) -> set[str]:
    result = subprocess.run(
        [str(binary), "list", "--short"],
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=3,
        check=False,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or "no stderr"
        raise RuntimeError(
            f"{binary} list failed with exit {result.returncode}: {detail}"
        )
    return {line.strip() for line in result.stdout.splitlines() if line.strip()}


def wait_for_session(
    binary: Path,
    env: dict[str, str],
    session: str,
    timeout: float = 8.0,
) -> None:
    deadline = time.monotonic() + timeout
    last_error: Exception | None = None
    while time.monotonic() < deadline:
        try:
            sessions = list_sessions(binary, env)
            last_error = None
            if session in sessions:
                return
        except (RuntimeError, subprocess.TimeoutExpired) as error:
            last_error = error
        time.sleep(0.05)
    error = AssertionError(f"session {session!r} never appeared")
    if last_error is not None:
        raise error from last_error
    raise error


def kill_session(
    daemon_binary: Path,
    candidate: Path,
    legacy: Path,
    env: dict[str, str],
    session: str,
) -> None:
    last_probe_error: Exception | None = None
    binaries = tuple(dict.fromkeys((daemon_binary, candidate, legacy)))
    for binary in binaries:
        try:
            subprocess.run(
                [str(binary), "kill", "--force", session],
                env=env,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=3,
                check=False,
            )
        except subprocess.TimeoutExpired:
            continue
        try:
            # Only the CLI that created the daemon is authoritative about
            # whether its session still exists. A cross-version client may
            # successfully return an empty list because it cannot interpret
            # the daemon, which is not proof that cleanup succeeded.
            if session not in list_sessions(daemon_binary, env):
                return
        except (RuntimeError, subprocess.TimeoutExpired) as error:
            last_probe_error = error
            continue
    cleanup_error = RuntimeError(
        f"could not stop zmx session {session!r}; preserving {env['ZMX_DIR']} for cleanup"
    )
    if last_probe_error is not None:
        raise cleanup_error from last_probe_error
    raise cleanup_error


def cleanup_case(
    directory: Path,
    env: dict[str, str],
    session: str,
    daemon_binary: Path,
    candidate: Path,
    legacy: Path,
    *attaches: Attach | None,
) -> None:
    errors: list[Exception] = []
    for attach in attaches:
        if attach is None:
            continue
        try:
            attach.terminate_client()
        except Exception as error:
            errors.append(error)

    try:
        kill_session(daemon_binary, candidate, legacy, env, session)
    except Exception as error:
        errors.append(error)
    else:
        shutil.rmtree(directory, ignore_errors=True)

    if errors:
        raise RuntimeError(
            f"zmx compatibility cleanup failed; scope retained at {directory}"
        ) from errors[0]


def make_scope() -> tuple[Path, dict[str, str]]:
    directory = Path(tempfile.mkdtemp(prefix="zmx-compat-", dir="/tmp"))
    return directory, zmx_env(directory)


def prepare_shell(attach: Attach) -> None:
    # The marker is assembled by printf so the terminal's command echo cannot
    # satisfy the wait before the shell has actually executed it.
    attach.write("printf '__SHELL_%s__\\n' READY\n")
    attach.wait_for("__SHELL_READY__")
    attach.write("stty -echo; printf '__NOECHO_%s__\\n' READY\n")
    attach.wait_for("__NOECHO_READY__")
    attach.clear_output()


def assert_grid(attach: Attach, rows: int, cols: int, marker: str) -> None:
    attach.write(f"printf '{marker}:'; stty size\n")
    output = attach.wait_for(f"{marker}:{rows} {cols}")
    if f"{marker}:{rows} {cols}" not in output:
        raise AssertionError(f"wrong grid after cross-version resize: {output!r}")


def assert_winsize(
    attach: Attach,
    rows: int,
    cols: int,
    xpixel: int,
    ypixel: int,
    marker: str,
) -> None:
    code = (
        "import fcntl,struct,termios;"
        "r,c,x,y=struct.unpack('HHHH',fcntl.ioctl(0,termios.TIOCGWINSZ,"
        "struct.pack('HHHH',0,0,0,0)));"
        f"print('{marker}:%d:%d:%d:%d' % (r,c,x,y))"
    )
    attach.write(f"{shlex.quote(sys.executable)} -c {shlex.quote(code)}\n")
    expected = f"{marker}:{rows}:{cols}:{xpixel}:{ypixel}"
    output = attach.wait_for(expected)
    if expected not in output:
        raise AssertionError(f"wrong winsize after cross-version resize: {output!r}")


def old_daemon_new_client(
    legacy: Path, candidate: Path, expect_cross_version_pixels: bool
) -> None:
    directory, env = make_scope()
    session = "compat-old-daemon"
    first: Attach | None = None
    second: Attach | None = None
    try:
        first = Attach(
            legacy,
            env,
            session,
            rows=24,
            cols=80,
            xpixel=800,
            ypixel=480,
        )
        wait_for_session(legacy, env, session)
        prepare_shell(first)
        first.write("export GRAFTTY_COMPAT_MARKER=old-daemon\nprintf 'OLD_READY\\n'\n")
        first.wait_for("OLD_READY")
        first.terminate_client()
        first = None

        second = Attach(
            candidate,
            env,
            session,
            rows=30,
            cols=100,
            xpixel=1000,
            ypixel=600,
        )
        prepare_shell(second)
        second.write("printf 'STATE:%s\\n' \"$GRAFTTY_COMPAT_MARKER\"\n")
        second.wait_for("STATE:old-daemon")
        second.resize(rows=37, cols=111, xpixel=1234, ypixel=777)
        time.sleep(0.2)
        assert_grid(second, 37, 111, "OLD_GRID")
        if expect_cross_version_pixels:
            assert_winsize(second, 37, 111, 1234, 777, "OLD_WINSIZE")

        logs = "\n".join(
            path.read_text(errors="replace")
            for path in (directory / "logs").glob("*.log")
        )
        if "unknown IPC tag=24" in logs:
            raise AssertionError("new client sent PixelSize before an old daemon advertised support")
    finally:
        cleanup_case(
            directory,
            env,
            session,
            legacy,
            candidate,
            legacy,
            first,
            second,
        )


def new_daemon_old_client(
    legacy: Path, candidate: Path, expect_cross_version_pixels: bool
) -> None:
    directory, env = make_scope()
    session = "compat-new-daemon"
    first: Attach | None = None
    second: Attach | None = None
    try:
        first = Attach(
            candidate,
            env,
            session,
            rows=25,
            cols=81,
            xpixel=810,
            ypixel=500,
        )
        wait_for_session(candidate, env, session)
        prepare_shell(first)
        first.write("export GRAFTTY_COMPAT_MARKER=new-daemon\nprintf 'NEW_READY\\n'\n")
        first.wait_for("NEW_READY")
        first.terminate_client()
        first = None

        second = Attach(
            legacy,
            env,
            session,
            rows=28,
            cols=90,
            xpixel=900,
            ypixel=560,
        )
        prepare_shell(second)
        second.write("printf 'STATE:%s\\n' \"$GRAFTTY_COMPAT_MARKER\"\n")
        second.wait_for("STATE:new-daemon")
        second.resize(rows=39, cols=112, xpixel=1240, ypixel=780)
        time.sleep(0.2)
        assert_grid(second, 39, 112, "NEW_GRID")
        if expect_cross_version_pixels:
            assert_winsize(second, 39, 112, 1240, 780, "NEW_WINSIZE")
    finally:
        cleanup_case(
            directory,
            env,
            session,
            candidate,
            candidate,
            legacy,
            first,
            second,
        )


def new_client_new_daemon_pixels(legacy: Path, candidate: Path) -> None:
    directory, env = make_scope()
    session = "compat-pixels"
    attach: Attach | None = None
    try:
        attach = Attach(
            candidate,
            env,
            session,
            rows=31,
            cols=101,
            xpixel=1313,
            ypixel=919,
        )
        wait_for_session(candidate, env, session)
        prepare_shell(attach)
        attach.resize(rows=31, cols=101, xpixel=1515, ypixel=929)
        time.sleep(0.2)

        assert_winsize(attach, 31, 101, 1515, 929, "PIXELS")
    finally:
        cleanup_case(
            directory,
            env,
            session,
            candidate,
            candidate,
            legacy,
            attach,
        )


def new_daemon_streams_snapshot(legacy: Path, candidate: Path) -> None:
    directory, env = make_scope()
    session = "compat-snapshot"
    first: Attach | None = None
    second: Attach | None = None
    try:
        first = Attach(
            candidate,
            env,
            session,
            rows=24,
            cols=80,
            xpixel=800,
            ypixel=480,
        )
        wait_for_session(candidate, env, session)
        prepare_shell(first)
        first.write("printf '__SNAPSHOT_%s__\\n' READY\n")
        first.wait_for("__SNAPSHOT_READY__")
        first.terminate_client()
        first = None

        second = Attach(
            candidate,
            env,
            session,
            rows=24,
            cols=80,
            xpixel=800,
            ypixel=480,
            snapshot=True,
            separate_output=True,
        )
        second.wait_for("GHOSTSNP")
        second.assert_raw_output()
        second.write("printf '__SNAPSHOT_LIVE_%s__\\n' READY\n")
        second.wait_for("__SNAPSHOT_LIVE_READY__")
    finally:
        cleanup_case(
            directory,
            env,
            session,
            candidate,
            candidate,
            legacy,
            first,
            second,
        )


def new_daemon_orders_snapshot_before_active_output(
    legacy: Path, candidate: Path
) -> None:
    directory, env = make_scope()
    session = "compat-snapshot-race"
    first: Attach | None = None
    second: Attach | None = None
    try:
        first = Attach(
            candidate,
            env,
            session,
            rows=24,
            cols=80,
            xpixel=800,
            ypixel=480,
        )
        wait_for_session(candidate, env, session)
        prepare_shell(first)
        first.write(
            "i=0; while :; do printf '__RACE_%s__\\n' \"$i\"; "
            "i=$((i + 1)); sleep 0.01; done\n"
        )
        first.wait_for("__RACE_1__")
        first.terminate_client()
        first = None

        second = Attach(
            candidate,
            env,
            session,
            rows=24,
            cols=80,
            xpixel=800,
            ypixel=480,
            snapshot=True,
            separate_output=True,
        )
        second.wait_for("GHOSTSNP")
        if not bytes(second.output).startswith(b"GHOSTSNP"):
            raise AssertionError("live PTY output preceded the snapshot envelope")
        second.write("\x03")
        time.sleep(0.1)
        second.write("printf '__RACE_LIVE_%s__\\n' READY\n")
        second.wait_for("__RACE_LIVE_READY__")
    finally:
        cleanup_case(
            directory,
            env,
            session,
            candidate,
            candidate,
            legacy,
            first,
            second,
        )


def new_daemon_snapshots_first_attach(legacy: Path, candidate: Path) -> None:
    directory, env = make_scope()
    session = "compat-snapshot-first"
    attach: Attach | None = None
    try:
        attach = Attach(
            candidate,
            env,
            session,
            rows=24,
            cols=80,
            xpixel=800,
            ypixel=480,
            snapshot=True,
            separate_output=True,
        )
        wait_for_session(candidate, env, session)
        attach.wait_for("GHOSTSNP")
        if not bytes(attach.output).startswith(b"GHOSTSNP"):
            raise AssertionError("snapshot stream was prefixed by non-snapshot output")
        attach.write("printf '__FIRST_LIVE_%s__\\n' READY\n")
        attach.wait_for("__FIRST_LIVE_READY__")
    finally:
        cleanup_case(
            directory,
            env,
            session,
            candidate,
            candidate,
            legacy,
            attach,
        )


def new_daemon_preserves_stream_continuation(legacy: Path, candidate: Path) -> None:
    directory, env = make_scope()
    session = "compat-snapshot-continuation"
    first: Attach | None = None
    second: Attach | None = None
    try:
        first = Attach(
            candidate,
            env,
            session,
            rows=24,
            cols=80,
            xpixel=800,
            ypixel=480,
        )
        wait_for_session(candidate, env, session)
        prepare_shell(first)
        code = (
            "import os,time;"
            "os.write(1,b'__CONT_START__\\n\\xe2');"
            "time.sleep(2);"
            "os.write(1,b'\\x82\\xac__CONT_READY__\\n')"
        )
        first.write(f"{shlex.quote(sys.executable)} -c {shlex.quote(code)}\n")
        first.wait_for("__CONT_START__")
        first.terminate_client()
        first = None

        second = Attach(
            candidate,
            env,
            session,
            rows=24,
            cols=80,
            xpixel=800,
            ypixel=480,
        )
        output = second.wait_for("__CONT_READY__", timeout=5.0)
        if "€__CONT_READY__" not in output:
            raise AssertionError(
                f"snapshot lost split UTF-8 continuation state: {output!r}"
            )
    finally:
        cleanup_case(
            directory,
            env,
            session,
            candidate,
            candidate,
            legacy,
            first,
            second,
        )


def new_daemon_preserves_large_scrollback(legacy: Path, candidate: Path) -> None:
    directory, env = make_scope()
    session = "compat-large-scrollback"
    first: Attach | None = None
    second: Attach | None = None
    try:
        first = Attach(
            candidate,
            env,
            session,
            rows=24,
            cols=80,
            xpixel=800,
            ypixel=480,
        )
        wait_for_session(candidate, env, session)
        prepare_shell(first)
        first.write(
            "/usr/bin/awk 'BEGIN { "
            'for (i = 1; i <= 10000; i++) printf "__H_%05d__\\n", i; '
            'print "__HISTORY_DONE__"'
            " }' "
            "&& printf '__HISTORY_%s__\\n' STABLE\n"
        )
        first.wait_for("__HISTORY_STABLE__", timeout=15.0)
        first.terminate_client()
        first = None

        second = Attach(
            candidate,
            env,
            session,
            rows=24,
            cols=80,
            xpixel=800,
            ypixel=480,
        )
        replay = second.wait_for("__HISTORY_STABLE__", timeout=8.0)
        second.write("printf '__REPLAY_DRAINED_%s__\\n' READY\n")
        second.wait_for("__REPLAY_DRAINED_READY__", timeout=8.0)
        replay = second.drain_for(0.25)
        history_rows = re.findall(r"__H_\d{5}__", replay)

        if len(history_rows) != 10000:
            raise AssertionError(
                "large-history reattach did not preserve every generated row: "
                f"received {len(history_rows)} rows"
            )
        if "__H_00001__" not in replay or "__H_10000__" not in replay:
            raise AssertionError("large-history replay dropped the oldest or newest row")
        if replay.count("__HISTORY_STABLE__") != 1:
            raise AssertionError(
                "large-history reattach duplicated the stable screen marker: "
                f"count={replay.count('__HISTORY_STABLE__')}"
            )
    finally:
        cleanup_case(
            directory,
            env,
            session,
            candidate,
            candidate,
            legacy,
            first,
            second,
        )


def main() -> None:
    # Convert cancellation into a Python exception so each compatibility
    # case unwinds through its `finally` cleanup instead of abandoning a
    # persistent zmx daemon and shell.
    signal.signal(signal.SIGTERM, terminate_on_signal)

    parser = argparse.ArgumentParser()
    parser.add_argument("--legacy", required=True, type=Path)
    parser.add_argument("--candidate", required=True, type=Path)
    parser.add_argument("--expect-cross-version-pixels", action="store_true")
    args = parser.parse_args()
    legacy = args.legacy.resolve()
    candidate = args.candidate.resolve()
    if not os.access(legacy, os.X_OK) or not os.access(candidate, os.X_OK):
        parser.error("legacy and candidate must both be executable")

    old_daemon_new_client(legacy, candidate, args.expect_cross_version_pixels)
    print("  ✓ old daemon → new client")
    new_daemon_old_client(legacy, candidate, args.expect_cross_version_pixels)
    print("  ✓ new daemon → old client")
    new_client_new_daemon_pixels(legacy, candidate)
    print("  ✓ negotiated pixel-size resize")
    new_daemon_streams_snapshot(legacy, candidate)
    print("  ✓ negotiated binary snapshot stream")
    new_daemon_orders_snapshot_before_active_output(legacy, candidate)
    print("  ✓ snapshot precedes active live output")
    new_daemon_snapshots_first_attach(legacy, candidate)
    print("  ✓ first attach starts with a snapshot envelope")
    new_daemon_preserves_stream_continuation(legacy, candidate)
    print("  ✓ snapshot preserves split stream continuation")
    new_daemon_preserves_large_scrollback(legacy, candidate)
    print("  ✓ complete, non-duplicated large-history replay")


if __name__ == "__main__":
    main()
