import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

from harness import Broker, InvariantFailure
from run import Run, prepare_home


class RunnerLifecycleTests(unittest.TestCase):
    def test_reentry_waits_for_current_rows_and_keeps_both_native_observations(self):
        runner = Run.__new__(Run)
        runner.invariant_failures = []
        runner.summary = {'assertions': []}
        physical = 'ROW-000001 retained output\nROW-000002 retained output\n\n› Ask Codex to do anything\n? for shortcuts'
        healthy = {'physicalRows': physical, 'pagedGridMismatches': '', 'grid': '41x5', 'nativeGrid': '41x5',
                   'keyboardTop': '500', 'terminalBottom': '442'}
        stale = {**healthy, 'physicalRows': physical.replace('ROW-000001 retained', 'ROW-000001 stale')}
        runner.snapshot = Mock(side_effect=[stale, healthy])
        runner.act = Mock(return_value={'authoritativeText': physical})
        with tempfile.TemporaryDirectory() as directory, patch('run.time.sleep'):
            runner.root = Path(directory)
            runner.check_mobile_reentry('codex', 'reentry-0')
            self.assertEqual(healthy, json.loads((runner.root / 'codex-reentry-0.json').read_text()))
            self.assertEqual(physical, json.loads((runner.root / 'codex-reentry-0-mac.json').read_text())['authoritativeText'])
        self.assertEqual(2, runner.snapshot.call_count)
        self.assertFalse(runner.invariant_failures)
        self.assertEqual('passed', runner.summary['assertions'][0]['status'])

    def test_reentry_records_a_persistent_payload_failure_after_settling(self):
        runner = Run.__new__(Run)
        runner.invariant_failures = []
        runner.summary = {'assertions': []}
        physical = 'ROW-000001 stale output\nROW-000002 retained output\n\n› Ask Codex to do anything\n? for shortcuts'
        runner.snapshot = Mock(return_value={'physicalRows': physical, 'pagedGridMismatches': '',
            'grid': '41x5', 'nativeGrid': '41x5', 'keyboardTop': '500', 'terminalBottom': '442'})
        runner.act = Mock(return_value={'authoritativeText': physical.replace('stale output', 'retained output')})
        with tempfile.TemporaryDirectory() as directory, patch('run.time.monotonic', side_effect=[0, 6]):
            runner.root = Path(directory)
            runner.check_mobile_reentry('codex', 'reentry-0')
        self.assertEqual(1, len(runner.invariant_failures))
        self.assertIn('logical row content', runner.invariant_failures[0]['error'])
        self.assertEqual('failed', runner.summary['assertions'][0]['status'])

    def test_provider_home_does_not_supply_terminal_capabilities(self):
        with tempfile.TemporaryDirectory() as directory:
            env = prepare_home(Path(directory), 'http://127.0.0.1:1234', Path('/bin/echo'), Path('/bin/echo'))
        for key in ('TERM', 'COLORTERM', 'TERM_PROGRAM', 'NO_COLOR', 'FORCE_COLOR'):
            self.assertNotIn(key, env, f'{key} would mask the production terminal environment')

    def test_mobile_build_finishes_before_native_deadline_starts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            options = SimpleNamespace(cli=Path('/bin/echo'), codex=Path('/bin/echo'), claude=Path('/bin/echo'),
                zmx=Path('/bin/echo'), rows=100, seed=1, mac_only=False, cache=root / 'cache', ghostty_package=None)
            server = Mock(endpoint='http://127.0.0.1:1234', broker=Broker())
            with patch('run.tempfile.mkdtemp', return_value=directory), patch('run.IntegrationServer', return_value=server):
                runner = Run(options)
            events = []
            with patch('run.execute', return_value='fixture-version'), \
                 patch('run.subprocess.run', return_value=SimpleNamespace(stdout=b'')), \
                 patch.object(runner, 'prepare_mobile', side_effect=lambda: events.append('mobile-build-finished')), \
                 patch.object(runner, 'spawn', side_effect=lambda *args: events.append('native-test-started')), \
                 patch.object(runner, 'wait_registered'), \
                 patch.object(runner, 'scenarios', side_effect=lambda: events.append('scenarios')):
                runner.run()
            self.assertEqual(['mobile-build-finished', 'native-test-started', 'scenarios'], events)
            self.assertEqual('passed', json.loads((root / 'result.json').read_text())['result'])

    def test_generated_content_failure_is_not_hidden_by_nonblank_text(self):
        runner = Run.__new__(Run)
        runner.invariant_failures = []
        runner.summary = {}
        runner.act = Mock(return_value={'buffer': 'ROW-000001 damaged', 'authoritativeText': 'ROW-000001 expected'})
        with self.assertRaises(InvariantFailure):
            runner.check_generated_content('claude')
        runner.act.return_value = {'buffer': 'plain TUI', 'authoritativeText': 'plain TUI'}
        runner.check_generated_content('claude')
        self.assertEqual('notObservable', runner.summary['generatedContentChecks'][-1]['status'])
        runner.invariant_failures = [{'agent': 'claude'}]
        runner.act.reset_mock()
        runner.check_generated_content('claude')
        runner.act.assert_not_called()
        self.assertEqual('baselineFailed', runner.summary['generatedContentChecks'][-1]['status'])
