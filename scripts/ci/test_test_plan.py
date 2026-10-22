#!/usr/bin/env python3
"""Check test selection against inventories, including overlapping suite names."""
import importlib.util
import json
import os
import re
import subprocess
import sys
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import test_plan

runner_spec = importlib.util.spec_from_file_location("mac_runner", Path(__file__).with_name("run-macos-tests.py"))
mac_runner = importlib.util.module_from_spec(runner_spec)
runner_spec.loader.exec_module(mac_runner)


class MacRunnerTests(unittest.TestCase):
    def run_fixture(self, outcome="complete"):
        run_process = subprocess.run
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / ".build/debug/GrafttyPackageTests.xctest/Contents/MacOS/GrafttyPackageTests"
            binary.parent.mkdir(parents=True)
            binary.touch()
            toolchain = root / "toolchain"
            helper = toolchain / "usr/libexec/swift/pm/swiftpm-testing-helper"
            helper.parent.mkdir(parents=True)
            if outcome != "missing-helper":
                helper.touch()
                helper.chmod(0o755)
            platform = root / "MacOSX.platform"
            commands = []

            def discover(command, **kwargs):
                if command[:2] == ["swift", "test"]:
                    self.assertIn("list", command)
                    if "--disable-xctest" in command:
                        return "KitTests.Parent/parameterized(_:)\nKitTests.Parent/disabled()\n"
                    return "MacTests.Native/testPass\n"
                if command == ["xcrun", "--find", "swift"]:
                    return str(toolchain / "usr/bin/swift") + "\n"
                if command == ["xcrun", "--sdk", "macosx", "--show-sdk-platform-path"]:
                    return str(platform) + "\n"
                self.fail(f"Unexpected discovery command: {command}")

            def execute(command, **kwargs):
                commands.append(command)
                transcript = Path(command[2])
                if str(helper) in command:
                    self.assertIn(str(binary.resolve()), command)
                    self.assertIn("--no-parallel", command)
                    expected_environment = {
                        "DYLD_FRAMEWORK_PATH": ":".join(("caller-frameworks", str(platform / "Developer/Library/Frameworks"),
                                                        str(platform / "Developer/Library/PrivateFrameworks"))),
                        "DYLD_LIBRARY_PATH": ":".join(("caller-libraries", str((root / ".build/debug").resolve()),
                                                      str(platform / "Developer/usr/lib"))),
                    }
                    self.assertEqual({key: command[command.index("/usr/bin/env") + index + 1].split("=", 1)[1]
                                      for index, key in enumerate(expected_environment)}, expected_environment)
                    if outcome == "pty":
                        # Cross the real macOS PTY boundary: SIP strips DYLD_*
                        # passed only in the environment of /usr/bin/script.
                        probe = root / "runtime-environment.json"
                        code = ("import json,os,pathlib; pathlib.Path(" + repr(str(probe)) + ").write_text("
                                "json.dumps({key:os.environ.get(key) for key in "
                                "['DYLD_FRAMEWORK_PATH','DYLD_LIBRARY_PATH']}))")
                        run_process([*command[:command.index(str(helper))], sys.executable, "-c", code],
                                    stdin=subprocess.DEVNULL,
                                    capture_output=True, check=True)
                        self.assertEqual(json.loads(probe.read_text()), expected_environment)
                    if outcome == "failed":
                        raise subprocess.CalledProcessError(1, command)
                    xml = Path(command[command.index("--xunit-output") + 1])
                    xml.write_text('<testsuites>' if outcome == "truncated" else '''<testsuites><testsuite>
                      <testcase classname="KitTests.Parent" name="parameterized(_:)"/>
                      <testcase classname="KitTests.Parent" name="disabled()"><skipped/></testcase>
                    </testsuite></testsuites>''')
                else:
                    self.assertIn("--disable-swift-testing", command)
                    transcript.write_text("Test Case '-[MacTests.Native testPass]' passed (0.001 seconds).\n")

            previous = Path.cwd()
            try:
                os.chdir(root)
                with mock.patch.dict(os.environ, {"GRAFTTY_RENDERER_CONTEXT": "-DTEST",
                                                  "DYLD_FRAMEWORK_PATH": "caller-frameworks",
                                                  "DYLD_LIBRARY_PATH": "caller-libraries"}), \
                     mock.patch.object(mac_runner.subprocess, "check_output", side_effect=discover), \
                     mock.patch.object(mac_runner.subprocess, "run", side_effect=execute):
                    mac_runner.main()
                evidence = root / ".ci-results/macos"
                return commands, (evidence / "verified-swift-tests.json").read_text(), \
                    (evidence / "verified-xctests.json").read_text()
            finally:
                os.chdir(previous)

    def test_runs_serial_swift_batches_without_reloading_the_package_graph(self):
        commands, swift_results, xctest_results = self.run_fixture()
        self.assertEqual(len(commands), 2)
        self.assertIn("KitTests.Parent/disabled()", swift_results)
        self.assertIn("KitTests.Parent/parameterized(_:)", swift_results)
        self.assertIn("MacTests.Native/testPass", xctest_results)

    def test_helper_failure_is_not_a_successful_batch(self):
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_fixture("failed")

    def test_incomplete_helper_results_fail_even_after_exit_zero(self):
        with self.assertRaisesRegex(ValueError, "Incomplete Swift test results"):
            self.run_fixture("truncated")

    def test_missing_helper_fails_instead_of_skipping_tests(self):
        with self.assertRaises(FileNotFoundError):
            self.run_fixture("missing-helper")

    @unittest.skipUnless(sys.platform == "darwin", "Requires macOS PTY and SIP behavior")
    def test_runtime_paths_survive_the_real_pty_boundary(self):
        self.run_fixture("pty")


