import copy
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from preview_ui import adapt_baseline_source, evaluate, run_phase, test_report_records


LIFECYCLE = 'GrafttyMobileBrowserTests/RemoteBrowserButtonTests/nativePreviewPreservesTerminalConnection(embedded:retained:)'
FOCUS = 'GrafttyMobileKitTests/TerminalPaneViewTests/focusRequestNotConsumedUntilTerminalCanFocus()'
PAIRS = ('false, false', 'false, true', 'true, false', 'true, true')


def records(red=False):
    result = [{'id': LIFECYCLE + '[' + pair + ']',
               'status': 'Failure' if red else 'Success',
               'failures': ['Expectation failed: (socket.closeCount → 1) == 0'] if red else []}
              for pair in PAIRS]
    if not red:
        result.append({'id': FOCUS, 'status': 'Success', 'failures': []})
    return result


def evaluate_cases(cases, red=False, code=None, errors=(), failures=()):
    return evaluate(cases, errors, failures, (65 if red else 0) if code is None else code, red)[0]


class PreviewEvidenceTests(unittest.TestCase):
    def test_green_requires_all_four_distinct_layout_retention_cases(self):
        self.assertTrue(evaluate_cases(records()))
        for index in range(4):
            with self.subTest(missing=PAIRS[index]):
                cases = records()
                del cases[index]
                self.assertFalse(evaluate_cases(cases))

    def test_duplicates_cannot_replace_an_unexecuted_case(self):
        cases = records()
        cases[3] = copy.deepcopy(cases[0])
        self.assertFalse(evaluate_cases(cases))

    def test_wrong_arguments_and_method_names_cannot_count(self):
        for wrong in ('[false, nil]', '[true, true, false]', '[false, False]', '', '[true, true]/retry'):
            with self.subTest(wrong=wrong):
                cases = records()
                cases[3]['id'] = LIFECYCLE + wrong
                self.assertFalse(evaluate_cases(cases))
        cases = records()
        cases[0]['id'] = cases[0]['id'].replace('nativePreviewPreserves', 'not_nativePreviewPreserves')
        self.assertFalse(evaluate_cases(cases))

    def test_zero_skipped_unknown_and_failed_execution_cannot_pass_green(self):
        self.assertFalse(evaluate_cases([]))
        for status in ('Skipped', 'Failure', 'Expected Failure', 'unknown', ''):
            with self.subTest(status=status):
                cases = records()
                cases[0]['status'] = status
                self.assertFalse(evaluate_cases(cases))
        self.assertFalse(evaluate_cases(records(), code=65))
        self.assertFalse(evaluate_cases(records(), errors=[{'message': 'build failed'}]))

    def test_focus_case_must_execute_once_under_exact_identifier(self):
        self.assertFalse(evaluate_cases(records()[:-1]))
        cases = records()
        cases[-1]['id'] += 'SimilarName'
        self.assertFalse(evaluate_cases(cases))
        self.assertFalse(evaluate_cases(records() + [records()[-1]]))

    def test_red_requires_targeted_assertion_in_every_argument_case(self):
        self.assertTrue(evaluate_cases(records(red=True), red=True))
        for index in range(4):
            with self.subTest(case=PAIRS[index]):
                cases = records(red=True)
                cases[index]['failures'] = ['Timed out waiting for native Quick Look presentation']
                # An aggregate method failure cannot prove this argument failed
                # for retention rather than setup, even if another case did.
                aggregate = [{'testCaseName': LIFECYCLE,
                              'message': 'Expectation failed: socket.closeCount == 0'}]
                self.assertFalse(evaluate_cases(cases, red=True, failures=aggregate))

    def test_red_rejects_success_exit_skips_duplicates_and_no_assertions(self):
        self.assertFalse(evaluate_cases(records(red=True), red=True, code=0))
        for status in ('Success', 'Skipped', 'Expected Failure', 'unknown'):
            cases = records(red=True)
            cases[0]['status'] = status
            self.assertFalse(evaluate_cases(cases, red=True))
        cases = records(red=True)
        cases[3] = copy.deepcopy(cases[0])
        self.assertFalse(evaluate_cases(cases, red=True))
        for message in ('Timed out waiting for socket.closeCount',
                        'Expectation failed: unrelatedCloseCount == 0',
                        'Expectation failed: other.client.isOwnerCopy'):
            cases = records(red=True)
            cases[0]['failures'] = [message]
            self.assertFalse(evaluate_cases(cases, red=True))

    def test_green_rejects_failure_messages_even_after_successful_retry(self):
        cases = records()
        cases[0]['failures'] = ['Expectation failed: socket.closeCount == 0']
        self.assertFalse(evaluate_cases(cases))


def report(red=False):
    # Shape verified against Xcode 26 xcresulttool test-results output. Legacy
    # object output repeats the method identifier and loses argument values.
    arguments = []
    for pair in PAIRS:
        arguments.append({'nodeType': 'Arguments', 'name': pair,
                          'result': 'Failed' if red else 'Passed',
                          'children': [{'nodeType': 'Failure Message',
                                        'name': 'Expectation failed: socket.closeCount == 0'}] if red else []})
    return {'testNodes': [{'nodeType': 'Test Plan', 'name': 'GrafttyMobile', 'children': [
        {'nodeType': 'Unit test bundle', 'name': 'GrafttyMobileBrowserTests', 'children': [
            {'nodeType': 'Test Suite', 'name': 'RemoteBrowserButtonTests', 'children': [
                {'nodeType': 'Test Case', 'nodeIdentifier': LIFECYCLE.split('/', 1)[1],
                 'name': '@spec PREVIEW-2.10: ...', 'result': 'Failed' if red else 'Passed',
                 'children': arguments}]}]},
        {'nodeType': 'Unit test bundle', 'name': 'GrafttyMobileKitTests', 'children': [
            {'nodeType': 'Test Case', 'nodeIdentifier': FOCUS.split('/', 1)[1],
             'name': 'focus requests...', 'result': 'Passed'}]}]}]}


