#!/usr/bin/env python3
"""Focused tests for the zmx compatibility harness lifecycle helpers."""

from __future__ import annotations

import importlib.util
import subprocess
import unittest
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).parent / "zmx" / "compatibility_test.py"
SPEC = importlib.util.spec_from_file_location("zmx_compatibility_test", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
compatibility = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(compatibility)


class ListSessionsTests(unittest.TestCase):
    def test_nonzero_list_result_is_not_treated_as_an_empty_session_set(self) -> None:
        failed = subprocess.CompletedProcess(
            args=["zmx", "list", "--short"],
            returncode=1,
            stdout="",
            stderr="protocol error",
        )
        with mock.patch.object(compatibility.subprocess, "run", return_value=failed):
            with self.assertRaisesRegex(RuntimeError, "protocol error"):
                compatibility.list_sessions(Path("/candidate/zmx"), {})


class KillSessionTests(unittest.TestCase):
    def test_only_the_daemon_binary_can_confirm_session_absence(self) -> None:
        daemon = Path("/legacy/zmx")
        candidate = Path("/candidate/zmx")
        run_result = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout="",
            stderr="",
        )
        with (
            mock.patch.object(compatibility.subprocess, "run", return_value=run_result),
            mock.patch.object(
                compatibility,
                "list_sessions",
                side_effect=[{"session"}, set()],
            ) as list_mock,
        ):
            compatibility.kill_session(
                daemon,
                candidate,
                daemon,
                {"ZMX_DIR": "/tmp/test-zmx"},
                "session",
            )

        self.assertEqual(
            list_mock.call_args_list,
            [
                mock.call(daemon, {"ZMX_DIR": "/tmp/test-zmx"}),
                mock.call(daemon, {"ZMX_DIR": "/tmp/test-zmx"}),
            ],
        )


class PrepareShellTests(unittest.TestCase):
    def test_waits_for_echo_safe_noecho_acknowledgement(self) -> None:
        class FakeAttach:
            def __init__(self) -> None:
                self.writes: list[str] = []
                self.markers: list[str] = []
                self.clear_count = 0

            def write(self, command: str) -> None:
                self.writes.append(command)

            def wait_for(self, marker: str, timeout: float = 8.0) -> str:
                del timeout
                self.markers.append(marker)
                return marker

            def clear_output(self) -> None:
                self.clear_count += 1

        attach = FakeAttach()
        compatibility.prepare_shell(attach)

        self.assertEqual(
            attach.markers,
            ["__SHELL_READY__", "__NOECHO_READY__"],
        )
        self.assertEqual(
            attach.writes[-1],
            "stty -echo; printf '__NOECHO_%s__\\n' READY\n",
        )
        self.assertEqual(attach.clear_count, 1)


if __name__ == "__main__":
    unittest.main()