class MacPlanTests(unittest.TestCase):
    def test_xctest_completions_match_discovery_including_skips(self):
        tests = ["MacTests.Native/testPass", "MacTests.Native/testSkipped"]
        with tempfile.TemporaryDirectory() as directory:
            transcript = Path(directory) / "xctest.log"
            transcript.write_text("Test Case '-[MacTests.Native testPass]' started.\n"
                                  "Test Case '-[MacTests.Native testPass]' passed (0.010 seconds).\n"
                                  "Test Case '-[MacTests.Native testSkipped]' skipped (0.001 seconds).\n")
            self.assertEqual(test_plan.verify_xctest_results(tests, [transcript]), tests)
            for inventory, results in [(tests + ["MacTests.Native/testMissing"], [transcript]),
                                       (tests, [transcript, transcript]), (tests[:1], [transcript])]:
                with self.assertRaises(ValueError):
                    test_plan.verify_xctest_results(inventory, results)

    def test_xctest_started_or_failed_is_not_a_successful_completion(self):
        with tempfile.TemporaryDirectory() as directory:
            transcript = Path(directory) / "xctest.log"
            for status in ["started.", "failed (0.010 seconds)."]:
                transcript.write_text(f"Test Case '-[MacTests.Native testPass]' {status}\n")
                with self.assertRaises(ValueError):
                    test_plan.verify_xctest_results(["MacTests.Native/testPass"], [transcript])

    def test_incomplete_results_identify_the_batch_and_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            result = Path(directory) / "swift-22.xml"
            result.write_text('<?xml version="1.0" encoding="UTF-8"?>\n<testsuites>\n')
            with self.assertRaisesRegex(ValueError, "Incomplete Swift test results.*swift-22.xml"):
                test_plan.verify_swift_results(["MacTests.Sidebar/test()"], [result])

    def test_execution_results_match_discovery_including_disabled_and_nested_tests(self):
        tests = ["KitTests.Parent/Child/nested()", "KitTests.Parent/parameterized(_:)",
                 "KitTests.Parent/backlog()", "KitTests.topLevel()", "OwnershipModelTests.Corpus/run()"]
        with tempfile.TemporaryDirectory() as directory:
            result = Path(directory) / "results.xml"
            result.write_text('''<testsuites><testsuite>
              <testcase classname="KitTests.Parent.Child" name="nested()"/>
              <testcase classname="KitTests.Parent" name="parameterized(_:)"/>
              <testcase classname="KitTests.Parent" name="backlog()"><skipped/></testcase>
              <testcase classname="KitTests" name="topLevel()"/>
            </testsuite></testsuites>''')
            self.assertEqual(test_plan.verify_swift_results(tests, [result]), sorted(tests[:-1]))
            for inventory, results in [(tests + ["KitTests.New/test()"], [result]),
                                       (tests, [result, result]), (tests[:-2], [result])]:
                with self.assertRaises(ValueError):
                    test_plan.verify_swift_results(inventory, results)

    def test_every_discovered_test_matches_exactly_one_batch(self):
        tests = [
            "ProtocolTests.PagedTerminalTests/roundTrip()",
            "MacTests.MacPagedTerminalTests/realTerminal()",
            "KitTests.ZmxAttachEngineTests/attach()",
            "KitTests.PagedZmxAttachEngineTests/history()",
            "KitTests.Parent/Child/nested()",
            "KitTests.Child/standalone()",
            "KitTests.Parent/parent()",
            "OtherTests.Parent/anotherModule()",
            "KitTests.TopLevel()",
            "OwnershipModelTests.OwnershipModelSmoke/corpus()",
        ]
        filters = test_plan.mac_filters(tests, batch_size=2)
        for test in tests:
            for identifier in [test, test.split(".", 1)[1]]:
                matches = sum(bool(re.search(pattern, identifier)) for pattern in filters)
                self.assertEqual(matches, 0 if test.startswith("OwnershipModelTests.") else 1, identifier)

    def test_substrings_are_not_selected(self):
        [pattern] = test_plan.mac_filters(["ProtocolTests.PagedTerminalTests/roundTrip()"])
        self.assertIsNone(re.search(pattern, "MacTests.MacPagedTerminalTests/realTerminal()"))
        self.assertIsNone(re.search(pattern, "PagedTerminalTestsExtra/roundTrip()"))

    def test_empty_or_malformed_discovery_fails(self):
        for tests in [[], ["warning: no tests"], ["OwnershipModelTests.Smoke/corpus()"]]:
            with self.subTest(tests=tests), self.assertRaises(ValueError):
                test_plan.mac_filters(tests)