class PreviewReportTests(unittest.TestCase):
    def test_argument_leaves_are_identified_without_counting_parent_summary(self):
        parsed = test_report_records(report())
        self.assertEqual(parsed, records())
        self.assertTrue(evaluate_cases(parsed))

    def test_assertion_messages_stay_with_their_argument_case(self):
        tree = report(red=True)
        tree['testNodes'][0]['children'].pop()  # RED selects only lifecycle.
        parsed = test_report_records(tree)
        self.assertEqual(len(parsed), 4)
        self.assertTrue(evaluate_cases(parsed, red=True))
        arguments = tree['testNodes'][0]['children'][0]['children'][0]['children'][0]['children']
        arguments[2]['children'] = [{'nodeType': 'Failure Message', 'name': 'Setup timed out'}]
        self.assertFalse(evaluate_cases(test_report_records(tree), red=True))

    def test_parent_summary_without_argument_execution_is_rejected(self):
        tree = report()
        tree['testNodes'][0]['children'][0]['children'][0]['children'][0]['children'] = []
        self.assertFalse(evaluate_cases(test_report_records(tree)))

    def test_duplicate_argument_metadata_is_rejected(self):
        tree = report()
        arguments = tree['testNodes'][0]['children'][0]['children'][0]['children'][0]['children']
        arguments[3] = copy.deepcopy(arguments[0])
        self.assertFalse(evaluate_cases(test_report_records(tree)))

    def test_missing_or_skipped_argument_result_is_not_success(self):
        for result in (None, 'Skipped', 'unknown'):
            tree = report()
            case = tree['testNodes'][0]['children'][0]['children'][0]['children'][0]['children'][0]
            if result is None:
                del case['result']
            else:
                case['result'] = result
            self.assertFalse(evaluate_cases(test_report_records(tree)))

    def test_run_phase_uses_and_saves_exact_report_instead_of_legacy_count(self):
        for tree, passed, count in ((report(), True, 5), ({'testNodes': []}, False, 0)):
            with self.subTest(passed=passed), tempfile.TemporaryDirectory() as temporary:
                directory = Path(temporary)
                options = SimpleNamespace(output=directory, derived_data=directory / 'derived',
                                          source_packages=None, timeout=10)
                with patch.dict('os.environ', {'GRAFTTY_RENDERER_CONTEXT': 'fixture'}), \
                     patch('preview_ui.execute', return_value=(0, '')), \
                     patch('preview_ui.read_result', return_value=(records(), [], [])), \
                     patch('preview_ui.capture', return_value=json.dumps(tree)) as capture:
                    result = run_phase('green', options, 'fixture-simulator')
                self.assertEqual(result['passed'], passed)
                self.assertEqual(result['executedCount'], count)
                self.assertIn('-only-testing:' + LIFECYCLE, result['command'])
                self.assertEqual(json.loads((directory / 'green' / 'xcresult-test-report.json').read_text()), tree)
                self.assertIn('test-results', capture.call_args.args[0])


class PreviewBaselineTests(unittest.TestCase):
    SOURCE = '''struct SingleSessionView {
    private let remoteConnectionProvider: RemoteConnectionProvider?
    init(
        remoteConnectionProvider: RemoteConnectionProvider? = nil
    ) {
        self.remoteConnectionProvider = remoteConnectionProvider
    }
    var body: some View {
        RemoteOpenButton(
                                     browserConnectionReady: connection == .live,
                                     isPaneFocused: isPaneFocused)
        .onDisappear {
            client?.stop()
            client = nil
        }
    }
}
'''

    def test_adapter_only_adds_optional_transport_seam_and_preserves_teardown(self):
        source, adjustments = adapt_baseline_source(self.SOURCE)
        self.assertEqual(len(adjustments), 4)
        self.assertIn('.onDisappear {\n            client?.stop()\n            client = nil\n        }', source)
        self.assertNotIn('ViewAttachmentObserver', source)
        self.assertNotIn('controlAttachmentID', source)
        self.assertIn('previewManagementTransport: ((WorktreeManagementRequest, Host) async throws -> WorktreeManagementResponse)? = nil', source)
        self.assertIn('self.previewManagementTransport = previewManagementTransport', source)
        self.assertIn('managementTransport: previewManagementTransport,', source)
        # A baseline already carrying the test seam must not gain duplicate
        # parameters or duplicate initialization on another validation run.
        self.assertEqual(adapt_baseline_source(source), (source, []))

    def test_adapter_rejects_missing_or_ambiguous_anchors(self):
        with self.assertRaises(ValueError):
            adapt_baseline_source(self.SOURCE.replace('private let remoteConnectionProvider',
                                                     'private let renamedConnectionProvider'))
        with self.assertRaises(ValueError):
            adapt_baseline_source(self.SOURCE + self.SOURCE)


if __name__ == '__main__':
    unittest.main()
