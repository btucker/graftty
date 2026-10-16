import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

from harness import Broker, InvariantFailure
from run import Run


class RunnerLifecycleTests(unittest.TestCase):
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
