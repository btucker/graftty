#!/usr/bin/env python3
"""Regression checks for suite-boundary dispatch samples."""
import tempfile
import re
import unittest
from pathlib import Path

import gcd_probe


SAMPLE = '''Analysis of sampling Fixture (pid 123) every 1 millisecond
Call graph:
    1 Thread_10
      1 _pthread_wqthread
        1 _dispatch_worker_thread2
          1 _dispatch_root_queue_drain
            1 closure #1 in LeakingSuite.run()
              1 _dispatch_semaphore_wait_slow
                1 semaphore_wait_trap
    1 Thread_11
      1 _pthread_wqthread
        1 __workq_kernreturn
    1 Thread_12: NIO-ELT-0
      1 _pthread_start
        1 kevent
    1 Thread_13
      1 _pthread_wqthread
        1 _dispatch_worker_thread2
          1 _dispatch_root_queue_drain
            1 closure #1 in OtherSuite.run()
              1 read
Total number in stack (recursive counted multiple, when >=5):
'''


class DispatchSampleTests(unittest.TestCase):
    def test_ci_process_order_keeps_swift_cohorts_then_xctest_targets_then_ownership(self):
        batches = ['first cohort', 'second cohort']
        classes = ['GrafttyTests.Second', 'GrafttyKitTests.First', 'GrafttyTests.First']
        self.assertEqual(gcd_probe.ci_processes(batches, classes), [
            (1, 'first cohort'), (2, 'second cohort'),
            ('xctest-GrafttyKitTests', ['GrafttyKitTests.First']),
            ('xctest-GrafttyTests', ['GrafttyTests.First', 'GrafttyTests.Second']),
            ('ownership', 'OwnershipModel'),
        ])

    def test_ownership_gate_inventory_is_checked_instead_of_silently_excluded(self):
        with tempfile.TemporaryDirectory() as directory:
            result = Path(directory) / 'results.xml'
            result.write_text('<testsuite><testcase classname="OwnershipModelTests.Model" name="corpus()"/></testsuite>')
            self.assertEqual(gcd_probe.verify_swift_results(['OwnershipModelTests.Model/corpus()'],
                [result], include_ownership=True), ['OwnershipModelTests.Model/corpus()'])
            with self.assertRaises(ValueError):
                gcd_probe.verify_swift_results(['OwnershipModelTests.Model/missing()'],
                    [result], include_ownership=True)

    def test_capture_uses_ci_skip_conditions_without_mutating_the_callers_environment(self):
        original = {'CI': 'false', 'GRAFTTY_GHOSTTY_PACKAGE_PATH': '/renderer'}
        environment = gcd_probe.ci_environment(original)
        self.assertEqual(environment['CI'], 'true')
        self.assertEqual(environment['GITHUB_ACTIONS'], 'true')
        self.assertEqual(environment['GRAFTTY_GHOSTTY_PACKAGE_PATH'], '/renderer')
        self.assertEqual(original, {'CI': 'false', 'GRAFTTY_GHOSTTY_PACKAGE_PATH': '/renderer'})

    def test_real_capture_requires_the_ci_paging_renderer_configuration(self):
        for environment in [{}, {'GRAFTTY_GHOSTTY_PACKAGE_PATH': '/renderer'},
                            {'GRAFTTY_REQUIRE_PAGED_HISTORY': '1'},
                            {'GRAFTTY_GHOSTTY_PACKAGE_PATH': '', 'GRAFTTY_REQUIRE_PAGED_HISTORY': '1'}]:
            with self.subTest(environment=environment), self.assertRaises(ValueError):
                gcd_probe.require_ci_renderer(environment)
        self.assertEqual(gcd_probe.require_ci_renderer({
            'GRAFTTY_GHOSTTY_PACKAGE_PATH': '/renderer', 'GRAFTTY_REQUIRE_PAGED_HISTORY': '1'}), '/renderer')

    def test_driver_filter_ignores_a_source_filename_matching_its_suite_name(self):
        self.assertIsNotNone(re.search(gcd_probe.HARNESS,
            'GrafttyKitTests.DispatchWorkProbeTests/runBatch()/DispatchWorkProbeTests.swift:12:1'))
        self.assertIsNone(re.search(gcd_probe.HARNESS,
            'GrafttyKitTests.DispatchWorkProbeFixture/test()/DispatchWorkProbeTests.swift:12:1'))
        self.assertIsNone(re.search(gcd_probe.HARNESS,
            'GrafttyKitTests.DispatchWorkProbeTests/verifiesDiagnostic()/DispatchWorkProbeTests.swift:6:1'))

    def test_counts_threads_not_stack_weights_or_idle_workers(self):
        report = gcd_probe.parse_sample(SAMPLE)
        self.assertEqual(report['dispatchWorkers'], 2)
        self.assertEqual(report['blockedDispatchWorkers'], 2)
        self.assertEqual(report['idleWorkers'], 1)
        self.assertEqual(report['otherThreads'], 1)
        self.assertEqual([thread['id'] for thread in report['blocked']], ['10', '13'])
        self.assertIn('LeakingSuite', report['blocked'][0]['stack'])
        self.assertEqual(gcd_probe.parse_sample(SAMPLE.replace('    1 Thread_', '    200 Thread_')), report)

    def test_anonymous_dispatch_stack_does_not_turn_the_preceding_main_thread_into_a_worker(self):
        value = SAMPLE.replace('    1 Thread_10', '''    1 Thread_9   DispatchQueue_1: com.apple.main-thread  (serial)
      1 CFRunLoopRun
        1 mach_msg2_trap
    1 Thread_<multiple>''')
        report = gcd_probe.parse_sample(value)
        self.assertEqual(report['blockedDispatchWorkers'], 1)
        self.assertEqual(report['otherThreads'], 2)
        self.assertEqual(report['blockedAnonymousDispatchStacks'], 1)
        self.assertEqual(report['anonymousDispatchStacks'], 1)
        self.assertEqual([thread['id'] for thread in report['blocked']], ['13'])
        self.assertIn('LeakingSuite', report['anonymous'][0]['stack'])

    def test_rejects_empty_and_truncated_samples(self):
        for value in ['', 'sample: cannot examine process', 'Call graph:\n', SAMPLE.split('Total number')[0]]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                gcd_probe.parse_sample(value)

    def test_active_worker_is_not_called_blocked(self):
        value = SAMPLE.replace('semaphore_wait_trap', 'performComputation').replace('1 read\n', '1 doWork\n')
        report = gcd_probe.parse_sample(value)
        self.assertEqual(report['blockedDispatchWorkers'], 0)
        self.assertEqual(report['dispatchWorkers'], 2)
        self.assertEqual(report['unclassifiedDispatchWorkers'], 2)
        self.assertEqual(len(report['unclassified']), 2)

    def test_appkit_mach_message_wait_still_occupies_a_dispatch_worker(self):
        value = SAMPLE.replace('semaphore_wait_trap', 'mach_msg2_trap')
        report = gcd_probe.parse_sample(value)
        self.assertEqual(report['blockedDispatchWorkers'], 2)

    def test_diagnostic_exclusion_matches_a_function_and_not_its_source_filename(self):
        value = SAMPLE.replace('LeakingSuite.run()',
            'DispatchWorkProbeFixture.run() (in GrafttyPackageTests) DispatchWorkProbeTests.swift:173')
        value = value.replace('OtherSuite.run()', 'DispatchWorkProbeState.sample(suite:phase:)')
        report = gcd_probe.parse_sample(value)
        self.assertEqual(report['blockedDispatchWorkers'], 1)
        self.assertEqual(report['diagnosticThreads'], 1)
        self.assertEqual(report['blocked'][0]['id'], '10')

    def test_async_worker_header_identifies_dispatch_when_the_drain_frame_is_absent(self):
        value = SAMPLE.replace('Total number in stack', '''    1 Thread_14   DispatchQueue_15: com.apple.root.default-qos.cooperative  (concurrent)
      1 completeTaskWithClosure
        1 backgroundTask
          1 __semwait_signal
Total number in stack''')
        report = gcd_probe.parse_sample(value)
        self.assertEqual(report['blockedDispatchWorkers'], 3)
        self.assertEqual(report['blockedCooperativeWorkers'], 1)

    def test_summary_preserves_order_and_thread_identity_instead_of_blame_by_total(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, text in [('0001-before', SAMPLE.replace('Thread_10', 'Thread_90')),
                               ('0002-after', SAMPLE), ('0003-after', SAMPLE)]:
                (root / (name + '.sample.txt')).write_text(text)
            records = [
                {'suite': 'First', 'phase': 'before', 'sample': '0001-before.sample.txt', 'pid': 123},
                {'suite': 'First', 'phase': 'after', 'sample': '0002-after.sample.txt', 'pid': 123},
                {'suite': 'Second', 'phase': 'after', 'sample': '0003-after.sample.txt', 'pid': 123},
            ]
            rows = gcd_probe.summarize(root, records)
            self.assertEqual([row['suite'] for row in rows], ['First', 'First', 'Second'])
            self.assertEqual(rows[1]['newBlockedThreadIDs'], ['10'])
            self.assertEqual(rows[2]['newBlockedThreadIDs'], [])
            self.assertEqual(rows[1]['blockedDispatchWorkers'], 2)
            with self.assertRaises(FileNotFoundError):
                gcd_probe.summarize(root, [{'suite': 'Missing', 'phase': 'after', 'sample': 'absent', 'pid': 123}])

    def test_every_completed_suite_requires_a_sample_in_event_order(self):
        events = [{'kind': 'test', 'payload': {'kind': 'suite', 'id': name}} for name in ['First', 'Second']]
        events += [{'kind': 'event', 'payload': {'kind': 'testEnded', 'testID': name}} for name in ['First', 'Second']]
        records = [{'suite': '<baseline>', 'phase': 'before'}]
        records += [{'suite': name, 'phase': 'after'} for name in ['First', 'Second']]
        gcd_probe.verify_boundaries(events, records)
        for incomplete in [records[:2], records[1:], records[:1] + records[:0:-1]]:
            with self.assertRaises(ValueError):
                gcd_probe.verify_boundaries(events, incomplete)


if __name__ == '__main__':
    unittest.main()
