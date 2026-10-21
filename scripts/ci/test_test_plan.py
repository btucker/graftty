#!/usr/bin/env python3
"""Check test selection against inventories, including overlapping suite names."""
import re
from pathlib import Path
import tempfile
import unittest

import test_plan


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
