import copy
import fcntl
import json
from pathlib import Path
import tempfile
import subprocess
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from preview_ui import (SOURCE, adapt_baseline_source, baseline_overlay, derived_data_lock,
                        evaluate, main, replace_source, require_clean_baseline_source,
                        run_phase, test_report_records)


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

    def test_explicit_local_baseline_is_allowed_under_shared_build_lock(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            arguments = ['preview_ui.py', '--output', str(directory / 'evidence'),
                         '--derived-data', str(directory / 'derived'), '--baseline', 'origin/main']
            with patch('sys.argv', arguments), \
                 patch.dict('os.environ', {'CI': 'false', 'GRAFTTY_RENDERER_CONTEXT': 'fixture',
                                           'GRAFTTY_GHOSTTY_PACKAGE_PATH': '/fixture'}), \
                 patch('preview_ui.run_validation', return_value=0, create=True) as validation:
                self.assertEqual(main(), 0)
            self.assertEqual(validation.call_args.args[0].baseline, 'origin/main')


class PreviewOverlaySafetyTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.repo = Path(temporary.name)
        self.source = self.repo / SOURCE
        self.source.parent.mkdir(parents=True)
        self.original = (PreviewBaselineTests.SOURCE + '// Preserve exact bytes: café\n').encode()
        self.source.write_bytes(self.original)
        self.git('init', '-q')
        self.git('add', '--', SOURCE)
        self.git('-c', 'user.name=Preview test', '-c', 'user.email=preview@example.invalid',
                 '-c', 'core.hooksPath=/dev/null', 'commit', '--no-gpg-sign', '-qm', 'Fixture')
        self.options = SimpleNamespace(output=self.repo / 'evidence', baseline='HEAD')
        self.options.output.mkdir()
        for replacement in (patch('preview_ui.REPO', self.repo),
                            patch('preview_ui.capture', side_effect=lambda command: self.git(*command[1:]).strip()),
                            patch('preview_ui.execute', side_effect=lambda command: (0, self.git(*command[1:])))):
            replacement.start()
            self.addCleanup(replacement.stop)

    def git(self, *arguments):
        result = subprocess.run(['git', *arguments], cwd=self.repo, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if result.returncode:
            raise RuntimeError(result.stderr)
        return result.stdout

    def test_requires_tracked_source_clean_in_both_index_and_worktree(self):
        self.assertEqual(require_clean_baseline_source(), self.original)
        self.source.write_bytes(self.original + b'// local edit\n')
        with self.assertRaisesRegex(RuntimeError, 'local changes'):
            require_clean_baseline_source()
        self.git('add', '--', SOURCE)
        with self.assertRaisesRegex(RuntimeError, 'local changes'):
            require_clean_baseline_source()
        self.git('rm', '--cached', '--', SOURCE)
        with self.assertRaises(RuntimeError):
            require_clean_baseline_source()
        self.assertTrue(self.source.read_bytes().endswith(b'// local edit\n'))

    def test_hidden_worktree_edits_and_changed_snapshot_are_rejected(self):
        self.git('update-index', '--assume-unchanged', '--', SOURCE)
        self.source.write_bytes(self.original + b'// hidden edit\n')
        self.assertEqual(self.git('status', '--porcelain=v1', '--', SOURCE), '')
        with self.assertRaisesRegex(RuntimeError, 'differs from HEAD'):
            require_clean_baseline_source()
        self.source.write_bytes(self.original)
        with self.assertRaisesRegex(RuntimeError, 'Source changed'):
            require_clean_baseline_source(expected=b'stale snapshot')

    def test_overlay_restores_bytes_and_mode_on_success_and_all_catchable_exits(self):
        self.source.chmod(0o640)
        for error in (None, RuntimeError('RED failed'), SystemExit('SIGTERM'), KeyboardInterrupt()):
            with self.subTest(error=type(error).__name__):
                summary = {}
                try:
                    with baseline_overlay(self.options, summary, self.original):
                        self.assertNotEqual(self.source.read_bytes(), self.original)
                        self.assertIn(b'.onDisappear', self.source.read_bytes())
                        if error is not None:
                            raise error
                except BaseException as caught:
                    self.assertIs(caught, error)
                self.assertEqual(self.source.read_bytes(), self.original)
                self.assertEqual(self.source.stat().st_mode & 0o777, 0o640)
                self.assertEqual((self.options.output / 'RootView.backup.swift').read_bytes(), self.original)
                self.assertTrue(summary['sourceRestored'])
                self.assertEqual(len(summary['baselineAdjustments']), 4)
                self.assertNotEqual(summary['baselineSourceHash'], summary['baselineOriginalSourceHash'])

    def test_overlay_guard_rejects_edit_since_initial_validation_without_overwriting_it(self):
        require_clean_baseline_source()
        edited = self.original + b'// edit during simulator boot\n'
        self.source.write_bytes(edited)
        with self.assertRaises(RuntimeError):
            with baseline_overlay(self.options, {}, self.original):
                self.fail('Dirty source must never enter RED')
        self.assertEqual(self.source.read_bytes(), edited)
        self.assertFalse((self.options.output / 'RootView.backup.swift').exists())

    def test_restoration_mismatch_prevents_continuing_to_green_and_keeps_backup(self):
        summary = {}
        writes = 0

        def fail_restore(source, data):
            nonlocal writes
            writes += 1
            if writes == 1:
                replace_source(source, data)

        with patch('preview_ui.replace_source', side_effect=fail_restore):
            with self.assertRaisesRegex(RuntimeError, 'GREEN will not run'):
                with baseline_overlay(self.options, summary, self.original):
                    pass
                self.fail('GREEN must not follow failed restoration')
        self.assertFalse(summary['sourceRestored'])
        self.assertIn('sourceRestoreError', summary)
        self.assertEqual((self.options.output / 'RootView.backup.swift').read_bytes(), self.original)

    def test_derived_data_lock_matches_provider_runner_and_releases_after_error(self):
        derived = self.repo / 'cache' / 'ios-derived'
        lock_path = derived.parent / (derived.name + '.lock')
        with self.assertRaisesRegex(RuntimeError, 'interrupted'):
            with derived_data_lock(derived):
                self.assertTrue(derived.is_dir())
                with lock_path.open('a') as competitor:
                    with self.assertRaises(BlockingIOError):
                        fcntl.flock(competitor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                raise RuntimeError('interrupted')
        with lock_path.open('a') as competitor:
            fcntl.flock(competitor, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_main_preserves_cache_symlink_for_provider_lock_identity(self):
        actual = self.repo / 'volume' / 'ios-build'
        actual.mkdir(parents=True)
        alias = self.repo / 'ios-cache-link'
        alias.symlink_to(actual, target_is_directory=True)
        lock_path = alias.parent / (alias.name + '.lock')

        def validate(options):
            self.assertEqual(options.derived_data, alias)
            self.assertFalse((actual.parent / (actual.name + '.lock')).exists())
            with lock_path.open('a') as provider:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(provider, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return 0

        arguments = ['preview_ui.py', '--output', str(self.repo / 'local-evidence'),
                     '--derived-data', str(alias), '--baseline', 'HEAD']
        with patch('sys.argv', arguments), \
             patch.dict('os.environ', {'CI': 'false', 'GRAFTTY_RENDERER_CONTEXT': 'fixture',
                                       'GRAFTTY_GHOSTTY_PACKAGE_PATH': '/fixture'}), \
             patch('preview_ui.run_validation', side_effect=validate):
            self.assertEqual(main(), 0)


if __name__ == '__main__':
    unittest.main()