class IOSPlanTests(unittest.TestCase):
    def test_combined_cli_preserves_all_four_processes_and_selects_each_test_once(self):
        result = subprocess.run([sys.executable, "-B", str(Path(test_plan.__file__)), "all"],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        batches = [line.split() for line in result.stdout.splitlines()]
        self.assertEqual(batches, [test_plan.ios_arguments("unit")] + [
            ["-only-testing:" + suite for suite in group]
            for group in test_plan.IOS_INTEGRATION_GROUPS
        ])
        tests = [suite + "/fixture()" for suite in test_plan.IOS_INTEGRATION_SUITES]
        tests += ["GrafttyMobileKitTests/NewSuite/test()",
                  "GrafttyMobileBrowserTests/RootViewTests/test()",
                  "GrafttyRemoteClientTests/SSHAuthLoopbackTestsExtra/test()"]
        for test in tests:
            selections = []
            for batch in batches:
                matches = any(test.startswith(argument.split(":", 1)[1] + "/") for argument in batch)
                selections.append(not matches if batch[0].startswith("-skip-testing:") else matches)
            self.assertEqual(sum(selections), 1, test)

    def test_complement_covers_existing_and_new_suites_once(self):
        tests = [suite + "/fixture()" for suite in test_plan.IOS_INTEGRATION_SUITES]
        tests += ["GrafttyMobileKitTests/NewSuite/newTest()",
                  "GrafttyMobileBrowserTests/RemoteBrowserButtonTests/nativePreview()",
                  "GrafttyRemoteClientTests/SSHAuthLoopbackTestsExtra/newTest()"]
        for test in tests:
            self.assertEqual(sum(test_plan.ios_selects(group, test) for group in ("unit", "integration")), 1)
        self.assertTrue(test_plan.ios_selects("unit", tests[-1]))

    def test_arguments_share_the_same_partition(self):
        self.assertEqual(test_plan.ios_arguments("unit"),
                         ["-skip-testing:" + suite for suite in test_plan.IOS_INTEGRATION_SUITES])
        self.assertEqual(test_plan.ios_arguments("integration"),
                         ["-only-testing:" + suite for suite in test_plan.IOS_INTEGRATION_SUITES])
        with self.assertRaises(ValueError):
            test_plan.ios_arguments("typo")


if __name__ == "__main__":
    unittest.main()
